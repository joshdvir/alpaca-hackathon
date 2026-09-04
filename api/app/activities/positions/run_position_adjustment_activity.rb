# frozen_string_literal: true

# RunPositionAdjustmentActivity — executes a non-hold review decision
# (close, roll, adjust, add) on a position. The activity does ALL the
# DB and broker work in one place so the calling workflow stays
# deterministic (no AR / connection-pool access from inside a Temporal
# workflow loop).
#
# Steps:
#   1. Re-fetch the position (cheap, indexed by PK).
#   2. Build the closing/opening leg from the review's adjustment
#      details (or a default if the LLM didn't supply them).
#   3. Create a TradeProposal (kind: <review action>) associated
#      with the position via closes_position.
#   4. Run RiskManager.check — if rejected, mark the proposal rejected
#      and return.
#   5. Mark the proposal risk_approved and call PortfolioManager.execute.
#   6. Mark the proposal cancelled if the broker rejected.

module Positions
  class RunPositionAdjustmentActivity < ApplicationActivity
    def execute(position_id, review_result, ctx)
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id]
      position = ::Position.find(position_id)

      # Defensive: the LLM can return action=nil (parse failure) or an
      # action we don't model in TradeProposal::KINDS. The workflow
      # also has its own gate (`if result[:action] == 'hold'`) but a
      # nil action slips through (nil != 'hold'). Skip cleanly here
      # so the workflow can keep looping on the next cycle.
      action = review_result[:action].to_s
      unless TradeProposal::KINDS.include?(action)
        activity.logger.info(
          "[position_adjustment] skip: action=#{action.inspect} not in KINDS for position=#{position.id}"
        )
        return { proposal_id: nil, outcome: "skipped: action=#{action.inspect} not in KINDS" }
      end

      details = review_result.dig(:adjustment, :details) || {}
      symbol  = position.symbol
      side_qty = position.qty.to_i

      new_leg = {
        'side' => details['side'] || (side_qty.positive? ? 'sell' : 'buy'),
        'ratio_qty' => details['qty'] || 1,
        'option_symbol' => details['symbol'] || symbol,
        'limit_price' => details['limit_price']
      }.compact

      proposal = TradeProposal.create!(
        agent_run: AgentRun.where(temporal_workflow_id: workflow_id).order(created_at: :desc).first,
        ticker: symbol.to_s.split(/\d/).first.to_s, # OCC symbol starts with the underlying root
        kind: action,
        strategy_type: 'hold', # not used for the closing leg shape, but the column is NOT NULL
        legs: [new_leg],
        max_loss: 0,
        max_profit: 0,
        rationale: "position_review: #{review_result[:reason]}",
        status: 'pending',
        closes_position: position
      )

      decision = Risk::RiskManager.new.check(proposal)
      if decision.rejected?
        proposal.update!(status: 'rejected')
        return { proposal_id: proposal.id, outcome: 'rejected_by_risk' }
      end

      proposal.update!(status: 'risk_approved')
      out = Portfolio::PortfolioManager.execute(proposal)
      proposal.update!(status: 'cancelled') unless out.ok?

      {
        proposal_id: proposal.id,
        outcome: out.ok? ? 'submitted' : "broker_rejected: #{out.reasons.join('; ')}"
      }
    end
  end
end
