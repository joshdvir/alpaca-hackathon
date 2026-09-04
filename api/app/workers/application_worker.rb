# frozen_string_literal: true

# ApplicationWorker is the base class for all Temporal workers.
# A concrete subclass declares which workflows and activities it handles
# and which task queue it polls, e.g.:
#
#   class TickerSelectorWorker < ApplicationWorker
#     def self.workflows_arr   = [TickerSelector::TickerSelectorWorkflow]
#     def self.activities_arr  = [
#       TickerSelector::FetchUniverseActivity,
#       TickerSelector::ApplyFiltersActivity,
#       TickerSelector::RankCandidatesActivity,
#       TickerSelector::PersistWatchlistActivity
#     ]
#     def self.task_queues     = ["trading-queue"]
#   end
#
# bin/worker instantiates one worker per declared task_queue and runs them.

class ApplicationWorker < T_WORKER
  def self.task_queues
    raise NotImplementedError, "#{name} must declare task_queues"
  end

  def self.workflows_arr
    raise NotImplementedError, "#{name} must declare workflows_arr"
  end

  def self.activities_arr
    raise NotImplementedError, "#{name} must declare activities_arr"
  end

  # Tuner slot defaults. bin/worker reads this Hash and builds the
  # Tuner from it. Subclasses override to tune the slot counts for
  # their own resource profile (e.g. TradingWorkflowsWorker uses a
  # small `activity_slots: 5` so the LLM burst stays under the
  # upstream rate limit).
  #
  # Override in a subclass:
  #
  #   def self.tuner_settings
  #     super.merge(activity_slots: 3)
  #   end
  #
  # Or replace the whole Hash:
  #
  #   def self.tuner_settings
  #     { workflow_slots: 50, activity_slots: 2, local_activity_slots: 50 }
  #   end
  #
  # Returned keys must be a subset of:
  #   :workflow_slots, :activity_slots, :local_activity_slots
  def self.tuner_settings
    {
      workflow_slots: 100,
      activity_slots: 5,
      local_activity_slots: 100
    }
  end
end
