# frozen_string_literal: true

# == Schema Information
#
# Table name: watchlist_entries
#
#  id                    :bigint           not null, primary key
#  cycle_minutes         :integer          default(15), not null
#  effective_from        :date             not null
#  effective_until       :date
#  last_cycle_started_at :datetime
#  source                :string           not null
#  tags                  :jsonb
#  ticker                :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  last_temporal_run_id  :string
#
# Indexes
#
#  idx_active_watchlist_ticker                           (ticker) WHERE (effective_until IS NULL)
#  index_watchlist_entries_on_effective_until            (effective_until)
#  index_watchlist_entries_on_ticker_and_effective_from  (ticker,effective_from)
#
class WatchlistEntry < ApplicationRecord
  include LiveUpdates
  self.inheritance_column = nil # 'source' is a regular column

  validates :ticker, :effective_from, :source, :cycle_minutes, presence: true

  scope :active, lambda {
    where('effective_from <= ? AND (effective_until IS NULL OR effective_until >= ?)',
          Date.current, Date.current)
  }
  scope :for_ticker, ->(ticker) { where(ticker: ticker) }

  def active?
    effective_from <= Date.current && (effective_until.nil? || effective_until >= Date.current)
  end

  def deactivate!(on_date = Date.current)
    update!(effective_until: on_date)
  end
end
