# frozen_string_literal: true

# FetchMarketStateActivity — pulls the latest Alpaca snapshot for one
# ticker. Pure MCP/IO — MUST run in an activity, not a workflow, because
# rate-limiter / circuit-breaker mutexes are non-deterministic.
#
# ProcessTickerWorkflow calls this once per cycle, then passes the
# result into RunAnalystPhaseActivity as `market_context`. Analysts
# don't need to re-fetch the snapshot.
#
# The original in-workflow fetch hit a Temporal deterministic-replay
# wall: `Cannot access Thread::Mutex synchronize from inside a workflow`.
# The rate limiter and circuit breaker both use mutexes internally,
# so any IO that goes through them has to live in an activity.

module Trading
  class FetchMarketStateActivity < ApplicationActivity
    def execute(ticker)
      activity.logger.info "[activity:start] FetchMarketStateActivity ticker=#{ticker}"
      started_at = Time.current
      # The Alpaca MCP server doesn't expose a `get_market_state` tool.
      # We use `get_stock_snapshot` for the latest quote + daily bar,
      # which gives analysts a point-in-time view of the underlying.
      tool = ALPACA_MCP_READONLY.tool('get_stock_snapshot')
      if tool.nil?
        activity.logger.warn "[activity:done] FetchMarketStateActivity ticker=#{ticker} no_tool return={}"
        return {}
      end

      result = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(symbols: ticker) }
      end
      duration_ms = ((Time.current - started_at) * 1000).to_i
      activity.logger.info "[activity:done] FetchMarketStateActivity ticker=#{ticker} #{duration_ms}ms result_class=#{result.class}"
      result
    rescue StandardError => e
      duration_ms = ((Time.current - Time.current) * 1000).to_i
      activity.logger.warn "[activity:done] FetchMarketStateActivity ticker=#{ticker} FAILED: #{e.class}: #{e.message[0, 200]}"
      # Return empty hash on any failure so the pipeline can still
      # proceed — analysts will get a nil market_context and adjust.
      {}
    end
  end
end
