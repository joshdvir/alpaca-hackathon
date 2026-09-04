# frozen_string_literal: true

# BacktestWorkflow — single-activity wrapper that runs the backtest engine
# and returns a summary. We split workflow from activity so the front-end
# can poll the workflow status separately from the per-trade persistence,
# and so the engine can be re-invoked from a Rails console without Temporal.
#
# Inputs (positional, passed as a hash to keep the signature stable):
#   { backtest_run_id:, tickers:, period_days:, mode: }

module Backtest
  class BacktestWorkflow < ApplicationWorkflow
    def execute(input)
      backtest_run_id = input[:backtest_run_id] || input['backtest_run_id']
      run = BacktestRun.find(backtest_run_id)
      activity.logger.info "[backtest_workflow] starting run=#{backtest_run_id} tickers=#{run.tickers.size}"

      end_date   = Date.current
      start_date = end_date - run.period_days.to_i.days

      result = T_WORKFLOW.execute_activity(
        RunBacktestActivity,
        backtest_run_id,
        start_date.to_s,
        end_date.to_s,
        start_to_close_timeout: 3600, # up to 1h; backtests are slow
        retry_policy: T_RETRY_POLICY
      )

      activity.logger.info "[backtest_workflow] done run=#{backtest_run_id} status=#{result[:status]}"
      result
    end
  end
end
