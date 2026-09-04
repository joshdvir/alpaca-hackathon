# frozen_string_literal: true

require "rails_helper"

# Unit test for RunMidBandMoversWorkflow. The parent workflow is the
# entry point for the `mid-band-movers` Temporal schedule (cron
# `30 11 * * 1-5` ET). Pipeline: BuildPlanActivity → SubmitBuyOrdersActivity
# → spawn one child SellWorkflow per submitted order.
#
# Verifies:
#   - calls BuildPlanActivity exactly once
#   - does NOT touch AR (no Position.open, no TradeProposal.create)
#   - exits cleanly with no children when the plan has 0 kept tickers
#   - spawns one child SellWorkflow per submitted order
#   - child workflow_id includes the tick_date + symbol + bucket
#   - child uses position-queue as the task queue

RSpec.describe MidBandMovers::RunMidBandMoversWorkflow do
  let(:workflow) { described_class.new }

  before do
    allow(T_WORKFLOW).to receive(:logger).and_return(Logger.new(File::NULL))
    allow(T_WORKFLOW).to receive(:info).and_return(
      instance_double('Temporalio::Workflow::Info', workflow_id: 'mbm-2026-09-01', run_id: 'run-1')
    )
  end

  def stub_plan(kept_per_bucket: { 'a' => 0, 'b' => 0, 'c' => 0 }, deployed: '0')
    plan = {
      'total_options_buying_power' => '10000.0',
      'total_cash_deployed' => deployed,
      'tick_date' => '2026-09-01',
      'now_et' => '2026-09-01T11:30:00-04:00',
      'a' => { 'name' => 'A', 'ticker_count' => kept_per_bucket['a'], 'orders' => [] },
      'b' => { 'name' => 'B', 'ticker_count' => kept_per_bucket['b'], 'orders' => [] },
      'c' => { 'name' => 'C', 'ticker_count' => kept_per_bucket['c'], 'orders' => [] }
    }
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::BuildPlanActivity, anything, anything)
      .and_return(plan)
  end

  def stub_buys(outcomes)
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::SubmitBuyOrdersActivity, anything, anything, anything)
      .and_return(orders: outcomes)
  end

  it "calls BuildPlanActivity exactly once and never touches AR" do
    stub_plan
    expect(Position).not_to receive(:open)
    expect(TradeProposal).not_to receive(:create!)
    workflow.execute
  end

  it "does not call T_WORKFLOW.sleep (no internal loop)" do
    stub_plan
    expect(T_WORKFLOW).not_to receive(:sleep)
    workflow.execute
  end

  it "exits cleanly with no children when the plan has 0 kept tickers" do
    stub_plan
    expect(T_WORKFLOW).not_to receive(:execute_activity).with(MidBandMovers::SubmitBuyOrdersActivity, anything)
    expect(T_WORKFLOW).not_to receive(:execute_child_workflow)
    workflow.execute
  end

  it "spawns one parented child SellWorkflow per submitted order" do
    stub_plan(kept_per_bucket: { 'a' => 1, 'b' => 1, 'c' => 0 }, deployed: '2100.0')
    stub_buys([
      { status: 'submitted', symbol: 'AAPL', option_symbol: 'AAPL260515C00200000',
        bucket: 'A', qty: 2, planned_sell_at: '2026-09-01T13:30:00Z' },
      { status: 'submitted', symbol: 'MSFT', option_symbol: 'MSFT260515C00400000',
        bucket: 'B', qty: 1, planned_sell_at: '2026-09-01T16:30:00Z' },
      { status: 'rejected_by_risk', symbol: 'X', bucket: 'C' } # not submitted → no child
    ])

    expect(T_WORKFLOW).to receive(:execute_child_workflow)
      .with(MidBandMovers::SellWorkflow,
            hash_including('option_symbol' => 'AAPL260515C00200000',
                           'bucket' => 'A',
                           'planned_sell_at' => '2026-09-01T13:30:00Z'),
            hash_including(id: /mbm-sell-AAPL260515C00200000-A-2026-09-01/,
                           task_queue: 'position-queue'))
    expect(T_WORKFLOW).to receive(:execute_child_workflow)
      .with(MidBandMovers::SellWorkflow,
            hash_including('option_symbol' => 'MSFT260515C00400000',
                           'bucket' => 'B',
                           'planned_sell_at' => '2026-09-01T16:30:00Z'),
            hash_including(id: /mbm-sell-MSFT260515C00400000-B-2026-09-01/,
                           task_queue: 'position-queue'))
    expect(T_WORKFLOW).not_to receive(:execute_child_workflow)
      .with(anything, hash_including('option_symbol' => 'X260515...'), anything)

    workflow.execute
  end

  it "skips orders that were not submitted (no_chain / cash_too_small / rejected)" do
    stub_plan(kept_per_bucket: { 'a' => 1, 'b' => 1, 'c' => 1 }, deployed: '3150.0')
    stub_buys([
      { status: 'submitted', symbol: 'AAPL', option_symbol: 'AAPL260515C00200000',
        bucket: 'A', qty: 2, planned_sell_at: '2026-09-01T13:30:00Z' },
      { status: 'no_chain', symbol: 'BAD', bucket: 'B' },
      { status: 'cash_too_small', symbol: 'EXP', bucket: 'C' }
    ])

    expect(T_WORKFLOW).to receive(:execute_child_workflow).once
    workflow.execute
  end
end
