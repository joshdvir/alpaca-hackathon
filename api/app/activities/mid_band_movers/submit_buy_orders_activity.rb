# frozen_string_literal: true

# SubmitBuyOrdersActivity — Mid-Band Movers strategy. For each order in
# the serialized Plan:
#   1. Look up the option chain via MCP and pick the ATM 30-DTE call
#   2. Compute contract qty from cash_allocated / (premium × 100)
#   3. Build a TradeProposal with `kind: 'new'`, `origin: 'mid_band_movers'`,
#      and a single buy_to_open leg
#   4. Run RiskManager.check
#   5. Run PortfolioManager.execute
#
# The activity is intentionally tolerant: a single bad ticker (chain
# down, no contract, broker rejection) does NOT block the rest of
# the batch. Each order is reported back with its outcome so the
# parent workflow can schedule the corresponding SellWorkflow for
# the orders that actually filled.
#
# `ctx` carries {workflow_id, run_id}; `plan` is the serialized
# Plan hash from BuildPlanActivity.

module MidBandMovers
  class SubmitBuyOrdersActivity < ApplicationActivity
    def execute(plan, ctx = {})
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id] || 'mbm'
      started = Time.current
      activity.logger.info "[activity:start] SubmitBuyOrdersActivity workflow_id=#{workflow_id}"

      cfg = (TradingConfig.fetch(:mid_band_movers) || {}).deep_stringify_keys
      now_et = Time.current.in_time_zone('America/New_York')
      buy_at_et = Time.parse(plan['now_et']).in_time_zone('America/New_York') rescue now_et

      outcomes = []
      %w[a b c].each do |bucket_key|
        bucket = plan[bucket_key] || {}
        orders = Array(bucket['orders'])
        next if orders.empty?

        bucket_name = bucket['name']
        offset = bucket['sell_at_offset_hours'].to_f
        planned_sell_at = (buy_at_et + offset.hours).utc

        orders.each do |order|
          outcome = submit_one(
            symbol: order['symbol'],
            cash: BigDecimal(order['cash_allocated'].to_s),
            bucket_name: bucket_name,
            planned_sell_at: planned_sell_at,
            cfg: cfg,
            workflow_id: workflow_id
          )
          outcomes << outcome
        end
      end

      activity.logger.info(
        "[activity:done] SubmitBuyOrdersActivity workflow_id=#{workflow_id} " \
        "submitted=#{outcomes.count { |o| o[:status] == 'submitted' }} " \
        "rejected=#{outcomes.count { |o| o[:status] == 'rejected' }} " \
        "no_chain=#{outcomes.count { |o| o[:status] == 'no_chain' }} " \
        "elapsed_ms=#{((Time.current - started) * 1000).to_i}"
      )
      { orders: outcomes }
    rescue StandardError => e
      activity.logger.error "[activity:done] SubmitBuyOrdersActivity FAILED: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
      { orders: [], error: "#{e.class}: #{e.message}" }
    end

    private

    # Submit a single buy order. Returns a hash describing the outcome
    # so the parent workflow can build a SellWorkflow for the ones
    # that actually filled.
    def submit_one(symbol:, cash:, bucket_name:, planned_sell_at:, cfg:, workflow_id:)
      dte_target = (cfg['dte_target'] || 30).to_i

      option_symbol, premium = find_atm_call(symbol, dte_target)
      if option_symbol.nil? || premium.nil? || premium <= 0
        activity.logger.warn "[submit_buy] no ATM #{dte_target}DTE call for #{symbol} (premium=#{premium.inspect})"
        return { symbol: symbol, bucket: bucket_name, status: 'no_chain' }
      end

      # 1 OCC contract = 100 shares of underlying. The contract premium
      # is quoted per share, so $X/share = $X*100 per contract.
      contract_cost = premium.to_d * 100
      qty = (cash / contract_cost).floor.to_i
      if qty < 1
        activity.logger.warn "[submit_buy] cash $#{cash.to_f.round(2)} too small for 1 #{symbol} contract @ $#{premium}"
        return { symbol: symbol, bucket: bucket_name, status: 'cash_too_small' }
      end

      proposal = TradeProposal.create!(
        ticker: symbol,
        kind: 'new',
        origin: 'mid_band_movers',
        strategy_type: 'long_call',
        legs: [
          {
            'side' => 'buy_to_open',
            'ratio_qty' => qty,
            'option_symbol' => option_symbol,
            'limit_price' => premium.to_f.round(4)
          }
        ],
        max_loss: (qty * contract_cost).to_f,
        max_profit: 0,
        # JSON tag carrying the planned sell time + bucket for the
        # AlpacaSync backfill. Keep it parseable so the SellWorkflow
        # can also read it from the TradeProposal if needed.
        rationale: JSON.generate(
          'planned_sell_at' => planned_sell_at.iso8601,
          'strategy_bucket' => bucket_name,
          'origin' => 'mid_band_movers',
          'human' => "ATM #{dte_target}DTE long call, bucket #{bucket_name}"
        ),
        status: 'pending'
      )

      decision = safe_risk(proposal)
      if decision.nil? || decision.rejected?
        proposal.update!(status: 'rejected', rejection_reason: (decision&.reasons || ['risk_check_failed']).join('; '))
        return {
          symbol: symbol, bucket: bucket_name, status: 'rejected_by_risk',
          proposal: proposal.id, reasons: decision&.reasons || ['risk_check_failed']
        }
      end

      result = safe_portfolio(proposal)
      if result.nil? || !result.ok?
        proposal.update!(status: 'cancelled') if proposal.status == 'risk_approved'
        return {
          symbol: symbol, bucket: bucket_name, status: 'broker_error',
          proposal: proposal.id,
          reasons: result&.reasons || ['portfolio_executor_failed']
        }
      end

      proposal.update!(status: 'portfolio_approved') if proposal.status == 'risk_approved'
      # Stamp the planned_sell_at + strategy_bucket on the resulting
      # Order row too. The TradeProposal carries the metadata; the
      # Position gets it via AlpacaSync backfill (when the position
      # is materialized) and on the next mirror tick we backfill any
      # positions that were created in the gap.
      tag_order_with_plan_metadata(result.order, planned_sell_at, bucket_name)

      {
        symbol: symbol, bucket: bucket_name, status: 'submitted',
        proposal: proposal.id, order: result.order&.id,
        option_symbol: option_symbol, qty: qty,
        planned_sell_at: planned_sell_at.iso8601
      }
    end

    # Look up the ATM 30-DTE call. The MCP `get_option_chain` accepts
    # `expiration_date`, `strike_price_gte`, and `strike_price_lte` so
    # we narrow the window to ±2 strikes around the spot price and
    # pick the closest one.
    def find_atm_call(symbol, dte_target)
      quote = fetch_underlying_price(symbol)
      return [nil, nil] if quote.nil?

      # The broker's option chain for a single (DTE, strike-range) tuple
      # often returns empty for illiquid tickers. Try a sequence of
      # widening windows before giving up. Empirical observation: the
      # broker's MCP only has data on certain weekly/monthly
      # expirations; for META-class tickers the 30-DTE exp often
      # comes back empty while the 45-DTE or 60-DTE exp is live.
      # We try a broad sweep to find any chain with quotes:
      #   1. (DTE, ±5%)         — primary ask
      #   2. (DTE, ±10%)        — same exp, wider strikes
      #   3. (DTE±7, ±10%)      — adjacent weekly
      #   4. (DTE±14, ±10%)     — adjacent monthly
      #   5. (DTE±30, ±10%)     — far out, last resort
      #   6. (DTE, ±20%)        — very wide, final
      # Whichever returns a chain with a positive premium wins.
      dte_target_i = dte_target.to_i
      attempts = [
        { dte: dte_target_i,            range: 0.05 },
        { dte: dte_target_i,            range: 0.10 },
        { dte: dte_target_i - 7,        range: 0.10 },
        { dte: dte_target_i + 7,        range: 0.10 },
        { dte: dte_target_i - 14,       range: 0.10 },
        { dte: dte_target_i + 14,       range: 0.10 },
        { dte: dte_target_i - 30,       range: 0.10 },
        { dte: dte_target_i + 30,       range: 0.10 },
        { dte: dte_target_i,            range: 0.20 }
      ]

      attempts.each do |a|
        result = find_atm_call_with_dte(symbol, quote, a[:dte], a[:range])
        return result if result[0]  # got a chain → done
      end
      [nil, nil]
    end

    def find_atm_call_with_dte(symbol, quote, dte, range_pct)
      # The broker's MCP returns an EMPTY chain when given an exact
      # `expiration_date` for days where no listed exp exists (e.g. an
      # arbitrary 30-day-out Tuesday). Pass a ±3-day window so we hit
      # the broker's actual listed weekly/monthly expirations near the
      # target DTE. Without this, `expiration_date: "2026-10-01"`
      # returns `{snapshots:{}}` while `gte=2026-10-01 lte=2026-10-16`
      # returns the live 30-45 DTE exp.
      center = Date.current + dte.days
      args = {
        underlying_symbol: symbol,
        expiration_date_gte: (center - 3).iso8601,
        expiration_date_lte: (center + 3).iso8601,
        type: 'call',
        limit: 100
      }
      if quote.positive? && range_pct.positive?
        args[:strike_price_gte] = (quote * (1.0 - range_pct)).floor(2)
        args[:strike_price_lte] = (quote * (1.0 + range_pct)).ceil(2)
      end

      chain = mcp_get_option_chain(args)
      return [nil, nil] unless chain.is_a?(Hash) && chain.any?

      # chain is `{ <occ_symbol> => { latestQuote: {ap: ask, bp: bid}, ... } }`.
      # The MCP's snapshot does NOT include a `strike_price` field —
      # the strike is encoded inside the OCC symbol itself
      # (`META261016C00290000` → strike 290.00). Pick the contract
      # whose strike is closest to the spot price.
      best = chain.min_by do |occ, snap|
        strike = parse_strike_from_occ(occ, snap)
        (strike - quote).abs
      end
      return [nil, nil] unless best

      occ, snap = best
      premium = (snap.dig('latestQuote', 'ap') || snap.dig('latest_quote', 'ap') ||
                 snap['ask'] || snap['last_quote', 'ap']).to_f
      premium = (snap['lastTrade', 'p'] || snap.dig('latestTrade', 'p') || snap['price']).to_f if premium <= 0
      [occ, premium.positive? ? premium : nil]
    rescue StandardError => e
      activity.logger.warn "[submit_buy] find_atm_call(#{symbol}, dte=#{dte}, range=#{range_pct}) failed: #{e.class}: #{e.message}"
      [nil, nil]
    end

    # OCC option symbol: 6-char root + YYMMDD + C/P + 8-digit strike × 1000.
    # E.g. `META261016C00290000` = META, 2026-10-16, Call, strike 290.00.
    # The broker's snapshot doesn't carry a `strike_price` field
    # directly, so we parse the OCC symbol. Falls back to the snap
    # field if the OCC symbol is malformed.
    def parse_strike_from_occ(occ, snap)
      if (snap['strike_price'] || snap.dig('details', 'strike_price'))
        return (snap['strike_price'] || snap.dig('details', 'strike_price')).to_f
      end
      return 0.0 if occ.to_s.length < 15
      # Strike is the last 8 characters, divided by 1000
      occ[-8..].to_i / 1000.0
    end

    def fetch_underlying_price(symbol)
      tool = ALPACA_MCP_READONLY.tool('get_stock_latest_trade')
      return nil unless tool

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(symbols: symbol) }
      end
      text = raw.is_a?(Array) ? raw.first&.text : (raw.respond_to?(:text) ? raw.text : raw.to_s)
      parsed = JSON.parse(text.to_s) rescue {}
      data = parsed.is_a?(Hash) ? (parsed['data'] || parsed) : {}
      trades = data['trades'] || data
      trade = trades.is_a?(Hash) ? (trades[symbol] || trades[symbol.to_sym]) : nil
      return nil unless trade.is_a?(Hash)

      (trade['p'] || trade[:p]).to_f
    rescue StandardError
      nil
    end

    def mcp_get_option_chain(args)
      cache_key = "mbm:option_chain:#{Digest::SHA1.hexdigest(args.inspect)}"
      Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        tool = ALPACA_MCP_READONLY.tool('get_option_chain')
        return {} unless tool

        raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
          CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(args) }
        end
        Mcp::Response.unwrap(raw, tool_name: 'get_option_chain') || {}
      end
    end

    def safe_risk(proposal)
      Risk::RiskManager.new.check(proposal)
    rescue StandardError => e
      activity.logger.error "[submit_buy] risk check raised: #{e.class}: #{e.message}"
      nil
    end

    def safe_portfolio(proposal)
      Portfolio::PortfolioManager.execute(proposal)
    rescue StandardError => e
      activity.logger.error "[submit_buy] portfolio execute raised: #{e.class}: #{e.message}"
      nil
    end

    # Order row doesn't have planned_sell_at/strategy_bucket columns.
    # Stash the metadata in raw_response so it's preserved with the
    # Order, and FindMbmPositionActivity can pick it up when the
    # position is created.
    def tag_order_with_plan_metadata(order, planned_sell_at, bucket_name)
      return if order.nil?

      raw = order.raw_response.is_a?(Hash) ? order.raw_response.dup : {}
      raw['mbm_planned_sell_at'] = planned_sell_at.iso8601
      raw['mbm_strategy_bucket'] = bucket_name
      raw['mbm_origin'] = 'mid_band_movers'
      order.update!(raw_response: raw)
    end
  end
end
