# frozen_string_literal: true

# ResetHoldStreakActivity — sets Position.hold_streak to 0. Used by
# ReviewPositionWorkflow when the LLM returns an actionable verdict
# (close/roll/adjust/add). The position is moving again, so the
# hold-exit optimization resets and the parent schedule will keep
# scheduling review ticks for it.

module Positions
  class ResetHoldStreakActivity < ApplicationActivity
    def execute(position_id)
      position = ::Position.find(position_id)
      previous = position.hold_streak.to_i
      position.update!(hold_streak: 0) if previous.positive?
      activity.logger.info "[hold_streak] position=#{position.id} reset (was #{previous})"
      { position_id: position.id, previous_hold_streak: previous }
    end
  end
end
