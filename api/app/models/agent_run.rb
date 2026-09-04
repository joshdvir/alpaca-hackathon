# frozen_string_literal: true

# == Schema Information
#
# Table name: agent_runs
#
#  id                   :bigint           not null, primary key
#  agent_name           :string           not null
#  duration_ms          :integer
#  error_message        :text
#  input_payload        :jsonb
#  input_tokens         :integer
#  model_used           :string
#  output_payload       :jsonb
#  output_tokens        :integer
#  rationale            :text
#  run_kind             :string           not null
#  status               :string           default("pending")
#  ticker               :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  temporal_run_id      :string
#  temporal_workflow_id :string
#
# Indexes
#
#  index_agent_runs_on_agent_name_and_ticker_and_created_at  (agent_name,ticker,created_at)
#  index_agent_runs_on_status                                (status)
#
class AgentRun < ApplicationRecord
  include LiveUpdates
  STATUSES = %w[pending success error].freeze
  RUN_KINDS = %w[analyst research trader risk portfolio position selector].freeze

  has_many :tool_calls, dependent: :destroy
  has_many :analyst_reports, dependent: :nullify
  has_many :bull_cases, dependent: :nullify
  has_many :bear_cases, dependent: :nullify
  has_one  :research_plan, dependent: :nullify
  has_many :trade_proposals, dependent: :nullify
  has_many :risk_decisions, dependent: :nullify
  # NOTE: PositionReview belongs_to :trade_proposal. The path
  # AgentRun -> trade_proposals -> position_reviews is reachable
  # via TradeProposal.position_reviews. The previous has_many
  # :position_reviews, through: :trade_proposals association was
  # removed because it paired with a `has_one :trade_proposal`
  # (singular), which Rails doesn't allow for a has_many through.

  validates :agent_name, :run_kind, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, ->(n = 50) { order(created_at: :desc).limit(n) }
  scope :for_ticker, ->(ticker) { where(ticker: ticker) }
  scope :successful, -> { where(status: 'success') }
  scope :errored, -> { where(status: 'error') }
  scope :by_agent, ->(name) { where(agent_name: name) }

  def successful?
    status == 'success'
  end
end
