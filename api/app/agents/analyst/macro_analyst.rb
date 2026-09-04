# frozen_string_literal: true

# MacroAnalyst — rates (FRED), VIX, sector rotation.
# FRED is reached via Faraday directly (not MCP). The agent pulls the
# configured macro series from the FRED HTTP API and reasons over them.
#
# RESILIENCE:
#   1. FRED responses are cached for 5 minutes (FRED series are daily
#      or weekly; refetching every 5 min just thrashes the 5/5min
#      free-tier rate limit and trips the circuit breaker).
#   2. If FRED is unreachable (circuit open, rate-limited, network down)
#      we return {} and the LLM still gets called — the analyst
#      produces a brief from what it knows, with `macro: {}` in the
#      payload. The LLM call itself is rate-limited and circuit-broken
#      by the existing LLM rate_limiter / circuit_breaker.
#   3. The LLM call is OUTSIDE the FRED circuit — the FRED circuit
#      is for FRED calls, the LLM has its own circuit.

module Analyst
  class MacroAnalyst < Base
    FRED_CACHE_TTL = 5.minutes

    def invoke(ticker, watchlist_entry, market_context = {})
      # Pull macro series (cached for 5 min to respect the 5/5min
      # free-tier rate limit; macro data is daily so this is fresh
      # enough for the 5-min cycle).
      macro = fetch_macro_context
      chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
      payload = user_payload(ticker, watchlist_entry, market_context).merge(macro: macro)
      response =
        with_breaker(:llm) do
          RATE_LIMITERS[:llm].with_limit do
            chat.ask(payload.to_json)
          end
        end
      response.content
    end

    private

    def fetch_macro_context
      cache_key = "fred:latest:#{(TradingConfig.fetch(:macro, :series) || []).sort.join(',')}"
      Rails.cache.fetch(cache_key, expires_in: FRED_CACHE_TTL) do
        FredClient.latest(TradingConfig.fetch(:macro, :series))
      end
    rescue StandardError => e
      Rails.logger.warn "[macro_analyst] FRED fetch failed (using empty macro): #{e.class}: #{e.message[0, 200]}"
      {}
    end
  end
end
