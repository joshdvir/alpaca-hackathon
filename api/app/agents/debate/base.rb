# frozen_string_literal: true

# Base class for the bull/bear debate. Each round the agents see the prior
# round's arguments and add their own. The research manager is a single-shot
# summarizer that decides whether to escalate to a full trade plan.
#
# Debate round count and minimum confidence to act are in trading.yml so we
# can tune the heat of the argument without touching code.

module Debate
  class Base < ::Agent
    ARGUMENT_KEY = :argument # shared shape between bull and bear
    # All debate agents (BullResearcher, BearResearcher, ResearchManager)
    # share the 'research' run_kind. Maps to AgentRun::RUN_KINDS.
    RUN_KIND = 'research'

    def user_payload(ticker, side, prior_rounds, context)
      {
        ticker: ticker,
        side: side,
        prior_rounds: prior_rounds,
        analyst_briefs: context[:analyst_briefs]
      }
    end

    def parse(content)
      data = extract_json(content.to_s.strip)
      {
        side: data['side'],
        argument: data['argument'].to_s,
        cited_signals: Array(data['cited_signals']),
        conviction: clamp_confidence(data['conviction'])
      }
    rescue JSON::ParserError => e
      raise ParseError, "#{self.class} returned non-JSON: #{e.message}"
    end

    # Debate fallback: the bull/bear/research_manager all expect the
    # same {side, argument, cited_signals, conviction} shape. On
    # failure we substitute a neutral 50-conviction "no data" round so
    # the transcript stays well-formed and the next round / research
    # manager can still produce a verdict.
    def self.default_brief(error, kind)
      Rails.logger.warn "[agent:debug] Debate::Base falling back to default brief (#{kind}): #{error.class}: #{error.message[0, 200]}"
      {
        side: 'neutral',
        argument: "insufficient data (#{kind})",
        cited_signals: ["insufficient_data:#{kind}", "error_class:#{error.class.name}"],
        conviction: 50,
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
