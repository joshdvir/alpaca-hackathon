# frozen_string_literal: true

# FetchPositionOriginActivity — returns the `origin` value for a
# given position. Used by ReviewPositionWorkflow as a 1-line
# precheck to skip the LLM review for non-default origins
# (Mid-Band Movers, future strategies, etc. — those have their
# own scheduled close path). The review workflow MUST NOT touch
# the AR connection pool directly (would raise
# Temporalio::Workflow::NondeterminismError), so this read is
# wrapped in an activity.

module Positions
  class FetchPositionOriginActivity < ApplicationActivity
    def execute(position_id)
      position = ::Position.find_by(id: position_id)
      return nil if position.nil?

      position.origin
    end
  end
end
