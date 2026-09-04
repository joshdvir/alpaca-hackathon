# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("app/strategies/mid_band_movers/plan").to_s
require Rails.root.join("app/strategies/mid_band_movers/strategy").to_s
require Rails.root.join("app/activities/mid_band_movers/submit_buy_orders_activity").to_s

# Tests for SubmitBuyOrdersActivity. This activity is the "I take a Plan
# and turn each order into a real option position" gate. It is tolerant
# by design: one bad ticker does NOT block the rest of the batch.
#
# Stubs:
#   - MCP get_option_chain → returns a small chain with one ATM call
#   - MCP get_stock_latest_trade → returns spot price
#   - RiskManager / PortfolioManager → real call path

RSpec.describe MidBandMovers::SubmitBuyOrdersActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: "wf-mbm-1", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }

  let(:cfg) do
    {
      'dte_target' => 30,
      'middle_band' => { 'drop_top_pct' => 20, 'drop_bottom_pct' => 50 },
      'buckets' => [
        { 'name' => 'A', 'weight_pct' => 30, 'hold_hours' => 2 },
        { 'name' => 'B', 'weight_pct' => 30, 'hold_hours' => 4 }
      ],
      'total_risk_pct' => 0.35,
      'universe_top_n' => 50
    }
  end

  let(:plan) do
    {
      'total_options_buying_power' => '10000.0',
      'total_cash_deployed' => '1050.0',
      'tick_date' => Date.current.iso8601,
      'now_et' => Time.current.in_time_zone('America/New_York').iso8601,
      'a' => {
        'name' => 'A', 'hold_hours' => 2.0, 'sell_at_offset_hours' => 2.0,
        'ticker_count' => 1, 'cash_per_ticker' => '1050.0',
        'orders' => [{ 'symbol' => 'AAPL', 'cash_allocated' => '1050.0' }]
      },
      'b' => {
        'name' => 'B', 'hold_hours' => 4.0, 'sell_at_offset_hours' => 4.0,
        'ticker_count' => 1, 'cash_per_ticker' => '1050.0',
        'orders' => [{ 'symbol' => 'MSFT', 'cash_allocated' => '1050.0' }]
      },
      'c' => MidBandMovers::Bucket.to_h(MidBandMovers::Bucket.empty('C'))
    }
  end

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
    allow(TradingConfig).to receive(:fetch).and_call_original
    allow(TradingConfig).to receive(:fetch).with(:mid_band_movers).and_return(cfg)
    # Risk::RiskManager freezes LIMITS = TradingConfig.fetch(:risk_limits)
    # at class load time, so we can't stub that fetch after the fact
    # without reloading the constant. Real trading.yml values are fine
    # for these tests — we're exercising the activity path, not the
    # risk rules themselves.

    # Stub PortfolioManager.execute so we don't have to mock the
    # place_option_order MCP call (which would need stubs for the
    # trading MCP, the rate-limiter, the circuit-breaker, and the
    # broker response envelope). The activity just needs a
    # `Result.new(ok: true, order:, reasons:)` back; the activity
    # doesn't inspect the order's internals.
    ok_result = instance_double('Portfolio::PortfolioManager::Result', ok?: true, reasons: [], order: nil)
    allow(Portfolio::PortfolioManager).to receive(:execute).and_return(ok_result)

    # Stub the rate-limiter / circuit-breaker so the wrapped block runs.
    rl = instance_double('RateLimiter')
    allow(rl).to receive(:with_limit) { |_timeout: nil, &blk| blk.call }
    cb = instance_double('CircuitBreaker')
    allow(cb).to receive(:call).and_yield
    allow(RATE_LIMITERS).to receive(:[]).with(:alpaca_mcp).and_return(rl)
    allow(CIRCUIT_BREAKERS).to receive(:[]).with(:alpaca_mcp).and_return(cb)

    # Stub get_stock_latest_trade to return a fixed price.
    trade_tool = instance_double('RubyLLM::Tool')
    trade_payload = { 'trades' => { 'AAPL' => { 'p' => 200.0 }, 'MSFT' => { 'p' => 400.0 } } }
    allow(trade_tool).to receive(:call).and_return(FakeMcpContent.new(trade_payload))
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_stock_latest_trade').and_return(trade_tool)

    # Stub get_option_chain to return an ATM call for both tickers.
    # OCC symbol format: TICKER + YYMMDD + C + STRIKE * 1000 (8 digits)
    occ_aapl = "AAPL260515C00200000" # 30 DTE ~ 2026-09-01 + 30 days, 200 strike
    occ_msft = "MSFT260515C00400000" # 400 strike
    chain_payload = {
      'snapshots' => {
        occ_aapl => {
          'strike_price' => 200.0,
          'latestQuote'  => { 'ap' => 5.0, 'bp' => 4.95 },
          'greeks' => { 'delta' => 0.50 }
        },
        occ_msft => {
          'strike_price' => 400.0,
          'latestQuote'  => { 'ap' => 8.0, 'bp' => 7.95 },
          'greeks' => { 'delta' => 0.50 }
        }
      }
    }
    chain_tool = instance_double('RubyLLM::Tool')
    allow(chain_tool).to receive(:call).and_return(FakeMcpContent.new(chain_payload))
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_chain').and_return(chain_tool)
  end

  describe '#execute' do
    it 'creates a TradeProposal + Order per bucket' do
      result = described_class.new.execute(plan, { 'workflow_id' => 'wf-mbm-1' })
      expect(result[:orders].size).to eq(2)
      expect(result[:orders].map { |o| o[:status] }).to all(eq('submitted'))
      # 1050 / (5.0 * 100) = 2 contracts; 1050 / (8.0 * 100) = 1 contract
      expect(result[:orders].map { |o| o[:qty] }).to contain_exactly(2, 1)
      expect(TradeProposal.where(origin: 'mid_band_movers').count).to eq(2)
    end

    it 'tags each TradeProposal rationale with the planned_sell_at + bucket' do
      described_class.new.execute(plan, {})
      proposals = TradeProposal.where(origin: 'mid_band_movers')
      expect(proposals.size).to eq(2)
      proposals.each do |p|
        meta = JSON.parse(p.rationale)
        expect(meta).to include('origin' => 'mid_band_movers')
        expect(meta['planned_sell_at']).to be_a(String)
        expect(%w[A B]).to include(meta['strategy_bucket'])
      end
    end

    it 'reports "no_chain" when the MCP chain is empty' do
      chain_tool = instance_double('RubyLLM::Tool')
      allow(chain_tool).to receive(:call).and_return(FakeMcpContent.new({ 'snapshots' => {} }))
      allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_chain').and_return(chain_tool)

      result = described_class.new.execute(plan, {})
      expect(result[:orders].map { |o| o[:status] }).to all(eq('no_chain'))
    end

    it 'reports "cash_too_small" when premium exceeds cash' do
      # Premium $50/share × 100 = $5000/contract. $1050 ÷ $5000 = 0 contracts.
      occ_aapl = "AAPL260515C00200000"
      chain_payload = {
        'snapshots' => {
          occ_aapl => { 'strike_price' => 200.0, 'latestQuote' => { 'ap' => 50.0 } }
        }
      }
      chain_tool = instance_double('RubyLLM::Tool')
      allow(chain_tool).to receive(:call).and_return(FakeMcpContent.new(chain_payload))
      allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_chain').and_return(chain_tool)

      result = described_class.new.execute(plan, {})
      expect(result[:orders].map { |o| o[:status] }).to all(eq('cash_too_small'))
    end

    it 'returns an empty result (not raises) on a hard exception' do
      allow(TradingConfig).to receive(:fetch).with(:mid_band_movers).and_raise(StandardError, 'cfg down')
      result = nil
      expect { result = described_class.new.execute(plan, {}) }.not_to raise_error
      expect(result[:error]).to include('cfg down')
    end
  end
end

# Same fake content shape used by BuildPlanActivity spec. Mirrors the
# real `MCP::Content` returned by `ruby_llm-mcp`'s tool calls.
class FakeMcpContent
  def initialize(hash) = @hash = hash
  def text = JSON.generate(@hash)
end
