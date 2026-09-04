# frozen_string_literal: true

require 'rails_helper'

Bar = Backtest::HistoricalDataProvider::Bar
OptionQuote = Backtest::HistoricalDataProvider::OptionQuote

# A canned data provider for the backtest engine that doesn't touch MCP.
class FakeDataProvider
  def initialize(bars_per_ticker: {}, chains: {})
    @bars = bars_per_ticker
    @chains = chains
  end

  def fetch_bars(ticker, _start, _end, **_opts)
    @bars[ticker] || []
  end

  def synthesize_chain(ticker, as_of_date, spot:, **_opts)
    @chains[ticker]&.call(spot, as_of_date) || default_chain(spot, as_of_date)
  end

  private

  def default_chain(spot, as_of_date)
    expiry = as_of_date + 30
    [[1.0, 1.0, 'C'], [1.0, 1.0, 'P']].map do |bid, ask, right|
      OptionQuote.new(
        symbol: "FAKE#{right}#{spot.to_i}",
        strike: spot, expiry: expiry, right: right,
        bid: bid, ask: ask, mid: (bid + ask) / 2.0,
        iv: 0.30, delta: 0.5, gamma: 0.05, theta: -0.05, vega: 0.10
      )
    end
  end
end

def make_bars(count, start_price: 100.0)
  start_date = Date.current - count
  Array.new(count) do |i|
    Bar.new(
      t: start_date + i,
      open: start_price,
      high: start_price + 1,
      low: start_price - 1,
      close: start_price,
      volume: 1_000_000
    )
  end
end

RSpec.describe Backtest::Engine do
  let(:run) do
    BacktestRun.create!(
      tickers: %w[SPY QQQ],
      period_days: 5,
      mode: 'full',
      start_of_day_equity: 100_000,
      status: 'pending'
    )
  end

  before do
    allow(Analyst::MarketDataAnalyst).to receive(:call).and_return(thesis: 'ok', signals: [], confidence: 80)
    allow(Analyst::NewsAnalyst).to receive(:call).and_return(thesis: 'ok', signals: [], confidence: 80)
    allow(Analyst::MacroAnalyst).to receive(:call).and_return(thesis: 'ok', signals: [], confidence: 80)
    allow(Analyst::InsiderAnalyst).to receive(:call).and_return(thesis: 'ok', signals: [], confidence: 80)
  end

  describe '#call' do
    it "sets the run to 'success' at the end" do
      provider = FakeDataProvider.new(bars_per_ticker: { 'SPY' => make_bars(3) })
      engine = described_class.new(
        run: run, start_date: Date.current - 3, end_date: Date.current,
        data_provider: provider
      )
      allow(Debate::BullResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 0)
      allow(Debate::BearResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 0)
      allow(Debate::ResearchManager).to receive(:call).and_return(
        verdict: 'no_trade', thesis: 'skip', trade_plan: nil, confidence: 0, no_trade_reasons: ['low']
      )

      engine.call
      expect(run.reload.status).to eq('success')
    end

    it "persists a BacktestTrade when the verdict is 'trade' and the option exists" do
      chain_quote = OptionQuote.new(
        symbol: 'SPY260116C00580000',
        strike: 100, expiry: Date.current + 5, right: 'C',
        bid: 1.00, ask: 1.10, mid: 1.05,
        iv: 0.30, delta: 0.5, gamma: 0.05, theta: -0.05, vega: 0.10
      )
      provider = FakeDataProvider.new(
        bars_per_ticker: { 'SPY' => make_bars(3, start_price: 100.0) },
        chains: { 'SPY' => ->(_spot, _date) { [chain_quote] } }
      )
      allow(Debate::BullResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 80)
      allow(Debate::BearResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 80)
      allow(Debate::ResearchManager).to receive(:call).and_return(
        verdict: 'trade', thesis: 'go', trade_plan: { 'strategy' => 'vertical' }, confidence: 80, no_trade_reasons: []
      )
      allow(Trader).to receive(:call).and_return(
        proposal: {
          symbol: 'SPY260116C00580000', side: 'buy_to_open', qty: 1,
          limit_price: BigDecimal('1.05'), tif: 'day', rationale: 'test'
        }
      )

      engine = described_class.new(
        run: run, start_date: Date.current - 3, end_date: Date.current,
        data_provider: provider
      )
      expect { engine.call }.to change { BacktestTrade.count }.by_at_least(1)
      expect(run.reload.total_trades).to be >= 1
    end

    it 'short-circuits the debate when avg analyst confidence is below threshold' do
      [Analyst::MarketDataAnalyst, Analyst::NewsAnalyst, Analyst::MacroAnalyst, Analyst::InsiderAnalyst].each do |klass|
        allow(klass).to receive(:call).and_return(thesis: 'weak', signals: [], confidence: 10)
      end
      expect(Debate::BullResearcher).not_to receive(:call)
      expect(Debate::BearResearcher).not_to receive(:call)
      expect(Debate::ResearchManager).not_to receive(:call)

      provider = FakeDataProvider.new(bars_per_ticker: { 'SPY' => make_bars(3) })
      engine = described_class.new(
        run: run, start_date: Date.current - 3, end_date: Date.current,
        data_provider: provider
      )
      engine.call
      expect(run.reload.status).to eq('success')
      expect(run.total_trades).to eq(0)
    end

    it 'records 0 trades when no ticker produces a tradable verdict' do
      allow(Debate::BullResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 0)
      allow(Debate::BearResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 0)
      allow(Debate::ResearchManager).to receive(:call).and_return(
        verdict: 'no_trade', thesis: 'skip', trade_plan: nil, confidence: 0, no_trade_reasons: ['low']
      )
      provider = FakeDataProvider.new(bars_per_ticker: { 'SPY' => make_bars(3) })
      engine = described_class.new(
        run: run, start_date: Date.current - 3, end_date: Date.current,
        data_provider: provider
      )
      engine.call
      run.reload
      expect(run.total_trades).to eq(0)
      expect(run.winning_trades).to eq(0)
      expect(run.final_equity).to eq(run.start_of_day_equity)
    end

    it "marks the run as 'error' on uncaught failure" do
      allow(Analyst::MarketDataAnalyst).to receive(:call).and_raise(RuntimeError, 'boom')
      provider = FakeDataProvider.new(bars_per_ticker: { 'SPY' => make_bars(3) })
      engine = described_class.new(
        run: run, start_date: Date.current - 3, end_date: Date.current,
        data_provider: provider
      )
      expect { engine.call }.to raise_error(RuntimeError, 'boom')
      run.reload
      expect(run.status).to eq('error')
      expect(run.error_message).to include('boom')
    end
  end

  describe 'max drawdown' do
    it 'is non-negative' do
      provider = FakeDataProvider.new(bars_per_ticker: { 'SPY' => make_bars(2) })
      allow(Debate::BullResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 0)
      allow(Debate::BearResearcher).to receive(:call).and_return(argument: 'x', cited_signals: [], conviction: 0)
      allow(Debate::ResearchManager).to receive(:call).and_return(
        verdict: 'no_trade', thesis: 'skip', trade_plan: nil, confidence: 0, no_trade_reasons: ['low']
      )
      engine = described_class.new(
        run: run, start_date: Date.current - 2, end_date: Date.current,
        data_provider: provider
      )
      engine.call
      expect(run.reload.max_drawdown.to_f).to be >= 0
    end
  end
end
