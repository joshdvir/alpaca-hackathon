# frozen_string_literal: true

# == Schema Information
#
# Table name: market_snapshots
#
#  id          :bigint           not null, primary key
#  captured_at :datetime         not null
#  data_type   :string           not null
#  payload     :jsonb            not null
#  symbol      :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_market_snapshots_on_symbol_and_data_type_and_captured_at  (symbol,data_type,captured_at)
#
# MarketSnapshot — point-in-time market data cache. Populated by
# FetchMarketStateActivity and friends; consumed by Monitor.current_mark
# to read the latest option quote, by the backtest data provider, and
# by any UI that wants a current snapshot without re-hitting the broker.
#
# `data_type` is a free-form string (`'option_snapshot'`, `'bars'`,
# `'quote'`, etc.) so a single table holds heterogeneous data without a
# wide schema. Payloads are JSONB.

class MarketSnapshot < ApplicationRecord
  validates :symbol, :data_type, :payload, :captured_at, presence: true

  scope :for_symbol, ->(sym) { where(symbol: sym) }
  scope :of_type, ->(t) { where(data_type: t) }
  scope :latest, -> { order(captured_at: :desc) }
end
