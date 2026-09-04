# frozen_string_literal: true

# LLM agent that ranks the filtered candidate tickers.
# Given the union of candidates from all enabled filters, picks the top N
# and provides a rationale per pick. Returns the same string-keyed hash
# shape that the persistence activity expects, so the call site is
# drop-in compatible.
#
# Uses the project's ::Agent base class so it picks up:
#   - AgentRun tracking when invoked with workflow_id / run_id
#   - Standard parse contract (returns a typed value or raises ParseError)
#   - Rate limiter + circuit breaker wrapping via #invoke
#   - YAML-driven prompts via TradingConfig.fetch(:agents, agent_key, :prompt)

class TickerSelectorAgent < Agent
  RUN_KIND = 'selector'

  # Override the default agent_key so the prompt lives at
  # `agents.ticker_selector_agent.prompt` in trading.yml instead of
  # colliding with the existing `ticker_selector:` config block (which
  # holds the filter spec + schedule).
  def agent_key
    :ticker_selector_agent
  end

  # user_payload — JSON-able input to the LLM
  def user_payload(candidates)
    {
      candidates: Array(candidates).map do |c|
        {
          ticker: c.respond_to?(:ticker) ? c.ticker : c['ticker'],
          source_filter: c.respond_to?(:source_filter) ? c.source_filter : c['source_filter'],
          scores: c.respond_to?(:scores) ? c.scores : c['scores']
        }
      end
    }
  end

  # parse — turn the LLM's JSON output into a list of pick hashes with
  # string keys (matches the persist_watchlist_activity contract).
  def parse(content)
    data = extract_json(content.to_s.strip)
    picks = data.is_a?(Hash) ? Array(data['picks']) : Array(data)
    picks.map do |p|
      {
        'ticker' => p['ticker'] || p[:ticker],
        'confidence' => clamp_confidence(p['confidence'] || p[:confidence]),
        'source_filter' => p['source_filter'] || p[:source_filter] || 'unknown',
        'rationale' => (p['rationale'] || p[:rationale]).to_s
      }
    end
  rescue JSON::ParserError => e
    raise ParseError, "ticker_selector returned non-JSON: #{e.message}"
  end

  # invoke — actual LLM call. Pulls prompt from trading.yml via the
  # ::Agent base class (system_prompt method).
  def invoke(candidates)
    chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
    response = with_breaker(:llm) do
      RATE_LIMITERS[:llm].with_limit(timeout: TradingConfig.fetch(:llm, :acquire_timeout_seconds)) do
        chat.ask(user_payload(candidates).to_json)
      end
    end
    response.content
  end

  # Class-level convenience: returns the parsed list of picks.
  # Preserves the existing `TickerSelectorAgent.rank(candidates)` call
  # site used by TickerSelector::RankCandidatesActivity.
  def self.rank(candidates, workflow_id: nil, run_id: nil)
    call(candidates, workflow_id: workflow_id, run_id: run_id)
  end

  private

  def clamp_confidence(value)
    n = Float(value)
    [[n, 0].max, 100].min.round
  rescue ArgumentError, TypeError
    50
  end
end
