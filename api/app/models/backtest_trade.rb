# frozen_string_literal: true

# == Schema Information
#
# Table name: backtest_trades
#
#  id              :bigint           not null, primary key
#  closed_at       :datetime
#  entry_price     :decimal(, )
#  exit_price      :decimal(, )
#  legs            :jsonb
#  opened_at       :datetime
#  pnl             :decimal(, )
#  strategy_type   :string
#  ticker          :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  backtest_run_id :bigint           not null
#
# Indexes
#
#  index_backtest_trades_on_backtest_run_id             (backtest_run_id)
#  index_backtest_trades_on_backtest_run_id_and_ticker  (backtest_run_id,ticker)
#
# Foreign Keys
#
#  fk_rails_...  (backtest_run_id => backtest_runs.id)
#
class BacktestTrade < ApplicationRecord
  include LiveUpdates
  belongs_to :backtest_run

  scope :for_ticker, ->(t) { where(ticker: t) }
  scope :chronological, -> { order(:opened_at, :id) }

  def pnl_dollar
    (pnl || 0).to_d
  end

  def holding_minutes
    return nil if opened_at.nil? || closed_at.nil?

    ((closed_at - opened_at) / 60).round
  end

  def winner?
    pnl_dollar.positive?
  end
end
