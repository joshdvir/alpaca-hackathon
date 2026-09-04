# frozen_string_literal: true

class AddTradeProposalsClosesPositionFk < ActiveRecord::Migration[8.0]
  def change
    add_foreign_key :trade_proposals, :positions, column: :closes_position_id
  end
end
