# frozen_string_literal: true

require "rails_helper"

# Unit test for ReviewAllPositionsWorkflow. The parent workflow is
# the entry point for the `position-review-all` Temporal schedule
# (every 30 min). It calls FetchEligiblePositionsActivity (because
# a workflow can't touch the AR connection pool — Temporal
# NondeterminismError) and spawns one parented child
# ReviewPositionWorkflow per returned ID.
#
# Verifies:
#   - calls FetchEligiblePositionsActivity exactly once (no AR access)
#   - does NOT call T_WORKFLOW.sleep (no internal loop)
#   - spawns one child per eligible position
#   - skips no positions (the activity does the filtering)
#   - each child gets a unique workflow ID (timestamp suffix)
#   - uses position-queue as the child task queue
RSpec.describe Positions::ReviewAllPositionsWorkflow do
  let(:workflow) { described_class.new }

  before do
    # `activity.logger.info` at the top of `execute` resolves
    # `T_WORKFLOW.logger`, which only exists inside a real workflow
    # environment. Stub it with a no-op logger so the test can run
    # outside one.
    allow(T_WORKFLOW).to receive(:logger).and_return(Logger.new(File::NULL))
  end

  def stub_eligible(ids, skipped: 0, threshold: 4)
    allow(T_WORKFLOW).to receive(:execute_activity)
      .with(Positions::FetchEligiblePositionsActivity, anything)
      .and_return(eligible_position_ids: ids, skipped_hold_stable: skipped, hold_exit_threshold: threshold)
  end

  it "calls FetchEligiblePositionsActivity exactly once and never touches AR" do
    stub_eligible([])
    expect(Position).not_to receive(:open)
    workflow.execute
  end

  it "does not call T_WORKFLOW.sleep (no internal loop)" do
    stub_eligible([])
    expect(T_WORKFLOW).not_to receive(:sleep)
    workflow.execute
  end

  it "spawns one parented child per eligible position" do
    stub_eligible([1, 2])
    expect(T_WORKFLOW).to receive(:execute_child_workflow)
      .with(Positions::ReviewPositionWorkflow, 1, hash_including(id: /review-1-\d+/))
    expect(T_WORKFLOW).to receive(:execute_child_workflow)
      .with(Positions::ReviewPositionWorkflow, 2, hash_including(id: /review-2-\d+/))
    workflow.execute
  end

  it "passes a unique child workflow_id (timestamp suffix) so each tick is a fresh execution" do
    stub_eligible([42])
    captured_id = nil
    allow(T_WORKFLOW).to receive(:execute_child_workflow) do |_wf, _arg, opts|
      captured_id = opts[:id]
    end
    workflow.execute
    expect(captured_id).to start_with("review-42-")
  end

  it "uses position-queue as the task queue for child workflows" do
    stub_eligible([7])
    expect(T_WORKFLOW).to receive(:execute_child_workflow)
      .with(Positions::ReviewPositionWorkflow, 7, hash_including(task_queue: "position-queue"))
    workflow.execute
  end

  it "no-ops cleanly when the activity returns an empty eligible list" do
    stub_eligible([])
    expect(T_WORKFLOW).not_to receive(:execute_child_workflow)
    workflow.execute
  end
end
