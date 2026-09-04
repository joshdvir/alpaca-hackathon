# frozen_string_literal: true

# PositionReviewAgent — runs every 30 min over every open position.
# Surfaces positions that have lost thesis, gone against the plan, or hit
# profit targets. Mostly returns "hold" unless something has materially
# changed.
#
# Position schema is intentionally minimal: `symbol` (OCC), `qty`, Greeks,
# unrealized_pl. We surface what's there and let the LLM reason over it.

module Positions
  class PositionReviewAgent < Base
    def user_payload(position, market_state)
      {
        position: serialize(position),
        market_state: market_state
      }
    end

    def invoke(position, market_state)
      chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
      response =
        with_breaker(:llm) do
          RATE_LIMITERS[:llm].with_limit do
            chat.ask(user_payload(position, market_state).to_json)
          end
        end
      response.content
    end

    private

    def serialize(position)
      {
        id: position.id,
        symbol: position.symbol, # OCC option symbol
        qty: position.qty,
        avg_entry_price: position.avg_entry_price,
        market_value: position.market_value,
        unrealized_pl: position.unrealized_pl,
        # `unrealized_plpc` is a FRACTION per Alpaca's convention.
        # The LLM gets the raw fraction; downstream consumers can
        # multiply by 100 for display.
        unrealized_plpc: position.unrealized_plpc,
        delta: position.delta,
        gamma: position.gamma,
        theta: position.theta,
        vega: position.vega,
        opened_at: position.created_at,
        holding_minutes: ((Time.current - position.created_at) / 60).round
      }
    end
  end
end
