# frozen_string_literal: true

# Make trade_proposals.agent_run_id nullable. System-generated
# proposals (PositionMonitor auto-close, AlpacaMirror reconciliation)
# don't have an associated AgentRun — the "agent" is the system
# itself. The Rails association has always been `optional: true`
# (see app/models/trade_proposal.rb), but the DB column had a
# leftover NOT NULL constraint from the original schema. Aligning
# the column to match the association lets the auto-close path
# save without first fabricating a synthetic AgentRun row.
#
# Mirrors the same fix applied to research_plans / analyst_reports /
# bull_cases / bear_cases in 20260831040000_allow_null_agent_run_on_research.
class AllowNullAgentRunOnTradeProposals < ActiveRecord::Migration[8.0]
  def change
    change_column_null :trade_proposals, :agent_run_id, true
  end
end
