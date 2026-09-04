# frozen_string_literal: true

# BacktestWorkflowsWorker — separate task queue so backtest runs don't
# compete for resources with live trading. Can be scaled independently
# (multiple replicas for parallel backtests) and shut down independently
# when no backtest is running.
#
# Run via: bin/worker BacktestWorkflowsWorker

class BacktestWorkflowsWorker < ApplicationWorker
  def self.workflows_arr
    [
      Backtest::BacktestWorkflow
    ]
  end

  def self.activities_arr
    [
      Backtest::RunBacktestActivity
    ]
  end

  def self.task_queues = ['backtest-queue']
end
