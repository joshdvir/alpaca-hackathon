# frozen_string_literal: true

class CreateMarketSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :market_snapshots do |t|
      t.string  :symbol, null: false
      t.string  :data_type, null: false # 'quote' | 'bar' | 'option_chain' | 'option_snapshot'
      t.jsonb   :payload, null: false
      t.datetime :captured_at, null: false
      t.timestamps
    end
    add_index :market_snapshots, %i[symbol data_type captured_at]
  end
end
