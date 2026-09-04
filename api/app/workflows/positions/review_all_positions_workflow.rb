# frozen_string_literal: true

# ReviewAllPositionsWorkflow — parent workflow driven by the
# `position-review-all` Temporal schedule (every 30 min). Iterates
# over all open positions and spawns one parented child
# `ReviewPositionWorkflow` per position. Each child is one-shot.
#
# Why a parent + parented children rather than per-position
# schedules:
#   - Single Temporal schedule to manage (vs N schedules, one per
#     position, with create-on-fill / delete-on-close lifecycle).
#   - Schedule overlap protection: if a tick takes longer than
#     30 min, Temporal refuses to start a second tick while the
#     previous one is still running (default overlap policy).
#   - Each child is independently observable in the UI and can
#     fail without affecting other positions.
#
# The `hold_streak` column on Position is the gate: if a position
# has hit `exit_after_hold_cycles` consecutive "hold" verdicts,
# we skip it (the LLM is being asked to look at a stable position
# and the answer is "nothing to do" — that's wasted spend).

module Positions
  class ReviewAllPositionsWorkflow < ApplicationWorkflow
    def execute
      activity.logger.info '[review_all_positions] starting'

      # Touching AR (Position.open.where) inside a workflow raises
      # Temporalio::Workflow::NondeterminismError because the
      # connection pool uses Thread::Mutex.synchronize. Wrap the
      # DB read in an activity and use only the returned IDs in
      # the workflow.
      result = T_WORKFLOW.execute_activity(
        FetchEligiblePositionsActivity,
        start_to_close_timeout: 30
      )

      ids = result[:eligible_position_ids] || []
      activity.logger.info "[review_all_positions] eligible=#{ids.size} " \
                            "skipped_hold_stable=#{result[:skipped_hold_stable]} " \
                            "hold_exit=#{result[:hold_exit_threshold]}"

      ids.each do |position_id|
        # Parented child workflow — Temporal will tie the child's
        # lifecycle to this parent. The child ID is unique per tick
        # (timestamp suffix) so each tick produces a fresh execution
        # with its own history.
        child_id = "review-#{position_id}-#{Time.now.to_f.to_s.tr('.', '')}"
        T_WORKFLOW.execute_child_workflow(
          ReviewPositionWorkflow,
          position_id,
          id: child_id,
          # Use the same task queue as the position workflows worker.
          task_queue: 'position-queue'
        )
      end

      activity.logger.info '[review_all_positions] done'
    end
  end
end
