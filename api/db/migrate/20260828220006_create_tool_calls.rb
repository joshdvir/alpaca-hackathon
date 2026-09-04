# frozen_string_literal: true

class CreateToolCalls < ActiveRecord::Migration[8.0]
  def change
    create_table :tool_calls do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.string  :tool_name, null: false        # MCP tool name or Faraday tool name
      t.string  :source                        # 'alpaca_mcp' | 'fred' | 'edgar' | 'anthropic' | etc.
      t.jsonb   :arguments
      t.jsonb   :result_summary                # first 500 chars of response or error
      t.string  :status, default: 'success'    # 'success' | 'rate_limited' | 'circuit_open' | 'error'
      t.integer :http_status
      t.integer :duration_ms
      t.integer :retry_count, default: 0
      t.timestamps
    end
    add_index :tool_calls, :source
    add_index :tool_calls, :status
    add_index :tool_calls, :created_at
  end
end
