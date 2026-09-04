# frozen_string_literal: true

# Placeholder for adjustment orchestration. The actual LLM agent
# (AdjustmentAgent) lives in app/agents/adjustment_agent.rb (next iteration).
# This file is where adjustments are post-processed before going to
# RiskManager -> PortfolioManager.

module Positions
  class Adjustment
    # Validate an AdjustmentAgent proposal before it becomes a TradeProposal.
    # Returns [ok?, reasons[]].
    def self.validate(proposal)
      reasons = []
      reasons << 'no legs' if proposal.legs.blank?
      reasons << 'max_loss exceeds 2x original' if exceeds_loss_tolerance?(proposal)
      [reasons.empty?, reasons]
    end

    def self.exceeds_loss_tolerance?(proposal)
      return false unless proposal.closes_position

      original_loss = proposal.closes_position.avg_entry_price.to_f * 2 # rough
      proposal.max_loss.to_f > original_loss * 2
    end
  end
end
