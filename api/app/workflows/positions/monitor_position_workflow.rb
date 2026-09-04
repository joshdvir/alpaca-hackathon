# frozen_string_literal: true

# MonitorPositionWorkflow — deterministic 1-min position check. Calls
# RunPositionMonitorActivity once to refresh Greeks, check breach flags,
# and (if a hard-exit rule triggers) create an auto_close TradeProposal.
#
# This workflow is ONE-SHOT, not a loop. The scheduler (currently the
# AlpacaMirrorWorkflow's `ensure_position_workflows_running` self-heal,
# which runs every minute) re-starts a new execution per tick using a
# unique workflow_id (`monitor-<position_id>-<timestamp>`). The earlier
# design with an internal `loop do ... T_WORKFLOW.sleep(60) ... end`
# kept a single workflow running for the lifetime of the position,
# which made Temporal's history grow unbounded, blocked "did the last
# check succeed?" observability, and pinned a slot in the worker for
# hours. One-shot is the right shape: short history, easy to see each
# tick, and the scheduler (not a `loop`) controls cadence.
#
# Started by:
#   - `AlpacaSync.ensure_position_for_fill` (first fill of a new symbol)
#   - `AlpacaSync.ensure_position_workflows_running` (every mirror tick)

module Positions
  class MonitorPositionWorkflow < ApplicationWorkflow
    def execute(position_id)
      activity.logger.info "[monitor_position:#{position_id}] starting"
      T_WORKFLOW.execute_activity(
        RunPositionMonitorActivity, position_id,
        start_to_close_timeout: 30
      )
    end
  end
end
