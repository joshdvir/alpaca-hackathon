# frozen_string_literal: true

# SubmitOrdersActivity — Overnight Reversal strategy. Walks the
# serialized Plan from BuildPlanActivity and places each order via
# PortfolioManager. Two buckets:
#
#   winners → single-leg ATM 0DTE long call (buy_to_open)
#   losers  → multi-leg bear call CREDIT SPREAD (mleg):
#              • sell_to_open short call  (target delta ~0.20)
#              • buy_to_open  long  call  (short_strike + spread_width)
#              • net limit price = -(short_premium − long_premium)
#                (negative = credit, per Trader parser convention)
#
# The bear call spread has a buy_to_open covering leg, so it satisfies
# the level-3 single-leg naked-cover rule (see PortfolioManager#level_violation_reason
# and #multi_leg_side_allowed?). No risk of naked sell_to_open.
#
# For 0DTE selection:
#   • Use expiration_date = today (live session).
#   • Find a chain with quote with the existing 6-attempt widening
#     strategy (reused from mid_band_movers).
#   • Winners: pick strike closest to spot.
#   • Losers:  pick the lowest-OOM short strike whose delta is
#              closest to 0.20 (default — configurable). Long strike
#              = short_strike + cfg['spread_width']. If a Greeks-
#              carrying snapshot is unavailable we fall back to "short
#              strike = ceil(spot) + 1 strike step" (typically 1 strike
#              above spot for OTM call).
#
# If the activity can't find a chain with a positive premium for a
# symbol, that name is **dropped** (per user decision: "drop it and
# go"). The remaining names still get orders; budget per name stays
# as planned (we don't rebalance the freed budget).
#
# Each outcome is reported back to the parent workflow so the
# CloseWorkflow child can decide what to close.

