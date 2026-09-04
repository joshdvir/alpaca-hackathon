# frozen_string_literal: true

require "rails_helper"

# Unit test for MidBandMovers::SellWorkflow. The child workflow
# waits until planned_sell_at, looks up the position via
# FindMbmPositionActivity, then calls SubmitSellOrderActivity.
#
# Verifies:
#   - sleeps when planned_sell_at is in the future
#   - does NOT sleep when planned_sell_at is in the past
#   - returns "noop" when no position is found at sell time
#   - calls SubmitSellOrderActivity with the resolved position_id

RSpec.describe MidBandMovers::SellWorkflow do
  let(:workflow) { described_class.new }

  before do
    allow(T_WORKFLOW).to receive(:logger).and_return(Logger.new(File::NULL))
    allow(T_WORKFLOW).to receive(:info).and_return(
      instance_double('Temporalio::Workflow::Info', workflow_id: 'mbm-sell-1', run_id: 'run-1')
    )
    # The workflow uses T_WORKFLOW.now (replay-safe clock). Stub
    # to a fixed moment so the `delay.positive?` branch is
    # deterministic in the future/past specs.
    allow(T_WORKFLOW).to receive(:now).and_return(Time.now.utc)
  end

  it "sleeps until planned_sell_at when it is in the future" do
    future = (Time.now.utc + 3600).iso8601
    allow(T_WORKFLOW).to receive(:sleep).with(a_value > 0)
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::FindMbmPositionActivity, anything, anything, anything, anything)
      .and_return(nil) # no position found
    workflow.execute({ "option_symbol" => "AAPL260515C00200000", "bucket" => "A", "planned_sell_at" => future })
  end

  it "does not sleep when planned_sell_at is already in the past" do
    past = (Time.now.utc - 60).iso8601
    expect(T_WORKFLOW).not_to receive(:sleep)
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::FindMbmPositionActivity, anything, anything, anything, anything)
      .and_return(nil)
    workflow.execute({ "option_symbol" => "AAPL260515C00200000", "bucket" => "A", "planned_sell_at" => past })
  end

  it "returns noop when no position is found at sell time" do
    past = (Time.now.utc - 60).iso8601
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::FindMbmPositionActivity, anything, anything, anything, anything)
      .and_return(nil)
    expect(T_WORKFLOW).not_to receive(:execute_activity)
      .with(MidBandMovers::SubmitSellOrderActivity, anything, anything)

    result = workflow.execute({ "option_symbol" => "AAPL260515C00200000", "bucket" => "A", "planned_sell_at" => past })
    expect(result).to eq(outcome: 'noop', reason: 'no_position')
  end

  it "calls SubmitSellOrderActivity with the resolved position_id" do
    past = (Time.now.utc - 60).iso8601
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::FindMbmPositionActivity, anything, anything, anything, anything)
      .and_return(42)
    expect(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::SubmitSellOrderActivity, 42, anything, anything)
      .and_return(outcome: 'submitted', order: 1)

    result = workflow.execute({ "option_symbol" => "AAPL260515C00200000", "bucket" => "A", "planned_sell_at" => past })
    expect(result[:outcome]).to eq('submitted')
  end

  it "does not touch AR (workflows must not query DB directly)" do
    past = (Time.now.utc - 60).iso8601
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(MidBandMovers::FindMbmPositionActivity, anything, anything, anything, anything)
      .and_return(nil)

    expect(Position).not_to receive(:open)
    expect(TradeProposal).not_to receive(:create!)
    workflow.execute({ "option_symbol" => "AAPL260515C00200000", "bucket" => "A", "planned_sell_at" => past })
  end
end
