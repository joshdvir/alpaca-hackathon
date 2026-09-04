# frozen_string_literal: true

# == Schema Information
#
# Table name: tool_calls
#
#  id             :bigint           not null, primary key
#  arguments      :jsonb
#  duration_ms    :integer
#  http_status    :integer
#  result_summary :jsonb
#  retry_count    :integer          default(0)
#  source         :string
#  status         :string           default("success")
#  tool_name      :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  agent_run_id   :bigint           not null
#
# Indexes
#
#  index_tool_calls_on_agent_run_id  (agent_run_id)
#  index_tool_calls_on_created_at    (created_at)
#  index_tool_calls_on_source        (source)
#  index_tool_calls_on_status        (status)
#
# Foreign Keys
#
#  fk_rails_...  (agent_run_id => agent_runs.id)
#
class ToolCall < ApplicationRecord
  STATUSES = %w[success rate_limited circuit_open error].freeze

  belongs_to :agent_run

  validates :tool_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :since, ->(t) { where(created_at: t..) }
  scope :by_source, ->(s) { where(source: s) }
  scope :recent, ->(n = 200) { order(created_at: :desc).limit(n) }
end
