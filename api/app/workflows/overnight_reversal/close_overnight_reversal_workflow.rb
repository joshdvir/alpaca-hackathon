# frozen_string_literal: true

# CloseWorkflow — child of RunOvernightReversalWorkflow. Sleeps until
# 15:55 ET, then calls ClosePositionsActivity to flatten every position
# the strategy created today.
#
# Why a child workflow (not a scheduled activity): the parent
# RunOvernightReversalWorkflow is one-shot per tick (driven by
# `overnight-reversal` Temporal schedule). Spawning a child lets the
# parent exit immediately after kicking off the submit, while the
# close waits in its own history. The child takes its wake time
# from the parent so multiple close children from different ticks
# never collide (each uses `tick_date` + `parent_workflow_id` in its ID).
#
# Time handling: `T_WORKFLOW.now` is replay-deterministic inside the
# workflow; using `Time.now` would break replay determinism.

module OvernightReversal
  class CloseOvernightReversalWorkflow < ApplicationWorkflow
    workflow_name 'OvernightReversal::CloseOvernightReversalWorkflow'

    def execute(payload)
      workflow_id = T_WORKFLOW.info.workflow_id
      close_at_iso = payload['close_at_et']
      tick_date    = payload['tick_date']
      activity.logger.info "[ovn_close:start] workflow_id=#{workflow_id} tick_date=#{tick_date} close_at=#{close_at_iso}"

      close_at = Time.iso8601(close_at_iso)
      now      = T_WORKFLOW.now
      delay    = close_at - now
      if delay.positive?
        activity.logger.info "[ovn_close:sleep] workflow_id=#{workflow_id} sleeping #{delay.round(1)}s until #{close_at.iso8601}"
        T_WORKFLOW.sleep(delay)
      end

      ctx = { 'workflow_id' => workflow_id, 'run_id' => T_WORKFLOW.info.run_id }
      result = T_WORKFLOW.execute_activity(
        ClosePositionsActivity, ctx,
        start_to_close_timeout: 300
      )
      activity.logger.info "[ovn_close:done] workflow_id=#{workflow_id} closed=#{result[:closed] || 0}"
      result
    end
  end
end
