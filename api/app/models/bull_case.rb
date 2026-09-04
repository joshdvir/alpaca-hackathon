# frozen_string_literal: true

# == Schema Information
#
# Table name: bull_cases
#
#  id           :bigint           not null, primary key
#  confidence   :integer
#  narrative    :text
#  payload      :jsonb
#  ticker       :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  agent_run_id :bigint
#
# Indexes
#
#  index_bull_cases_on_agent_run_id           (agent_run_id)
#  index_bull_cases_on_ticker_and_created_at  (ticker,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (agent_run_id => agent_runs.id)
#
class BullCase < ApplicationRecord
  # `optional: true` because the PersistResearchActivity can run when
  # the workflow that created the AgentRun is gone (e.g. a different
  # worker, the workflow_id is no longer in the local AgentRun table).
  belongs_to :agent_run, optional: true

  validates :ticker, presence: true

  scope :recent, ->(n = 50) { order(created_at: :desc).limit(n) }
  scope :for_ticker, ->(t) { where(ticker: t) }
end
