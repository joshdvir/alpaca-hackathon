# frozen_string_literal: true

class CreateAgentRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_runs do |t|
      t.string  :agent_name, null: false       # 'MarketDataAnalyst', 'BullResearcher', etc.
      t.string  :run_kind, null: false         # 'analyst' | 'research' | 'trader' | 'risk' | 'portfolio' | 'position' | 'selector'
      t.string  :ticker
      t.string  :temporal_workflow_id
      t.string  :temporal_run_id
      t.jsonb   :input_payload
      t.jsonb   :output_payload               # structured JSON from the agent
      t.text    :rationale                    # LLM's narrative reasoning
      t.string  :model_used
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :duration_ms
      t.string  :status, default: 'pending' # 'pending' | 'success' | 'error'
      t.text    :error_message
      t.timestamps
    end
    add_index :agent_runs, %i[agent_name ticker created_at]
    add_index :agent_runs, :status
  end
end
