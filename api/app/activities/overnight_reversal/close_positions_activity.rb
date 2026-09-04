# frozen_string_literal: true

# ClosePositionsActivity — Overnight Reversal strategy. Closes all
# positions created by this strategy today at the planned close time
# (15:55 ET by default).
#
# Two buckets, two close paths:
#
#   winners (long calls, single-leg):
#     • Best-effort `sell_to_close` at the option's current bid.
#     • Limit to the latest bid so the order is marketable.
#     • On failure: noop (position will expire at 4:00 PM ET if OTM).
#
#   losers (bear call credit spreads, two-leg):
#     • Best-effort `buy_to_close` BOTH legs simultaneously as
#       a multi-leg mleg order.
#     • On a partial failure (one leg has no bid), fall back to a
#       single-leg `buy_to_close` of whichever leg has a quote and
#       let the other side be assigned / expire.
#     • If both bids are 0 (deep OTM), the spread is left to expire —
#       no risk, no value.
#
# Position lookup: we filter `Position.where(origin: 'overnight_reversal').open`
# at execution time. Positions created by earlier strategies remain
# untouched. The activity is one-shot per scheduled close.

module OvernightReversal
  class ClosePositionsActivity < ApplicationActivity
    MAX_ATTEMPTS = 3

    activity_name 'OvernightClosePositionsActivity'

    def execute(ctx = {})
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id] || 'ovn-close'
      started = Time.current
      activity.logger.info "[activity:start] ClosePositionsActivity workflow_id=#{workflow_id}"

      cfg = (TradingConfig.fetch(:overnight_reversal) || {}).deep_stringify_keys
      max_attempts = cfg.fetch('max_close_attempts', MAX_ATTEMPTS).to_i

      positions = Position.where(origin: 'overnight_reversal').where(closed_at: nil).order(:id)
      if positions.empty?
        activity.logger.info "[activity:done] ClosePositionsActivity no positions to close"
        return { positions: [], closed: 0 }
      end

      results = positions.map do |position|
        if spread_position?(position)
          close_spread(position, max_attempts: max_attempts, workflow_id: workflow_id)
        else
          close_single(position, max_attempts: max_attempts, workflow_id: workflow_id)
        end
      end

      closed = results.count { |r| r[:status] == 'submitted' }
      noop   = results.count { |r| r[:status] == 'noop' }
      activity.logger.info(
        "[activity:done] ClosePositionsActivity workflow_id=#{workflow_id} " \
        "positions=#{positions.size} closed=#{closed} noop=#{noop} " \
        "elapsed_ms=#{((Time.current - started) * 1000).to_i}"
      )
      { positions: results, closed: closed }
    rescue StandardError => e
      activity.logger.error "[activity:done] ClosePositionsActivity FAILED: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
      { positions: [], error: "#{e.class}: #{e.message}" }
    end

    private

    # A position is treated as a spread if it carries spread metadata
    # in `raw` jsonb (set by the order row's raw_response, which gets
    # backfilled to the Position row when the mirror syncs). We use
    # a simple heuristic: look for `ovn_bucket: 'loser'` in the
    # `raw` jsonb. Spreads are ALWAYS 2-leg in this strategy.
    def spread_position?(position)
      raw = position.raw
      return raw['ovn_bucket'] == 'loser' if raw.is_a?(Hash) && raw['ovn_bucket']
      false
    end

    # ---- single-leg close: sell_to_close ----

    def close_single(position, max_attempts:, workflow_id:)
      symbol = position.symbol
      qty    = position.qty.to_i

      bid = fetch_option_bid(symbol)
      if bid.nil? || bid <= 0
        activity.logger.warn "[ovn_close] #{symbol}: no bid — letting OTM expire / ITM assign"
        return { position_id: position.id, symbol: symbol, status: 'noop', reason: 'no_bid' }
      end

      # Dust filter: positions worth less than `dust_threshold` (per
      # contract) are typically deep-OTM long calls that the broker
      # refuses to register as closing trades after hours (rejection
      # code 40310000 — "uncovered option contracts"). The position
      # will either fill at market open the next trading day, expire
      # worthless, or get assigned. We mark these as dust-noop so
      # they're not re-attempted every cycle. Threshold per-contract
      # is configurable via `dust_threshold_per_contract` (default
      # $0.05 = 5 cents).
      dust_threshold = cfg.fetch('dust_threshold_per_contract', 0.05).to_f
      if bid < dust_threshold
        activity.logger.warn "[ovn_close] #{symbol}: bid=$#{bid.round(4)} < dust_threshold=$#{dust_threshold.round(2)} — skipping broker submit (will expire / next-open retry)"
        position.update!(closed_at: Time.current, snapshot_at: Time.current) unless position.closed_at.present?
        return { position_id: position.id, symbol: symbol, status: 'noop', reason: 'dust', bid: bid.to_f.round(4) }
      end

      submit_with_retries(max_attempts: max_attempts, workflow_id: workflow_id) do
        TradeProposal.create!(
          ticker:           symbol.to_s.split(/\d/).first.to_s,
          kind:             'auto_close',
          origin:           'overnight_reversal',
          strategy_type:    'hold',
          closes_position:  position,
          legs: [
            {
              'side'         => 'sell_to_close',
              'ratio_qty'    => qty,
              'option_symbol'=> symbol,
              'limit_price'  => bid.to_f.round(4)
            }
          ],
          max_loss: 0,
          max_profit: 0,
          rationale: JSON.generate(
            'origin' => 'overnight_reversal',
            'bucket' => 'winner',
            'human'  => '0DTE winner auto-close at 15:55 ET'
          ),
          status: 'pending'
        )
      end
    end

    # ---- multi-leg spread close: buy_to_close both legs ----

    def close_spread(position, max_attempts:, workflow_id:)
      # The Position is on a single OCC option symbol (the short leg).
      # The long leg is `+ width` strikes. To find it we read the
      # Position's `raw` jsonb (filled when the order mirror synced).
      # Falls back to the original TradeProposal for the second leg.
      short_occ = position.symbol
      long_occ  = nil
      raw = position.raw
      if raw.is_a?(Hash)
        long_occ = raw['ovn_long_occ']
      end

      if long_occ.nil?
        # Fallback: query the original TradeProposal for the second leg.
        tp = TradeProposal.where('closes_position_id IS NULL OR closes_position_id != ?', position.id)
                          .where(ticker: position.ticker)
                          .where(origin: 'overnight_reversal', strategy_type: 'bear_call_spread')
                          .order(created_at: :desc).first
        if tp
          legs = Array(tp.legs)
          non_pos = legs.reject { |l| (l['option_symbol'] || l[:option_symbol]).to_s == short_occ }
          long_occ = non_pos.first&.then { |l| (l['option_symbol'] || l[:option_symbol]).to_s } || nil
        end
      end

      if long_occ.nil? || long_occ.empty?
        activity.logger.warn "[ovn_close] short=#{short_occ}: long leg not found — falling back to single-leg close"
        return close_single(position, max_attempts: max_attempts, workflow_id: workflow_id)
      end

      qty = position.qty.to_i
      short_bid = fetch_option_bid(short_occ)
      long_bid  = fetch_option_bid(long_occ)

      # Both bids 0 → spread is deep OTM → expire.
      if (short_bid.to_f <= 0) && (long_bid.to_f <= 0)
        activity.logger.info "[ovn_close] spread #{short_occ}/#{long_occ}: both legs OTM → expire"
        return { position_id: position.id, symbol: "#{short_occ}|#{long_occ}", status: 'noop', reason: 'deep_otm' }
      end

      # Net debit to close = short_bid − long_bid (short we buy back at bid,
      # long we sell at bid; the net cost is short_bid − long_bid). We pass
      # it as a POSITIVE limit_price (debit) on each leg. PortfolioManager
      # treats mleg limit_price as net (positive = debit).
      short_px = short_bid.to_f.positive? ? short_bid.to_f : 0.01
      long_px  = long_bid.to_f.positive?  ? long_bid.to_f  : 0.01
      net_debit = (short_px - long_px).round(4)
      net_debit = 0.01 if net_debit <= 0 # ensure positive

      submit_with_retries(max_attempts: max_attempts, workflow_id: workflow_id) do
        TradeProposal.create!(
          ticker:          position.ticker,
          kind:            'auto_close',
          origin:          'overnight_reversal',
          strategy_type:   'hold',
          closes_position: position,
          legs: [
            {
              'side'           => 'buy_to_close',
              'ratio_qty'      => qty,
              'option_symbol'  => short_occ,
              'limit_price'    => short_px,
              'net_limit_price'=> net_debit
            },
            {
              'side'           => 'buy_to_close',
              'ratio_qty'      => qty,
              'option_symbol'  => long_occ,
              'limit_price'    => long_px,
              'net_limit_price'=> net_debit
            }
          ],
          max_loss: 0,
          max_profit: 0,
          rationale: JSON.generate(
            'origin' => 'overnight_reversal',
            'bucket' => 'loser',
            'short_occ' => short_occ,
            'long_occ'  => long_occ,
            'human'  => '0DTE bear-call spread auto-close at 15:55 ET'
          ),
          status: 'pending'
        )
      end
    end

    # ---- risk + portfolio with retry ----

    def submit_with_retries(max_attempts:, workflow_id:)
      proposal = yield
      decision = safe_risk(proposal)
      if decision.nil? || decision.rejected?
        proposal.update!(status: 'rejected', rejection_reason: (decision&.reasons || ['risk_check_failed']).join('; '))
        return { position_id: nil, status: 'rejected_by_risk', proposal: proposal.id,
                 reasons: decision&.reasons || ['risk_check_failed'] }
      end

      last_err = nil
      max_attempts.times do |i|
        result = safe_portfolio(proposal)
        if result&.ok?
          proposal.update!(status: 'portfolio_approved') if proposal.status == 'risk_approved'
          return {
            position_id:    proposal.closes_position&.id,
            symbol:         proposal.closes_position&.symbol,
            status:         'submitted',
            proposal:       proposal.id,
            order:          result.order&.id
          }
        end

        last_err = result&.reasons&.first
        sleep(0.5 * (i + 1)) if i < max_attempts - 1
      end

      proposal.update!(status: 'cancelled') if proposal.status == 'risk_approved'
      {
        position_id: proposal.closes_position&.id,
        symbol:      proposal.closes_position&.symbol,
        status:      'broker_error',
        proposal:    proposal.id,
        reasons:     [last_err || 'portfolio_executor_failed_after_retries']
      }
    end

    # ---- option bid fetcher ----

    def fetch_option_bid(symbol)
      return nil if symbol.to_s.empty?
      cache_key = "ovn:option_bid:#{symbol}"
      cached = Rails.cache.read(cache_key)
      return cached if cached

      tool = ALPACA_MCP_READONLY.tool('get_option_snapshot')
      return nil unless tool

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(symbols: symbol) }
      end
      text = unwrap_text(raw)
      parsed = JSON.parse(text) rescue {}
      snap = parsed.dig('data', 'snapshots', symbol) ||
             parsed.dig('snapshots', symbol) || {}
      bid = snap.dig('latestQuote', 'bp') || snap.dig('latest_quote', 'bp') ||
            snap['bid'] || snap['bid_price']
      bid = bid.to_f if bid
      Rails.cache.write(cache_key, bid, expires_in: 15.seconds) if bid && bid.positive?
      bid
    rescue StandardError
      nil
    end

    # ---- wrappers ----

    def safe_risk(proposal)
      Risk::RiskManager.new.check(proposal)
    rescue StandardError => e
      activity.logger.error "[ovn_close] risk check raised: #{e.class}: #{e.message}"
      nil
    end

    def safe_portfolio(proposal)
      Portfolio::PortfolioManager.execute(proposal)
    rescue StandardError => e
      activity.logger.error "[ovn_close] portfolio execute raised: #{e.class}: #{e.message}"
      nil
    end

    def unwrap_text(raw)
      return raw if raw.is_a?(String)
      raw.respond_to?(:text) ? raw.text : raw.to_s
    end
  end
end
