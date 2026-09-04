# frozen_string_literal: true

# RunBacktestActivity — calls Backtest::Engine for the run identified by
# the workflow's input. Long-running (start_to_close_timeout: 1h default
# in the workflow), so this activity is registered on the backtest-queue
# and polled by the BacktestWorkflowsWorker.
#
# On uncaught failure the engine marks the BacktestRun as `error` with the
# message before re-raising, so the workflow's retry policy is the second
# line of defense.

module Backtest
  class RunBacktestActivity < ApplicationActivity
    def execute(backtest_run_id, start_date_iso, end_date_iso)
      run = BacktestRun.find(backtest_run_id)
      Engine.new(
        run: run,
        start_date: Date.parse(start_date_iso),
        end_date: Date.parse(end_date_iso)
      ).call
      { run_id: run.id, status: run.reload.status, final_equity: run.final_equity, total_pnl: run.total_pnl }
    end
  end
end
