# frozen_string_literal: true

class CreateWatchlistRecommendations < ActiveRecord::Migration[8.0]
  def change
    create_table :watchlist_recommendations do |t|
      t.string  :ticker, null: false
      t.date    :recommended_on, null: false
      t.string  :source_filter, null: false # which filter triggered inclusion
      t.jsonb   :scores # per-criterion scores
      t.decimal :confidence # 0..100
      t.text    :rationale
      t.timestamps
    end
    add_index :watchlist_recommendations, %i[ticker recommended_on], unique: true
    add_index :watchlist_recommendations, :recommended_on
  end
end
