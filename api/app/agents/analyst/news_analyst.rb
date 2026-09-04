# frozen_string_literal: true

# NewsAnalyst — recent news, sentiment, material events.
# Calls Alpaca MCP news endpoints (read-only).

module Analyst
  class NewsAnalyst < Base
    def invoke(ticker, watchlist_entry, market_context = {})
      chat = RubyLLM.chat(model: @model)
                    .with_instructions(system_prompt)
                    # `with_tools` is `*tools` — must splat, otherwise the
                    # chat iterates over a single Array arg and calls
                    # `.name` on the Array itself
                    # (`NoMethodError: undefined method 'name' for an
                    # instance of Array`).
                    .with_tools(*ALPACA_MCP_READONLY.tools)
      payload = user_payload(ticker, watchlist_entry, market_context)
      response =
        with_breaker(:alpaca_mcp) do
          RATE_LIMITERS[:alpaca_mcp].with_limit do
            chat.ask(payload.to_json)
          end
        end
      response.content
    end
  end
end
