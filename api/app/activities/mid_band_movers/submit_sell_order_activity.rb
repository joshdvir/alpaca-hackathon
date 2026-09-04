# frozen_string_literal: true

# SubmitSellOrderActivity — Mid-Band Movers strategy. Closes one
# position by submitting a market sell_to_close order. This is the
# activity the SellWorkflow calls when `planned_sell_at` is reached.
#
# Design notes:
#   - Always tries to close, even if the LLM has already closed the
#     position — the activity short-circuits with outcome: "noop"
#     when the position is already gone or has qty=0.
#   - Uses `kind: 'auto_close'` so the TradeProposal lands in the
#     audit trail as a planned (non-LLM) close.
#   - Market order (no limit price). A market order at the sell
#     time is the simplest execution path and matches the user's
#     "always sell at sell time, market order" decision.
#   - `closes_position` is set so the Position gets linked to the
#     closing proposal.
#
# `ctx` carries {workflow_id, run_id} for log correlation.

module MidBandMovers
  class SubmitSellOrderActivity < ApplicationActivity
    def execute(position_id, ctx = {})
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id] || 'mbm-sell'
      activity.logger.info "[activity:start] SubmitSellOrderActivity workflow_id=#{workflow_id} position_id=#{position_id}"

      position = Position.find_by(id: position_id)
      if position.nil? || position.closed? || position.qty.to_i <= 0
        activity.logger.info "[activity:done] SubmitSellOrderActivity position_id=#{position_id} noop (already closed or missing)"
        return { position_id: position_id, outcome: 'noop' }
      end

      symbol = position.symbol
      qty = position.qty.to_i

      # The broker REJECTS limit orders without a limit price
      # (code=40010001). Fetch the current best bid from the MCP
      # and use that as the limit. This produces a marketable
      # order that fills at or near the bid on a paper account.
      # If the bid fetch fails, fall back to the position's
      # avg_entry_price so we still have a sensible price floor.
      bid = fetch_option_bid(symbol) || position.avg_entry_price.to_f
      if bid.to_f <= 0
        bid = 0.01 # broker minimum; better than failing the close
      end

      proposal = TradeProposal.create!(
        ticker: symbol.to_s.split(/\d/).first.to_s, # OCC symbol: strip digits for the underlying root
        kind: 'auto_close',
        origin: 'mid_band_movers',
        strategy_type: 'hold', # column is NOT NULL; 'hold' is the closest semantic
        closes_position: position,
        legs: [
          {
            'side' => 'sell_to_close',
            'ratio_qty' => qty,
            'option_symbol' => symbol,
            # Limit at the current bid → marketable, should fill
            # immediately on the paper account.
            'limit_price' => bid.to_f.round(4)
          }
        ],
        max_loss: 0,
        max_profit: 0,
        rationale: JSON.generate(
          'origin' => 'mid_band_movers',
          'bucket' => position.strategy_bucket,
          'planned_sell_at' => position.planned_sell_at&.iso8601,
          'human' => "Mid-Band Movers scheduled close for bucket #{position.strategy_bucket}"
        ),
        status: 'pending'
      )

      decision = safe_risk(proposal)
      if decision.nil? || decision.rejected?
        proposal.update!(status: 'rejected', rejection_reason: (decision&.reasons || ['risk_check_failed']).join('; '))
        activity.logger.warn "[activity:done] SubmitSellOrderActivity position_id=#{position_id} risk_rejected proposal=#{proposal.id}"
        return { position_id: position_id, outcome: 'rejected_by_risk', proposal: proposal.id }
      end

      result = safe_portfolio(proposal)
      if result.nil? || !result.ok?
        proposal.update!(status: 'cancelled') if proposal.status == 'risk_approved'
        activity.logger.warn "[activity:done] SubmitSellOrderActivity position_id=#{position_id} broker_error proposal=#{proposal.id} reasons=#{result&.reasons.inspect}"
        return {
          position_id: position_id, outcome: 'broker_error',
          proposal: proposal.id, reasons: result&.reasons || ['portfolio_executor_failed']
        }
      end

      proposal.update!(status: 'portfolio_approved') if proposal.status == 'risk_approved'
      activity.logger.info "[activity:done] SubmitSellOrderActivity position_id=#{position_id} submitted proposal=#{proposal.id} order=#{result.order&.id}"
      { position_id: position_id, outcome: 'submitted', proposal: proposal.id, order: result.order&.id }
    rescue StandardError => e
      activity.logger.error "[activity:done] SubmitSellOrderActivity FAILED position_id=#{position_id}: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
      { position_id: position_id, outcome: 'uncaught_error', error: "#{e.class}: #{e.message}" }
    end

    private

    def safe_risk(proposal)
      Risk::RiskManager.new.check(proposal)
    rescue StandardError => e
      activity.logger.error "[submit_sell] risk check raised: #{e.class}: #{e.message}"
      nil
    end

    def safe_portfolio(proposal)
      Portfolio::PortfolioManager.execute(proposal)
    rescue StandardError => e
      activity.logger.error "[submit_sell] portfolio execute raised: #{e.class}: #{e.message}"
      nil
    end

    # Best-effort current bid for an OCC option symbol, via the
    # MCP `get_option_snapshot` tool. Returns nil on any error
    # so the caller can fall back to a sane default. Cached
    # for 30s to avoid hammering the broker.
    def fetch_option_bid(symbol)
      return nil if symbol.to_s.empty?

      cache_key = "mbm:option_bid:#{symbol}"
      cached = Rails.cache.read(cache_key)
      return cached if cached

      tool = ALPACA_MCP_READONLY.tool('get_option_snapshot')
      return nil unless tool

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(symbols: symbol) }
      end
      text = raw.is_a?(Array) ? raw.first&.text : (raw.respond_to?(:text) ? raw.text : raw.to_s)
      parsed = JSON.parse(text.to_s) rescue {}
      snap = parsed.dig('data', 'snapshots', symbol) || {}
      bid = snap.dig('latestQuote', 'bp') || snap.dig('latest_quote', 'bp')
      bid = bid.to_f if bid
      Rails.cache.write(cache_key, bid, expires_in: 30.seconds) if bid && bid.positive?
      bid
    rescue StandardError => e
      activity.logger.warn "[submit_sell] bid fetch for #{symbol} failed: #{e.class}: #{e.message}"
      nil
    end
  end
end
