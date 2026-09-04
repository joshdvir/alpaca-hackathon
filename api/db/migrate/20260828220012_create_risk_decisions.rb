# frozen_string_literal: true

class CreateRiskDecisions < ActiveRecord::Migration[8.0]
  def change
    create_table :risk_decisions do |t|
      t.references :trade_proposal, null: false, foreign_key: true
      t.references :agent_run, foreign_key: true
      t.string  :decision, null: false # 'approved' | 'rejected'
      t.text    :reasons                      # JSON array of human-readable reasons
      t.jsonb   :limit_snapshot               # the limit values that were checked
      t.timestamps
    end
    add_index :risk_decisions, :decision
  end
end
