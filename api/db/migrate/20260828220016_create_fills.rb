# frozen_string_literal: true

class CreateFills < ActiveRecord::Migration[8.0]
  def change
    create_table :fills do |t|
      t.references :order, null: false, foreign_key: true
      t.string   :alpaca_fill_id
      t.decimal  :price, null: false
      t.integer  :qty, null: false
      t.datetime :filled_at, null: false
      t.timestamps
    end
    add_index :fills, :alpaca_fill_id, unique: true, where: 'alpaca_fill_id IS NOT NULL'
  end
end
