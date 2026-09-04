# frozen_string_literal: true

# RunOvernightReversalWorkflow — parent workflow driven by the
# `overnight-reversal` Temporal schedule (cron `35 9 * * 1-5` ET —
# 9:35 AM Mon–Fri, 5 min after the open). Pipeline:
#
#   1. BuildPlanActivity          → serialized Plan hash (skipped if half-day)
#   2. SubmitOrdersActivity       → winners (single-leg long calls) +
#                                   losers (mleg bear-call credit spreads)
#   3. Spawn one CloseWorkflow child per tick. The child sleeps until
#      15:55 ET and then calls ClosePositionsActivity to flatten
#      everything from this tick.
#
# This workflow is one-shot per tick. The parent exits as soon as the
# orders are submitted and the close child is spawned. The child owns
# the long-lived wait until market close.
#
# Skipped days: when the plan comes back with `skipped: true`
# (half-day, no survivors, exception), the workflow logs and exits
# cleanly. No orders, no close child.

module OvernightReversal
  class RunOvernightReversalWorkflow < ApplicationWorkflow
    # Temporal uses the unqualified class name as the workflow
    # type by default. We override to disambiguate from any other
    # workflow in the same namespace that might share the class name.
    workflow_name 'OvernightReversal::RunOvernightReversalWorkflow'

    # ParentClosePolicy::TERMINATE — when this workflow ends (e.g.
    # because the inner BuyWorkflow already cleared the positions),
    # also cancel the child CloseWorkflow. We use TERMINATE rather
    # than ABANDON so the child stops immediately.
    ParentClosePolicy = Temporalio::Workflow::ParentClosePolicy

    def execute
      workflow_id = T_WORKFLOW.info.workflow_id
      run_id = T_WORKFLOW.info.run_id
      ctx = { 'workflow_id' => workflow_id, 'run_id' => run_id }
      activity.logger.info "[ovn:start] workflow_id=#{workflow_id}"

      plan = T_WORKFLOW.execute_activity(
        BuildPlanActivity, ctx,
        start_to_close_timeout: 300
      )

      if (plan.is_a?(Hash) ? plan['skipped'] : false) || (plan.is_a?(Hash) && Array(plan['winners']).empty? && Array(plan['losers']).empty?)
        activity.logger.info "[ovn:plan] workflow_id=#{workflow_id} skipped=#{plan['skipped_reason'].inspect} — exiting (no orders, no close child)"
        return
      end

      activity.logger.info "[ovn:plan] tick_date=#{plan['tick_date']} " \
                          "winners=#{Array(plan['winners']).size} losers=#{Array(plan['losers']).size} " \
                          "deployed=#{plan['total_cash_deployed']} " \
                          "close_at_et=#{plan['close_at_et']}"

      result = T_WORKFLOW.execute_activity(
        SubmitOrdersActivity, plan, ctx,
        start_to_close_timeout: 600
      )

      outcomes = Array((result[:orders] || result['orders']) || [])
      outcomes = outcomes.map { |o| o.transform_keys(&:to_s) }
      submitted = outcomes.select { |o| o['status'] == 'submitted' }
      activity.logger.info "[ovn:buy] workflow_id=#{workflow_id} submitted=#{submitted.size} " \
                           "no_chain=#{outcomes.count { |o| o['status'] == 'no_chain' }} " \
                           "rejected=#{outcomes.count { |o| o['status'] == 'rejected_by_risk' }} " \
                           "broker_err=#{outcomes.count { |o| o['status'] == 'broker_error' }}"

      if submitted.empty?
        activity.logger.info '[ovn:buy] nothing submitted — no close child needed'
        return
      end

      # One close child per tick. Child workflow sleeps until
      # `close_at_et` (plan['close_at_et']) and runs ClosePositionsActivity.
      child_id = "ovn-close-#{plan['tick_date']}-#{workflow_id}"
      T_WORKFLOW.execute_child_workflow(
        CloseOvernightReversalWorkflow,
        { 'tick_date' => plan['tick_date'], 'close_at_et' => plan['close_at_et'] },
        id: child_id,
        task_queue: 'position-queue',
        parent_close_policy: ParentClosePolicy::TERMINATE
      )

      activity.logger.info "[ovn:done] workflow_id=#{workflow_id} scheduled=#{submitted.size} close child for tick_date=#{plan['tick_date']}"
    end
  end
end
