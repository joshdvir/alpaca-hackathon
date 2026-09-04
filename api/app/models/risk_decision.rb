# frozen_string_literal: true

# == Schema Information
#
# Table name: risk_decisions
#
#  id                :bigint           not null, primary key
#  decision          :string           not null
#  limit_snapshot    :jsonb
#  reasons           :text
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  agent_run_id      :bigint
#  trade_proposal_id :bigint           not null
#
# Indexes
#
#  index_risk_decisions_on_agent_run_id       (agent_run_id)
#  index_risk_decisions_on_decision           (decision)
#  index_risk_decisions_on_trade_proposal_id  (trade_proposal_id)
#
# Foreign Keys
#
#  fk_rails_...  (agent_run_id => agent_runs.id)
#  fk_rails_...  (trade_proposal_id => trade_proposals.id)
#
class RiskDecision < ApplicationRecord
  include LiveUpdates
  DECISIONS = %w[approved rejected].freeze

  belongs_to :trade_proposal
  belongs_to :agent_run, optional: true

  validates :decision, presence: true, inclusion: { in: DECISIONS }

  scope :recent, ->(n = 100) { order(created_at: :desc).limit(n) }
  scope :approved, -> { where(decision: 'approved') }
  scope :rejected, -> { where(decision: 'rejected') }
  scope :since,    ->(t) { where(created_at: t..) }

  def approved? = decision == 'approved'
  def rejected? = decision == 'rejected'

  def reasons_array
    JSON.parse(reasons.to_s.presence || '[]')
  rescue JSON::ParserError
    []
  end
end
