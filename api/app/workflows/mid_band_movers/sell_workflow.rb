# frozen_string_literal: true

# SellWorkflow — child of RunMidBandMoversWorkflow. Waits until
# `planned_sell_at` (passed in as a Time), then calls
# SubmitSellOrderActivity to close the position. One-shot per
# scheduled sell.
#
# Why a child workflow (not just an activity scheduled from the
# parent): the parent RunMidBandMoversWorkflow is itself one-shot
# per tick (driven by the `mid-band-movers` Temporal schedule).
# Spawning a child lets the parent exit immediately after kicking
# off the buy activity, while the sell waits in its own history.
# Each child has its own workflow ID (suffixed with the planned
# sell timestamp) so multiple sells from the same tick are
# independently observable in the UI.
#
# The child workflow sleeps with `T_WORKFLOW.sleep(...)` until
# the planned sell time, then calls a "find position" activity
# to resolve the current DB position by symbol (the position
# may not exist yet at child-spawn time — AlpacaSync creates it
# after the buy order fills). Sleeping inside a workflow is
# replay-deterministic (unlike mutex-based IO), so this is the
# safe pattern.

module MidBandMovers
  class SellWorkflow < ApplicationWorkflow
    def execute(payload)
      option_symbol = payload['option_symbol']
      bucket = payload['bucket']
      planned_sell_at_iso = payload['planned_sell_at']

      workflow_id = T_WORKFLOW.info.workflow_id
      activity.logger.info "[mbm_sell:#{option_symbol}/#{bucket}] starting (workflow_id=#{workflow_id})"

      planned_sell_at = Time.iso8601(planned_sell_at_iso)
      # `Time.now` is non-deterministic inside a workflow and raises
      # NondeterminismError. Use `T_WORKFLOW.now` instead — it
      # returns UTC and is replay-safe (the same value the server
      # gives us on this workflow task).
      now = T_WORKFLOW.now
      delay = planned_sell_at - now
      if delay.positive?
        activity.logger.info "[mbm_sell:#{option_symbol}/#{bucket}] sleeping #{delay.round(1)}s until planned_sell_at=#{planned_sell_at.iso8601}"
        T_WORKFLOW.sleep(delay)
      end

      ctx = { 'workflow_id' => workflow_id, 'run_id' => T_WORKFLOW.info.run_id }

      # The position is created by AlpacaSync after the buy order
      # fills. Resolve it inside an activity (workflows must not
      # touch the AR connection pool — would raise
      # Temporalio::Workflow::NondeterminismError).
      position_id = T_WORKFLOW.execute_activity(
        FindMbmPositionActivity,
        option_symbol, bucket, ctx,
        start_to_close_timeout: 30
      )

      if position_id.nil?
        activity.logger.warn "[mbm_sell:#{option_symbol}/#{bucket}] no open position found at sell time — noop"
        return { outcome: 'noop', reason: 'no_position' }
      end

      result = T_WORKFLOW.execute_activity(
        SubmitSellOrderActivity,
        position_id, ctx,
        start_to_close_timeout: 120
      )

      activity.logger.info "[mbm_sell:#{option_symbol}/#{bucket}] sell_outcome=#{result[:outcome].inspect}"
      result
    end
  end
end
