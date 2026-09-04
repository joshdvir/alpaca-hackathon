# frozen_string_literal: true

# BearResearcher — argues the short/no-trade case.
# Symmetric to BullResearcher. Both agents see the same prior_rounds so
# they can quote each other.

module Debate
  class BearResearcher < Base
    def invoke(ticker, side, prior_rounds, context)
      chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
      response =
        with_breaker(:llm) do
          RATE_LIMITERS[:llm].with_limit do
            chat.ask(user_payload(ticker, side, prior_rounds, context).to_json)
          end
        end
      response.content
    end
  end
end
