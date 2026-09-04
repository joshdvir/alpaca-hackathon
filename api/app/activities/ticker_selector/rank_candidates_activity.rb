# frozen_string_literal: true

module TickerSelector
  class RankCandidatesActivity < ApplicationActivity
    def execute(candidates)
      max_n = TradingConfig.fetch(:ticker_selector, :max_recommended)
      activity.logger.info "[ticker_selector] RankCandidates starting: input=#{candidates.size} max=#{max_n}"
      activity.heartbeat("starting LLM rank of #{candidates.size} candidates")

      ranked = TickerSelectorAgent.call(
        candidates,
        workflow_id: activity.info.workflow_id,
        run_id: activity.info.workflow_run_id
      )
      activity.heartbeat("LLM rank returned #{ranked.size} ranked")
      trimmed = ranked.first(max_n)
      activity.logger.info "[ticker_selector] RankCandidates done: ranked=#{ranked.size} after-trim=#{trimmed.size}"
      trimmed
    end
  end
end
