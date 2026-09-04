# frozen_string_literal: true

class CreateBullCases < ActiveRecord::Migration[8.0]
  def change
    create_table :bull_cases do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.string  :ticker, null: false
      t.jsonb   :payload                     # structured bull thesis
      t.text    :narrative                   # LLM's narrative
      t.integer :confidence
      t.timestamps
    end
    add_index :bull_cases, %i[ticker created_at]
  end
end
