# frozen_string_literal: true

# FetchEligiblePositionsActivity — returns the list of open
# position IDs that the review cycle should spawn a child
# ReviewPositionWorkflow for. Excludes positions that have hit
# `position_review.exit_after_hold_cycles` consecutive hold
# verdicts (the hold-exit optimization).
#
# This activity exists because Temporal workflows cannot touch
# ActiveRecord (the AR connection pool uses Thread::Mutex, which
# raises Temporalio::Workflow::NondeterminismError). The parent
# ReviewAllPositionsWorkflow calls this activity to get the work
# set, then spawns one parented child workflow per returned id.
module Positions
  class FetchEligiblePositionsActivity < ApplicationActivity
    def execute
      hold_exit = TradingConfig.fetch(:position_review, :exit_after_hold_cycles)
      eligible = ::Position.open.where('hold_streak < ?', hold_exit)
      {
        eligible_position_ids: eligible.pluck(:id),
        skipped_hold_stable: ::Position.open.where('hold_streak >= ?', hold_exit).count,
        hold_exit_threshold: hold_exit
      }
    end
  end
end
