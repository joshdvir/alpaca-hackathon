# frozen_string_literal: true

# ProcessTickerWorkflow — per-ticker pipeline:
#   1. Fetch market state (one MCP call)
#   2. Run analyst phase (4 analysts)
#   3. Run debate phase (bull/bear/research_manager)
#   4. Run execution phase (Trader, Risk, Portfolio)
#
# Single-pass: the cron schedule (`trading-scheduler-reconcile`) is
# the sole driver of cycle frequency. Every cron tick launches a fresh
# ProcessTickerWorkflow per active watchlist ticker, runs the pipeline
# once, and lets the workflow complete. A previous version looped in
# the workflow body with `T_WORKFLOW.sleep(cycle_minutes * 60)`, but
# that meant each child workflow lived forever and accumulated
# parallel runs on top of the cron's own children, eventually
# crowding the task queue. The cron-only design is simpler and the
# `parent_close_policy: TERMINATE` on `execute_child_workflow` cleans
# up any in-flight children when the scheduler is replaced.
#
# RESILIENCE: every activity call is wrapped in `safe_activity_call`.
# A failure of any single phase (MCP down, LLM down, parse failure,
# risk rejected, broker error) does NOT crash the workflow — it
# produces a structured result hash that the workflow logs. The next
# cron tick will retry from a fresh workflow. This is the "always
# have a result" guarantee: the user always sees a verdict and a
# reason in the log for every cycle, even on hard outages.
#
# Determinism note:
#   - The watch hash is JSON-deserialized by Temporal's payload
#     converter, so its keys are STRINGS — not the symbol keys the
#     SchedulerWorkflow/Activity code uses. All accesses use strings.
#   - MCP / rate-limiter / circuit-breaker IO happens inside
#     FetchMarketStateActivity (NOT inline). Calling them inline
#     blows up with `Cannot access Thread::Mutex synchronize from
#     inside a workflow` because the rate limiter and breaker use
#     mutexes internally, and Temporal forbids Mutex#synchronize
#     inside workflow code.

