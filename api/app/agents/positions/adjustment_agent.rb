# frozen_string_literal: true

# AdjustmentAgent — when the position monitor or the review agent decides an
# adjustment is needed, this agent proposes the specific new leg.
# The PortfolioManager turns the proposal into a TradeProposal and routes it
# to risk check.

module Positions
  class AdjustmentAgent < Base
    def user_payload(position, trigger, market_state)
      {
        position: serialize(position),
        trigger: trigger,
        market_state: market_state
      }
    end

    def invoke(position, trigger, market_state)
      chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
      response =
        with_breaker(:llm) do
          RATE_LIMITERS[:llm].with_limit do
            chat.ask(user_payload(position, trigger, market_state).to_json)
          end
        end
      response.content
    end

    private

    def serialize(position)
      {
        id: position.id,
        symbol: position.symbol,
        qty: position.qty,
        side: position.qty.to_i.positive? ? 'long' : 'short',
        avg_entry_price: position.avg_entry_price,
        unrealized_pl: position.unrealized_pl,
        delta: position.delta,
        theta: position.theta
      }
    end
  end
end