module OvernightReversal
  class SubmitOrdersActivity < ApplicationActivity
    activity_name 'OvernightSubmitOrdersActivity'

    def execute(plan, ctx = {})
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id] || 'ovn'
      started = Time.current
      activity.logger.info "[activity:start] SubmitOrdersActivity workflow_id=#{workflow_id}"

      cfg = (TradingConfig.fetch(:overnight_reversal) || {}).deep_stringify_keys
      outcomes = []

      plan = OvernightReversal::Plan.from_h(plan) unless plan.is_a?(OvernightReversal::Plan)
      p = plan

      if p.skipped
        activity.logger.info "[activity:done] SubmitOrdersActivity workflow_id=#{workflow_id} " \
                          "skipped=#{p.skipped_reason.inspect} (no orders submitted)"
        return { orders: [], skipped: true, skipped_reason: p.skipped_reason }
      end

      p.winners.each do |w|
        outcomes << submit_winner(w, cfg: cfg, workflow_id: workflow_id)
      end

      p.losers.each do |l|
        outcomes << submit_loser(l, cfg: cfg, workflow_id: workflow_id)
      end

      activity.logger.info(
        "[activity:done] SubmitOrdersActivity workflow_id=#{workflow_id} " \
        "winners=#{outcomes.count { |o| o[:bucket] == 'winner' }} " \
        "losers=#{outcomes.count { |o| o[:bucket] == 'loser' }} " \
        "submitted=#{outcomes.count { |o| o[:status] == 'submitted' }} " \
        "no_chain=#{outcomes.count { |o| o[:status] == 'no_chain' }} " \
        "rejected=#{outcomes.count { |o| o[:status] == 'rejected_by_risk' }} " \
        "broker_err=#{outcomes.count { |o| o[:status] == 'broker_error' }} " \
        "elapsed_ms=#{((Time.current - started) * 1000).to_i}"
      )
      { orders: outcomes }
    rescue StandardError => e
      activity.logger.error "[activity:done] SubmitOrdersActivity FAILED: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
      { orders: [], error: "#{e.class}: #{e.message}" }
    end

    private

    # ----- WINNERS: single-leg long call -----

    def submit_winner(order, cfg:, workflow_id:)
      symbol      = order.symbol
      cash        = order.cash_allocated
      # Use the per-order dte_target populated by BuildPlanActivity
      # during the runtime eligibility probe (the probe walks the
      # configured `dte_target` list and stamps the chosen DTE on
      # each order). Fall back to cfg only if the field is absent
      # (e.g. fixtures that bypass the probe).
      dte_targets = []
      if order.respond_to?(:dte_target) && order.dte_target
        dte_targets = Array(order.dte_target).map(&:to_i).reject(&:negative?).uniq
      end
      if dte_targets.empty?
        cfg_val = cfg.fetch('dte_target', 0)
        dte_targets = Array(cfg_val).map(&:to_i).reject(&:negative?).uniq
        dte_targets = [0] if dte_targets.empty?
      end

      option_symbol, premium, ask_size = find_atm_call(symbol, dte_targets.first)
      if option_symbol.nil? || premium.nil? || premium <= 0
        activity.logger.warn "[ovn:submit_winner] #{symbol}: dte=#{dte_targets} ATM chain empty — dropping (per probe)"
        return { symbol: symbol, bucket: 'winner', status: 'no_chain' }
      end

      contract_cost = premium.to_d * 100
      qty = (cash / contract_cost).floor.to_i
      # Apply the max_position_pct cap so a single survivor can't blow
      # 10% of equity on its own. The cap is on the position DEBIT
      # (qty × contract_cost), not on qty itself, so convert back.
      equity      = (PortfolioSnapshot.order(created_at: :desc).first&.equity || cash.to_f).to_f
      max_pos_pct = TradingConfig.fetch(:risk_limits, :max_position_pct).to_f
      cap_dollars = (equity * max_pos_pct)
      cap_qty     = cap_dollars.zero? ? 0 : (cap_dollars / contract_cost).floor.to_i
      qty = cap_qty if qty > cap_qty
      # Cap on a per-contract basis. Most brokers reject large 0DTE
      # orders on illiquid tickers; capping qty at this value avoids
      # partial fills where the broker accepts a small fraction and
      # the rest of the order is silently dropped. Tune per symbol
      # class if needed.
      max_qty_per_order = cfg['max_qty_per_order'].to_i
      max_qty_per_order = 10 if max_qty_per_order <= 0  # safe default
      qty = max_qty_per_order if qty > max_qty_per_order
      # Per-symbol broker inventory cap: the chain's `as` field
      # (ask size) is the maximum number of contracts the broker has
      # at the ask price. Asking for more than this is silently
      # capped by the broker and the surplus is dropped. The ask
      # size is per-strike; we use the strike the probe chose.
      # `as=0` means no liquidity at the ask — drop to a no_chain.
      if ask_size.to_i > 0
        qty = ask_size.to_i if qty > ask_size.to_i
      else
        activity.logger.warn "[ovn:submit_winner] #{symbol}: ask_size=0 — broker has no liquidity at the ask, dropping"
        return { symbol: symbol, bucket: 'winner', status: 'no_chain' }
      end
      if qty < 1
        activity.logger.warn "[ovn:submit_winner] #{symbol}: cash $#{cash.to_f.round(2)} too small for 1 contract @ $#{premium} (cap=#{cap_qty} @ #{max_pos_pct} of $#{equity.round(0)}, qty_cap=#{max_qty_per_order}, broker_size=#{ask_size})"
        return { symbol: symbol, bucket: 'winner', status: 'cash_too_small' }
      end
      activity.logger.info "[ovn:submit_winner] #{symbol}: qty=#{qty} (cash=#{cash.round(2)} cap=#{cap_qty} qty_cap=#{max_qty_per_order} broker_size=#{ask_size})"

      proposal = TradeProposal.create!(
        ticker:         symbol,
        kind:           'new',
        origin:         'overnight_reversal',
        strategy_type:  'long_call',
        legs: [
          {
            'side'         => 'buy_to_open',
            'ratio_qty'    => 1,  # GCD constraint — broker wants ratio_qty=1 (see spread path)
            'qty'          => qty,  # absolute position size lives here; PortfolioManager reads this
            'option_symbol'=> option_symbol,
            'limit_price'  => premium.to_f.round(4)
          }
        ],
        max_loss: (qty * contract_cost).to_f,
        max_profit: 0,
        rationale: JSON.generate(
          'origin'   => 'overnight_reversal',
          'bucket'   => 'winner',
          'human'    => "0DTE ATM long call (winner of yesterday's ranking)"
        ),
        status: 'pending'
      )

      decision = safe_risk(proposal)
      if decision.nil? || decision.rejected?
        reasons = decision&.reasons || ['risk_check_failed']
        activity.logger.warn "[ovn:submit_winner] #{symbol} qty=#{qty} -> rejected_by_risk: #{reasons.inspect}"
        proposal.update!(status: 'rejected', rejection_reason: reasons.join('; '))
        return { symbol: symbol, bucket: 'winner', status: 'rejected_by_risk',
                 proposal: proposal.id, reasons: reasons }
      end

      result = safe_portfolio(proposal)
      if result.nil? || !result.ok?
        proposal.update!(status: 'cancelled') if proposal.status == 'risk_approved'
        reasons = result&.reasons || ['portfolio_executor_failed']
        activity.logger.warn "[ovn:submit_winner] #{symbol} qty=#{qty} -> broker_error: #{reasons.inspect}"
        return { symbol: symbol, bucket: 'winner', status: 'broker_error',
                 proposal: proposal.id, reasons: reasons }
      end

      proposal.update!(status: 'portfolio_approved') if proposal.status == 'risk_approved'
      tag_order(result.order, origin: 'overnight_reversal', bucket: 'winner', qty: qty)

      {
        symbol:         symbol,
        bucket:         'winner',
        status:         'submitted',
        proposal:       proposal.id,
        order:          result.order&.id,
        option_symbol:  option_symbol,
        qty:            qty,
        premium:        premium.to_f.round(4)
      }
    end

    # Disabled: long_call fallback for degenerate spreads. Per strategy
    # decision (2026-09-03), losers must be shorts only — falling back
    # to a long call would double-up directionally with winners. We
    # now drop losers with `no_bear_legs` status instead.
    def submit_loser_as_long_call(order, dte, cfg, workflow_id)
      symbol  = order.symbol
      cash    = order.cash_allocated
      dte_targets = [dte].compact
      dte_targets = [] if dte_targets.empty?

      option_symbol, premium, ask_size = find_atm_call(symbol, dte_targets.first)
      if option_symbol.nil? || premium.nil? || premium <= 0
        activity.logger.warn "[ovn:submit_loser:long_fallback] #{symbol}: no chain at dte=#{dte_targets.first} — dropping"
        return { symbol: symbol, bucket: 'loser', status: 'no_chain' }
      end

      contract_cost = premium.to_d * 100
      qty = (cash / contract_cost).floor.to_i
      equity = (PortfolioSnapshot.order(created_at: :desc).first&.equity || cash.to_f).to_f
      max_pos_pct = TradingConfig.fetch(:risk_limits, :max_position_pct).to_f
      cap_dollars = (equity * max_pos_pct)
      cap_qty = cap_dollars.zero? ? 0 : (cap_dollars / contract_cost).floor.to_i
      qty = cap_qty if qty > cap_qty
      max_qty = cfg['max_qty_per_order'].to_i
      max_qty = 10 if max_qty <= 0
      qty = max_qty if qty > max_qty
      if qty < 1
        return { symbol: symbol, bucket: 'loser', status: 'cash_too_small' }
      end

      proposal = TradeProposal.create!(
        ticker: symbol, kind: 'new', origin: 'overnight_reversal',
        strategy_type: 'long_call',
        legs: [{
          'side' => 'buy_to_open', 'ratio_qty' => 1, 'qty' => qty,
          'option_symbol' => option_symbol, 'limit_price' => premium.to_f.round(4)
        }],
        max_loss: (qty * contract_cost).to_f, max_profit: 0,
        rationale: JSON.generate(
          'origin' => 'overnight_reversal', 'bucket' => 'loser',
          'fallback' => 'long_call', 'dte' => dte_targets.first,
          'human' => "Loser fell back to long call (degenerate spread)"
        ),
        status: 'pending'
      )

      decision = safe_risk(proposal)
      if decision.nil? || decision.rejected?
        proposal.update!(status: 'rejected', rejection_reason: (decision&.reasons || ['risk_check_failed']).join('; '))
        return { symbol: symbol, bucket: 'loser', status: 'rejected_by_risk',
                 proposal: proposal.id, reasons: decision&.reasons || ['risk_check_failed'] }
      end

      result = safe_portfolio(proposal)
      if result.nil? || !result.ok?
        reasons = result&.reasons || ['portfolio_executor_failed']
        activity.logger.warn "[ovn:submit_loser:long_fallback] #{symbol} -> broker_error: #{reasons.inspect}"
        proposal.update!(status: 'cancelled') if proposal.status == 'risk_approved'
        return { symbol: symbol, bucket: 'loser', status: 'broker_error',
                 proposal: proposal.id, reasons: reasons }
      end

      proposal.update!(status: 'portfolio_approved') if proposal.status == 'risk_approved'
      tag_order(result.order, origin: 'overnight_reversal', bucket: 'loser', qty: qty)
      activity.logger.info "[ovn:submit_loser:long_fallback] #{symbol} qty=#{qty} -> submitted as long call"

      {
        symbol: symbol, bucket: 'loser', status: 'submitted',
        proposal: proposal.id, order: result.order&.id,
        option_symbol: option_symbol, qty: qty,
        premium: premium.to_f.round(4), fallback: 'long_call'
      }
    rescue StandardError => e
      activity.logger.warn "[ovn:submit_loser:long_fallback] #{symbol} raised: #{e.class}: #{e.message}"
      { symbol: symbol, bucket: 'loser', status: 'no_chain' }
    end

    # ----- LOSERS: bear call credit spread (multi-leg mleg) -----

    def submit_loser(order, cfg:, workflow_id:)
      symbol    = order.symbol
      cash      = order.cash_allocated
      width     = order.width.to_f.positive? ? order.width.to_f : cfg.fetch('spread_width', 5.0).to_f
      dte_targets = []
      if order.respond_to?(:dte_target) && order.dte_target
        dte_targets = Array(order.dte_target).map(&:to_i).reject(&:negative?).uniq
      end
      if dte_targets.empty?
        cfg_val = cfg.fetch('dte_target', 0)
        dte_targets = Array(cfg_val).map(&:to_i).reject(&:negative?).uniq
        dte_targets = [0] if dte_targets.empty?
      end

      spot = fetch_underlying_price(symbol)
      if spot.nil? || spot <= 0
        activity.logger.warn "[ovn:submit_loser] #{symbol}: spot price unavailable — dropping"
        return { symbol: symbol, bucket: 'loser', status: 'no_chain' }
      end

      short, short_leg, long_leg = find_bear_call_legs(
        symbol: symbol,
        spot:   spot,
        dte:    dte_targets.first,
        width:  width,
        cfg:    cfg
      )
      if short.nil?
        activity.logger.warn "[submit_loser] #{symbol}: bear-call chain empty — dropping (no fallback)"
        return { symbol: symbol, bucket: 'loser', status: 'no_bear_legs',
                 reason: 'chain_empty' }
      end

      short_premium = short_leg[:premium]
      long_premium  = long_leg[:premium]
      net_credit    = short_premium - long_premium
      min_credit    = width * cfg.fetch('min_credit_to_width', 0.05).to_f

      if net_credit <= 0
        # The "credit spread" came back as a net-debit. We will NOT
        # fall back to long_call — long direction in the loser bucket
        # would double-up with winners. Drop the name entirely so
        # the loser bucket stays 100% short.
        activity.logger.warn "[submit_loser] #{symbol}: net_debit $#{(net_credit.abs).round(4)} (short=$#{short_premium.round(4)} long=$#{long_premium.round(4)}) — dropping"
        return { symbol: symbol, bucket: 'loser', status: 'no_bear_legs',
                 reason: 'net_debit', net_credit: net_credit.to_f.round(4) }
      end
      if net_credit < min_credit
        activity.logger.warn "[submit_loser] #{symbol}: credit $#{net_credit.round(4)} < min_credit $#{min_credit.round(4)} — dropping"
        return { symbol: symbol, bucket: 'loser', status: 'credit_too_small' }
      end

      # qty sizing with two caps:
      #   1. cash-derived max (per the planner's per-name cash budget)
      #   2. max_position_pct cap: max_loss_per_name = equity × pct
      #   3. max_qty_per_order: hard cap on absolute count (broker
      #      partial-fill safety on illiquid tickers)
      # All three apply so a single survivor doesn't blow any cap.
      max_loss_per = width * 100
      equity = (PortfolioSnapshot.order(created_at: :desc).first&.equity || cash.to_f).to_f
      max_pos_pct = TradingConfig.fetch(:risk_limits, :max_position_pct).to_f
      max_loss_cap = (equity * max_pos_pct).floor
      qty = (cash.to_d / BigDecimal(max_loss_per.to_s)).floor.to_i
      qty = (max_loss_cap / max_loss_per).floor.to_i if qty * max_loss_per > max_loss_cap
      max_qty_per_order = cfg['max_qty_per_order'].to_i
      max_qty_per_order = 10 if max_qty_per_order <= 0
      qty = max_qty_per_order if qty > max_qty_per_order
      # Per-symbol broker inventory cap: the chain's `bs`/`as` fields
      # cap how many contracts the broker will accept at our chosen
      # strikes. A spread needs both legs to have at least 1 contract
      # available, so we cap qty at min(short_leg[:ask_size], long_leg[:ask_size]).
      spread_size = [short_leg[:ask_size].to_i, long_leg[:ask_size].to_i].min
      spread_size = 0 if spread_size < 1
      if spread_size > 0
        qty = spread_size if qty > spread_size
      else
        activity.logger.warn "[submit_loser] #{symbol}: spread_size=0 — broker has no liquidity at one leg, dropping"
        return { symbol: symbol, bucket: 'loser', status: 'no_chain' }
      end
      if qty < 1
        activity.logger.warn "[submit_loser] #{symbol}: cash $#{cash.to_f.round(2)} too small for 1 spread @ max_loss $#{max_loss_per.round(2)} (equity $#{equity.round(0)} × max_pos_pct=#{max_pos_pct}, qty_cap=#{max_qty_per_order}, broker_size=#{spread_size})"
        return { symbol: symbol, bucket: 'loser', status: 'cash_too_small' }
      end
      activity.logger.info "[ovn:submit_loser] #{symbol}: qty=#{qty} (cash=#{cash.round(2)} cap=#{max_loss_cap / max_loss_per} qty_cap=#{max_qty_per_order} broker_size=#{spread_size})"

      proposal = TradeProposal.create!(
        ticker:         symbol,
        kind:           'new',
        origin:         'overnight_reversal',
        strategy_type:  'vertical',
        legs: [
          {
            # ratio_qty MUST be 1 for both legs. Per the broker (and
            # the RiskManager pre-flight): GCD of leg ratio_qty[] must
            # be 1, otherwise the broker rejects with code=42210000.
            # Position size lives in `qty:` so PortfolioManager can
            # read the absolute count separately from the ratio.
            'side'           => 'sell_to_open',
            'ratio_qty'      => 1,
            'qty'            => qty,
            'option_symbol'  => short_leg[:occ],
            'limit_price'    => short_premium.to_f.round(4),
            'net_limit_price'=> -net_credit.to_f.round(4)  # negative = credit
          },
          {
            'side'           => 'buy_to_open',
            'ratio_qty'      => 1,
            'qty'            => qty,
            'option_symbol'  => long_leg[:occ],
            'limit_price'    => long_premium.to_f.round(4),
            'net_limit_price'=> -net_credit.to_f.round(4)  # both legs carry the same net
          }
        ],
        max_loss: (qty * max_loss_per).to_f,
        max_profit: (qty * net_credit * 100).to_f,
        rationale: JSON.generate(
          'origin'       => 'overnight_reversal',
          'bucket'       => 'loser',
          'short_strike' => short,
          'long_strike'  => short + width,
          'width'        => width,
          'net_credit'   => net_credit.to_f.round(4),
          'human'        => "0DTE bear call spread (loser of yesterday's ranking): sell #{short}C / buy #{short + width}C for $#{net_credit.round(4)} credit"
        ),
        status: 'pending'
      )

      decision = safe_risk(proposal)
      if decision.nil? || decision.rejected?
        reasons = decision&.reasons || ['risk_check_failed']
        activity.logger.warn "[ovn:submit_loser] #{symbol} qty=#{qty} net_credit=#{net_credit.round(4)} -> rejected_by_risk: #{reasons.inspect}"
        proposal.update!(status: 'rejected', rejection_reason: reasons.join('; '))
        return { symbol: symbol, bucket: 'loser', status: 'rejected_by_risk',
                 proposal: proposal.id, reasons: decision&.reasons || ['risk_check_failed'] }
      end

      result = safe_portfolio(proposal)
      if result.nil? || !result.ok?
        proposal.update!(status: 'cancelled') if proposal.status == 'risk_approved'
        reasons = result&.reasons || ['portfolio_executor_failed']
        activity.logger.warn "[ovn:submit_loser] #{symbol} qty=#{qty} net_credit=#{net_credit.round(4)} -> broker_error: #{reasons.inspect}"
        return { symbol: symbol, bucket: 'loser', status: 'broker_error',
                 proposal: proposal.id, reasons: reasons }
      end

      proposal.update!(status: 'portfolio_approved') if proposal.status == 'risk_approved'
      tag_order(result.order, origin: 'overnight_reversal', bucket: 'loser', qty: qty)

      {
        symbol:         symbol,
        bucket:         'loser',
        status:         'submitted',
        proposal:       proposal.id,
        order:          result.order&.id,
        option_symbol:  "#{short_leg[:occ]}|#{long_leg[:occ]}",
        qty:            qty,
        short_strike:   short,
        long_strike:    short + width,
        net_credit:     net_credit.to_f.round(4)
      }
    end

    # ----- option-chain helpers -----

    # Find the ATM 0DTE call for the winner side. Returns [occ, premium]
    # or [nil, nil] on failure (e.g. no chain for today).
    def find_atm_call(symbol, dte_target)
      quote = fetch_underlying_price(symbol)
      return [nil, nil] if quote.nil?

      dte_target_i = dte_target.to_i
      attempts = [
        { dte: dte_target_i,        range: 0.05 },
        { dte: dte_target_i,        range: 0.10 },
        { dte: dte_target_i - 1,    range: 0.10 }, # today-only: back-to-yesterday (already expired)
        { dte: dte_target_i + 1,    range: 0.05 },
        { dte: dte_target_i,        range: 0.15 },
        { dte: dte_target_i + 2,    range: 0.10 }
      ]

      attempts.each do |a|
        result = find_atm_call_with_dte(symbol, quote, a[:dte], a[:range])
        return result if result[0]
      end
      [nil, nil]
    end

    # Same as the helper in mid_band_movers/submit_buy_orders_activity.rb —
    # pulls a chain over a ±N-day / ±X% strike window and picks the
    # strike closest to spot.
    def find_atm_call_with_dte(symbol, quote, dte, range_pct)
      center = Date.current + dte.days
      args = {
        underlying_symbol:      symbol,
        expiration_date_gte:    (center - 1).iso8601,
        expiration_date_lte:    (center + 1).iso8601,
        type:                   'call',
        limit:                  100
      }
      if quote.positive? && range_pct.positive?
        args[:strike_price_gte] = (quote * (1.0 - range_pct)).floor(2)
        args[:strike_price_lte] = (quote * (1.0 + range_pct)).ceil(2)
      end

      chain = mcp_get_option_chain(args)
      return [nil, nil] unless chain.is_a?(Hash) && chain.any?

      best = chain.min_by do |occ, snap|
        strike = parse_strike_from_occ(occ, snap)
        (strike - quote).abs
      end
      return [nil, nil] unless best

      occ, snap = best
      premium = best_premium(snap)
      # Also capture the broker's available size at the ask (as field).
      # This is the per-symbol inventory cap the broker enforces —
      # if as=2, only 2 contracts will fill no matter what we ask for.
      ask_size = snap.dig('latestQuote', 'as') || snap.dig('latest_quote', 'as') || 0
      [occ, premium.positive? ? premium : nil, ask_size.to_i]
    rescue StandardError => e
      activity.logger.warn "[submit_orders] find_atm_call(#{symbol}, dte=#{dte}, range=#{range_pct}) failed: #{e.class}: #{e.message}"
      [nil, nil, 0]
    end

    # Find the two legs of a bear call credit spread: short_strike and
    # long_strike (= short + width). Returned as
    #   [short_strike, {occ:, premium:}, {occ:, premium:}]
    # If no live chain returns [nil, nil, nil].
    def find_bear_call_legs(symbol:, spot:, dte:, width:, cfg:)
      short_delta_target = cfg.fetch('short_delta_target', 0.20).to_f

      # Pull a slightly wider window (0.95–1.10) so we have room to
      # find short strikes modestly OTM and the long strike a width
      # further up. For a $200 stock with width=$5, we want strikes
      # 0.95 × 200 = 190 to 1.10 × 200 = 220.
      center = Date.current + dte.days
      low_strike  = (spot * 0.95).floor
      high_strike = (spot * 1.10).ceil + width.ceil

      args = {
        underlying_symbol:   symbol,
        expiration_date_gte: (center - 1).iso8601,
        expiration_date_lte: (center + 1).iso8601,
        type:                'call',
        strike_price_gte:    low_strike,
        strike_price_lte:    high_strike,
        limit:               200
      }
      chain = mcp_get_option_chain(args)
      return [nil, nil, nil] unless chain.is_a?(Hash) && chain.any?

      # chain: { occ => snap }. Filter to strikes >= spot (so we can
      # sell the OTM short call) and pick the lowest such strike as
      # the short. Long = next width above the short.
      above = chain.select { |occ, snap| parse_strike_from_occ(occ, snap) >= spot }
                    .sort_by { |occ, snap| parse_strike_from_occ(occ, snap) }
      return [nil, nil, nil] if above.empty?

      short_strike = above.first.first.then { |occ| parse_strike_from_occ(occ, above.first.last) }
      # Find the long strike = short + width
      long_candidate = above.find { |occ, snap| parse_strike_from_occ(occ, snap) >= short_strike + width }
      return [nil, nil, nil] if long_candidate.nil?

      short_occ, short_snap = above.first
      long_occ,  long_snap  = long_candidate
      short_premium = best_premium(short_snap)
      long_premium  = best_premium(long_snap)

      return [nil, nil, nil] if short_premium.nil? || long_premium.nil?

      # Best-effort delta check: some broker snapshots carry a
      # `greeks.delta` field. If available, prefer the strike whose
      # delta is closest to `short_delta_target`. Otherwise accept
      # the lowest-OOM strike.
      if cfg.fetch('use_delta_selection', true)
        best_short = choose_short_by_delta(above, short_delta_target)
        if best_short
          occ, snap = best_short
          new_strike = parse_strike_from_occ(occ, snap)
          long_above = above.find { |o, s| parse_strike_from_occ(o, s) >= new_strike + width }
          if long_above
            short_occ, short_snap = best_short
            short_strike = new_strike
            long_occ, long_snap = long_above
            short_premium = best_premium(short_snap)
            long_premium  = best_premium(long_snap)
            return [nil, nil, nil] if short_premium.nil? || long_premium.nil?
          end
        end
      end

      [
        short_strike,
        { occ: short_occ, premium: short_premium, ask_size: short_snap.dig('latestQuote', 'as').to_i },
        { occ: long_occ,  premium: long_premium,  ask_size: long_snap.dig('latestQuote', 'as').to_i }
      ]
    rescue StandardError => e
      activity.logger.warn "[submit_orders] find_bear_call_legs(#{symbol}) failed: #{e.class}: #{e.message}"
      [nil, nil, nil]
    end

    # If the chain snapshot carries `greeks.delta`, pick the strike
    # above spot whose delta is closest to the target. Returns
    # [occ, snap] or nil if no snapshot carries Greeks.
    def choose_short_by_delta(above_sorted, target_delta)
      with_greeks = above_sorted.select { |_occ, snap| snap.is_a?(Hash) && snap.dig('greeks', 'delta') }
      return nil if with_greeks.empty?

      # Calls: delta is positive. We want delta ≈ target (e.g. 0.20).
      with_greeks.min_by do |_occ, snap|
        (snap.dig('greeks', 'delta').to_f - target_delta).abs
      end
    end

    def parse_strike_from_occ(occ, snap)
      return (snap['strike_price'] || snap.dig('details', 'strike_price')).to_f if snap.is_a?(Hash) && (snap['strike_price'] || snap.dig('details', 'strike_price'))
      return 0.0 if occ.to_s.length < 15
      occ[-8..].to_i / 1000.0
    end

    def best_premium(snap)
      return nil unless snap.is_a?(Hash)
      ap = snap.dig('latestQuote', 'ap') || snap.dig('latest_quote', 'ap') || snap['ask'] || snap['ask_price']
      bp = snap.dig('latestQuote', 'bp') || snap.dig('latest_quote', 'bp') || snap['bid'] || snap['bid_price']
      ap = ap.to_f
      bp = bp.to_f
      return ap if ap.positive?           # use ask for buy_to_open / sell_to_open (worst-case price)
      last = snap['lastTrade', 'p'] || snap.dig('latestTrade', 'p') || snap['price']
      last = last.to_f
      last.positive? ? last : nil
    end

    def mcp_get_option_chain(args)
      cache_key = "ovn:option_chain:#{Digest::SHA1.hexdigest(args.inspect)}"
      Rails.cache.fetch(cache_key, expires_in: 1.minute) do
        tool = ALPACA_MCP_READONLY.tool('get_option_chain')
        return {} unless tool

        raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
          CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(**args) }
        end
        Mcp::Response.unwrap(raw, tool_name: 'get_option_chain') || {}
      end
    end

    def fetch_underlying_price(symbol)
      tool = ALPACA_MCP_READONLY.tool('get_stock_latest_trade')
      return nil unless tool

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(symbols: symbol) }
      end
      text = unwrap_text(raw)
      parsed = JSON.parse(text) rescue {}
      trade = parsed.dig('data', 'trades', symbol) || parsed.dig('trades', symbol)
      trade.is_a?(Hash) ? trade['p'].to_f : nil
    rescue StandardError
      nil
    end

    def unwrap_text(raw)
      return raw if raw.is_a?(String)
      raw.respond_to?(:text) ? raw.text : raw.to_s
    end

    # ----- wrappers around risk + portfolio for fault isolation -----

    def safe_risk(proposal)
      Risk::RiskManager.new.check(proposal)
    rescue StandardError => e
      activity.logger.error "[submit_orders] risk check raised: #{e.class}: #{e.message}"
      nil
    end

    def safe_portfolio(proposal)
      Portfolio::PortfolioManager.execute(proposal)
    rescue StandardError => e
      activity.logger.error "[submit_orders] portfolio execute raised: #{e.class}: #{e.message}"
      nil
    end

    # Stamp the order with strategy metadata so the ClosePositionsActivity
    # can find these positions.
    def tag_order(order, origin:, bucket:, qty:)
      return if order.nil?
      raw = order.raw_response.is_a?(Hash) ? order.raw_response.dup : {}
      raw['ovn_origin']  = origin
      raw['ovn_bucket']  = bucket
      raw['ovn_qty']     = qty
      order.update!(raw_response: raw)
    end
  end
end
