# frozen_string_literal: true

class CreateBearCases < ActiveRecord::Migration[8.0]
  def change
    create_table :bear_cases do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.string  :ticker, null: false
      t.jsonb   :payload # structured bear thesis
      t.text    :narrative
      t.integer :confidence
      t.timestamps
    end
    add_index :bear_cases, %i[ticker created_at]
  end
end
