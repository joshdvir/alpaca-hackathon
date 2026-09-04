# frozen_string_literal: true

# Make research_plans.agent_run_id and analyst_reports.agent_run_id
# nullable. PersistResearchActivity can run after the workflow that
# created the AgentRun is gone (workflow_id not in the local table
# for any reason — different worker, restarted, etc.), and we still
# want the row created so the Research tab has data. The model
# association is `optional: true` to match.
class AllowNullAgentRunOnResearch < ActiveRecord::Migration[8.0]
  def change
    change_column_null :research_plans,    :agent_run_id, true
    change_column_null :analyst_reports,  :agent_run_id, true
    change_column_null :bull_cases,       :agent_run_id, true
    change_column_null :bear_cases,       :agent_run_id, true
  end
end
