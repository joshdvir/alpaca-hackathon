# frozen_string_literal: true

# RunAnalystPhaseActivity — invokes the four analyst LLM agents sequentially
# and returns the consolidated briefs. Each brief is a hash with
# thesis/signals/confidence.
#
# RESILIENCE: each analyst is wrapped in safe_call so a single
# analyst's failure (auth error, MCP rate limit, parse rejection) does
# NOT block the rest of the pipeline. The failed analyst returns its
# own default brief (low-confidence, signals: ["insufficient_data:…"]).
# The activity always returns a hash with all four keys, even if every
# analyst failed. The downstream debate activity treats
# `brief[:_error]` as a signal to lean toward no_trade.
#
# The activity stamps every AgentRun with the calling workflow id/run id
# (passed via the `ctx` hash as the last positional arg) so the UI can show
# "this analyst ran as part of workflow X".

module Trading
  class RunAnalystPhaseActivity < ApplicationActivity
    ANALYSTS = [
      ['market_data', Analyst::MarketDataAnalyst],
      ['news',        Analyst::NewsAnalyst],
      ['macro',       Analyst::MacroAnalyst],
      ['insider',     Analyst::InsiderAnalyst]
    ].freeze

    def execute(ticker, watchlist_entry, market_context, ctx)
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id]
      run_id      = ctx['run_id']      || ctx[:run_id]
      activity.logger.info "[activity:start] RunAnalystPhaseActivity ticker=#{ticker} workflow_id=#{workflow_id}"

      # Run the 4 analysts IN PARALLEL via threads. Each analyst hits
      # the LLM (and possibly MCP) on its own. Sequential would mean
      # ~30s × 4 = 120s per ticker; parallel is ~30s per ticker. The
      # RateLimiter (50/60s on :llm) handles the cross-thread
      # contention safely.
      results = ANALYSTS.map do |(key, klass)|
        Thread.new do
          activity.logger.info "[activity:analyst] ticker=#{ticker} running #{klass.name}"
          started_at = Time.current
          begin
            value = klass.call(
              ticker, watchlist_entry, market_context,
              workflow_id: workflow_id, run_id: run_id
            )
            duration_ms = ((Time.current - started_at) * 1000).to_i
            confidence = value&.dig(:confidence)
            insufficient = value&.dig(:_insufficient) ? ' (insufficient_data)' : ''
            activity.logger.info "[activity:analyst] ticker=#{ticker} #{klass.name} done #{duration_ms}ms " \
                              "confidence=#{confidence}#{insufficient}"
            [key, value]
          rescue StandardError => e
            # Theoretically unreachable: Agent.call rescues everything
            # and returns default_brief. This is a defense-in-depth
            # backstop. We log + return an empty brief so the debate
            # can still run.
            duration_ms = ((Time.current - started_at) * 1000).to_i
            activity.logger.error "[activity:analyst] ticker=#{ticker} #{klass.name} FAILED #{duration_ms}ms: " \
                               "#{e.class}: #{e.message}"
            [key, {
              thesis: "insufficient data (activity_error)",
              signals: ["insufficient_data:activity_error", "error_class:#{e.class.name}"],
              confidence: 50,
              _error: { kind: 'activity_error', class: e.class.name, message: e.message[0, 500] }
            }]
          end
        end
      end.map(&:value)

      briefs = results.to_h
      avg = briefs.values.map { |b| (b['confidence'] || b[:confidence] || 50).to_i }.sum / briefs.size.to_f
      activity.logger.info "[activity:done] RunAnalystPhaseActivity ticker=#{ticker} briefs=#{briefs.size} avg_confidence=#{avg.round(1)}"
      briefs
    end
  end
end
