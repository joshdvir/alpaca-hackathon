# frozen_string_literal: true

# == Schema Information
#
# Table name: trade_proposals
#
#  id                 :bigint           not null, primary key
#  kind               :string           default("new"), not null
#  legs               :jsonb            not null
#  max_loss           :decimal(, )
#  max_profit         :decimal(, )
#  origin             :string           default("default"), not null
#  rationale          :text
#  rejection_reason   :text
#  status             :string           default("pending")
#  strategy_type      :string           not null
#  ticker             :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  agent_run_id       :bigint
#  closes_position_id :bigint
#  research_plan_id   :bigint
#
# Indexes
#
#  index_trade_proposals_on_agent_run_id                      (agent_run_id)
#  index_trade_proposals_on_closes_position_id                (closes_position_id)
#  index_trade_proposals_on_kind                              (kind)
#  index_trade_proposals_on_origin                            (origin)
#  index_trade_proposals_on_research_plan_id                  (research_plan_id)
#  index_trade_proposals_on_ticker_and_status_and_created_at  (ticker,status,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (agent_run_id => agent_runs.id)
#  fk_rails_...  (closes_position_id => positions.id)
#  fk_rails_...  (research_plan_id => research_plans.id)
#
class TradeProposal < ApplicationRecord
  include LiveUpdates
  KINDS = %w[new close roll adjust add auto_close].freeze
  STRATEGIES = %w[iron_condor vertical straddle strangle calendar long_call hold].freeze
  STATUSES = %w[pending risk_approved rejected portfolio_approved filled expired cancelled deferred].freeze

  belongs_to :agent_run, optional: true
  belongs_to :research_plan, optional: true
  belongs_to :closes_position, class_name: 'Position', optional: true
  has_many :risk_decisions, dependent: :nullify
  has_many :orders, dependent: :nullify
  has_many :position_reviews, dependent: :nullify

  validates :ticker, :kind, :strategy_type, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :strategy_type, inclusion: { in: STRATEGIES }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: 'pending') }
  scope :open, -> { where(status: %w[pending risk_approved portfolio_approved]) }
  scope :closed, -> { where(status: %w[rejected expired cancelled filled]) }
  scope :for_ticker, ->(ticker) { where(ticker: ticker) }
  scope :recent, ->(n = 50) { order(created_at: :desc).limit(n) }

  def approved?
    %w[risk_approved portfolio_approved filled].include?(status)
  end

  def terminal?
    %w[rejected expired cancelled filled].include?(status)
  end
end
