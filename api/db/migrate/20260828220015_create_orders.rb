# frozen_string_literal: true

class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders do |t|
      t.references :trade_proposal, foreign_key: true
      t.string   :client_order_id, null: false
      t.string   :alpaca_order_id
      t.string   :symbol, null: false          # OCC option symbol
      t.string   :side, null: false            # 'buy' | 'sell'
      t.integer  :qty, null: false
      t.string   :type, null: false            # 'market' | 'limit'
      t.string   :status, null: false, default: 'new'
      # status: 'new' | 'filled' | 'partial' | 'cancelled' | 'expired'
      t.decimal  :filled_avg_price
      t.integer  :filled_qty, default: 0
      t.jsonb    :raw_response
      t.datetime :submitted_at
      t.datetime :filled_at
      t.timestamps
    end
    add_index :orders, :client_order_id, unique: true
    add_index :orders, :alpaca_order_id, unique: true, where: 'alpaca_order_id IS NOT NULL'
    add_index :orders, :status
  end
end
