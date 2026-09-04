# frozen_string_literal: true

# Base for position LLM agents. Two of them:
#   - PositionReviewAgent — periodic 30-min look at every open position
#   - AdjustmentAgent     — proposes a specific roll/close/add when the
#                            position monitor detects drift
#
# Both return a hash with :action (one of: hold, close, roll, adjust, add)
# and a free-form :reason. The PortfolioManager turns an actionable response
# into a TradeProposal; "hold" is a no-op.

module Positions
  class Base < ::Agent
    ACTIONS = %w[hold close roll adjust add].freeze
    # PositionReviewAgent and AdjustmentAgent both write to
    # agent_runs.run_kind = 'position'.
    RUN_KIND = 'position'

    def parse(content)
      # Use the inherited `extract_json` helper rather than JSON.parse so
      # the parser can handle the LLM's common ` ```json ... ``` ` fence
      # and preamble prose. Calling JSON.parse directly here would fail
      # on the first backtick and surface as `[parse_error] returned
      # non-JSON: unexpected character: '\`\`\`json'` — a parse failure
      # means the review cycle produces a `nil` action and the workflow
      # treats it as a hold, so the position never gets reviewed.
      data = extract_json(content)
      action = data['action'].to_s
      raise ParseError, "invalid action #{action.inspect}" unless ACTIONS.include?(action)

      {
        action: action,
        reason: data['reason'].to_s,
        details: data['details'] || {}
      }
    rescue JSON::ParserError => e
      raise ParseError, "#{self.class} returned non-JSON: #{e.message}"
    end
  end
end
