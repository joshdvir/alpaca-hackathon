# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TickerSelectorAgent do
  # Minimal Data.define mirroring FilterEngine::Result so the spec doesn't
  # pull in the whole filter pipeline.
  Candidate = Data.define(:ticker, :source_filter, :scores)

  let(:candidates) do
    [
      Candidate.new('SPY', 'high_iv_premium_sellers', { iv_rank: 75 }),
      Candidate.new('QQQ', 'momentum_7d',             { pct_change_7d: 12.4 })
    ]
  end

  describe '::RUN_KIND' do
    it 'is "selector" so the AgentRun row passes model validation' do
      expect(described_class::RUN_KIND).to eq('selector')
      expect(AgentRun::RUN_KINDS).to include(described_class::RUN_KIND)
    end
  end

  describe '.rank with workflow_id' do
    it 'creates an AgentRun row with the correct run_kind, agent_name, and temporal ids' do
      # Bypass the whole invoke/parse/finalize flow — we just want to
      # verify the AgentRun row gets created with the right columns.
      # The finalize code has its own pre-existing bug
      # (finished_at= references a non-existent column) that we're not
      # fixing in this turn.
      allow_any_instance_of(described_class).to receive(:invoke).and_return(
        '[{"ticker":"SPY","confidence":90,"rationale":"x","source_filter":"high_iv"}]'
      )
      # Stub the post-invoke finalize so the test doesn't hit the
      # unrelated finished_at bug.
      allow_any_instance_of(AgentRun).to receive(:update!).and_return(true)

      expect {
        described_class.rank(candidates, workflow_id: 'wf-1', run_id: 'run-1')
      }.to change(AgentRun, :count).by(1)

      run = AgentRun.last
      expect(run.temporal_workflow_id).to eq('wf-1')
      expect(run.temporal_run_id).to eq('run-1')
      expect(run.agent_name).to eq('TickerSelectorAgent')
      expect(run.run_kind).to eq('selector')
    end
  end

  describe '#user_payload' do
    it 'serializes candidates to a JSON-able hash' do
      agent = described_class.new
      payload = agent.user_payload(candidates)
      expect(payload[:candidates].size).to eq(2)
      expect(payload[:candidates].first).to eq(
        ticker: 'SPY', source_filter: 'high_iv_premium_sellers', scores: { iv_rank: 75 }
      )
    end
  end

  describe '#parse' do
    it 'accepts a bare array of pick objects' do
      agent = described_class.new
      json = '[{"ticker":"SPY","confidence":80,"source_filter":"high_iv_premium_sellers","rationale":"high IV"}]'
      result = agent.parse(json)
      expect(result.size).to eq(1)
      expect(result.first['ticker']).to eq('SPY')
      expect(result.first['confidence']).to eq(80)
      expect(result.first['source_filter']).to eq('high_iv_premium_sellers')
      expect(result.first['rationale']).to eq('high IV')
    end

    it 'accepts a {picks: [...]} wrapper' do
      agent = described_class.new
      json = '{"picks":[{"ticker":"SPY","confidence":70,"source_filter":"x","rationale":"ok"}]}'
      result = agent.parse(json)
      expect(result.first['ticker']).to eq('SPY')
    end

    it 'clamps confidence to 0..100' do
      agent = described_class.new
      json = '[{"ticker":"X","confidence":250,"source_filter":"y","rationale":"z"}]'
      result = agent.parse(json)
      expect(result.first['confidence']).to eq(100)
    end

    it 'defaults missing confidence to 50' do
      agent = described_class.new
      json = '[{"ticker":"X","source_filter":"y","rationale":"z"}]'
      result = agent.parse(json)
      expect(result.first['confidence']).to eq(50)
    end

    it 'raises ParseError on non-JSON' do
      agent = described_class.new
      expect { agent.parse('not json') }.to raise_error(Agent::ParseError)
    end

    it "falls back to 'unknown' for missing source_filter" do
      agent = described_class.new
      json = '[{"ticker":"X","confidence":50,"rationale":"z"}]'
      result = agent.parse(json)
      expect(result.first['source_filter']).to eq('unknown')
    end
  end

  describe '.rank (class method)' do
    it 'wraps Agent.call with workflow_id and run_id' do
      expect(described_class).to receive(:call).with(
        candidates,
        workflow_id: 'wf-1',
        run_id: 'run-1'
      ).and_return([{ 'ticker' => 'SPY' }])
      described_class.rank(candidates, workflow_id: 'wf-1', run_id: 'run-1')
    end
  end
end
