# frozen_string_literal: true

# Add an `origin` column to `trade_proposals` so multiple strategies
# can coexist without trampling each other. The existing default
# strategy's rows will have `origin: 'default'` (the new column's
# default), preserving all current behavior. The new mid-band-movers
# strategy sets `origin: 'mid_band_movers'` explicitly. Downstream
# code (e.g. ReviewPositionWorkflow) can filter on `origin` to avoid
# acting on positions opened by a different strategy.
class AddOriginToTradeProposals < ActiveRecord::Migration[8.0]
  def change
    add_column :trade_proposals, :origin, :string, default: 'default', null: false
    add_index  :trade_proposals, :origin
  end
end
