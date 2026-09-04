# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("app/strategies/mid_band_movers/plan").to_s
require Rails.root.join("app/strategies/mid_band_movers/strategy").to_s

# Tests for BuildPlanActivity. The activity is the only place this
# strategy touches the broker / DB. It composes:
#   1. Optionable universe via get_all_assets (cached 15 min)
#   2. Movers via get_market_movers
#   3. options_buying_power from the latest PortfolioSnapshot
#   4. Pure-Ruby Strategy.plan(...)
# And returns the serialized Plan hash.
#
# We stub the MCP tool, the universe cache, and the snapshot so the
# activity runs as a unit without external calls.

RSpec.describe MidBandMovers::BuildPlanActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: "wf-mbm-1", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }

  before do
    PortfolioSnapshot.delete_all
    # Pre-populate the cache so the activity's fetch hits the stubbed value.
    # Avoid stubbing Rails.cache.fetch directly (positional vs keyword arg
    # matchers are brittle); write+read works in every Rails.cache backend.
    Rails.cache.delete('mbm:optionable_universe:v1')
    Rails.cache.write('mbm:optionable_universe:v1', universe_assets, expires_in: 15.minutes)
  end

  let(:cfg) do
    {
      'middle_band' => { 'drop_top_pct' => 20, 'drop_bottom_pct' => 50 },
      'buckets' => [
        { 'name' => 'A', 'weight_pct' => 30, 'hold_hours' => 2 },
        { 'name' => 'B', 'weight_pct' => 30, 'hold_hours' => 4 },
        { 'name' => 'C', 'weight_pct' => 40, 'hold_hours' => 23.5 }
      ],
      'total_risk_pct' => 0.35,
      'fallback_random_count' => 20,
      'movers_top_n' => 100,
      'universe_top_n' => 50
    }
  end

  let(:universe_assets) do
    50.times.map { |i| { 'symbol' => "TKR#{i}", 'attributes' => ['has_options'] } }
  end

  let(:movers_payload) do
    { 'movers' => 50.times.map { |i| { 'symbol' => "TKR#{i}", 'price' => 100.0, 'change' => 1.0, 'percent_change' => 100.0 - i } } }
  end

  # Fake `MCP::Content` whose `.text` carries a JSON string. Mirrors
  # what `ruby_llm-mcp` actually returns from `tool.call(...)` —
  # the unwrap helper reads `.text` and JSON-parses it.
  class FakeMcpContent
    def initialize(hash) = @hash = hash
    def text = JSON.generate(@hash)
  end

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
    allow(TradingConfig).to receive(:fetch).with(:mid_band_movers).and_return(cfg)

    # Stub the MCP get_market_movers call.
    movers_tool = instance_double('RubyLLM::Tool')
    allow(movers_tool).to receive(:call).with(market_type: 'stocks', top: 100).and_return(FakeMcpContent.new(movers_payload))
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_market_movers').and_return(movers_tool)

    # Stub the rate-limiter / circuit-breaker so the wrapped block
    # actually runs. `with_limit: nil` would NOT yield — the block
    # containing the tool call would be skipped, and `raw` would be
    # nil. Mirror the real shape: yield the block, return its value.
    rl = instance_double('RateLimiter')
    allow(rl).to receive(:with_limit) { |_timeout: nil, &blk| blk.call }
    cb = instance_double('CircuitBreaker')
    allow(cb).to receive(:call).and_yield
    allow(RATE_LIMITERS).to receive(:[]).with(:alpaca_mcp).and_return(rl)
    allow(CIRCUIT_BREAKERS).to receive(:[]).with(:alpaca_mcp).and_return(cb)
  end

  describe '#execute' do
    it 'returns a serialized Plan hash' do
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({ 'workflow_id' => 'wf-mbm-1' })
      expect(result).to be_a(Hash)
      expect(result.keys).to include('tick_date', 'now_et', 'a', 'b', 'c', 'total_options_buying_power', 'total_cash_deployed')
      expect(result['a']['name']).to eq('A')
      expect(result['a']).to have_key('orders')
      expect(result['b']['name']).to eq('B')
      expect(result['c']['name']).to eq('C')
    end

    it 'splits 50 movers through the strategy and produces 15 kept tickers' do
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({})
      kept = result['a']['ticker_count'] + result['b']['ticker_count'] + result['c']['ticker_count']
      expect(kept).to eq(15)
    end

    it 'deploys <= 35% of options_buying_power' do
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({})
      expect(BigDecimal(result['total_cash_deployed'])).to be <= BigDecimal('3500')
    end

    it 'returns an empty Plan when the MCP universe call returns nothing' do
      Rails.cache.write('mbm:optionable_universe:v1', [], expires_in: 15.minutes)
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({})
      expect(result['a']['ticker_count']).to eq(0)
      expect(result['b']['ticker_count']).to eq(0)
      expect(result['c']['ticker_count']).to eq(0)
      expect(BigDecimal(result['total_cash_deployed'])).to eq(0)
    end

    it 'falls back to 0 buying power without a snapshot' do
      result = described_class.new.execute({})
      # 0 bp × 35% = 0 deployed. The strategy still runs and emits
      # an empty plan (every order has $0 allocated).
      expect(BigDecimal(result['total_cash_deployed'])).to eq(0)
    end

    it 'returns an empty Plan (not raises) when get_market_movers errors' do
      movers_tool = instance_double('RubyLLM::Tool')
      allow(movers_tool).to receive(:call).and_raise(StandardError, 'mcp down')
      allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_market_movers').and_return(movers_tool)
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = nil
      expect { result = described_class.new.execute({}) }.not_to raise_error
      # With 0 movers, the strategy falls back to random sampling of the
      # universe, so some orders come out. Total stays <= 20.
      kept = result['a']['ticker_count'] + result['b']['ticker_count'] + result['c']['ticker_count']
      expect(kept).to be <= 20
    end

    it 'tops off the movers list when the universe filter leaves < min_kept_after_filter' do
      # The MCP feed returns 5 names; only 1 is in the optionable
      # universe. Without the top-off, the strategy has only 1 name
      # to work with and produces a degenerate 1-ticker-per-bucket
      # plan. The top-off pads the list with names from the
      # universe so the strategy has enough material to split.
      movers_tool = instance_double('RubyLLM::Tool')
      few_movers = {
        'gainers' => [
          { 'symbol' => 'TKR1', 'price' => 100, 'change' => 5, 'percent_change' => 5 },
          { 'symbol' => 'TKR2', 'price' => 100, 'change' => 4, 'percent_change' => 4 },
          { 'symbol' => 'TKR3', 'price' => 100, 'change' => 3, 'percent_change' => 3 },
          { 'symbol' => 'TKR4', 'price' => 100, 'change' => 2, 'percent_change' => 2 },
          { 'symbol' => 'TKR5', 'price' => 100, 'change' => 1, 'percent_change' => 1 }
        ]
      }
      # Wrap in the MCP envelope so Mcp::Response.unwrap can find_array it.
      envelope = { '_alpaca_mcp_security' => {}, 'data' => few_movers }
      allow(movers_tool).to receive(:call).and_return(FakeMcpContent.new(envelope))
      allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_market_movers').and_return(movers_tool)

      # Universe has 50 names, only TKR1 is in the movers list.
      universe = (1..50).map { |i| { 'symbol' => "UNV#{i}", 'attributes' => ['has_options'] } }
      Rails.cache.delete('mbm:optionable_universe:v1')
      Rails.cache.write('mbm:optionable_universe:v1', universe, expires_in: 15.minutes)

      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)
      result = described_class.new.execute({})
      # The 5 movers (TKR1..TKR5) aren't in the UNV universe, so
      # the post-filter list is empty. The top-off pads it up to
      # min_kept_after_filter (20) with UNV1..UNV20. The strategy
      # then runs on 20 names, drops top 20% (4) + bottom 50% (10),
      # keeps 6, splits 2/2/2 across the 3 buckets.
      kept = result['a']['ticker_count'] + result['b']['ticker_count'] + result['c']['ticker_count']
      expect(kept).to eq(6)
    end
  end
end
