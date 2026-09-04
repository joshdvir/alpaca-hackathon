# frozen_string_literal: true

class CreateBacktestRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :backtest_runs do |t|
      t.jsonb :config_snapshot # the trading.yml at the time of run
      t.string   :tickers, array: true, default: []
      t.integer  :period_days
      t.datetime :started_at
      t.datetime :finished_at
      t.decimal  :final_equity
      t.decimal  :sharpe
      t.decimal  :max_drawdown
      t.integer  :total_trades, default: 0
      t.integer  :winning_trades, default: 0
      t.string   :status, default: 'running' # 'running' | 'success' | 'error'
      t.text     :error_message
      t.timestamps
    end
  end
end
