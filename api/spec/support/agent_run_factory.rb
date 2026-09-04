# frozen_string_literal: true

module AgentRunFactory
  def create_agent_run(overrides = {})
    AgentRun.create!({
      agent_name: 'SpecHelper',
      run_kind: 'trader',
      status: 'success',
      input_payload: { 'ticker' => 'SPY' }
    }.merge(overrides))
  end

  def create_proposal(overrides = {})
    TradeProposal.create!({
      ticker: 'SPY',
      kind: 'new',
      strategy_type: 'vertical',
      legs: [{ 'side' => 'buy_to_open', 'ratio_qty' => 1, 'option_symbol' => 'SPY260116C00580000' }],
      max_loss: 500,
      max_profit: 500,
      status: 'pending',
      agent_run: create_agent_run
    }.merge(overrides))
  end
end

RSpec.configure do |config|
  config.include AgentRunFactory
end