module Trading
  class ProcessTickerWorkflow < ApplicationWorkflow
    def execute(watch)
      ticker = watch['ticker']
      activity.logger.info "[workflow:start] ProcessTickerWorkflow ticker=#{ticker} watch=#{watch.inspect[0, 300]}"
      run_pipeline(ticker, watch)
    rescue StandardError => e
      # Last-line backstop for workflow-level failures (e.g. watch
      # hash is missing required keys). Log loudly and let Temporal
      # mark the workflow failed — the next cron tick will retry
      # from a fresh workflow.
      activity.logger.error "[workflow:fatal] ProcessTickerWorkflow crashed: #{e.class}: #{e.message}\n" \
                              "#{e.backtrace.first(8).join("\n")}"
      raise
    end

    private

    def run_pipeline(ticker, watch)
      workflow_id = T_WORKFLOW.info.workflow_id
      run_id      = T_WORKFLOW.info.run_id
      ctx = { 'workflow_id' => workflow_id, 'run_id' => run_id }

      activity.logger.info "[workflow:phase] ticker=#{ticker} phase=market_state"
      market_state = safe_activity_call(ticker, 'market_state',
                                        FetchMarketStateActivity, ticker,
                                        start_to_close_timeout: 60)
      # MCP responses can be a Hash, a String, or even an Array
      # depending on the tool. We just need something to feed to the
      # analyst's JSON payload — wrap non-Hash responses under a
      # "raw" key so the analyst sees a stable shape. NEVER call .to_h
      # on a String (it raises NoMethodError and crashes the whole
      # workflow — which is exactly what we built the rescue for).
      market_state = case market_state
                     when Hash   then market_state
                     when nil    then {}
                     else            { 'raw' => market_state }
                     end

      activity.logger.info "[workflow:phase] ticker=#{ticker} phase=analyst"
      analyst_briefs = safe_activity_call(ticker, 'analyst',
                                          RunAnalystPhaseActivity, ticker, watch, market_state, ctx,
                                          start_to_close_timeout: 600)
      # analyst_briefs may be nil if even the outer wrapper failed.
      # Substitute empty briefs so the debate can still run.
      analyst_briefs ||= empty_analyst_briefs(ticker)
      activity.logger.info "[workflow:phase] ticker=#{ticker} analyst done briefs=#{analyst_briefs.size}"

      if fast_no_trade?(analyst_briefs)
        activity.logger.info "[workflow:phase] ticker=#{ticker} fast no-trade (low confidence across analysts)"
        record_watchlist_skip(ticker, watch, 'fast_no_trade')
        # Still persist the analyst briefs so the Research screen
        # has data. We don't have a debate result yet, so pass an
        # empty default — the activity handles `no_trade` as a
        # neutral recommendation so the row is valid.
        safe_activity_call(ticker, 'persist_research',
                           PersistResearchActivity, ticker, analyst_briefs, default_debate_result, ctx,
                           start_to_close_timeout: 60)
        return
      end

      activity.logger.info "[workflow:phase] ticker=#{ticker} phase=debate"
      debate = safe_activity_call(ticker, 'debate',
                                  RunDebatePhaseActivity, ticker, analyst_briefs, ctx,
                                  start_to_close_timeout: 1200)
      # debate may be nil if the outer wrapper failed. Substitute a
      # no_trade verdict so the execution phase still records an
      # outcome.
      debate ||= default_debate_result
      verdict = (debate.is_a?(Hash) ? (debate[:verdict] || debate['verdict']) : nil) || {}
      verdict_str = verdict[:verdict] || verdict['verdict']
      confidence = verdict[:confidence] || verdict['confidence']
      activity.logger.info "[workflow:phase] ticker=#{ticker} debate done verdict=#{verdict_str} confidence=#{confidence}"

      # Persist the analyst briefs + debate result so the Research
      # screen has rows. Runs even when verdict=no_trade so users
      # can see what the LLM decided (or what errored).
      activity.logger.info "[workflow:phase] ticker=#{ticker} phase=persist_research"
      safe_activity_call(ticker, 'persist_research',
                         PersistResearchActivity, ticker, analyst_briefs, debate, ctx,
                         start_to_close_timeout: 60)

      activity.logger.info "[workflow:phase] ticker=#{ticker} phase=execution"
      outcome = safe_activity_call(ticker, 'execution',
                                   RunExecutionPhaseActivity, ticker, debate, market_state, watch, ctx,
                                   start_to_close_timeout: 300)
      activity.logger.info "[workflow:phase] ticker=#{ticker} execution done outcome=#{(outcome || {})[:outcome] || (outcome || {})['outcome'] || 'unknown'}"
    end

    # Wraps T_WORKFLOW.execute_activity so a Temporal activity error
    # becomes a structured nil. The caller then substitutes a default
    # state and continues — the workflow always reaches its
    # `[workflow:done]` log line.
    def safe_activity_call(ticker, phase, activity_klass, *args, **opts)
      T_WORKFLOW.execute_activity(activity_klass, *args, **opts)
    rescue StandardError => e
      activity.logger.error "[workflow:phase] ticker=#{ticker} phase=#{phase} activity failed: " \
                              "#{e.class}: #{e.message[0, 300]}"
      nil
    end

    def fast_no_trade?(briefs)
      threshold = TradingConfig.fetch(:debate, :fast_no_trade_avg_confidence).to_i
      return false if threshold.zero? || briefs.blank?

      avg = briefs.values.map { |b| (b['confidence'] || b[:confidence] || 50).to_i }.sum / briefs.size.to_f
      avg < threshold
    end

    def empty_analyst_briefs(ticker)
      Rails.logger.warn "[workflow:fallback] ticker=#{ticker} using empty analyst briefs (activity returned nil)"
      {
        'market_data' => insufficient_brief('activity_nil'),
        'news'        => insufficient_brief('activity_nil'),
        'macro'       => insufficient_brief('activity_nil'),
        'insider'     => insufficient_brief('activity_nil')
      }
    end

    def insufficient_brief(kind)
      {
        'thesis' => "insufficient data (#{kind})",
        'signals' => ["insufficient_data:#{kind}"],
        'confidence' => 50,
        '_error' => { 'kind' => kind }
      }
    end

    def default_debate_result
      {
        transcript: [],
        verdict: {
          'verdict' => 'no_trade',
          'thesis' => 'insufficient data (activity_nil)',
          'trade_plan' => nil,
          'confidence' => 0,
          'no_trade_reasons' => ['insufficient_data:activity_nil'],
          '_error' => { 'kind' => 'activity_nil' }
        }
      }
    end

    # Best-effort watchlist annotation. We don't want a DB hiccup to
    # crash the workflow; just log and move on.
    def record_watchlist_skip(ticker, watch, reason)
      return unless watch && watch['ticker']

      activity.logger.info "[workflow:watchlist] ticker=#{ticker} skip reason=#{reason}"
    end
  end
end
