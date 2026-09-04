# frozen_string_literal: true

# ReviewPositionWorkflow — 30-min LLM review for ONE position. Calls
# RunPositionReviewActivity (which does the DB read and the LLM call),
# and if the result is actionable, calls RunPositionAdjustmentActivity
# to create a TradeProposal and route through risk + portfolio.
#
# This workflow is ONE-SHOT, not a loop. The scheduler
# (`ReviewAllPositionsWorkflow` driven by the `position-review-all`
# Temporal schedule, every 30 min) creates a fresh execution per tick
# with a unique workflow ID. The earlier design with an internal
# `loop do ... T_WORKFLOW.sleep(1800) ... end` kept a single
# workflow running for the lifetime of the position, which made
# Temporal's history grow unbounded and made each tick
# non-independently observable.
#
# Hold-exit behavior (formerly tracked in a local `hold_streak`
# variable across loop iterations) is now persisted on the
# Position row as `hold_streak`. After N consecutive "hold" verdicts
# (configured by `position_review.exit_after_hold_cycles`), the
# ReviewAllPositionsWorkflow parent will stop scheduling new ticks
# for that position until the position moves materially.
#
# Non-default origins (Mid-Band Movers, future strategies) are
# skipped at the top of `execute` — those positions have their own
# scheduled close path via the SellWorkflow and re-evaluating them
# with the LLM review would race against the planned_sell_at.

module Positions
  class ReviewPositionWorkflow < ApplicationWorkflow
    def execute(position_id)
      activity.logger.info "[review_position:#{position_id}] starting"
      workflow_id = T_WORKFLOW.info.workflow_id
      run_id      = T_WORKFLOW.info.run_id
      ctx         = { 'workflow_id' => workflow_id, 'run_id' => run_id }

      # Skip non-default origins (Mid-Band Movers, etc.). Those
      # positions have their own SellWorkflow child that closes at
      # planned_sell_at; the 30-min LLM review would race against
      # that path and could double-submit a close. Re-evaluating
      # the position with the LLM is a default-strategy-only path.
      return if non_default_origin?(position_id)

      result = T_WORKFLOW.execute_activity(
        RunPositionReviewActivity, position_id, ctx,
        start_to_close_timeout: 600
      )

      # RunPositionReviewActivity returns nil only if the activity
      # itself raised; in that case the activity would have failed
      # and we'd never get here. Defensive guard for a future shape
      # change.
      return if result.nil?

      if result[:closed]
        activity.logger.info "[review_position:#{position_id}] position closed, exiting"
        return
      end

      case result[:action].to_s
      when 'hold', ''
        # `hold` means the LLM decided nothing to do. `''` / nil
        # means the LLM parse failed — treat as hold so we don't
        # burn an activity on a broken result.
        # We use an activity to increment the hold_streak so the
        # DB write doesn't happen inside the workflow (workflows
        # must not touch the connection pool — would raise
        # Temporalio::Workflow::NondeterminismError).
        T_WORKFLOW.execute_activity(
          IncrementHoldStreakActivity, position_id,
          start_to_close_timeout: 10
        )
      else
        if TradeProposal::KINDS.include?(result[:action].to_s)
          # Reset the hold_streak on an actionable verdict — the
          # position is moving again.
          T_WORKFLOW.execute_activity(
            ResetHoldStreakActivity, position_id,
            start_to_close_timeout: 10
          )
          # The adjustment activity does the TradeProposal +
          # RiskManager + PortfolioManager work in one place. The
          # workflow just orchestrates.
          T_WORKFLOW.execute_activity(
            RunPositionAdjustmentActivity, position_id, result, ctx,
            start_to_close_timeout: 300
          )
        else
          # Defensive: an action we don't know how to model. Treat as
          # hold and try again next cycle.
          activity.logger.warn "[review_position:#{position_id}] unknown action=#{result[:action].inspect}, treating as hold"
          T_WORKFLOW.execute_activity(
            IncrementHoldStreakActivity, position_id,
            start_to_close_timeout: 10
          )
        end
      end
    end

    private

    # Reads the position's `origin` without touching the AR
    # connection pool from inside a workflow (which would raise
    # Temporalio::Workflow::NondeterminismError). Wraps the read
    # in an activity to keep the workflow replay-deterministic.
    # For positions with origin != 'default', returns true and
    # the workflow exits.
    def non_default_origin?(position_id)
      origin = T_WORKFLOW.execute_activity(
        FetchPositionOriginActivity, position_id,
        start_to_close_timeout: 10
      )
      origin.present? && origin != 'default'
    rescue StandardError => e
      # Defensive: a missing position or DB blip should not block
      # the review path. Default to "treat as default" so the LLM
      # review proceeds. The risk of a missed skip is much smaller
      # than the risk of a hard fail that blocks every position.
      activity.logger.warn "[review_position:#{position_id}] origin lookup failed: #{e.class}: #{e.message}; falling through to LLM review"
      false
    end
  end
end
