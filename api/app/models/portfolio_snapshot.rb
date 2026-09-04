# frozen_string_literal: true

# == Schema Information
#
# Table name: portfolio_snapshots
#
#  id                   :bigint           not null, primary key
#  buying_power         :decimal(, )
#  cash                 :decimal(, )
#  daily_pl             :decimal(, )
#  equity               :decimal(, )
#  options_buying_power :decimal(, )
#  raw                  :jsonb
#  total_pl             :decimal(, )
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#
# Indexes
#
#  index_portfolio_snapshots_on_created_at  (created_at)
#
class PortfolioSnapshot < ApplicationRecord
  scope :recent, ->(n = 50) { order(created_at: :desc).limit(n) }
  scope :today, -> { where(created_at: Date.current.beginning_of_day..) }
end
