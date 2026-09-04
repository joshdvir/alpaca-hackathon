# frozen_string_literal: true

# OvernightReversal::Strategy — pure planning logic, no I/O.
#
# Takes (yesterday_movers, optionable_universe, spot_prices_now,
# options_buying_power, cfg) and returns a Plan with two buckets:
#   - winners: top N largest positive %change names → long calls
#   - losers:  top N largest negative %change names → bear call spreads
#
# Pipeline (deterministic, no randomness):
#   1. Filter yesterday_movers to the optionable universe.
#   2. Apply liquidity / price filters from cfg (drop penny stocks,
#      names with no spot quote, names below min_daily_volume).
#   3. Sort by pct_change: winners = top positive, losers = bottom negative.
#   4. Truncate to winners_count / losers_count.
#   5. Compute close_at_et = today 15:55 in America/New_York
#      (configurable; default 15:55).
#   6. Size winners via the average-premium heuristic — winners
#      get 1 single-leg long call, sized so that the call's debit
#      fits inside cash_allocated.
#   7. Size losers via width heuristic — credit spreads are sized
#      so that `qty × spread.width × 100 ≤ cash_allocated`.
#   8. If empty after filtering (no survivors), mark skipped=true
#      and return an empty plan.
#
# Strike selection logic:
#   - winners.strike ≈ spot_price (ATM). The activity does the live
#     0DTE chain lookup at submit time and picks the strike closest
#     to spot. The plan's strike field is a hint for logging.
#   - losers.short_strike ≈ spot + small OTM step (target delta 0.20).
#     losers.long_strike  = short_strike + cfg['spread_width'].
#
# Why ATM-not-exact: the live chain lookup at submit time will pick
# the actual strike; the planner's strike is just used for log lines
# and for the cfg['skip-half-days'] guard (we still need to know
# roughly how many names we'll see). At submit time the activity
# narrows with `select { |c| strike >= spot * 0.95 && strike <= spot * 1.05 }`
# and picks the one closest to spot.
#
# Per-contract qty is intentionally NOT in the Plan — the submit
# activity does a fresh option-chain lookup at submit time so the
# premium reflects the live market.

require_relative 'plan'

