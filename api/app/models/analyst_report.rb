# frozen_string_literal: true

# == Schema Information
#
# Table name: analyst_reports
#
#  id             :bigint           not null, primary key
#  analyst_name   :string           not null
#  confidence     :integer
#  data_freshness :string
#  payload        :jsonb
#  summary        :text
#  thesis         :text
#  ticker         :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  agent_run_id   :bigint
#
# Indexes
#
#  idx_on_analyst_name_ticker_created_at_14b199f9e2  (analyst_name,ticker,created_at)
#  index_analyst_reports_on_agent_run_id             (agent_run_id)
#  index_analyst_reports_on_ticker_and_confidence    (ticker,confidence)
#
# Foreign Keys
#
#  fk_rails_...  (agent_run_id => agent_runs.id)
#
class AnalystReport < ApplicationRecord
  FRESHNESSES = %w[fresh stale missing].freeze
  ANALYSTS    = %w[market_data news macro insider].freeze

  # `optional: true` because the PersistResearchActivity can run when
  # the workflow that created the AgentRun is gone (e.g. a different
  # worker, the workflow_id is no longer in the local AgentRun table).
  # The audit-trail nicety of the FK is not worth blocking the row.
  belongs_to :agent_run, optional: true

  validates :ticker, :analyst_name, presence: true
  validates :analyst_name, inclusion: { in: ANALYSTS }
  validates :data_freshness, inclusion: { in: FRESHNESSES }, allow_nil: true

  scope :recent, ->(n = 50) { order(created_at: :desc).limit(n) }
  scope :for_ticker, ->(t) { where(ticker: t) }
  scope :for_analyst, ->(a) { where(analyst_name: a) }
end
