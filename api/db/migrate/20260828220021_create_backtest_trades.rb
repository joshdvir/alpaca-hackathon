# frozen_string_literal: true

class CreateBacktestTrades < ActiveRecord::Migration[8.0]
  def change
    create_table :backtest_trades do |t|
      t.references :backtest_run, null: false, foreign_key: true
      t.string  :ticker
      t.string  :strategy_type
      t.jsonb   :legs
      t.decimal :entry_price
      t.decimal :exit_price
      t.decimal :pnl
      t.datetime :opened_at
      t.datetime :closed_at
      t.timestamps
    end
    add_index :backtest_trades, %i[backtest_run_id ticker]
  end
end
