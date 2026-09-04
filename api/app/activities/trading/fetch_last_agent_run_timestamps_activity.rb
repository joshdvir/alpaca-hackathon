# frozen_string_literal: true

# FetchLastAgentRunTimestampsActivity — returns the most-recent
# per-ticker AgentRun timestamp as a hash
# `{ ticker => last_run_epoch_seconds }`.
#
# The SchedulerWorkflow needs to know "is this ticker due for a new
# cycle?" — i.e. has it been processed in the last `cycle_minutes`
# minutes? Computing that requires reading AgentRun rows, which is IO
# and cannot run inside a workflow (Temporal's deterministic replay
# would fail with NondeterminismError if it tried). The workflow calls
# this activity instead, gets back a plain hash, and does the
# comparison in deterministic time (T_WORKFLOW.now vs epoch seconds).
#
# Schema notes (the original SchedulerWorkflow query got these wrong):
#   - The relevant column is `agent_name` (not `agent_class`).
#   - The `agent_name` value is the agent/workflow class basename, e.g.
#     "TickerSelectorAgent" or "ProcessTickerWorkflow".
#   - The dedicated `ticker` column on AgentRun is always NULL in
#     practice — the ticker is stored inside `input_payload` (a JSONB
#     column). We extract it from there.
#
# Missing tickers simply don't appear in the hash — the workflow treats
# absence as "never run, due immediately". The hash is small (a few
# hundred bytes) and round-trips through Temporal's JSON converter
# without surprises.

module Trading
  class FetchLastAgentRunTimestampsActivity < ApplicationActivity
    # Agent names that count as "ticker was processed". Adding more here
    # is a one-line change; the workflow stays oblivious to which
    # agents exist.
    TRACKED_AGENTS = %w[
      ProcessTickerWorkflow
      TickerSelectorAgent
    ].freeze

    def execute
      relation = AgentRun.where(agent_name: TRACKED_AGENTS)
                         .order(created_at: :desc)
                         .limit(10_000)
      relation.each_with_object({}) do |run, acc|
        ticker = run.input_payload.is_a?(Hash) ? run.input_payload['ticker'] : nil
        next if ticker.blank?
        next if acc.key?(ticker) # keep only the most recent

        acc[ticker] = run.created_at.to_i
      end
    end
  end
end

