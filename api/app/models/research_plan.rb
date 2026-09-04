# frozen_string_literal: true

# == Schema Information
#
# Table name: research_plans
#
#  id                      :bigint           not null, primary key
#  confidence              :integer
#  invalidation_conditions :jsonb
#  key_catalysts           :jsonb
#  recommendation          :string           not null
#  synthesis               :text
#  ticker                  :string           not null
#  valid_until             :datetime         not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  agent_run_id            :bigint
#
# Indexes
#
#  index_research_plans_on_agent_run_id           (agent_run_id)
#  index_research_plans_on_ticker_and_created_at  (ticker,created_at)
#  index_research_plans_on_valid_until            (valid_until)
#
# Foreign Keys
#
#  fk_rails_...  (agent_run_id => agent_runs.id)
#
class ResearchPlan < ApplicationRecord
  RECOMMENDATIONS = %w[bullish bearish neutral].freeze

  # `optional: true` because the PersistResearchActivity can run after
  # the workflow that created the AgentRun is gone (e.g. the
  # research_manager ran on a different worker, the workflow_id is
  # not in the local AgentRun table). The activity falls back to
  # `agent_run: nil` so the row still gets created; the audit trail
  # still has the synthesis / verdict.
  belongs_to :agent_run, optional: true

  validates :ticker, :recommendation, :valid_until, presence: true
  validates :recommendation, inclusion: { in: RECOMMENDATIONS }

  scope :recent, ->(n = 100) { order(created_at: :desc).limit(n) }
  scope :for_ticker, ->(t) { where(ticker: t) }
  scope :valid, -> { where(valid_until: Time.current..) }

  def expired?
    valid_until < Time.current
  end
end
