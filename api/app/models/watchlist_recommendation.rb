# frozen_string_literal: true

# == Schema Information
#
# Table name: watchlist_recommendations
#
#  id             :bigint           not null, primary key
#  confidence     :decimal(, )
#  rationale      :text
#  recommended_on :date             not null
#  scores         :jsonb
#  source_filter  :string           not null
#  ticker         :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# Indexes
#
#  index_watchlist_recommendations_on_recommended_on             (recommended_on)
#  index_watchlist_recommendations_on_ticker_and_recommended_on  (ticker,recommended_on) UNIQUE
#
class WatchlistRecommendation < ApplicationRecord
  belongs_to :watchlist_entry, foreign_key: :ticker, primary_key: :ticker, optional: true

  validates :ticker, :recommended_on, :source_filter, presence: true

  scope :recent, ->(n = 50) { order(recommended_on: :desc).limit(n) }
  scope :for_ticker, ->(t) { where(ticker: t) }
  scope :today, -> { where(recommended_on: Date.current) }
end
