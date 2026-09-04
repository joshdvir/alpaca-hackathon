# frozen_string_literal: true

class CreatePortfolioSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :portfolio_snapshots do |t|
      t.decimal :equity
      t.decimal :cash
      t.decimal :buying_power
      t.decimal :options_buying_power
      t.decimal :daily_pl
      t.decimal :total_pl
      t.jsonb   :raw
      t.timestamps
    end
    add_index :portfolio_snapshots, :created_at
  end
end
