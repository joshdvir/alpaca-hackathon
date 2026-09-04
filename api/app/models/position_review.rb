# frozen_string_literal: true

# == Schema Information
#
# Table name: position_reviews
#
#  id                      :bigint           not null, primary key
#  current_iv_vs_entry     :decimal(, )
#  delta_drift             :decimal(, )
#  new_legs                :jsonb
#  rationale               :text
#  recommendation          :string           not null
#  status                  :string           default("pending")
#  thesis_evolution        :text
#  thesis_still_valid      :boolean
#  ticker                  :string           not null
#  time_decay_consumed_pct :decimal(, )
#  trigger                 :string           not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  agent_run_id            :bigint           not null
#  trade_proposal_id       :bigint           not null
#
# Indexes
#
#  index_position_reviews_on_agent_run_id           (agent_run_id)
#  index_position_reviews_on_ticker_and_created_at  (ticker,created_at)
#  index_position_reviews_on_trade_proposal_id      (trade_proposal_id)
#
# Foreign Keys
#
#  fk_rails_...  (agent_run_id => agent_runs.id)
#  fk_rails_...  (trade_proposal_id => trade_proposals.id)
#
class PositionReview < ApplicationRecord
  TRIGGERS         = %w[scheduled time_based thesis_drift vol_spike].freeze
  RECOMMENDATIONS  = %w[hold close roll adjust add].freeze
  STATUSES         = %w[pending action_approved no_action rejected].freeze

  belongs_to :agent_run
  belongs_to :trade_proposal

  validates :ticker, :trigger, :recommendation, presence: true
  validates :trigger,        inclusion: { in: TRIGGERS }
  validates :recommendation, inclusion: { in: RECOMMENDATIONS }
  validates :status,         inclusion: { in: STATUSES }

  scope :for_ticker, ->(t) { where(ticker: t) }
  scope :recent, ->(n = 50) { order(created_at: :desc).limit(n) }
end
