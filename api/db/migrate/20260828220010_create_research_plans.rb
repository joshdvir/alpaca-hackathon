# frozen_string_literal: true

class CreateResearchPlans < ActiveRecord::Migration[8.0]
  def change
    create_table :research_plans do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.string  :ticker, null: false
      t.string  :recommendation, null: false # 'bullish' | 'bearish' | 'neutral'
      t.integer :confidence
      t.text    :synthesis
      t.jsonb   :key_catalysts
      t.jsonb   :invalidation_conditions
      t.datetime :valid_until, null: false
      t.timestamps
    end
    add_index :research_plans, %i[ticker created_at]
    add_index :research_plans, :valid_until
  end
end
