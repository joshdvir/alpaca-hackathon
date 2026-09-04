# frozen_string_literal: true

# Add two columns to `positions` for the mid-band-movers strategy:
#   - `planned_sell_at`: when the strategy plans to close this position
#     (set by SubmitBuyOrdersActivity, read by the open-positions panel)
#   - `strategy_bucket`: "A" / "B" / "C" so the panel can label the hold-time
#     ("Bucket A — sells 1:30 PM ET", etc.)
# Both NULL for the existing default strategy (no planned exit).
class AddPlannedSellAtAndStrategyBucketToPositions < ActiveRecord::Migration[8.0]
  def change
    add_column :positions, :planned_sell_at, :datetime
    add_column :positions, :strategy_bucket, :string
    add_index  :positions, :planned_sell_at
  end
end
