# frozen_string_literal: true

class CreateAnalystReports < ActiveRecord::Migration[8.0]
  def change
    create_table :analyst_reports do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.string  :analyst_name, null: false   # 'market_data' | 'news' | 'macro' | 'insider'
      t.string  :ticker, null: false
      t.jsonb   :payload                     # structured report data
      t.string  :data_freshness              # 'fresh' | 'stale' | 'missing'
      t.timestamps
    end
    add_index :analyst_reports, %i[analyst_name ticker created_at]
  end
end
