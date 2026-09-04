# frozen_string_literal: true

# == Schema Information
#
# Table name: positions
#
#  id              :bigint           not null, primary key
#  asset_class     :string           default("us_option")
#  avg_entry_price :decimal(, )
#  closed_at       :datetime
#  delta           :decimal(, )
#  gamma           :decimal(, )
#  hold_streak     :integer          default(0), not null
#  market_value    :decimal(, )
#  origin          :string           default("default"), not null
#  planned_sell_at :datetime
#  qty             :integer
#  raw             :jsonb
#  snapshot_at     :datetime         not null
#  strategy_bucket :string
#  symbol          :string           not null
#  theta           :decimal(, )
#  unrealized_pl   :decimal(, )
#  vega            :decimal(, )
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_positions_on_closed_at               (closed_at)
#  index_positions_on_hold_streak             (hold_streak)
#  index_positions_on_origin                  (origin)
#  index_positions_on_planned_sell_at         (planned_sell_at)
#  index_positions_on_symbol_and_snapshot_at  (symbol,snapshot_at)
#
class Position < ApplicationRecord
  include LiveUpdates
  belongs_to :closes_proposal, class_name: 'TradeProposal', foreign_key: :closes_position_id, optional: true
  has_many :closed_by_proposals, class_name: 'TradeProposal', foreign_key: :closes_position_id, dependent: :nullify
  has_many :position_reviews, dependent: :nullify

  scope :open, -> { where(closed_at: nil) }
  scope :closed, -> { where.not(closed_at: nil) }
  scope :for_symbol, ->(symbol) { where(symbol: symbol) }

  def open?
    closed_at.nil?
  end

  def closed?
    !open?
  end

  def unrealized_plpc
    # Returns the unrealized P&L as a FRACTION (e.g., -0.0786 for
    # -7.86%), matching Alpaca's `unrealized_plpc` convention so the
    # front-end can multiply by 100 once for display.
    #
    # OCC option contracts have a 100x multiplier (one contract
    # controls 100 shares of the underlying). The broker sends
    # `market_value` and `unrealized_pl` in per-contract dollars
    # (already multiplied by 100), but we store `avg_entry_price`
    # as the per-share premium. So the cost basis for a percentage
    # comparison must also be multiplied by 100 — otherwise a $4.45
    # entry on 1 contract with a $4.10 current price shows -7.86%
    # (0.35 / 4.45 × 100) instead of the wrong -786%. Stocks don't
    # have this multiplier.
    return 0.0 if avg_entry_price.to_f.zero? || qty.to_i.zero?

    multiplier = (asset_class == 'us_option') ? 100 : 1
    (unrealized_pl.to_f / (avg_entry_price.to_f * qty.to_i * multiplier).abs)
  end
end
