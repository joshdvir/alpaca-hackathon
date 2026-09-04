# frozen_string_literal: true

# TradingWorkflowsWorker — registers the SchedulerWorkflow,
# ProcessTickerWorkflow, and the trading activities on the trading-queue
# task queue. The TickerSelector worker runs on its own queue
# (`ticker-selector-queue`) so the two no longer compete for slots.

class TradingWorkflowsWorker < ApplicationWorker
  def self.workflows_arr
    [
      Trading::SchedulerWorkflow,
      Trading::ProcessTickerWorkflow
    ]
  end

  def self.activities_arr
    [
      Trading::FetchActiveWatchlistActivity,
      Trading::FetchLastAgentRunTimestampsActivity,
      Trading::FetchMarketStateActivity,
      Trading::ListRunningTickerWorkflowsActivity,
      Trading::RunAnalystPhaseActivity,
      Trading::RunDebatePhaseActivity,
      Trading::RunExecutionPhaseActivity,
      Trading::PersistResearchActivity
    ]
  end

  def self.task_queues = ['trading-queue']

  # Tuner defaults for THIS worker. The trading pipeline is LLM-heavy:
  # each ProcessTickerWorkflow fan-outs to 4 analyst LLM calls + 3
  # debate LLM calls + an execution activity, all in a ~30s burst. With
  # a 20-ticker watchlist the worker is tempted to run 80-140 LLM
  # calls in parallel — which trips the upstream MiniMax / Anthropic
  # rate limit. The Tuner caps activities to 5 concurrent, so the worst
  # case is ~20 parallel LLM calls, under the upstream threshold.
  def self.tuner_settings
    {
      workflow_slots: 100,
      activity_slots: 5,
      local_activity_slots: 100
    }
  end
end
