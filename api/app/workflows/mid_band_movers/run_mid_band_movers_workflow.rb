# frozen_string_literal: true

# RunMidBandMoversWorkflow — parent workflow driven by the
# `mid-band-movers` Temporal schedule (cron `30 11 * * 1-5` ET,
# 11:30 AM Mon–Fri, 2h after the 9:30 AM market open). Pipeline:
#
#   1. BuildPlanActivity         → serialized Plan hash
#   2. SubmitBuyOrdersActivity   → fills the 3 buckets via PortfolioManager
#   3. For each order that was submitted, spawn a child
#      SellWorkflow that sleeps until `planned_sell_at` and then
#      calls SubmitSellOrderActivity
#
# This workflow is one-shot per tick. The Temporal schedule fires
# it once per day; the child SellWorkflows are the long-lived
# pieces (they sleep for hours). The parent exits immediately
# after spawning the children, so it doesn't tie up a worker slot
# waiting for the sells to fire.
#
# Empty plan: if BuildPlanActivity returns a plan with zero
# tickers across all 3 buckets, the workflow logs and exits
# cleanly. No children are spawned. The Temporal UI shows the
# "no-trade" run for the day.

module MidBandMovers
  class RunMidBandMoversWorkflow < ApplicationWorkflow
    # Re-export the Temporal SDK constant so the spec can refer to it
    # by the same path the workflow uses (`ParentClosePolicy::TERMINATE`).
    ParentClosePolicy = Temporalio::Workflow::ParentClosePolicy unless const_defined?(:ParentClosePolicy)

    def execute
      workflow_id = T_WORKFLOW.info.workflow_id
      run_id = T_WORKFLOW.info.run_id
      ctx = { 'workflow_id' => workflow_id, 'run_id' => run_id }
      activity.logger.info "[mbm:start] workflow_id=#{workflow_id}"

      plan = T_WORKFLOW.execute_activity(
        BuildPlanActivity, ctx,
        start_to_close_timeout: 300
      )

      kept_total = total_kept(plan)
      activity.logger.info "[mbm:plan] tick_date=#{plan['tick_date']} kept=#{kept_total} deployed=#{plan['total_cash_deployed']}"

      if kept_total.zero?
        activity.logger.info '[mbm:plan] no tickers kept — exiting (no children spawned)'
        return
      end

      buy_result = T_WORKFLOW.execute_activity(
        SubmitBuyOrdersActivity, plan, ctx,
        start_to_close_timeout: 600
      )

      outcomes = Array(buy_result[:orders] || buy_result['orders'])
      # The activity's return hash uses symbol keys, but Temporal
      # serializes the result through JSON, so the keys arrive here
      # as strings. Normalize to strings before filtering.
      outcomes = outcomes.map { |o| o.transform_keys(&:to_s) }
      submitted = outcomes.select { |o| o['status'] == 'submitted' }
      activity.logger.info "[mbm:buy] submitted=#{submitted.size} rejected=#{outcomes.count { |o| o['status'] == 'rejected_by_risk' }} " \
                           "broker_error=#{outcomes.count { |o| o['status'] == 'broker_error' }} " \
                           "no_chain=#{outcomes.count { |o| o['status'] == 'no_chain' }}"

      # Schedule a child SellWorkflow per submitted order. The child
      # ID is unique per sell so multiple sells from the same tick
      # can be tracked independently in the UI. The child takes
      # (option_symbol, bucket, planned_sell_at) — not position_id —
      # because the position is created by AlpacaSync after the buy
      # order fills and may not exist at child-spawn time.
      submitted.each do |order|
        sell_id = "mbm-sell-#{order['option_symbol']}-#{order['bucket']}-#{plan['tick_date']}-#{order['planned_sell_at'].tr(':', '').gsub(/[^0-9]/, '')}"
        T_WORKFLOW.execute_child_workflow(
          SellWorkflow,
          { 'option_symbol' => order['option_symbol'],
            'bucket' => order['bucket'],
            'planned_sell_at' => order['planned_sell_at'] },
          id: sell_id,
          task_queue: 'position-queue',
          parent_close_policy: ParentClosePolicy::TERMINATE
        )
      end

      activity.logger.info "[mbm:done] workflow_id=#{workflow_id} scheduled=#{submitted.size} sell children"
    end

    private

    def total_kept(plan)
      %w[a b c].sum { |k| (plan.dig(k, 'ticker_count') || 0).to_i }
    end
  end
end
