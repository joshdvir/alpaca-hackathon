# frozen_string_literal: true

class CreatePositions < ActiveRecord::Migration[8.0]
  def change
    create_table :positions do |t|
      t.string   :symbol, null: false
      t.string   :asset_class, default: 'us_option'
      t.integer  :qty
      t.decimal  :avg_entry_price
      t.decimal  :market_value
      t.decimal  :unrealized_pl
      t.decimal  :delta
      t.decimal  :gamma
      t.decimal  :theta
      t.decimal  :vega
      t.jsonb    :raw
      t.datetime :snapshot_at, null: false
      t.datetime :closed_at
      t.timestamps
    end
    add_index :positions, %i[symbol snapshot_at]
    add_index :positions, :closed_at
  end
end
