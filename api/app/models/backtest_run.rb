# frozen_string_literal: true

# == Schema Information
#
# Table name: backtest_runs
#
#  id                   :bigint           not null, primary key
#  config_snapshot      :jsonb
#  error_message        :text
#  final_equity         :decimal(, )
#  finished_at          :datetime
#  max_drawdown         :decimal(, )
#  mode                 :string           default("full")
#  period_days          :integer
#  sharpe               :decimal(, )
#  start_of_day_equity  :decimal(, )
#  started_at           :datetime
#  status               :string           default("running")
#  tickers              :string           default([]), is an Array
#  total_pnl            :decimal(, )
#  total_trades         :integer          default(0)
#  winning_trades       :integer          default(0)
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  temporal_run_id      :string
#  temporal_workflow_id :string
#
# Indexes
#
#  index_backtest_runs_on_status                (status)
#  index_backtest_runs_on_temporal_workflow_id  (temporal_workflow_id)
#
class BacktestRun < ApplicationRecord
  include LiveUpdates
  STATUSES = %w[pending running success error cancelled].freeze
  MODES    = %w[full deterministic hybrid].freeze

  has_many :backtest_trades, dependent: :destroy

  validates :tickers, :period_days, :mode, presence: true
  validates :status,  inclusion: { in: STATUSES }
  validates :mode,    inclusion: { in: MODES }

  scope :recent,   ->(n = 50) { order(created_at: :desc).limit(n) }
  scope :running,  -> { where(status: 'running') }
  scope :finished, -> { where(status: %w[success error cancelled]) }

  def win_rate
    return 0.0 if total_trades.to_i.zero?

    (winning_trades.to_f / total_trades) * 100.0
  end

  def duration_seconds
    return nil if started_at.nil? || finished_at.nil?

    (finished_at - started_at).to_i
  end

  def total_pnl_dollar
    (total_pnl || 0).to_d
  end
end
