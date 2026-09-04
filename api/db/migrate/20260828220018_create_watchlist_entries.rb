# frozen_string_literal: true

class CreateWatchlistEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :watchlist_entries do |t|
      t.string  :ticker, null: false
      t.date    :effective_from, null: false
      t.date    :effective_until # NULL = currently active
      t.string  :source, null: false               # 'ticker_selector' | 'manual' | 'fallback'
      t.integer :cycle_minutes, default: 15, null: false
      t.jsonb   :tags                              # ['high_iv', 'momentum', ...]
      t.string  :last_temporal_run_id
      t.datetime :last_cycle_started_at
      t.timestamps
    end
    add_index :watchlist_entries, %i[ticker effective_from]
    add_index :watchlist_entries, :effective_until
    add_index :watchlist_entries, :ticker, where: 'effective_until IS NULL', name: 'idx_active_watchlist_ticker'
  end
end
