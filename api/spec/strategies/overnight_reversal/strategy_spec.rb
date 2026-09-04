# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('app/strategies/overnight_reversal/plan').to_s
require Rails.root.join('app/strategies/overnight_reversal/strategy').to_s

RSpec.describe OvernightReversal::Strategy do
  let(:cfg) do
    {
      'winners_count'        => 5,
      'losers_count'         => 5,
      # Spec runs probe_pool_multiplier=1 so the plan returns the
      # configured count exactly (the production default is 3 so
      # we have headroom for ineligibility drops).
      'probe_pool_multiplier' => 1,
      'total_risk_pct'       => 0.80,
      'winner_bucket_weight' => 0.50,
      'spread_width'         => 5.0,
      'short_delta_target'   => 0.20,
      'min_underlying_price' => 10,
      'min_daily_volume'     => 500_000,
      'close_at_et'          => '15:55',
      'screen_source'        => 'tradingview'
    }
  end

  let(:now) { Time.zone.local(2026, 9, 2, 9, 35, 0) } # 9:35 AM ET on a Tuesday

  def asset(symbol)
    { 'symbol' => symbol, 'name' => symbol, 'has_options' => true }
  end

  # %change; positive = winner, negative = loser, zero = ignored.
  def mover(symbol, pct)
    { 'symbol' => symbol, 'pct_change' => pct }
  end

  let(:universe) do
    [
      asset('AAPL'), asset('NVDA'), asset('TSLA'), asset('AMD'), asset('META'),
      asset('AMZN'), asset('MSFT'), asset('GOOGL'), asset('AVGO'), asset('PLTR')
    ]
  end

  let(:spot_prices) do
    {
      'AAPL' => 220.0, 'NVDA' => 180.0, 'TSLA' => 250.0, 'AMD' => 140.0,
      'META' => 570.0, 'AMZN' => 200.0, 'MSFT' => 420.0, 'GOOGL' => 175.0,
      'AVGO' => 230.0, 'PLTR' => 35.0
    }
  end

  let(:bp) { BigDecimal('66_000') }

  describe '.plan — happy path' do
    let(:movers) do
      # 4 winners, 4 losers, 1 zero (skipped), 1 below price (skipped).
      [
        mover('NVDA',  6.20),
        mover('AMD',   4.10),
        mover('AAPL',  3.45),
        mover('META',  2.10),
        mover('AVGO',  0.10), # zero → skipped
        mover('PLTR',  1.20),
        mover('TSLA', -5.30),
        mover('AMZN', -3.20),
        mover('MSFT', -2.40),
        mover('GOOGL', -1.10),
        # Below price floor:
        mover('PENNY', -2.00)
      ]
    end

    let(:spots_with_penny) do
      spot_prices.merge('PENNY' => 5.0) # below min_underlying_price
    end

    it 'returns a Plan with top 5 winners + top 5 losers' do
      plan = described_class.plan(
        yesterday_movers:     movers,
        optionable_universe:  universe,
        spot_prices_now:      spots_with_penny,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      expect(plan.skipped).to be(false)
      expect(plan.winners.size).to eq(5)
      # Only 4 losers survived the filters (PENNY dropped by min_price,
      # AVGO had zero %change). Strategy deploys thinner buckets when
      # the universe is short.
      expect(plan.losers.size).to eq(4)

      # Winners sorted desc by pct_change; tops are NVDA, AMD, AAPL, META, PLTR.
      expect(plan.winners.map(&:symbol)).to eq(%w[NVDA AMD AAPL META PLTR])
      expect(plan.losers.map(&:symbol)).to eq(%w[TSLA AMZN MSFT GOOGL])
    end

    it 'sizes the buckets 50/50 of 80% of BP' do
      plan = described_class.plan(
        yesterday_movers:     movers,
        optionable_universe:  universe,
        spot_prices_now:      spots_with_penny,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      expected = bp * BigDecimal('0.80') # 0.80 × 66K = 52,800
      expect(plan.total_cash_deployed).to eq(expected)
      expect(plan.winner_bucket_budget).to eq(expected * BigDecimal('0.50'))
      expect(plan.loser_bucket_budget).to eq(expected * BigDecimal('0.50'))
    end

    it 'distributes per-name cash equally within each bucket' do
      plan = described_class.plan(
        yesterday_movers:     movers,
        optionable_universe:  universe,
        spot_prices_now:      spots_with_penny,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      # 5 winners → 26,400 / 5 = 5280 each (worst case; may differ in last digit).
      per_winner = plan.winner_bucket_budget / 5
      plan.winners.each { |w| expect(w.cash_allocated).to be_within(0.01).of(per_winner) }

      # 4 losers (only 4 survived the filter) → 26,400 / 4 = 6600 each.
      per_loser = plan.loser_bucket_budget / 4
      plan.losers.each { |l| expect(l.cash_allocated).to be_within(0.01).of(per_loser) }
    end

    it 'builds spread orders with short + width long strikes' do
      plan = described_class.plan(
        yesterday_movers:     movers,
        optionable_universe:  universe,
        spot_prices_now:      spots_with_penny,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      tsla = plan.losers.find { |l| l.symbol == 'TSLA' }
      expect(tsla.short_strike).to be > 250.0 # short is OTM (delta target 0.20)
      expect(tsla.long_strike).to eq(tsla.short_strike + cfg['spread_width'])
      expect(tsla.short_leg_side).to eq('sell_to_open')
      expect(tsla.long_leg_side).to eq('buy_to_open')
    end

    it 'computes close_at_et as today 15:55 ET' do
      plan = described_class.plan(
        yesterday_movers:     movers,
        optionable_universe:  universe,
        spot_prices_now:      spots_with_penny,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      expect(DateTime.iso8601(plan.close_at_et).in_time_zone('America/New_York').hour).to eq(15)
      expect(DateTime.iso8601(plan.close_at_et).in_time_zone('America/New_York').min).to eq(55)
    end
  end

  describe '.plan — empty universe / empty movers' do
    it 'returns a Plan.empty (skipped) when no survivors' do
      plan = described_class.plan(
        yesterday_movers:     [mover('AAPL', 0.0)], # zero %change → filtered
        optionable_universe:  universe,
        spot_prices_now:      spot_prices,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      expect(plan.skipped).to be(true)
      expect(plan.skipped_reason).to eq('no_survivors')
      expect(plan.winners).to be_empty
      expect(plan.losers).to be_empty
    end

    it 'filters symbols that are not in the optionable universe' do
      plan = described_class.plan(
        yesterday_movers:     [
          mover('AAPL',  5.0),  # in universe
          mover('XYZ',   4.0),  # NOT in universe → filtered
          mover('TSLA', -5.0),  # in universe
          mover('ABC',  -4.0)   # NOT in universe → filtered
        ],
        optionable_universe:  universe,
        spot_prices_now:      spot_prices,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      expect(plan.winners.map(&:symbol)).to eq(['AAPL'])
      expect(plan.losers.map(&:symbol)).to eq(['TSLA'])
    end

    it 'lets the runtime probe handle spot/floor filtering — planner only checks universe membership' do
      # Strategy-level filter is intentionally minimal:
      #   - symbol must be a String
      #   - symbol must be in the optionable universe
      #   - pct_change must be non-zero
      # Spot price and floor checks happen at the runtime chain probe
      # in BuildPlanActivity, not here.
      plan = described_class.plan(
        yesterday_movers:     [mover('AAPL', 5.0), mover('TSLA', -5.0)],
        optionable_universe:  universe,
        spot_prices_now:      { 'AAPL' => 220.0, 'TSLA' => 0.0 }, # TSLA halted
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      expect(plan.winners.map(&:symbol)).to eq(['AAPL'])
      expect(plan.losers.map(&:symbol)).to eq(['TSLA'])
    end

    it 'no longer filters on min_underlying_price (probe decides eligibility)' do
      plan = described_class.plan(
        yesterday_movers:     [mover('AAPL', 5.0), mover('PENNY', 4.0)],
        optionable_universe:  universe + [asset('PENNY')],
        spot_prices_now:      spot_prices.merge('PENNY' => 5.0),
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      # Both names survive the planner (probe at plan time decides).
      expect(plan.winners.map(&:symbol)).to contain_exactly('AAPL', 'PENNY')
    end
  end

  describe '.plan — close_at_et shift when past 15:55 ET' do
    it 'shifts close_at_et to the next day when firing late' do
      late_now = ActiveSupport::TimeZone['America/New_York'].local(2026, 9, 2, 16, 30, 0) # 4:30 PM ET

      movers_happy = [
        mover('AAPL', 5.0)
      ]

      plan = described_class.plan(
        yesterday_movers:     movers_happy,
        optionable_universe:  universe,
        spot_prices_now:      spot_prices,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  late_now
      )

      ts = DateTime.iso8601(plan.close_at_et).in_time_zone('America/New_York')
      expect(ts.day).to eq(3) # next day
    end
  end

  describe '.plan — half-day / skipped plumbing' do
    it 'returns Plan.empty when no winners and no losers' do
      plan = described_class.plan(
        yesterday_movers:     [],
        optionable_universe:  universe,
        spot_prices_now:      spot_prices,
        options_buying_power: bp,
        cfg:                  cfg,
        now:                  now
      )

      expect(plan.skipped).to be(true)
      expect(plan.skipped_reason).to eq('no_survivors')
    end
  end

  describe '#compute_close_at_et' do
    it 'returns today 15:55 ET when fired before the close time' do
      ts = described_class.compute_close_at_et(now, cfg)
      expect(ts.hour).to eq(15)
      expect(ts.min).to eq(55)
    end

    it 'returns tomorrow 15:55 ET when fired after the close time' do
      late = ActiveSupport::TimeZone['America/New_York'].local(2026, 9, 2, 17, 0, 0)
      ts = described_class.compute_close_at_et(late, cfg)
      expect(ts.hour).to eq(15)
      expect(ts.day).to eq(3)
    end
  end
end
