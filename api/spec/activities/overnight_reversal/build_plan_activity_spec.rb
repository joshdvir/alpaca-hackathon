# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('app/strategies/overnight_reversal/plan').to_s
require Rails.root.join('app/strategies/overnight_reversal/strategy').to_s

RSpec.describe OvernightReversal::BuildPlanActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: 'wf-ovn-1', workflow_run_id: 'run-1') }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }

  let(:cfg) do
    {
      'winners_count'        => 5,
      'losers_count'         => 5,
      'total_risk_pct'       => 0.80,
      'winner_bucket_weight' => 0.50,
      'spread_width'         => 5.0,
      'short_delta_target'   => 0.20,
      'min_underlying_price' => 10,
      'min_daily_volume'     => 500_000,
      'close_at_et'          => '15:55',
      'skip_half_days'       => false,
      'screen_source'        => 'tradingview'
    }
  end

  let(:universe) do
    %w[AAPL NVDA TSLA AMD META AMZN MSFT].map do |s|
      { 'symbol' => s, 'attributes' => ['has_options'], 'tradable' => true, 'marginable' => true }
    end
  end

  let(:movers_payload_gainers) do
    [
      { 'symbol' => 'NVDA', 'change_percent' => 6.20 },
      { 'symbol' => 'AMD',  'change_percent' => 4.10 },
      { 'symbol' => 'AAPL', 'change_percent' => 3.45 }
    ]
  end

  let(:movers_payload_losers) do
    [
      { 'symbol' => 'TSLA', 'change_percent' => -5.30 },
      { 'symbol' => 'AMZN', 'change_percent' => -3.20 },
      { 'symbol' => 'MSFT', 'change_percent' => -2.40 }
    ]
  end

  let(:movers_payload) do
    # Used as default for either tool.
    movers_payload_gainers
  end

  class FakeMcpContent
    def initialize(hash) = @hash = hash
    def text = JSON.generate(@hash)
  end

  let(:tv_tool) { instance_double('RubyLLM::Tool') }
  let(:alpaca_clock_tool) { instance_double('RubyLLM::Tool') }
  let(:alpaca_calendar_tool) { instance_double('RubyLLM::Tool') }
  let(:alpaca_trade_tool) { instance_double('RubyLLM::Tool') }
  let(:alpaca_universe_tool) { instance_double('RubyLLM::Tool') }

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
    allow(TradingConfig).to receive(:fetch).with(:overnight_reversal).and_return(cfg)

    # Pre-populate the universe cache so the activity's fetch hits our value.
    Rails.cache.delete(described_class::UNIVERSE_CACHE_KEY)
    Rails.cache.write(described_class::UNIVERSE_CACHE_KEY, universe, expires_in: 15.minutes)

    # Stub TradingView MCP screening — return our payload for each exchange.
    # top_gainers returns the gainers list; top_losers returns the losers list.
    exchanges = %w[NASDAQ NYSE]
    tv_limit = (cfg['tv_top_n_per_exchange'] || 20)
    allow(TRADINGVIEW_MCP).to receive(:tool).with('top_gainers').and_return(tv_tool)
    allow(TRADINGVIEW_MCP).to receive(:tool).with('top_losers').and_return(tv_tool)
    exchanges.each do |exch|
      allow(tv_tool).to receive(:call).with(hash_including(exchange: exch, timeframe: '1D', limit: tv_limit))
        .and_return(FakeMcpContent.new(movers_payload_gainers))
      allow(tv_tool).to receive(:call).with(hash_including(exchange: exch, timeframe: '1D', limit: tv_limit))
        .and_return(FakeMcpContent.new(movers_payload_losers))
    end

    # Stub the clock + calendar so half-day check is deterministic.
    clock = { 'timestamp' => Time.current.iso8601, 'is_open' => true }
    cal   = [
      { 'date' => Date.current.iso8601,            'closes_at' => '2026-09-02T20:00:00Z' },
      { 'date' => (Date.current - 1).iso8601,      'closes_at' => '2026-09-01T20:00:00Z' }
    ]
    allow(alpaca_clock_tool).to receive(:call).and_return(FakeMcpContent.new(clock))
    allow(alpaca_calendar_tool).to receive(:call).and_return(FakeMcpContent.new({ 'calendar' => cal }))

    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_clock').and_return(alpaca_clock_tool)
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_calendar').and_return(alpaca_calendar_tool)

    # Stub get_stock_latest_trade so the spot lookup returns
    # reasonable values for every symbol we use.
    trade_payload = ->(sym) do
      { 'data' => { 'trades' => { sym => { 'p' => sym == 'PENNY' ? 5.0 : 200.0 } } } }
    end
    syms = %w[NVDA AMD AAPL TSLA AMZN MSFT META]
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_stock_latest_trade').and_return(alpaca_trade_tool)
    syms.each do |s|
      allow(alpaca_trade_tool).to receive(:call).with(symbols: s).and_return(FakeMcpContent.new(trade_payload.call(s)))
    end

    # Stub get_all_assets (already cached above, but other call sites
    # can reach for it).
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_all_assets').and_return(alpaca_universe_tool)

    # Stub get_stock_bars (used by the alpaca_yesterday_movers fallback
    # path; pre-stub so a missed fallback doesn't blow up).
    bars_tool = instance_double('RubyLLM::Tool')
    allow(alpaca_trade_tool).to receive(:call).and_return(FakeMcpContent.new({})) if false # placeholder
    allow(bars_tool).to receive(:call).and_return(FakeMcpContent.new({ 'bars' => {} }))
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_stock_bars').and_return(bars_tool)

    # Stub the per-name DTE eligibility probe (BuildPlanActivity calls
    # `mcp_get_option_chain` for every surviving name). Always return a
    # non-empty chain so the probe accepts every name in this happy-path
    # test and the focus is on plan volume, not option markets.
    chain_tool = instance_double('RubyLLM::Tool')
    allow(chain_tool).to receive(:call).and_return(
      FakeMcpContent.new({
        'snapshots' => {
          'TEST260902C00200000' => { 'latestQuote' => { 'ap' => 1.0, 'bp' => 0.95 } }
        }
      })
    )
    allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_chain').and_return(chain_tool)

    # Stub rate-limiter / circuit-breaker so the wrapped block runs.
    rl_tv = instance_double('RateLimiter')
    allow(rl_tv).to receive(:with_limit) { |_t: nil, &blk| blk.call }
    cb_tv = instance_double('CircuitBreaker')
    allow(cb_tv).to receive(:call).and_yield
    allow(RATE_LIMITERS).to receive(:[]).with(:tradingview_mcp).and_return(rl_tv)
    allow(CIRCUIT_BREAKERS).to receive(:[]).with(:tradingview_mcp).and_return(cb_tv)

    rl_a = instance_double('RateLimiter')
    allow(rl_a).to receive(:with_limit) { |_t: nil, &blk| blk.call }
    cb_a = instance_double('CircuitBreaker')
    allow(cb_a).to receive(:call).and_yield
    allow(RATE_LIMITERS).to receive(:[]).with(:alpaca_mcp).and_return(rl_a)
    allow(CIRCUIT_BREAKERS).to receive(:[]).with(:alpaca_mcp).and_return(cb_a)
  end

  describe '#execute' do
    it 'returns a serialized Plan hash with winners/losers/close_at_et' do
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({ 'workflow_id' => 'wf-ovn-1' })

      expect(result.keys).to include('tick_date', 'now_et', 'close_at_et',
                                     'total_options_buying_power', 'total_cash_deployed',
                                     'winner_bucket_budget', 'loser_bucket_budget',
                                     'skipped', 'winners', 'losers')
      expect(result['skipped']).to be(false)
      expect(result['winners']).to be_an(Array)
      expect(result['losers']).to be_an(Array)
    end

    it 'deploys <= 80% of options_buying_power' do
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({})
      expect(BigDecimal(result['total_cash_deployed'])).to be <= BigDecimal('8000')
    end

    it 'produces winners with positive pct_change and losers with negative' do
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({})
      result['winners'].each { |w| expect(w['pct_change']).to be > 0 }
      result['losers'].each  { |l| expect(l['pct_change']).to be < 0 }
    end

    it 'skips half-day when clock shows an early close' do
      cfg_with_skip = { 'winners_count' => 5, 'skip_half_days' => true, 'screen_source' => 'tradingview' }
      # Calendar with a 13:00 ET close = half-day.
      cal = [
        { 'date' => Date.current.iso8601, 'closes_at' => '2026-09-02T17:00:00Z' } # 13:00 ET
      ]
      allow(alpaca_calendar_tool).to receive(:call).and_return(FakeMcpContent.new({ 'calendar' => cal }))
      allow(TradingConfig).to receive(:fetch).with(:overnight_reversal).and_return(cfg_with_skip)
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = described_class.new.execute({})
      expect(result['skipped']).to be(true)
      expect(result['skipped_reason']).to eq('half_day')
      expect(result['winners']).to be_empty
      expect(result['losers']).to be_empty
    end

    it 'falls through when TradingView MCP is down (no exception)' do
      # Simulate TradingView tool returning nil (server offline).
      allow(TRADINGVIEW_MCP).to receive(:tool).with('top_gainers').and_return(nil)
      allow(TRADINGVIEW_MCP).to receive(:tool).with('top_losers').and_return(nil)
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      expect { @res = described_class.new.execute({}) }.not_to raise_error
      # With 0 movers, the strategy falls back to empty → skipped.
      expect(@res['skipped']).to be(true)
    end

    it 'returns an empty Plan (skipped) without raising when everyone crashes' do
      allow(TRADINGVIEW_MCP).to receive(:tool).and_raise(StandardError, 'mcp down')
      allow(RATE_LIMITERS).to receive(:[]).and_call_original
      PortfolioSnapshot.create!(options_buying_power: 10_000, cash: 10_000, buying_power: 10_000, equity: 10_000)

      result = nil
      expect { result = described_class.new.execute({}) }.not_to raise_error
      expect(result).to be_a(Hash)
    end
  end
end
