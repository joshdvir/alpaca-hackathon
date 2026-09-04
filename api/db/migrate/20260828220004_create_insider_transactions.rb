# frozen_string_literal: true

class CreateInsiderTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :insider_transactions do |t|
      t.string  :ticker, null: false
      t.string  :filer_name
      t.string  :filer_relationship        # 'CEO', 'Director', etc.
      t.string  :transaction_code          # 'P' (purchase), 'S' (sale)
      t.date    :transaction_date
      t.decimal :shares
      t.decimal :price_per_share
      t.decimal :total_value
      t.string  :accession_number          # SEC accession #
      t.timestamps
    end
    add_index :insider_transactions, %i[ticker transaction_date]
  end
end
