# frozen_string_literal: true

class CreateNewsItems < ActiveRecord::Migration[8.0]
  def change
    create_table :news_items do |t|
      t.string   :alpaca_news_id, null: false
      t.string   :source
      t.string   :headline
      t.text     :summary
      t.jsonb    :symbols
      t.datetime :published_at
      t.timestamps
    end
    add_index :news_items, :alpaca_news_id, unique: true
    add_index :news_items, :published_at
  end
end
