# frozen_string_literal: true

# ResearchManager — deterministic-ish summarizer that decides whether the
# debate has produced a plan worth trading. Reads the full transcript and
# returns either a recommendation (with a trade_plan hash) or a no-trade
# verdict with reasons. This is the gate before the Trader agent.

module Debate
  class ResearchManager < Base
    def user_payload(ticker, transcript, analyst_briefs)
      {
        ticker: ticker,
        analyst_briefs: analyst_briefs,
        transcript: transcript
      }
    end

    def parse(content)
      data = extract_json(content.to_s.strip)
      {
        verdict: data['verdict'], # "trade" or "no_trade"
        thesis: data['thesis'].to_s,
        trade_plan: data['trade_plan'], # nil unless verdict == "trade"
        confidence: clamp_confidence(data['confidence']),
        no_trade_reasons: Array(data['no_trade_reasons'])
      }
    rescue JSON::ParserError => e
      raise ParseError, "#{self.class} returned non-JSON: #{e.message}"
    end

    # The research manager is a single-shot LLM call. It does NOT take part
    # in the bull/bear loop. The ProcessTickerWorkflow invokes it after the
    # configured number of rounds.
    def invoke(ticker, transcript, analyst_briefs)
      chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
      response =
        with_breaker(:llm) do
          RATE_LIMITERS[:llm].with_limit do
            chat.ask(user_payload(ticker, transcript, analyst_briefs).to_json)
          end
        end
      response.content
    end

    # ResearchManager fallback: on any failure, the ONLY safe verdict is
    # "no_trade" with `insufficient_data` in the reasons. The
    # `RunExecutionPhaseActivity` checks `verdict == 'trade'` to decide
    # whether to call the Trader, so this short-circuits the whole
    # trade path without losing the audit trail.
    def self.default_brief(error, kind)
      Rails.logger.warn "[agent:debug] Debate::ResearchManager falling back to default brief (#{kind}): #{error.class}: #{error.message[0, 200]}"
      {
        verdict: 'no_trade',
        thesis: "insufficient data (#{kind})",
        trade_plan: nil,
        confidence: 0,
        no_trade_reasons: ["insufficient_data:#{kind}", "error_class:#{error.class.name}"],
        _error: { kind: kind, class: error.class.name, message: error.message[0, 500] }
      }
    end

    private

    def clamp_confidence(value)
      n = Float(value)
      [[n, 0].max, 100].min.round
    rescue ArgumentError, TypeError
      50
    end
  end
end
