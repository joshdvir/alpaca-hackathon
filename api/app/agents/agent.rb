# frozen_string_literal: true

# Base class for all LLM-backed trading agents.
#
# Each subclass corresponds to one node in the multi-agent pipeline. They share:
#   - A consistent call interface: `Agent.call(*args, workflow_id: nil)` so
#     activities can invoke them uniformly and stamp the AgentRun row.
#   - The same rate limiter / circuit breaker wrapping for any external call.
#   - A single JSON-typed return contract enforced at deserialization time.
#
# Subclasses MUST:
#   - implement `system_prompt` (read from `trading.yml` for tunability)
#   - implement `user_payload(*args)` to produce the deterministic input
#   - implement `parse(content)` to extract a typed value from the LLM reply
#
# This class is intentionally NOT a Temporal activity — it is called from
# activities. Keeping it out of Temporal lets the same agent class be unit-
# tested or replay-tested in isolation.

class Agent
  class AgentError < StandardError; end
  class ParseError < AgentError; end

  # Standard entry point used by `RunAnalystPhaseActivity`,
  # `RunDebatePhaseActivity`, `RunPositionReviewActivity`, etc.
  #
  # Records an AgentRun row around the call (if workflow_id is supplied) so we
  # can trace which workflow call produced which decision.
  #
  # RESILIENCE CONTRACT: this method NEVER raises. Any failure (auth
  # error on the LLM, MCP rate limit, parse error, missing required
  # keys) is logged, persisted to AgentRun.error_message, and converted
  # to a default brief. The reasoning: a missing or malformed analyst
  # brief should not block a trading decision — the downstream debate
  # will see a low-confidence "insufficient data" brief and naturally
  # skew toward no_trade. The opposite policy (raise + retry forever)
  # wastes API budget and leaves the workflow in retry-storm hell
  # whenever a transient outage happens.
  def self.call(*, workflow_id: nil, run_id: nil) # rubocop:disable Metrics/AbcSize
    instance = new
    run = nil
    if workflow_id
      run = AgentRun.create!(
        temporal_workflow_id: workflow_id,
        temporal_run_id: run_id,
        agent_name: name,
        run_kind: instance.class::RUN_KIND,
        status: 'pending',
        input_payload: instance.user_payload(*)
      )
    end

    # DEBUG: log the outgoing prompt so we can compare what we ASKED vs
    # what came back. Truncated to keep the worker log readable.
    log_request(name.to_s, instance, *)

    started_at = Time.current
    begin
      content = instance.invoke(*)
      duration_ms = ((Time.current - started_at) * 1000).to_i
      log_llm_response(name.to_s, content, duration_ms)

      parsed = instance.parse(content)
      log_parsed_response(name.to_s, parsed)
      run&.update!(status: 'success', output_payload: parsed)
      parsed
    rescue Agent::ParseError => e
      # Parse errors are a sub-class of failure but we keep them
      # distinct in error_message so callers can grep for them.
      Rails.logger.warn "[agent:debug] #{name} parse_error: #{e.message}"
      run&.update!(status: 'error', error_message: "[parse_error] #{e.message}")
      default_brief(e, 'parse_error')
    rescue StandardError => e
      log_invoke_failure(name.to_s, e, ((Time.current - started_at) * 1000).to_i)
      run&.update!(status: 'error', error_message: "#{e.class}: #{e.message}")
      default_brief(e, 'invoke_error')
    end
  end

  # When the LLM/MCP/parser fails, return a low-confidence default brief
  # so the downstream debate and execution can still run. The brief
  # carries a structured `_error` field so the research manager / risk
  # gate can see WHY the brief is empty and lean toward no_trade. This
  # is the "always have a result" guarantee.
  #
  # Each subclass should override this to return the shape its
  # downstream consumer expects (e.g. analyst -> {thesis, signals,
  # confidence}, debate -> {side, argument, cited_signals, conviction}).
  # The base implementation returns a generic marker that downstream
  # code can detect via `_insufficient: true` if it cares.
  def self.default_brief(error, kind)
    Rails.logger.warn "[agent:debug] #{name} falling back to default brief (#{kind}): #{error.class}: #{error.message[0, 200]}"
    {
      _insufficient: true,
      _error: { kind: kind, class: error.class.name, message: error.message[0, 500] }
    }
  end

  # DEBUG helpers — print outgoing request, raw LLM response, and the
  # parsed result so we can see exactly what the model produced.
  # Truncated so a runaway response doesn't drown the worker log.
  def self.log_request(agent_name, instance, *args)
    payload = instance.user_payload(*args)
    Rails.logger.info "[agent:debug] #{agent_name} model=#{instance.model} input: #{payload.to_json[0, 1500]}"
  end

  def self.log_llm_response(agent_name, content, duration_ms)
    snippet = content.to_s[0, 2000]
    Rails.logger.info "[agent:debug] #{agent_name} LLM response (#{duration_ms}ms, #{content.to_s.bytesize} bytes):"
    Rails.logger.info "[agent:debug] #{snippet.inspect}"
  end

  def self.log_parsed_response(agent_name, parsed)
    Rails.logger.info "[agent:debug] #{agent_name} parsed: #{parsed.inspect[0, 500]}"
  end

  def self.log_invoke_failure(agent_name, err, duration_ms)
    Rails.logger.warn "[agent:debug] #{agent_name} invoke failed after #{duration_ms}ms: " \
                      "#{err.class}: #{err.message}"
    # Include the first 3 lines of the cause chain so we can trace e.g.
    # CircuitOpenError -> underlying Faraday::ConnectionFailed -> DNS error.
    if err.cause
      cause = err.cause
      depth = 0
      while cause && depth < 3
        Rails.logger.warn "[agent:debug] #{agent_name} cause[#{depth}]: #{cause.class}: #{cause.message}"
        cause = cause.cause
        depth += 1
      end
    end
  end
  class << self
    private :log_request, :log_llm_response, :log_parsed_response, :log_invoke_failure
  end

  def initialize
    @model = TradingConfig.fetch(:llm, :default_model)
  end

  # Subclasses may override to use a different model than the default
  attr_reader :model

  # The system prompt lives in trading.yml under agents.<class>.prompt.
  # Looking it up by class name keeps YAML keys stable even if Ruby class
  # names change.
  def system_prompt
    TradingConfig.fetch(:agents, agent_key, :prompt)
  end

  # YAML key for this agent — derived from the class name. Subclasses can
  # override if they want a custom section.
  #
  # Strips both the `Agent` suffix (Trader, PositionReviewAgent) and the
  # `Analyst` suffix (MarketDataAnalyst, etc.) so the YAML key reflects the
  # pipeline role, not the Ruby class spelling. Examples:
  #   Trader                          -> :trader
  #   Analyst::MarketDataAnalyst      -> :analyst_market_data
  #   Debate::BullResearcher          -> :debate_bull_researcher
  #   Positions::PositionReviewAgent  -> :positions_position_review
  def agent_key
    self.class.name
        .gsub(/(Agent|Analyst)\z/, '')
        .gsub('::', '_')
        .gsub(/([a-z])([A-Z])/, '\1_\2')
        .downcase
        .to_sym
  end

  def user_payload(*)
    raise NotImplementedError, "#{self.class} must implement #user_payload"
  end

  def parse(_content)
    raise NotImplementedError, "#{self.class} must implement #parse"
  end

  # Shared JSON extraction used by every agent's `parse` method.
  #
  # The LLM is told to "respond with JSON only" but in practice it almost
  # always wraps its reply in a markdown ```json fence and sometimes adds
  # preamble prose ("Sure! Here's my analysis: { ... }"). A naive
  # `JSON.parse(content)` blows up on the first backtick with the unhelpful
  # `unexpected character: '\`\`\`json'` and the whole pipeline falls back
  # to "no_trade". The pipeline runs every 5 minutes, so a parsing failure
  # means an entire cycle produces zero actionable output.
  #
  # Three layers, in order:
  #   1. Strict JSON.parse on the trimmed content.
  #   2. Strip ```/```json fence (with optional leading `json` tag) and
  #      use the balanced walker on the inner content. The walker is
  #      required because a non-greedy regex like `\{.*?\}` stops at
  #      the first `}` (the inner nested object's close — e.g. closing
  #      of `trade_plan: { strategy: ... }`) and yields truncated,
  #      unparseable JSON.
  #   3. Balanced-brace walk on the raw text. Finds the first `{` and
  #      tracks depth while respecting string literals and backslash
  #      escapes, so we get the longest balanced top-level object.
  #
  # If all three fail, raises JSON::ParserError; callers should convert
  # that to Agent::ParseError with a preview so the audit log shows what
  # the LLM actually returned.
  def extract_json(raw)
    JSON.parse(raw)
  rescue JSON::ParserError
    stripped = strip_json_fence(raw)
    if stripped && (m = balanced_json_block(stripped))
      return JSON.parse(m)
    end
    if (m = balanced_json_block(raw))
      return JSON.parse(m)
    end
    raise JSON::ParserError, 'no JSON object found in response'
  end

  # Strip a leading ```json or ``` fence and the matching closing ``` so
  # the balanced walker sees a clean top-level `{`. Returns nil if no
  # fence is detected (so the caller knows to fall through to the
  # raw-text walk).
  def strip_json_fence(raw)
    return nil unless raw.start_with?('```')

    if (m = raw.match(/\A```(?:json)?\s*\n?(.*?)\n?\s*```/m))
      m[1]
    end
  end

  # Walks the string from the first `{` and tracks brace depth so we
  # return the longest balanced object starting there. More robust than
  # regex: respects string literals and backslash escapes so a `}`
  # inside a quoted string does not terminate the walk.
  def balanced_json_block(raw)
    start = raw.index('{')
    return nil unless start

    depth = 0
    in_string = false
    escape = false
    (start...raw.length).each do |i|
      c = raw[i]
      if in_string
        if escape
          escape = false
        elsif c == '\\'
          escape = true
        elsif c == '"'
          in_string = false
        end
      elsif c == '"'
        in_string = true
      elsif c == '{'
        depth += 1
      elsif c == '}'
        depth -= 1
        return raw[start..i] if depth.zero?
      end
    end
    nil
  end

  # Wraps the LLM call in a circuit breaker. Subclasses with no external HTTP
  # can call `chat.ask` directly; analysts that go through MCP tools use
  # `with_breaker` around `chat.ask` to gain the failure tracking.
  #
  # The block is passed through to CircuitBreaker#call so the wrapped
  # operation actually runs through the breaker (and is fast-failed
  # when the breaker is open). Returning the breaker instance — as
  # the previous version did — silently skipped the block and
  # produced NoMethodError when callers did `response.content`.
  def with_breaker(source, &block)
    CIRCUIT_BREAKERS.fetch(source).call(&block)
  end

  # LLM invocation with rate limit. The call is wrapped in a
  # CircuitBreaker.call and a RateLimiter.with_limit so a single misbehaving
  # source can't drag the whole pipeline down.
  def invoke(*)
    chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
    payload = user_payload(*)
    response =
      with_breaker(:llm) do
        RATE_LIMITERS[:llm].with_limit(timeout: TradingConfig.fetch(:llm, :acquire_timeout_seconds)) do
          chat.ask(payload.is_a?(String) ? payload : payload.to_json)
        end
      end
    response.content
  end
end
