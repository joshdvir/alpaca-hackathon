# frozen_string_literal: true

require "rails_helper"

# Tests for the two thin hold_streak activities. These exist so the
# ReviewPositionWorkflow can persist state across ticks (it now runs
# one-shot per tick, driven by the parent schedule) without touching
# the DB from inside a workflow (which would raise
# Temporalio::Workflow::NondeterminismError).
RSpec.describe Positions::IncrementHoldStreakActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: "wf-test", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }
  let(:position) do
    Position.create!(
      symbol: "SPY260116C00500000",
      qty: 1,
      avg_entry_price: 5.0,
      snapshot_at: Time.current,
      hold_streak: 0
    )
  end

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
  end

  it "increments hold_streak by 1" do
    position.update!(hold_streak: 2)
    result = described_class.new.execute(position.id)
    expect(result[:hold_streak]).to eq(3)
    expect(position.reload.hold_streak).to eq(3)
  end

  it "treats a non-positive current value as 0 (clamped before increment)" do
    # The column is NOT NULL with default 0, but the activity's
    # `to_i + 1` defends against legacy rows from before the
    # migration or any manually-edited values.
    position.update_columns(hold_streak: -1)
    result = described_class.new.execute(position.id)
    expect(result[:hold_streak]).to eq(0)
  end

  it "returns the position_id and the new streak" do
    result = described_class.new.execute(position.id)
    expect(result[:position_id]).to eq(position.id)
    expect(result[:hold_streak]).to eq(1)
  end
end

RSpec.describe Positions::ResetHoldStreakActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: "wf-test", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }
  let(:position) do
    Position.create!(
      symbol: "SPY260116C00500000",
      qty: 1,
      avg_entry_price: 5.0,
      snapshot_at: Time.current,
      hold_streak: 3
    )
  end

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
  end

  it "resets hold_streak to 0" do
    result = described_class.new.execute(position.id)
    expect(position.reload.hold_streak).to eq(0)
    expect(result[:previous_hold_streak]).to eq(3)
  end

  it "is a no-op when hold_streak is already 0" do
    position.update!(hold_streak: 0)
    expect { described_class.new.execute(position.id) }.not_to change { position.reload.hold_streak }
  end

  it "returns the position_id and the previous streak" do
    result = described_class.new.execute(position.id)
    expect(result[:position_id]).to eq(position.id)
    expect(result[:previous_hold_streak]).to eq(3)
  end
end
