# frozen_string_literal: true

# RunDebatePhaseActivity — runs the bull/bear debate for the configured
# number of rounds, then asks the ResearchManager to summarize. Returns
# the ResearchManager's verdict (trade or no_trade) plus the full transcript
# for later inspection.
#
# Number of rounds is in trading.yml -> debate.rounds.
# `ctx` carries {workflow_id, run_id} for AgentRun tracing.
#
# RESILIENCE: each round and the research manager are wrapped in
# safe_call. A failed round produces a neutral 50-conviction
# placeholder in the transcript (downstream code keeps working). A
# failed research manager produces a no_trade verdict with
# `insufficient_data` in the reasons, which is the correct conservative
# outcome when the LLM can't tell us whether to act.

module Trading
  class RunDebatePhaseActivity < ApplicationActivity
    def execute(ticker, analyst_briefs, ctx)
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id]
      run_id      = ctx['run_id']      || ctx[:run_id]
      rounds = TradingConfig.fetch(:debate, :rounds).to_i
      transcript = []
      context = { analyst_briefs: analyst_briefs }
      activity.logger.info "[activity:start] RunDebatePhaseActivity ticker=#{ticker} rounds=#{rounds}"

      rounds.times do |i|
        # Bull/Bear each take (ticker, side, prior_rounds, context).
        # Pass them positionally so safe_call doesn't have to know
        # which agent wants which shape.
        bull = safe_call(ticker, Debate::BullResearcher, 'bull', i + 1,
                         workflow_id, run_id, ticker, 'bull', transcript, context)
        transcript << round_row(i + 1, 'bull', bull)

        bear = safe_call(ticker, Debate::BearResearcher, 'bear', i + 1,
                         workflow_id, run_id, ticker, 'bear', transcript, context)
        transcript << round_row(i + 1, 'bear', bear)
      end

      # ResearchManager takes (ticker, transcript, analyst_briefs).
      verdict = safe_call(ticker, Debate::ResearchManager, 'research_manager', 0,
                          workflow_id, run_id, ticker, transcript, analyst_briefs)
      activity.logger.info "[activity:done] RunDebatePhaseActivity ticker=#{ticker} verdict=#{verdict[:verdict] || verdict['verdict']} " \
                        "confidence=#{verdict[:confidence] || verdict['confidence']}"

      {
        transcript: transcript,
        verdict: verdict
      }
    end

    private

    def safe_call(ticker, klass, role, round, workflow_id, run_id, *args)
      activity.logger.info "[activity:debate] ticker=#{ticker} round=#{round} role=#{role} agent=#{klass.name}"
      started_at = Time.current
      result = klass.call(*args,
                          workflow_id: workflow_id, run_id: run_id)
      duration_ms = ((Time.current - started_at) * 1000).to_i
      insufficient = result[:_insufficient] || result[:_error] ? ' (insufficient_data)' : ''
      activity.logger.info "[activity:debate] ticker=#{ticker} round=#{round} role=#{role} done #{duration_ms}ms#{insufficient}"
      result
    rescue StandardError => e
      # Defense in depth — Agent.call already rescues. This catches
      # anything that escapes (e.g. AR failures, programmer error).
      duration_ms = ((Time.current - started_at) * 1000).to_i
      activity.logger.error "[activity:debate] ticker=#{ticker} round=#{round} role=#{role} FAILED #{duration_ms}ms: " \
                         "#{e.class}: #{e.message}"
      # Synthesize a no-context placeholder so the transcript stays
      # well-formed. For the research_manager, the caller checks
      # verdict == 'trade' so a no_trade here is the safe path.
      if klass == Debate::ResearchManager
        {
          verdict: 'no_trade',
          thesis: "insufficient data (activity_error)",
          trade_plan: nil,
          confidence: 0,
          no_trade_reasons: ["insufficient_data:activity_error", "error_class:#{e.class.name}"],
          _error: { kind: 'activity_error', class: e.class.name, message: e.message[0, 500] }
        }
      else
        {
          side: 'neutral',
          argument: "insufficient data (activity_error)",
          cited_signals: ["insufficient_data:activity_error", "error_class:#{e.class.name}"],
          conviction: 50,
          _error: { kind: 'activity_error', class: e.class.name, message: e.message[0, 500] }
        }
      end
    end

    def round_row(round, speaker, brief)
      {
        round: round,
        speaker: speaker,
        argument: brief[:argument] || brief['argument'],
        cited_signals: brief[:cited_signals] || brief['cited_signals'] || [],
        conviction: (brief[:conviction] || brief['conviction'] || 50).to_i
      }
    end
  end
end
