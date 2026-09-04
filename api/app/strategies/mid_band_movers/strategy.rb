# frozen_string_literal: true

# MidBandMovers::Strategy — pure planning logic, no I/O.
#
# Takes (optionable_universe, movers, options_buying_power) and returns
# a Plan with 3 buckets of orders. See plan.rb for the data shape.
#
# Pipeline (deterministic, no randomness):
#   1. Filter movers → keep only symbols in the optionable universe
#   2. Fallback       → if filtered is empty, random-sample the universe
#   3. Sort           → by percent_change desc (biggest mover first)
#   4. Middle band    → drop top 20% and bottom 50% (configurable)
#   5. Split into 3 buckets by weight
#   6. Size each       → budget = options_buying_power × total_risk_pct,
#                         split by bucket weight, then equally per ticker
#
# Per-contract qty is intentionally NOT computed here — the buy
# activity does a fresh option-chain lookup at submit time so the
# premium reflects the live market.
#
# Namespace note: this is `MidBandMovers::Strategy` (not nested
# under `Strategies::`) so Zeitwerk's autoload convention holds —
# `app/strategies/mid_band_movers/strategy.rb` → `MidBandMovers::Strategy`.

require_relative 'plan'

module MidBandMovers
  module Strategy
    module_function

    # @param optionable_universe [Array<Hash>]    get_all_assets response (filtered to has_options by caller)
    # @param movers              [Array<Hash>]    get_market_movers response, sorted by %change desc
    # @param options_buying_power [Numeric]        current buying power from the broker mirror
    # @param cfg [Hash]                              from trading.yml -> mid_band_movers
    # @return [Plan]
    def plan(optionable_universe:, movers:, options_buying_power:, cfg:, now: Time.current)
      optionable_symbols = optionable_universe.map { |a| a['symbol'] }.compact.to_set
      filtered = filter_movers(movers, optionable_symbols, cfg)
      filtered = fallback(optionable_universe, cfg) if filtered.empty?

      sorted = filtered.sort_by { |m| -m['percent_change'].to_f }
      kept = take_middle_band(sorted, cfg)

      return Plan.empty(now_et: now) if kept.empty?

      bucket_specs = Array(cfg['buckets'])
      total_weight = bucket_specs.sum { |b| b['weight_pct'].to_f }
      total_budget = options_buying_power.to_d * BigDecimal(cfg['total_risk_pct'].to_s)
      # Adjust total to be exactly divisible across buckets (we
      # want each bucket to get its proportional share, not more).
      per_bucket_budgets = distribute(total_budget, bucket_specs.map { |b| b['weight_pct'].to_f })

      buckets = bucket_specs.each_with_index.map do |spec, i|
        tickers = slice_for_bucket(kept, bucket_specs, i)
        build_bucket(
          name: spec['name'],
          hold_hours: spec['hold_hours'].to_f,
          sell_at_offset_hours: spec['hold_hours'].to_f,
          tickers: tickers,
          bucket_budget: per_bucket_budgets[i]
        )
      end

      Plan.new(
        total_options_buying_power: options_buying_power.to_d,
        total_cash_deployed:        per_bucket_budgets.sum,
        tick_date:                  now.to_date.to_s,
        now_et:                     now.iso8601,
        a:                          buckets[0] || Plan.empty_bucket('A'),
        b:                          buckets[1] || Plan.empty_bucket('B'),
        c:                          buckets[2] || Plan.empty_bucket('C')
      )
    end

    # ---- internals ----

    def filter_movers(movers, optionable_symbols, _cfg)
      movers.select { |m| optionable_symbols.include?(m['symbol']) }
    end

    def fallback(optionable_universe, cfg)
      n = cfg['fallback_random_count'].to_i
      sample_size = [n, optionable_universe.size].min
      # No LLM / no external randomness source: use Array#sample
      # which is uniformly random. For deterministic tests, callers
      # can stub `Random.rand` or pass a pre-shuffled universe.
      optionable_universe.sample(sample_size).map do |a|
        {
          'symbol'         => a['symbol'],
          'price'          => a['price'] || 0,
          'change'         => 0,
          'percent_change' => 0
        }
      end
    end

    def take_middle_band(sorted, cfg)
      n = sorted.size
      return [] if n.zero?

      drop_top = (n * cfg['middle_band']['drop_top_pct'].to_f / 100.0).ceil
      drop_bottom = (n * cfg['middle_band']['drop_bottom_pct'].to_f / 100.0).ceil
      kept_start = drop_top
      kept_end = n - drop_bottom
      return [] if kept_end <= kept_start

      sorted[kept_start...kept_end] || []
    end

    # Distribute `total` across the buckets in proportion to
    # `weights` (which sum to any positive value). Returns an
    # Array<BigDecimal> of the same length, summing to <= total
    # (rounding losses stay in the unallocated remainder).
    def distribute(total, weights)
      weight_sum = weights.sum.to_d
      return Array.new(weights.size, 0) if weight_sum.zero?

      # Floor each allocation so the sum never exceeds total.
      amounts = weights.map { |w| (total * BigDecimal(w.to_s) / weight_sum).floor(2) }
      remainder = total - amounts.sum
      # Distribute the rounding remainder to the bucket with the
      # largest fractional part (avoids systematic underfunding).
      if remainder > 0 && amounts.any?
        fractional = weights.each_with_index.map { |w, i| [total * BigDecimal(w.to_s) / weight_sum - amounts[i], i] }
        _, idx = fractional.max_by { |f, _| f }
        amounts[idx] += remainder
      end
      amounts
    end

    def slice_for_bucket(sorted, bucket_specs, bucket_index)
      # Distribute the kept band across buckets in proportion to
      # weight, so the top 30% / mid 30% / bottom 40% of the band
      # maps to the right bucket.
      n = sorted.size
      weights = bucket_specs.map { |b| b['weight_pct'].to_f }
      # Cumulative per-bucket band ranges
      cumulative = []
      acc = 0.0
      weights.each do |w|
        acc += w
        cumulative << (n * acc / weights.sum).round
      end
      # cumulative[i] = end (exclusive) index for bucket i.
      # Determine start (inclusive) for current bucket.
      starts = [0] + cumulative[0..-2]
      sorted[starts[bucket_index]...cumulative[bucket_index]] || []
    end

    def build_bucket(name:, hold_hours:, sell_at_offset_hours:, tickers:, bucket_budget:)
      return Plan.empty_bucket(name) if tickers.empty?

      # Split bucket_budget equally across tickers, then round each
      # to cents. Total <= bucket_budget (rounding losses stay).
      per = distribute(bucket_budget, Array.new(tickers.size, 1.0))
      orders = tickers.each_with_index.map do |t, i|
        Order.new(symbol: t['symbol'], cash_allocated: per[i])
      end
      Bucket.new(
        name: name,
        hold_hours: hold_hours,
        sell_at_offset_hours: sell_at_offset_hours,
        ticker_count: tickers.size,
        cash_per_ticker: tickers.empty? ? 0 : (bucket_budget / tickers.size).floor(2),
        orders: orders
      )
    end
  end
end
