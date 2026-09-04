# frozen_string_literal: true

class CreateTradeProposals < ActiveRecord::Migration[8.0]
  def change
    create_table :trade_proposals do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.references :research_plan, foreign_key: true
      t.string  :ticker, null: false
      t.string  :kind, null: false, default: 'new'
      # kind: 'new' | 'close' | 'roll' | 'adjust' | 'add' | 'auto_close'
      t.string  :strategy_type, null: false # 'iron_condor' | 'vertical' | etc.
      t.jsonb   :legs, null: false # [{side, ratio_qty, option_symbol, ...}]
      t.decimal :max_loss
      t.decimal :max_profit
      t.text    :rationale
      t.string  :status, default: 'pending'
      # status: 'pending' | 'risk_approved' | 'rejected' | 'portfolio_approved' | 'filled' | 'expired' | 'cancelled'
      t.text    :rejection_reason
      t.references :closes_position, foreign_key: false # FK added in 20260829000002 after positions table exists
      t.timestamps
    end
    add_index :trade_proposals, %i[ticker status created_at]
    add_index :trade_proposals, :kind
  end
end
