# frozen_string_literal: true

# InsiderAnalyst — Form 4 filings via SEC EDGAR (Faraday).
# Recent insider transactions often precede a re-rating; the agent
# surfaces clusters and dollar-weighted buys.

module Analyst
  class InsiderAnalyst < Base
    def invoke(ticker, watchlist_entry, market_context = {})
      # Fetch recent Form 4 filings directly so the LLM has them up front
      filings = fetch_form4(ticker)
      chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
      payload = user_payload(ticker, watchlist_entry, market_context).merge(form4: filings)
      response =
        with_breaker(:edgar) do
          RATE_LIMITERS[:edgar].with_limit do
            chat.ask(payload.to_json)
          end
        end
      response.content
    end

    private

    def fetch_form4(ticker)
      EdgarClient.recent_form4(ticker, since: 14.days.ago)
    rescue StandardError => e
      Rails.logger.warn "[insider_analyst] EDGAR fetch failed: #{e.message}"
      []
    end
  end
end
