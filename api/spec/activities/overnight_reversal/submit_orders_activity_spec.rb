# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('app/strategies/overnight_reversal/plan').to_s
require Rails.root.join('app/strategies/overnight_reversal/strategy').to_s

RSpec.describe OvernightReversal::SubmitOrdersActivity do
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
      'dte_target'           => [0, 3, 7],
      'min_credit_to_width'  => 0.05,
      'use_delta_selection'  => false
    }
  end

  # Build a Plan hash with one winner and one loser.
  let(:plan_hash) do
    {
      'total_options_buying_power' => '10000',
      'total_cash_deployed'        => '8000',
      'winner_bucket_budget'       => '4000',
      'loser_bucket_budget'        => '4000',
      'tick_date'                  => Date.current.to_s,
      'now_et'                     => Time.current.in_time_zone('America/New_York').iso8601,
      'close_at_et'                => (Time.current + 6.hours).iso8601,
      'skipped'                    => false,
      'skipped_reason'             => nil,
      'winners' => [
        {
          'symbol'         => 'AAPL',
          'pct_change'     => 3.45,
          'cash_allocated' => '4000',
          'strike'         => 220.0,
          'side'           => 'buy_to_open'
        }
      ],
      'losers' => [
        {
          'symbol'         => 'TSLA',
          'pct_change'     => -3.20,
          'cash_allocated' => '4000',
          'short_strike'   => 250.0,
          'long_strike'    => 255.0,
          'width'          => 5.0,
          'short_leg_side' => 'sell_to_open',
          'long_leg_side'  => 'buy_to_open'
        }
      ]
    }
  end

  class FakeMcpContent
    def initialize(hash) = @hash = hash
    def text = JSON.generate(@hash)
  end

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
    allow(TradingConfig).to receive(:fetch).and_call_original
    allow(TradingConfig).to receive(:fetch).with(:overnight_reversal).and_return(cfg)
    # The per-position cap uses risk_limits.max_position_pct (10%).
    # Stub the nested risk_limits lookup so the test exercises a real
    # cap against a fake-equity PortfolioSnapshot.
    allow(TradingConfig).to receive(:fetch).with(:risk_limits).and_return({ max_position_pct: 0.10 })

    # Stub the rate limiter / circuit breaker (test env doesn't have these).
    rl = instance_double('RateLimiter')
    allow(rl).to receive(:with_limit) { |_t: nil, &blk| blk.call }
    cb = instance_double('CircuitBreaker')
    allow(cb).to receive(:call).and_yield
    allow(RATE_LIMITERS).to receive(:[]).and_return(rl)
    allow(CIRCUIT_BREAKERS).to receive(:[]).and_return(cb)

    # Provide a real PortfolioSnapshot so the cap math can run against
    # a known equity without depending on the Alpaca mirror.
    PortfolioSnapshot.delete_all
    PortfolioSnapshot.create!(equity: 50_000.0, options_buying_power: 50_000.0)
  end

  describe '#execute' do
    context 'with a valid winner chain and loser chain' do
      let(:trade_tool) { instance_double('RubyLLM::Tool') }
      let(:chain_tool) { instance_double('RubyLLM::Tool') }

      before do
        # Clear cache so prior tests don't pollute the option-chain cache.
        Rails.cache.clear

        # Trade lookup for AAPL → $220; TSLA → $250.
        trade_aapl = { 'data' => { 'trades' => { 'AAPL' => { 'p' => 220.0 } } } }
        trade_tsla = { 'data' => { 'trades' => { 'TSLA' => { 'p' => 250.0 } } } }
        allow(trade_tool).to receive(:call).with(symbols: 'AAPL').and_return(FakeMcpContent.new(trade_aapl))
        allow(trade_tool).to receive(:call).with(symbols: 'TSLA').and_return(FakeMcpContent.new(trade_tsla))
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_stock_latest_trade').and_return(trade_tool)

        # Stub get_option_chain to return different snapshots based
        # on the underlying_symbol arg.
        aapl_chain = { 'snapshots' => {
          'AAPL260902C00220000' => { 'latestQuote' => { 'ap' => 3.50, 'bp' => 3.40, 'as' => 10 } }
        } }
        tsla_chain = { 'snapshots' => {
          'TSLA260902C00250000' => { 'latestQuote' => { 'ap' => 1.00, 'bp' => 0.90, 'as' => 10 } },
          'TSLA260902C00255000' => { 'latestQuote' => { 'ap' => 0.30, 'bp' => 0.20, 'as' => 10 } }
        } }

        # Stub based on arg matching: when underlying_symbol=AAPL/TSLA.
        allow(chain_tool).to receive(:call) do |args|
          sym = args[:underlying_symbol] || args['underlying_symbol']
          case sym
          when 'AAPL' then FakeMcpContent.new(aapl_chain)
          when 'TSLA' then FakeMcpContent.new(tsla_chain)
          else FakeMcpContent.new({ 'snapshots' => {} })
          end
        end
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_chain').and_return(chain_tool)
      end

      it 'submits a winner long call and a loser bear-call spread, returning both outcomes' do
        # Stub risk + portfolio
        fake_decision = double('Risk::Decision', approved?: true, rejected?: false, reasons: [])
        fake_result = double('Portfolio::Result', ok?: true, rejected?: false, reasons: [])
        fake_order = double('Order', id: 42, raw_response: {})
        allow(fake_order).to receive(:update!).and_return(true) # tag_order
        allow(fake_result).to receive(:order).and_return(fake_order)
        allow(Risk::RiskManager).to receive(:new).and_return(double(check: fake_decision))
        allow(Portfolio::PortfolioManager).to receive(:execute).and_return(fake_result)
        allow_any_instance_of(OvernightReversal::SubmitOrdersActivity).to receive(:safe_risk).and_return(fake_decision)
        allow_any_instance_of(OvernightReversal::SubmitOrdersActivity).to receive(:safe_portfolio).and_return(fake_result)

        result = described_class.new.execute(plan_hash, { 'workflow_id' => 'wf-ovn-1' })

        expect(result[:orders]).to be_an(Array)
        expect(result[:orders].size).to eq(2)
        winner_outcome = result[:orders].find { |o| o[:bucket] == 'winner' }
        loser_outcome  = result[:orders].find { |o| o[:bucket] == 'loser' }

        expect(winner_outcome[:status]).to eq('submitted')
        expect(winner_outcome[:symbol]).to eq('AAPL')

        expect(loser_outcome[:status]).to eq('submitted')
        expect(loser_outcome[:symbol]).to eq('TSLA')
        expect(loser_outcome[:short_strike]).to eq(250.0)
        expect(loser_outcome[:long_strike]).to eq(255.0)
      end
    end

    context 'when the 0DTE chain is empty for a winner' do
      it 'drops the name and proceeds (no rebalance)' do
        chain_tool = instance_double('RubyLLM::Tool')
        trade_tool = instance_double('RubyLLM::Tool')

        # Empty chain for every option lookup.
        allow(chain_tool).to receive(:call).and_return(FakeMcpContent.new({ 'snapshots' => {} }))
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_chain').and_return(chain_tool)

        # Trade price lookup still works.
        trade = { 'data' => { 'trades' => { 'AAPL' => { 'p' => 220.0 } } } }
        allow(trade_tool).to receive(:call).and_return(FakeMcpContent.new(trade))
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_stock_latest_trade').and_return(trade_tool)

        result = described_class.new.execute(plan_hash, {})
        winner = result[:orders].find { |o| o[:bucket] == 'winner' }
        expect(winner[:status]).to eq('no_chain')
      end
    end

    context 'when the plan is skipped (e.g. half-day)' do
      it 'returns an empty :orders list with skipped: true' do
        plan_hash['skipped'] = true
        plan_hash['skipped_reason'] = 'half_day'
        result = described_class.new.execute(plan_hash, {})
        expect(result[:orders]).to be_empty
        expect(result[:skipped]).to be(true)
        expect(result[:skipped_reason]).to eq('half_day')
      end
    end

    context 'when the plan spread has degenerate credit (net_debit)' do
      it 'drops the loser (no long_call fallback) so the bucket stays 100% short' do
        # Build a chain where short premium < long premium → net debit.
        # Per strategy decision (2026-09-03), losers must NEVER fall
        # back to long_call — that would double-up directionally with
        # winners. We drop the name with `no_bear_legs` instead.
        trade_tool = instance_double('RubyLLM::Tool')
        allow(trade_tool).to receive(:call).and_return(FakeMcpContent.new({ 'data' => { 'trades' => { 'TSLA' => { 'p' => 250.0 } } } }))
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_stock_latest_trade').and_return(trade_tool)

        chain_tool = instance_double('RubyLLM::Tool')
        tsla_chain = {
          'TSLA260902C00250000' => { 'latestQuote' => { 'ap' => 0.10, 'bp' => 0.05, 'as' => 10 } },
          'TSLA260902C00255000' => { 'latestQuote' => { 'ap' => 1.50, 'bp' => 1.40, 'as' => 10 } } # long > short → net debit
        }
        allow(chain_tool).to receive(:call).and_return(FakeMcpContent.new({ 'snapshots' => tsla_chain }))
        allow(ALPACA_MCP_READONLY).to receive(:tool).with('get_option_chain').and_return(chain_tool)

        result = described_class.new.execute(plan_hash, {})
        loser = result[:orders].find { |o| o[:bucket] == 'loser' }
        expect(loser[:status]).to eq('no_bear_legs')
        expect(loser[:reason]).to eq('net_debit')
        expect(loser[:fallback]).to be_nil
      end
    end
  end
end
