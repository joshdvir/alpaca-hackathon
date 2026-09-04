# frozen_string_literal: true

class CreatePositionReviews < ActiveRecord::Migration[8.0]
  def change
    create_table :position_reviews do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.references :trade_proposal, null: false, foreign_key: true
      t.string  :ticker, null: false
      t.string  :trigger, null: false         # 'scheduled' | 'time_based' | 'thesis_drift' | 'vol_spike'
      t.string  :recommendation, null: false  # 'hold' | 'close' | 'roll' | 'adjust' | 'add'
      t.boolean :thesis_still_valid
      t.text    :thesis_evolution
      t.decimal :current_iv_vs_entry
      t.decimal :delta_drift
      t.decimal :time_decay_consumed_pct
      t.text    :rationale
      t.jsonb   :new_legs
      t.string  :status, default: 'pending'   # 'pending' | 'action_approved' | 'no_action' | 'rejected'
      t.timestamps
    end
    add_index :position_reviews, %i[ticker created_at]
  end
end
