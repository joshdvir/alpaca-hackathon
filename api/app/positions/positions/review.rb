# frozen_string_literal: true

# Placeholder for position review orchestration logic.
# The actual LLM re-evaluation lives in app/agents/position_review_agent.rb
# (to be written in the next iteration).
# This file holds the orchestration that wires the LLM output to a
# trade_proposal when the recommendation is anything other than "hold".

module Positions
  class Review
    # Called by ReviewPositionWorkflow after the LLM agent runs.
    # Creates a trade_proposal if the recommendation is an action.
    def self.apply(position_review)
      case position_review.recommendation
      when 'hold'
        position_review.update!(status: 'no_action')
        nil
      when 'close', 'roll', 'adjust', 'add'
        proposal = build_proposal(position_review)
        proposal.save!
        position_review.update!(status: 'action_approved')
        proposal
      else
        Rails.logger.warn "[position_review] unknown recommendation: #{position_review.recommendation}"
        position_review.update!(status: 'rejected')
        nil
      end
    end

    def self.build_proposal(review)
      TradeProposal.new(
        ticker: review.ticker,
        kind: review.recommendation, # 'close' | 'roll' | 'adjust' | 'add'
        strategy_type: review.trade_proposal&.strategy_type || 'hold',
        legs: review.new_legs,
        max_loss: 0,
        max_profit: 0,
        rationale: review.rationale,
        closes_position: review.trade_proposal,
        status: 'pending'
      )
    end
  end
end
