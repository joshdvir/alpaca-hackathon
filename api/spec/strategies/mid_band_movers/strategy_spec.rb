# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("app/strategies/mid_band_movers/plan").to_s
require Rails.root.join("app/strategies/mid_band_movers/strategy").to_s

# Pure-Ruby tests for MidBandMovers::Strategy. No I/O,
# no MCP, no DB. Inputs are stubbed dicts in the same shape the
# BuildPlanActivity will pass in.
RSpec.describe MidBandMovers::Strategy do
  let(:cfg) do
    {
      'middle_band' => { 'drop_top_pct' => 20, 'drop_bottom_pct' => 50 },
      'buckets' => [
        { 'name' => 'A', 'weight_pct' => 30, 'hold_hours' => 2 },
        { 'name' => 'B', 'weight_pct' => 30, 'hold_hours' => 4 },
        { 'name' => 'C', 'weight_pct' => 40, 'hold_hours' => 23.5 }
      ],
      'total_risk_pct' => 0.35,
      'fallback_random_count' => 20
    }
  end

  # 50 optionable names (PLTR..PLTR+50 is just a stand-in symbol set)
  def optionable_universe(symbols = %w[PLTR TSLA AAPL MSFT AMZN NVDA GOOG META NFLX AMD AVGO COST PEP KO JPM BAC WFC XOM CVX UNH JNJ ABBV LLY PFE MRK TMO ABT ACN DHR ORCL CSCO IBM QCOM TXN MU INTC AMAT LRCX KLAC SNPS CDNS ADBE CRM NOW INTU META])
    symbols.map { |s| { 'symbol' => s, 'price' => 100.0, 'attributes' => ['has_options'] } }
  end

  def movers(entries)
    # entries: [[symbol, percent_change], ...]
    entries.map { |sym, pct| { 'symbol' => sym, 'price' => 100.0, 'change' => pct, 'percent_change' => pct } }
  end

  def tkr_universe(n)
    optionable_universe(n.times.map { |i| "TKR#{i}" })
  end

  def tkr_movers(n)
    movers(n.times.map { |i| ["TKR#{i}", 100.0 - i] })
  end

  describe '#plan' do
    it 'drops the top 20% and bottom 50% to keep the middle 30%' do
      # 50 movers → drop 10 (20%) and 25 (50%) → keep 15 (30%)
      movs = tkr_movers(50)
      plan = described_class.plan(
        optionable_universe: tkr_universe(50),
        movers: movs,
        options_buying_power: 10_000,
        cfg: cfg,
        now: Time.zone.parse('2026-09-01 11:30:00 EDT')
      )
      expect(plan.a.ticker_count + plan.b.ticker_count + plan.c.ticker_count).to eq(15)
    end

    it 'splits the kept band into 3 buckets by weight' do
      movs = tkr_movers(50)
      plan = described_class.plan(
        optionable_universe: tkr_universe(50), movers: movs,
        options_buying_power: 10_000, cfg: cfg, now: Time.current
      )
      # 15 kept, weights 30/30/40 → buckets roughly 4-5 / 4-5 / 6
      expect(plan.a.ticker_count).to be_within(1).of(5)
      expect(plan.b.ticker_count).to be_within(1).of(5)
      expect(plan.c.ticker_count).to be_within(1).of(6)
    end

    it 'allocates 35% of options_buying_power split by bucket weight' do
      movs = tkr_movers(50)
      plan = described_class.plan(
        optionable_universe: tkr_universe(50), movers: movs,
        options_buying_power: 10_000, cfg: cfg, now: Time.current
      )
      # Total should be <= $3,500 (35% of 10K)
      expect(plan.total_cash_deployed).to be <= BigDecimal('3500')
      # Bucket A holds 30% of the total (~$1,050)
      a_orders_spend = plan.a.orders.sum(&:cash_allocated)
      expect(a_orders_spend).to be <= BigDecimal('1050')
    end

    it 'filters movers to only optionable symbols' do
      # Only 30 of the 50 movers are in the optionable universe
      movs = tkr_movers(50)
      uni = tkr_universe(30) # TKR0..TKR29
      plan = described_class.plan(
        optionable_universe: uni, movers: movs,
        options_buying_power: 10_000, cfg: cfg, now: Time.current
      )
      # After filtering we have 30 movers → drop 6 (20%) and 15 (50%) → keep 9
      expect(plan.a.ticker_count + plan.b.ticker_count + plan.c.ticker_count).to eq(9)
    end

    it 'falls back to random sampling when no movers match the universe' do
      # No movers in the universe
      movs = movers([['XYZ', 5.0]]) # XYZ not in universe
      plan = described_class.plan(
        optionable_universe: tkr_universe(50), movers: movs,
        options_buying_power: 10_000, cfg: cfg, now: Time.current
      )
      # Fallback: 20 random names (or fewer if universe is small)
      total = plan.a.ticker_count + plan.b.ticker_count + plan.c.ticker_count
      expect(total).to be > 0
      expect(total).to be <= 20
    end

    it 'returns an empty plan when universe is empty and no movers' do
      plan = described_class.plan(
        optionable_universe: [], movers: [],
        options_buying_power: 10_000, cfg: cfg, now: Time.current
      )
      expect(plan.a.ticker_count).to eq(0)
      expect(plan.b.ticker_count).to eq(0)
      expect(plan.c.ticker_count).to eq(0)
      expect(plan.total_cash_deployed).to eq(0)
    end

    it 'round-trips through Plan.to_h / Plan.from_h' do
      movs = tkr_movers(50)
      plan = described_class.plan(
        optionable_universe: tkr_universe(50), movers: movs,
        options_buying_power: 10_000, cfg: cfg, now: Time.zone.parse('2026-09-01 11:30:00 EDT')
      )
      round = MidBandMovers::Plan.from_h(MidBandMovers::Plan.to_h(plan))
      expect(round.a.orders.size).to eq(plan.a.orders.size)
      expect(round.b.sell_at_offset_hours).to eq(plan.b.sell_at_offset_hours)
      expect(round.c.cash_per_ticker).to eq(plan.c.cash_per_ticker)
    end
  end
end
