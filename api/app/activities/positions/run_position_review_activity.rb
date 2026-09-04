# frozen_string_literal: true

# RunPositionReviewActivity — 30-min LLM review. Fetches the position,
# calls the PositionReviewAgent and (if the agent says anything but
# "hold") the AdjustmentAgent. Returns the action + reason + scalars
# the workflow needs (symbol, position_qty, closed) so the workflow
# can do orchestration without touching the DB.
#
# The activity does NOT call the PortfolioManager — that's a separate
# activity (`RunPositionAdjustmentActivity`) the workflow calls when
# the review says non-hold.
# `ctx` carries {workflow_id, run_id}.

module Positions
  class RunPositionReviewActivity < ApplicationActivity
    def execute(position_id, ctx)
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id]
      run_id      = ctx['run_id']      || ctx[:run_id]
      position = ::Position.find(position_id)

      # If the position was closed (manually, by the monitor, or by
      # another workflow), the workflow should exit. We can't call
      # the LLM for a review on a position that no longer exists.
      if position.closed?
        return { position_id: position.id, closed: true }
      end

      market_state = fetch_market_state(position.symbol)
      review = Positions::PositionReviewAgent.call(
        position, market_state,
        workflow_id: workflow_id, run_id: run_id
      )

      base = {
        position_id: position.id,
        symbol: position.symbol,
        position_qty: position.qty,
        closed: false
      }

      if review[:action] == 'hold'
        return base.merge(action: 'hold', reason: review[:reason])
      end

      # AdjustmentAgent#invoke(position, trigger, market_state) needs
      # 3 positional args. We pass market_state so the LLM has the
      # latest quote to design the new leg.
      adjustment = Positions::AdjustmentAgent.call(
        position, review, market_state,
        workflow_id: workflow_id, run_id: run_id
      )

      base.merge(
        action: review[:action],
        reason: review[:reason],
        adjustment: adjustment
      )
    end

    private

    def fetch_market_state(symbol)
      # The Alpaca MCP server doesn't expose `get_market_state`. Use
      # `get_stock_snapshot` for the latest quote + daily bar instead.
      tool = ALPACA_MCP_READONLY.tool('get_stock_snapshot')
      return {} if tool.nil?

      RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(symbols: symbol) }
      end
    rescue StandardError => e
      activity.logger.warn "[review_position] market_state fetch failed: #{e.message}"
      {}
    end
  end
end