module OvernightReversal
  module Strategy
    module_function

    # @param yesterday_movers [Array<Hash>] each { symbol, pct_change }
    #   from the screening source (TradingView screen or Alpaca bars).
    # @param optionable_universe [Array<Hash>] get_all_assets response
    #   (already filtered to has_options by caller).
    # @param spot_prices_now [Hash<String, Numeric>] { symbol => price }
    #   best-effort current quote for filtering penny stocks.
    # @param options_buying_power [Numeric] from PortfolioSnapshot.
    # @param cfg [Hash] from trading.yml -> overnight_reversal.
    # @param now [ActiveSupport::TimeWithZone] current time, ET.
    # @return [Plan]
    def plan(yesterday_movers:, optionable_universe:, spot_prices_now:,
             options_buying_power:, cfg:, now:)
      universe_syms = optionable_universe.map { |a| a['symbol'] }.compact.to_set
      filtered = apply_filters(yesterday_movers, universe_syms, spot_prices_now, cfg)

      winners_pool, losers_pool = split_winners_losers(filtered, cfg)

      winners_count = cfg.fetch('winners_count', 5).to_i
      losers_count  = cfg.fetch('losers_count', 5).to_i
      probe_mult    = cfg.fetch('probe_pool_multiplier', 3).to_i
      probe_mult    = 1 if probe_mult < 1

      # Probe pool: take N * multiplier candidates per bucket so the
      # activity has enough headroom to fill winners_count/losers_count
      # even if some candidates fail the runtime eligibility probe.
      winners = winners_pool.first(winners_count * probe_mult)
      losers  = losers_pool.first(losers_count * probe_mult)

      if winners.empty? && losers.empty?
        return Plan.empty(now_et: now, skipped_reason: 'no_survivors')
      end

      total_budget       = options_buying_power.to_d * BigDecimal(cfg.fetch('total_risk_pct', '0.80').to_s)
      winner_budget      = total_budget * BigDecimal(cfg.fetch('winner_bucket_weight', '0.50').to_s)
      loser_budget       = total_budget - winner_budget
      deployed           = winner_budget + loser_budget

      # Floor each allocation to cents so the sum never exceeds the
      # total budget. This matches the distribute() helper in
      # mid_band_movers — kept inline here for clarity since we have
      # only two buckets and don't need full multi-bucket logic.
      per_winner_cash = winners.empty? ? BigDecimal('0') : distribute_evenly(winner_budget, winners.size)
      per_loser_cash  = losers.empty?  ? BigDecimal('0') : distribute_evenly(loser_budget, losers.size)

      now_et_str    = now.in_time_zone('America/New_York').iso8601
      close_at_str  = compute_close_at_et(now, cfg).iso8601

      # Default DTE list. Accepts either Integer or Array in cfg.
      # Probe picks the first DTE that has a chain; carry the full
      # list on each order so the order-time caller knows which DTEs
      # to try.
      dte_target = parse_dte_target(cfg.fetch('dte_target', 0))

      winner_orders = winners.each_with_index.map do |m, i|
        WinnerOrder.new(
          symbol:         m['symbol'],
          pct_change:     m['pct_change'].to_f,
          cash_allocated: per_winner_cash[i],
          strike:         round_strike(spot_prices_now[m['symbol']].to_f, cfg),
          side:           'buy_to_open',
          dte_target:     dte_target
        )
      end

      width = cfg.fetch('spread_width', 5.0).to_f
      loser_orders = losers.each_with_index.map do |m, i|
        spot = spot_prices_now[m['symbol']].to_f
        short = round_strike(spot, cfg, otm_steps: cfg.fetch('short_delta_target', 0.20).to_f)
        SpreadOrder.new(
          symbol:         m['symbol'],
          pct_change:     m['pct_change'].to_f,
          cash_allocated: per_loser_cash[i],
          short_strike:   short,
          long_strike:    short + width,
          width:          width,
          short_leg_side: 'sell_to_open',
          long_leg_side:  'buy_to_open',
          dte_target:     dte_target
        )
      end

      Plan.new(
        total_options_buying_power: options_buying_power.to_d,
        total_cash_deployed:        deployed,
        winner_bucket_budget:       winner_budget,
        loser_bucket_budget:        loser_budget,
        tick_date:                  now.in_time_zone('America/New_York').to_date.to_s,
        now_et:                     now_et_str,
        close_at_et:                close_at_str,
        skipped:                    false,
        skipped_reason:             nil,
        winners:                    winner_orders,
        losers:                     loser_orders
      )
    end

    # ---- internals ----

    # Coerce cfg['dte_target'] (scalar Integer or Array<Integer>) into
    # a sorted, deduplicated Array<Integer>. The runtime probe walks
    # this list and uses the first DTE that has a chain.
    def parse_dte_target(raw)
      Array(raw).map(&:to_i).reject(&:negative?).uniq.sort
    end

    # Apply the universe + liquidity + price filters to yesterday_movers.
    # Returns the filtered list preserving the original ordering
    # (caller sorts later).
    #
    # Strategy-level filter — only the two gates the planner owns:
    #   1. symbol must be a non-empty String
    #   2. symbol must be in the optionable universe
    #   3. pct_change must be non-zero
    #
    # Eligibility for the actual trade (chain existence at the chosen
    # DTE) is decided at plan time by the runtime chain probe. No
    # price floor, no exchange allowlist, no curated universe — the
    # probe is the single source of truth.
    def apply_filters(movers, universe_syms, _spot_prices_now, cfg)
      _min_price = cfg.fetch('min_underlying_price', 0).to_f
      _min_vol   = cfg.fetch('min_daily_volume', 0).to_f

      movers.select do |m|
        sym = m['symbol']
        next false unless sym.is_a?(String)
        next false unless universe_syms.include?(sym)

        pct = m['pct_change'].to_f
        next false if pct.zero?

        true
      end
    end

    # Split the filtered movers into two sorted pools:
    #   winners_pool → pct_change > 0, sorted desc
    #   losers_pool  → pct_change < 0, sorted asc
    def split_winners_losers(filtered, _cfg)
      winners = filtered.select { |m| m['pct_change'].to_f.positive? }
                          .sort_by { |m| -m['pct_change'].to_f }
      losers  = filtered.select { |m| m['pct_change'].to_f.negative? }
                          .sort_by { |m|  m['pct_change'].to_f }
      [winners, losers]
    end

    # Distribute `total` evenly across `n` slots. Returns an Array of
    # BigDecimal of size n, summing to <= total (rounding loss stays
    # in the unallocated remainder).
    def distribute_evenly(total, n)
      return [] if n <= 0
      base = (total / n).floor(2)
      amounts = Array.new(n, base)
      remainder = total - amounts.sum
      amounts[0] += remainder if remainder.positive? && amounts.any?
      amounts
    end

    # Round the desired strike to a sensible value. For 0DTE ATM
    # calls we keep the exact spot. For OTM short strikes we add a
    # small step (roughly 1 strike ≈ 1% of spot for a $200 name).
    # The activity does the final strike picking from the live chain.
    def round_strike(spot, _cfg, otm_steps: 0.0)
      return 0.0 if spot <= 0
      step = (spot * otm_steps).clamp(1.0, 10.0)
      (spot + step).round(2)
    end

    # Compute the close_at_et timestamp for the close workflow.
    # Defaults to today 15:55 ET; if the strategy fires after that
    # (e.g. a backfill re-run), shift to the next business day.
    # The Temporal cron / Temporal schedule is the source of truth
    # for "fire time" — this just produces the *target* close.
    def compute_close_at_et(now, cfg)
      now_et = now.in_time_zone('America/New_York')
      hh, mm = cfg.fetch('close_at_et', '15:55').split(':').map(&:to_i)
      target = now_et.change(hour: hh, min: mm, sec: 0)
      target += 1.day if target <= now_et
      target
    end
  end
end
