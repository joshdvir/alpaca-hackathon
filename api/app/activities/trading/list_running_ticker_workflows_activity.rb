# frozen_string_literal: true

# ListRunningTickerWorkflowsActivity — visibility query against Temporal.
# Returns the workflow_id + run_id + start_time + ticker (from search
# attributes) for every running ProcessTickerWorkflow. The scheduler uses
# this to avoid double-launching a workflow for the same ticker in the
# same cycle.
#
# We filter by WorkflowKind = "process_ticker" so other workflow types
# (TickerSelector, MonitorPosition, etc.) are excluded.

module Trading
  class ListRunningTickerWorkflowsActivity < ApplicationActivity
    # Hard cap on returned rows. The scheduler uses this to avoid
    # double-launching a workflow for the same ticker; we don't need
    # a 100% accurate count, just enough to dedupe within the same
    # cycle. 1,000 covers any realistic same-cycle launch fan-out.
    MAX_RUNNING = 1_000

    def execute
      query = "WorkflowKind = 'process_ticker' AND ExecutionStatus = 'Running'"
      # T_CLIENT.list_workflows returns an Enumerator that pages
      # through every match — `limit:` is NOT a valid kwarg on this
      # version of the SDK. We materialize up to MAX_RUNNING rows
      # via Enumerable#first, which is enough for dedupe within a
      # single cycle.
      T_CLIENT.list_workflows(query).first(MAX_RUNNING).map do |info|
        {
          workflow_id: info.id,
          run_id: info.run_id,
          start_time: info.start_time,
          ticker: extract_ticker(info)
        }
      end
    end

    private

    def extract_ticker(info)
      attrs = info.search_attributes
      return nil if attrs.blank?

      # Search attributes are returned as a Hash keyed by the Key object.
      # We look up by identity to be agnostic of how Temporalio renders the hash.
      attrs.each do |k, v|
        return v if k == TickerKey
      end
      nil
    end
  end
end
