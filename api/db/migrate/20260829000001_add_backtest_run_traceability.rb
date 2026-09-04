# frozen_string_literal: true

class AddBacktestRunTraceability < ActiveRecord::Migration[8.0]
  def change
    add_column :backtest_runs, :temporal_workflow_id, :string
    add_column :backtest_runs, :temporal_run_id, :string
    add_column :backtest_runs, :mode, :string, default: 'full' # 'full' | 'deterministic' | 'hybrid'
    add_column :backtest_runs, :start_of_day_equity, :decimal # snapshot of initial capital
    add_column :backtest_runs, :total_pnl, :decimal # final - initial
    add_index  :backtest_runs, :temporal_workflow_id
    add_index  :backtest_runs, :status
  end
end
