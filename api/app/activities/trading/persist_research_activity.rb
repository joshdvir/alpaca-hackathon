# frozen_string_literal: true

# PersistResearchActivity — turns the analyst + debate output into
# persistent ResearchPlan / BullCase / BearCase / AnalystReport rows
# so the Research screen has data to show, and so the next cycle can
# see the previous cycle's reasoning.
#
# This was added because the pipeline was running the LLM analysts and
# debate agents in-memory, then either writing (on success) or
# nothing at all (on no_trade / error). The "nothing" path meant the
# Research tab in the UI was always empty even after dozens of
# successful workflow runs — the briefs were computed and thrown
# away. This activity persists them, including the no_trade / error
# cases, with status flags so the UI can show what actually happened.
#
# We always persist SOMETHING for every ticker that reaches the
# debate phase, so the screen never goes blank for long. We mark
# `recommendation: 'neutral'` for error cases so the validation passes
# (the schema requires inclusion in %w[bullish bearish neutral]).

module Trading
  class PersistResearchActivity < ApplicationActivity
    # Map analyst key -> bare agent name (matches the
    # `analyst_name` validation in AnalystReport model). The AgentRun
    # table stores the full namespaced class name, so we keep the
    # namespace for the AgentRun lookup and strip it for the
    # AnalystReport row.
    ANALYST_PERSIST = {
      'market_data' => { class: 'Analyst::MarketDataAnalyst', bare: 'market_data' },
      'news'        => { class: 'Analyst::NewsAnalyst',        bare: 'news' },
      'macro'       => { class: 'Analyst::MacroAnalyst',       bare: 'macro' },
      'insider'     => { class: 'Analyst::InsiderAnalyst',     bare: 'insider' }
    }.freeze

    def execute(ticker, analyst_briefs, debate, ctx)
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id]
      run_id      = ctx['run_id']      || ctx[:run_id]

      activity.logger.info "[activity:start] PersistResearch ticker=#{ticker} workflow_id=#{workflow_id}"

      plan_id = persist_research_plan(ticker, debate, workflow_id, run_id)
      persist_analyst_reports(ticker, analyst_briefs, workflow_id, run_id)
      persist_debate_cases(ticker, debate, workflow_id, run_id)

      activity.logger.info "[activity:done] PersistResearch ticker=#{ticker} plan_id=#{plan_id}"
      plan_id
    end

    private

    # Upsert a ResearchPlan so the screen always has a row for
    # this ticker. We use the most recent AgentRun for the
    # research_manager to satisfy the belongs_to. The verdict
    # drives `recommendation` (one of %w[bullish bearish neutral]);
    # no_trade / errors fall back to 'neutral' with
    # `synthesis` explaining what happened.
    def persist_research_plan(ticker, debate, workflow_id, run_id)
      verdict = (debate.is_a?(Hash) ? (debate[:verdict] || debate['verdict']) : nil) || {}
      verdict_str = (verdict[:verdict] || verdict['verdict']).to_s
      confidence = (verdict[:confidence] || verdict['confidence']).to_i
      # REGRESSION FIX: the original code read `verdict['synthesis']`
      # but the ResearchManager parser returns `verdict['thesis']` (per
      # app/agents/debate/research_manager.rb). The miss caused the
      # fallback "(no synthesis — no_trade)" to fire on every plan,
      # even when the LLM had written a thoughtful 200+ word thesis.
      # Also try `trade_plan.synthesis` (some LLM responses put the
      # narrative under the trade_plan object).
      synthesis = (
        verdict[:thesis] || verdict['thesis'] ||
        (verdict[:trade_plan] || {})[:synthesis] || (verdict['trade_plan'] || {})['synthesis']
      ).to_s
      no_trade_reasons = Array(verdict[:no_trade_reasons] || verdict['no_trade_reasons'])

      recommendation =
        case verdict_str
        when 'trade'
          # Trade plan direction: 'bullish' or 'bearish' (per the
          # research_manager prompt). The `trade_plan` payload is a
          # JSON-deserialized hash (string keys); fall back to
          # indifferent access for symbols.
          tp = (verdict[:trade_plan] || verdict['trade_plan'] || {})
          dir = (tp[:direction] || tp['direction'] || 'neutral').to_s
          %w[bullish bearish neutral].include?(dir) ? dir : 'neutral'
        when 'no_trade', ''
          'neutral'
        else
          'neutral'
        end

      # Look up the research_manager's AgentRun for this workflow to
      # satisfy the FK. If we can't find it, use the most recent one
      # for this ticker (defensive — should never happen in practice
      # because the debate always creates a run). If still nil,
      # ResearchPlan.agent_run is `optional: true` so the row is
      # created with agent_run: nil. The synthesis + verdict are
      # the important parts; the FK is an audit nicety.
      run = find_agent_run(workflow_id, run_id, 'Debate::ResearchManager', ticker)
      run ||= AgentRun.where(agent_name: 'Debate::ResearchManager', ticker: ticker).order(created_at: :desc).first

      ResearchPlan.create!(
        agent_run:                 run,
        ticker:                    ticker,
        recommendation:            recommendation,
        confidence:                confidence,
        synthesis:                 synthesis.presence || "(no synthesis — #{verdict_str.presence || 'unknown verdict'})",
        key_catalysts:             [],
        invalidation_conditions:   no_trade_reasons,
        valid_until:               Time.current + TradingConfig.fetch(:workflow, :research_plan_ttl_hours).to_i.hours
      )
    rescue StandardError => e
      activity.logger.error "[persist_research] plan failed for #{ticker}: #{e.class}: #{e.message}"
      nil
    end

    def persist_analyst_reports(ticker, briefs, workflow_id, run_id)
      Array(briefs).each do |(key, brief)|
        next unless ANALYST_PERSIST.key?(key)
        next unless brief.is_a?(Hash)

        meta = ANALYST_PERSIST[key]
        run = find_agent_run(workflow_id, run_id, meta[:class], ticker)
        run ||= AgentRun.where(agent_name: meta[:class], ticker: ticker).order(created_at: :desc).first

        AnalystReport.create!(
          agent_run:        run,
          ticker:           ticker,
          analyst_name:     meta[:bare],
          data_freshness:   'fresh',
          confidence:       (brief['confidence'] || brief[:confidence]).to_i,
          payload:          brief,
          thesis:           brief['thesis'] || brief[:thesis],
          summary:          (brief['thesis'] || brief[:thesis]).to_s[0, 500]
        )
      rescue StandardError => e
        activity.logger.error "[persist_research] analyst report failed for #{ticker}/#{key}: #{e.class}: #{e.message}"
      end
    end

    def persist_debate_cases(ticker, debate, workflow_id, run_id)
      transcript = (debate.is_a?(Hash) ? (debate[:transcript] || debate['transcript']) : nil) || []
      Array(transcript).each do |round|
        side = (round[:speaker] || round['speaker']).to_s
        next unless %w[bull bear].include?(side)

        kind_class = side == 'bull' ? BullCase : BearCase
        run = find_agent_run(workflow_id, run_id, "Debate::#{side == 'bull' ? 'Bull' : 'Bear'}Researcher", ticker)
        run ||= AgentRun.where(agent_name: "Debate::#{side == 'bull' ? 'Bull' : 'Bear'}Researcher", ticker: ticker).order(created_at: :desc).first

        kind_class.create!(
          agent_run:  run,
          ticker:     ticker,
          confidence: (round[:conviction] || round['conviction']).to_i,
          narrative:  (round[:argument] || round['argument']).to_s,
          payload:    round
        )
      rescue StandardError => e
        activity.logger.error "[persist_research] debate case failed for #{ticker}/#{side}: #{e.class}: #{e.message}"
      end
    end

    def find_agent_run(workflow_id, run_id, agent_name, ticker)
      return nil unless workflow_id
      AgentRun.where(
        temporal_workflow_id: workflow_id,
        agent_name:           agent_name,
        ticker:               ticker
      ).order(created_at: :desc).first
    end

    def camelize(s)
      s.split('_').map(&:capitalize).join
    end
  end
end
