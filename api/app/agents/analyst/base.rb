# frozen_string_literal: true

# Base class for the four analyst agents.
# Each analyst gathers one slice of context for a given ticker:
#   - MarketDataAnalyst  — price action, vol surface, technicals
#   - NewsAnalyst        — recent headlines and material events
#   - MacroAnalyst       — rates, VIX, sector rotation
#   - InsiderAnalyst     — Form 4 filings, cluster buys
#
# All four return the same shape: a hash with :thesis, :signals, :confidence.
# The bull/bear debate then uses these to argue about the same ticker.

module Analyst
  class Base < ::Agent
    # The model column on `agent_runs.run_kind` must be one of
    # AgentRun::RUN_KINDS. All four Analyst subclasses inherit this.
    RUN_KIND = 'analyst'

    def user_payload(ticker, watchlist_entry, market_context = {})
      # The watchlist_entry is a Hash passed through Temporal's JSON
      # payload converter when this agent runs inside a workflow, so
      # its keys are STRINGS. We read with string keys (the Symbol
      # access `watchlist_entry.tags` crashes with
      # `undefined method 'tags' for an instance of Hash`). When
      # called outside a workflow (e.g. ad-hoc tests) it could be an
      # AR model — in that case `.respond_to?` lets both work.
      tags =
        if watchlist_entry.respond_to?(:tags) && !watchlist_entry.is_a?(Hash)
          watchlist_entry.tags
        elsif watchlist_entry.is_a?(Hash)
          watchlist_entry['tags'] || watchlist_entry[:tags]
        end
      cycle =
        if watchlist_entry.respond_to?(:cycle_minutes) && !watchlist_entry.is_a?(Hash)
          watchlist_entry.cycle_minutes
        elsif watchlist_entry.is_a?(Hash)
          watchlist_entry['cycle_minutes'] || watchlist_entry[:cycle_minutes]
        end
      {
        ticker: ticker,
        watchlist_tags: tags,
        cycle_minutes: cycle,
        market_context: market_context
      }
    end

    # Expected response shape (from trading.yml agent prompts):
    #   {
    #     "thesis":    "<1-3 sentence directional view>",
    #     "signals":   ["<bullet 1>", "<bullet 2>", ...],
    #     "confidence": <0-100 integer or float>
    #   }
    REQUIRED_KEYS = %w[thesis signals confidence].freeze

    # When the LLM/MCP call fails OR the parse guardrails reject the
    # response, Agent.call falls back to this shape. We keep the
    # standard {thesis, signals, confidence} keys so the debate
    # activity can keep working — it just sees a 50-confidence "no
    # data" brief and naturally skews the research manager toward
    # no_trade. The `_error` field carries the original cause for the
    # audit log.
    def self.default_brief(error, kind)
      Rails.logger.warn "[agent:debug] Analyst::Base falling back to default brief (#{kind}): #{error.class}: #{error.message[0, 200]}"
      {
        thesis: "insufficient data (#{kind})",
        signals: ["insufficient_data:#{kind}", "error_class:#{error.class.name}"],
        confidence: 50,
        _error: { kind: kind, class: error.class.name, message: error.message[0, 500] }
      }
    end

    def parse(content)
      raw = content.to_s.strip
      data = extract_json(raw)
      validate_structure!(data)
      normalize_response(data)
    rescue ParseError
      raise
    rescue JSON::ParserError => e
      # Log the first 500 chars of the bad response so the operator can
      # see exactly what the LLM produced. Persisted to the AgentRun
      # error_message by the Agent.call rescue.
      preview = content.to_s[0, 500]
      raise ParseError,
            "#{self.class} returned non-JSON: #{e.message}; " \
            "raw_first_500=#{preview.inspect}"
    end

    private

    # Raise ParseError (caught upstream as a distinct error class) if
    # any required key is missing or the wrong shape. The agent prompt
    # contract is what we validate against — if the LLM drops a field,
    # we'd rather fail loudly and surface the prompt drift than silently
    # feed garbage into the bull/bear debate.
    def validate_structure!(data)
      raise ParseError, "expected JSON object, got #{data.class.name}: #{data.inspect[0, 200]}" unless data.is_a?(Hash)

      missing = REQUIRED_KEYS.reject { |k| data.key?(k) }
      unless missing.empty?
        raise ParseError,
              "#{self.class} response missing required keys: #{missing.inspect}; " \
              "got=#{data.keys.inspect}"
      end

      validate_thesis(data)
      validate_signals(data)
      validate_confidence(data)
    end

    def validate_thesis(data)
      return if data['thesis'].is_a?(String)

      raise ParseError,
            "#{self.class} response 'thesis' must be a String, got #{data['thesis'].class.name}"
    end

    def validate_signals(data)
      return if data['signals'].is_a?(Array)

      raise ParseError,
            "#{self.class} response 'signals' must be an Array, got #{data['signals'].class.name}: " \
            "#{data['signals'].inspect[0, 200]}"
    end

    def validate_confidence(data)
      return if numeric?(data['confidence'])

      raise ParseError,
            "#{self.class} response 'confidence' must be numeric, got #{data['confidence'].class.name}: " \
            "#{data['confidence'].inspect[0, 100]}"
    end

    def numeric?(value)
      return true if value.is_a?(Numeric)
      return false if value.is_a?(String) && value.strip.empty?

      Float(value.to_s)
      true
    rescue ArgumentError, TypeError
      false
    end

    def normalize_response(data)
      {
        thesis: data['thesis'].to_s,
        signals: Array(data['signals']).map(&:to_s),
        confidence: clamp_confidence(data['confidence'])
      }
    end

    def clamp_confidence(value)
      n = Float(value)
      [[n, 0].max, 100].min.round
    rescue ArgumentError, TypeError
      50
    end
  end
end
