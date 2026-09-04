# frozen_string_literal: true

# Add `hold_streak` to positions — a counter for consecutive "hold"
# verdicts from ReviewPositionWorkflow. When the counter reaches
# `position_review.exit_after_hold_cycles` (default 4), the position
# is considered "stable" and the review cycle can skip it (saves LLM
# cost on positions that aren't moving).
#
# The counter used to live in a local variable inside the
# ReviewPositionWorkflow's internal loop. The loop is being removed
# (the workflow becomes one-shot per tick, driven by a Temporal
# schedule), so the counter needs to persist across workflow
# executions. Storing it on the Position row keeps the data with
# the position it describes, and lets the schedule do a quick
# `Position.open.where("hold_streak < ?", HOLD_EXIT)` filter to
# skip stable positions.
class AddHoldStreakToPositions < ActiveRecord::Migration[8.0]
  def change
    add_column :positions, :hold_streak, :integer, default: 0, null: false
    add_index  :positions, [:hold_streak]
  end
end
