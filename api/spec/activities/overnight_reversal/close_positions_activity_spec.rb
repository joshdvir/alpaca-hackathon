# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('app/strategies/overnight_reversal/plan').to_s

RSpec.describe OvernightReversal::ClosePositionsActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: 'wf-ovn-close', workflow_run_id: 'run-1') }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
    allow(TradingConfig).to receive(:fetch).and_call_original
    allow(TradingConfig).to receive(:fetch).with(:overnight_reversal).and_return('max_close_attempts' => 2)

    Rails.cache.clear
    rl = instance_double('RateLimiter')
    allow(rl).to receive(:with_limit) { |_t: nil, &blk| blk.call }
    cb = instance_double('CircuitBreaker')
    allow(cb).to receive(:call).and_yield
    allow(RATE_LIMITERS).to receive(:[]).and_return(rl)
    allow(CIRCUIT_BREAKERS).to receive(:[]).and_return(cb)
  end

  describe '#execute' do
    context 'with no open strategy positions' do
      it 'returns an empty result' do
        result = described_class.new.execute({})
        expect(result[:positions]).to be_empty
        expect(result[:closed]).to eq(0)
      end
    end

    context 'with one open winner position' do
      it 'submits a sell_to_close at the bid' do
        Position.create!(
          symbol:      'AAPL260902C00220000',
          qty:         1,
          avg_entry_price: 3.50,
          origin:      'overnight_reversal',
          strategy_bucket: 'winner',
          snapshot_at: Time.current
        )

        snapshot_tool = instance_double('RubyLLM::Tool')
        snap = {
          'data' => {
            'snapshots' => {
              'AAPL260902C00220000' => { 'latestQuote' => { 'ap' => 3.6, 'bp' => 3.4 } }
            }
          }
        }
        allow(snapshot_tool).to receive(:call).and_return(FakeMcpContent.new(snap))
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_snapshot').and_return(snapshot_tool)

        fake_decision = double('Risk::Decision', approved?: true, rejected?: false, reasons: [])
        fake_result = double('Portfolio::Result', ok?: true, rejected?: false, reasons: [])
        fake_order = double('Order', id: 99, raw_response: {})
        allow(fake_order).to receive(:update!).and_return(true)
        allow(fake_result).to receive(:order).and_return(fake_order)
        allow_any_instance_of(described_class).to receive(:safe_risk).and_return(fake_decision)
        allow_any_instance_of(described_class).to receive(:safe_portfolio).and_return(fake_result)

        result = described_class.new.execute({ 'workflow_id' => 'wf-ovn-close' })
        expect(result[:closed]).to eq(1)
        outcome = result[:positions].first
        expect(outcome[:status]).to eq('submitted')
        expect(outcome[:symbol]).to eq('AAPL260902C00220000')
      end
    end

    context 'with one open spread position' do
      it 'submits buy_to_close on both legs (no_cache)' do
        Position.create!(
          symbol:      'TSLA260902C00250000',
          qty:         1,
          avg_entry_price: 1.00,
          origin:      'overnight_reversal',
          strategy_bucket: 'loser',
          raw: { 'ovn_long_occ' => 'TSLA260902C00255000' },
          snapshot_at: Time.current
        )

        snapshot_tool = instance_double('RubyLLM::Tool')
        snap_short = {
          'data' => {
            'snapshots' => {
              'TSLA260902C00250000' => { 'latestQuote' => { 'ap' => 1.10, 'bp' => 1.00 } },
              'TSLA260902C00255000' => { 'latestQuote' => { 'ap' => 0.40, 'bp' => 0.30 } }
            }
          }
        }
        allow(snapshot_tool).to receive(:call).and_return(FakeMcpContent.new(snap_short))
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_snapshot').and_return(snapshot_tool)

        fake_decision = double('Risk::Decision', approved?: true, rejected?: false, reasons: [])
        fake_result = double('Portfolio::Result', ok?: true, rejected?: false, reasons: [])
        fake_order = double('Order', id: 100, raw_response: {})
        allow(fake_order).to receive(:update!).and_return(true)
        allow(fake_result).to receive(:order).and_return(fake_order)
        allow_any_instance_of(described_class).to receive(:safe_risk).and_return(fake_decision)
        allow_any_instance_of(described_class).to receive(:safe_portfolio).and_return(fake_result)

        result = described_class.new.execute({})
        expect(result[:closed]).to eq(1)
        outcome = result[:positions].first
        expect(outcome[:status]).to eq('submitted')
      end
    end
  end

  class FakeMcpContent
    def initialize(hash) = @hash = hash
    def text = JSON.generate(@hash)
  end
end
