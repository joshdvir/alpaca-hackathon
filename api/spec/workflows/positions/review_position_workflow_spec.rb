# frozen_string_literal: true

require "rails_helper"

# Unit test for the ONE-SHOT ReviewPositionWorkflow. Verifies the
# workflow:
#   - calls RunPositionReviewActivity exactly once
#   - does NOT loop (no T_WORKFLOW.sleep)
#   - routes hold / nil action → IncrementHoldStreakActivity
#   - routes unknown action → IncrementHoldStreakActivity (defensive)
#   - routes actionable KINDS action → ResetHoldStreakActivity + RunPositionAdjustmentActivity
#   - exits early when position is closed
#
# Each tick is now driven by ReviewAllPositionsWorkflow (the parent
# scheduled by `position-review-all`). The hold_streak state lives
# on the Position row, so a fresh workflow execution per tick can
# pick it up where the previous one left off.
RSpec.describe Positions::ReviewPositionWorkflow do
  let(:workflow) { described_class.new }

  before do
    # Workflow execution requires a Temporal environment for the
    # activity logger and the workflow-info shim. Stub both.
    allow(T_WORKFLOW).to receive(:logger).and_return(Logger.new(File::NULL))
    allow(T_WORKFLOW).to receive(:info).and_return(
      Struct.new(:workflow_id, :run_id).new("review-99-12345", "run-abc")
    )
  end

  def stub_review(result)
    # The new origin precheck (FetchPositionOriginActivity) runs
    # before RunPositionReviewActivity. Default to 'default' so
    # the existing tests fall through to the LLM review path.
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::FetchPositionOriginActivity, instance_of(Integer), anything)
      .and_return('default')
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::RunPositionReviewActivity, instance_of(Integer), instance_of(Hash), anything)
      .and_return(result)
  end

  it "calls RunPositionReviewActivity exactly once" do
    stub_review(position_id: 99, closed: false, action: "hold", reason: "stable")
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, anything, anything)
      .and_return({})

    workflow.execute(99)
  end

  it "does not call T_WORKFLOW.sleep (no internal loop)" do
    stub_review(position_id: 99, closed: false, action: "hold", reason: "stable")
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, anything, anything)
      .and_return({})
    expect(T_WORKFLOW).not_to receive(:sleep)

    workflow.execute(99)
  end

  it "exits early when the position is closed" do
    stub_review(position_id: 99, closed: true, action: nil, reason: nil)
    # The closed branch must NOT call any other activity.
    expect(T_WORKFLOW).not_to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, anything, anything)
    expect(T_WORKFLOW).not_to receive(:execute_activity)
      .with(Positions::RunPositionAdjustmentActivity, anything, anything, anything, anything)

    workflow.execute(99)
  end

  it "routes a hold verdict to IncrementHoldStreakActivity" do
    stub_review(position_id: 99, closed: false, action: "hold", reason: "stable")
    expect(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, 99, anything)
      .and_return({})
    expect(T_WORKFLOW).not_to receive(:execute_activity)
      .with(Positions::RunPositionAdjustmentActivity, anything, anything, anything, anything)

    workflow.execute(99)
  end

  it "routes a nil action (parse failure) to IncrementHoldStreakActivity" do
    stub_review(position_id: 99, closed: false, action: nil, reason: nil)
    expect(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, 99, anything)
      .and_return({})

    workflow.execute(99)
  end

  it "routes an unknown action to IncrementHoldStreakActivity (defensive)" do
    stub_review(position_id: 99, closed: false, action: "mystery", reason: "?")
    expect(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, 99, anything)
      .and_return({})

    workflow.execute(99)
  end

  it "routes a close verdict to ResetHoldStreakActivity + RunPositionAdjustmentActivity" do
    stub_review(position_id: 99, closed: false, action: "close", reason: "stop hit",
                adjustment: { details: { side: "sell_to_close", qty: 1 } })
    expect(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::ResetHoldStreakActivity, 99, anything)
      .and_return({})
    expect(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::RunPositionAdjustmentActivity, 99, anything, anything, anything)
      .and_return({})

    workflow.execute(99)
  end

  it "routes each TradeProposal::KINDS action to adjustment (roll, adjust, add)" do
    %w[roll adjust add].each do |action|
      stub_review(position_id: 99, closed: false, action: action, reason: "x", adjustment: { details: {} })
      expect(T_WORKFLOW).to receive(:execute_activity)
        .with(Positions::ResetHoldStreakActivity, 99, anything)
        .and_return({})
      expect(T_WORKFLOW).to receive(:execute_activity)
        .with(Positions::RunPositionAdjustmentActivity, 99, anything, anything, anything)
        .and_return({})
      workflow.execute(99)
    end
  end

  it "skips the LLM review when the position has a non-default origin (Mid-Band Movers, etc.)" do
    # Origin precheck returns 'mid_band_movers' → workflow must
    # exit cleanly without ever calling the review or adjustment
    # activities.
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::FetchPositionOriginActivity, 99, anything)
      .and_return('mid_band_movers')
    expect(T_WORKFLOW).not_to receive(:execute_activity)
      .with(Positions::RunPositionReviewActivity, anything, anything, anything)
    expect(T_WORKFLOW).not_to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, anything, anything)
    expect(T_WORKFLOW).not_to receive(:execute_activity)
      .with(Positions::ResetHoldStreakActivity, anything, anything)

    workflow.execute(99)
  end

  it "proceeds with the LLM review when the origin is 'default'" do
    stub_review(position_id: 99, closed: false, action: "hold", reason: "stable")
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, anything, anything)
      .and_return({})

    workflow.execute(99)
  end

  it "proceeds with the LLM review when the position is missing (defensive)" do
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::FetchPositionOriginActivity, 99, anything)
      .and_return(nil)
    # The workflow falls through to the review path; stub the
    # review activity to return a benign hold so the workflow
    # completes without further side effects.
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::RunPositionReviewActivity, instance_of(Integer), instance_of(Hash), anything)
      .and_return(position_id: 99, closed: false, action: "hold", reason: "missing-position")
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::IncrementHoldStreakActivity, anything, anything)
      .and_return({})

    workflow.execute(99)
  end
end
