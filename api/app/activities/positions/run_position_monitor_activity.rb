# frozen_string_literal: true

# RunPositionMonitorActivity — deterministic 1-min check. Calls
# Positions::Monitor.check_position to refresh the position's state and
# check hard-exit rules. If a rule triggers, a TradeProposal (kind:
# auto_close) is created and goes through the normal risk + portfolio
# pipeline downstream. No LLM, no MCP tools in the hot path.

module Positions
  class RunPositionMonitorActivity < ApplicationActivity
    def execute(position_id)
      position = ::Position.find(position_id)
      proposal = Positions::Monitor.check_position(position)
      {
        position_id: position.id,
        status: position.reload.closed? ? 'closed' : 'open',
        auto_close_proposal_id: proposal&.id,
        monitored_at: Time.current
      }
    end
  end
end
