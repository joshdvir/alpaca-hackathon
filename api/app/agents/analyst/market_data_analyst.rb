# frozen_string_literal: true

# MarketDataAnalyst — price action, vol surface, technicals.
# Calls Alpaca MCP for the latest quote, chain snapshot, and recent bars.
# Read-only MCP tools, so uses ALPACA_MCP_READONLY.

module Analyst
  class MarketDataAnalyst < Base
    def invoke(ticker, watchlist_entry, market_context = {})
      chat = RubyLLM.chat(model: @model)
                    .with_instructions(system_prompt)
                    # `with_tools` is `*tools` — we must splat, otherwise
                    # the entire Array of tools is passed as a single
                    # arg and the chat's internal `each` then calls
                    # `.name` on the Array itself, raising
                    # `NoMethodError: undefined method 'name' for an
                    # instance of Array`.
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
