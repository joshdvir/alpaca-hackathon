# frozen_string_literal: true

# BullResearcher — argues the long case.
# Reads the analyst briefs and the bear's prior arguments, then produces a
# counter-argument. The point is to force the model to engage with the bear,
# not just restate bullish priors.

module Debate
  class BullResearcher < Base
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
