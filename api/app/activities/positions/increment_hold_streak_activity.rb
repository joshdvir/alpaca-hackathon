# frozen_string_literal: true

# IncrementHoldStreakActivity — bumps Position.hold_streak by 1.
# Used by ReviewPositionWorkflow when the LLM returns "hold" (or a
# parse failure / unknown action that we treat as hold). After N
# consecutive increments, ReviewAllPositionsWorkflow stops scheduling
# new review ticks for the position.

module Positions
  class IncrementHoldStreakActivity < ApplicationActivity
    def execute(position_id)
      position = ::Position.find(position_id)
      new_streak = position.hold_streak.to_i + 1
      position.update!(hold_streak: new_streak)
      activity.logger.info "[hold_streak] position=#{position.id} streak=#{new_streak}"
      { position_id: position.id, hold_streak: new_streak }
    end
  end
end
