# frozen_string_literal: true

# PositionWorkflowsWorker — registers the position monitor and review
# workflows plus their activities on a separate task queue. Splitting the
# queue lets us scale position workers independently from the trading
# pipeline (positions churn 24/7; trading is market-hours heavy).

class PositionWorkflowsWorker < ApplicationWorker
  def self.workflows_arr
    [
      Positions::MonitorPositionWorkflow,
      Positions::ReviewPositionWorkflow,
      Positions::ReviewAllPositionsWorkflow,
      # Mid-Band Movers strategy. The parent workflow is invoked by
      # the `mid-band-movers` Temporal schedule; the child
      # SellWorkflows sleep until planned_sell_at then call
      # SubmitSellOrderActivity. Both run on position-queue so the
      # position worker process is the single owner of all
      # position-related activity.
      MidBandMovers::RunMidBandMoversWorkflow,
      MidBandMovers::SellWorkflow,
      # Overnight Reversal strategy. Parent fires 9:35 AM ET
      # Mon–Fri, builds a 0DTE long-call/bear-call-spread plan,
      # submits orders, and spawns a CloseWorkflow child that
      # sleeps to 15:55 ET then runs ClosePositionsActivity.
      OvernightReversal::RunOvernightReversalWorkflow,
      OvernightReversal::CloseOvernightReversalWorkflow
    ]
  end

  def self.activities_arr
    [
      Positions::RunPositionMonitorActivity,
      Positions::RunPositionReviewActivity,
      Positions::RunPositionAdjustmentActivity,
      Positions::IncrementHoldStreakActivity,
      Positions::ResetHoldStreakActivity,
      Positions::FetchEligiblePositionsActivity,
      Positions::FetchPositionOriginActivity,
      # Mid-Band Movers strategy activities (parent + child).
      MidBandMovers::BuildPlanActivity,
      MidBandMovers::SubmitBuyOrdersActivity,
      MidBandMovers::SubmitSellOrderActivity,
      MidBandMovers::FindMbmPositionActivity,
      # Overnight Reversal strategy activities.
      OvernightReversal::BuildPlanActivity,
      OvernightReversal::SubmitOrdersActivity,
      OvernightReversal::ClosePositionsActivity
    ]
  end

  def self.task_queues = ['position-queue']
end
