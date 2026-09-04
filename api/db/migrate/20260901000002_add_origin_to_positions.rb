# frozen_string_literal: true

# Add an `origin` column to `positions` mirroring trade_proposals.origin.
# Same purpose: tag positions by the strategy that opened them so
# downstream code (e.g. ReviewPositionWorkflow) can filter.
class AddOriginToPositions < ActiveRecord::Migration[8.0]
  def change
    add_column :positions, :origin, :string, default: 'default', null: false
    add_index  :positions, :origin
  end
end
