# frozen_string_literal: true

# BuildPlanActivity — Mid-Band Movers strategy. Pulls the day's
# movers + optionable universe + current options_buying_power, then
# hands them to the pure-Ruby `MidBandMovers::Strategy.plan`
# to produce a `Plan` value object. Serializes to a Hash so the
# workflow can pass it through Temporal's JSON layer.
#
# This is the only place this strategy touches the broker / DB.
# Downstream activities (SubmitBuyOrdersActivity, SubmitSellOrderActivity)
# only see the serialized plan hash.
#
# `ctx` is the standard {workflow_id, run_id} hash for log correlation.

module MidBandMovers
  class BuildPlanActivity < ApplicationActivity
    def execute(ctx = {})
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id] || 'mbm'
      started = Time.current
      activity.logger.info "[activity:start] BuildPlanActivity workflow_id=#{workflow_id}"

      # `TradingConfig.fetch` returns a symbol-keyed hash. The strategy
      # uses STRING keys (`cfg['middle_band']['drop_top_pct']`). Without
      # this stringify pass, every `cfg['…']` lookup would be nil and
      # the activity would silently fall through to the empty-plan
      # rescue — no orders, no error, no clue what went wrong.
      cfg = (TradingConfig.fetch(:mid_band_movers) || {}).deep_stringify_keys
      now = Time.current
      now_et = now.in_time_zone('America/New_York')

      optionable = fetch_optionable_universe
      movers = fetch_movers(cfg)
      # Filter to the optionable universe FIRST (the strategy
      # would do this internally but we need the post-filter count
      # to decide whether to top off). Then top off with names from
      # the universe if the filter left us below the minimum.
      # Doing the top-off AFTER the filter guarantees the strategy
      # sees at least `min_kept_after_filter` optionable names, no
      # matter how skewed the live movers feed is toward
      # micro-caps / warrants.
      movers = filter_to_optionable(movers, optionable)
      movers = top_off_movers(movers, optionable, cfg)
      options_buying_power = fetch_options_buying_power

      plan = MidBandMovers::Strategy.plan(
        optionable_universe: optionable,
        movers: movers,
        options_buying_power: options_buying_power,
        cfg: cfg,
        now: now_et
      )

      hash = MidBandMovers::Plan.to_h(plan)
      activity.logger.info(
        "[activity:done] BuildPlanActivity workflow_id=#{workflow_id} " \
        "universe=#{optionable.size} movers=#{movers.size} " \
        "bp=#{options_buying_power.to_f.round(2)} " \
        "kept=#{plan.a.ticker_count + plan.b.ticker_count + plan.c.ticker_count} " \
        "deployed=#{plan.total_cash_deployed.to_f.round(2)} " \
        "elapsed_ms=#{((Time.current - started) * 1000).to_i}"
      )
      hash
    rescue StandardError => e
      # Never raise out of an activity — return an empty plan so
      # the workflow can decide whether to no-op or alert. The
      # stack trace still gets logged.
      activity.logger.error "[activity:done] BuildPlanActivity FAILED: #{e.class}: #{e.message}\n" \
                         "#{e.backtrace.first(8).join("\n")}"
      empty = MidBandMovers::Plan.empty(now_et: Time.current)
      MidBandMovers::Plan.to_h(empty)
    end

    private

    # Fetch the optionable universe via the Alpaca MCP. Returns the
    # raw asset hash list — `Strategy.plan` only needs `symbol` from
    # each asset, so we don't bother transforming to symbol arrays.
    #
    # The full universe is ~6,300 names, all already filtered to
    # `has_options` server-side. We use the WHOLE set (no alphabet
    # cap) because the planning filter needs to match top movers
    # against the universe — capping to the first 500 names by
    # alphabetical order is a silent bug: any mover outside A..C
    # never matches, the strategy emits an empty plan, and the
    # workflow exits with no orders and no error. The 15-min cache
    # keeps the underlying MCP call cheap (~6 MB response).
    def fetch_optionable_universe
      cfg = (TradingConfig.fetch(:mid_band_movers) || {}).deep_stringify_keys
      cap = (cfg['universe_top_n'] || 50).to_i
      cache_key = "mbm:optionable_universe:v1"
      assets = Rails.cache.fetch(cache_key, expires_in: 15.minutes) do
        tool = ALPACA_MCP_READONLY.tool('get_all_assets')
        next [] unless tool

        Array(
          Mcp::Response.unwrap(
            tool.call(
              asset_class: 'us_equity',
              status: 'active',
              attributes: %w[has_options]
            ),
            tool_name: 'get_all_assets'
          )
        )
      end
      # `universe_top_n` is now a soft cap on the *planning* input.
      # We still cap to avoid the strategy iterating over 6,300
      # names for nothing, but the cap is applied to a CACHE-keyed
      # full universe so the next call reuses the full set.
      assets = assets.first(cap) if assets.size > cap
      assets
    end

    # Top N market movers, sorted by %change desc. `get_market_movers`
    # already returns movers sorted by biggest gainer first, so we
    # just take the top `movers_top_n` (the planning function re-sorts
    # anyway, but we avoid carrying 50 entries through MCP when the
    # strategy only cares about the top of the list).
    #
    # The MCP server is heavily skewed toward micro-cap / warrant /
    # OTC tickers in the top-of-day-gainers feed (e.g. a 740% move
    # on a $0.02 warrant dominates the response). Most of those
    # symbols aren't in the optionable universe, so 50 movers
    # typically yields only 2-5 optionable names — not enough for
    # the strategy's band/split math to produce 14 orders. We
    # ask for `movers_top_n: 200` by default and combine the
    # gainers + losers so we have a larger pool to filter from.
    # After the optionable-universe filter we still want at least
    # `min_kept_after_filter: 20` names; if the filter produces
    # fewer, `top_off_with_universe` kicks in and samples high-
    # liquidity names from the universe sorted by `name` (a
    # cheap proxy for "liquid enough to have options"). That
    # guarantees the strategy always has enough material to work
    # with, even on a quiet day.
    def fetch_movers(cfg)
      n = (cfg['movers_top_n'] || cfg['universe_top_n'] || 200).to_i
      min_kept = (cfg['min_kept_after_filter'] || 20).to_i
      tool = ALPACA_MCP_READONLY.tool('get_market_movers')
      return [] unless tool

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(market_type: 'stocks', top: n) }
      end
      movers = Array(Mcp::Response.unwrap(raw, tool_name: 'get_market_movers'))
      activity.logger.info "[build_plan] get_market_movers returned #{movers.size} (top=#{n})"
      movers
    rescue StandardError => e
      activity.logger.warn "[build_plan] get_market_movers failed: #{e.message}"
      []
    end

    # The strategy expects at least N optionable movers so the band
    # filter + bucket split has enough material to work with.
    # If the live movers feed + universe filter produced fewer than
    # Top off the movers list to `min_kept_after_filter` names when
    # the universe filter leaves us with fewer. We prefer a curated
    # list of well-known high-volume names (likely to have liquid
    # 30-DTE options chains) over the first N alphabetical universe
    # names — the alphabetical sample might land on obscure tickers
    # whose option chains return empty. If we exhaust the curated
    # list, fall back to the universe in alphabetical order.
    LIQUID_OPTIONABLES = %w[
      AAPL MSFT NVDA GOOGL META AMZN TSLA JPM V UNH XOM CVX LLY
      AVGO COST WMT PG HD MA BAC ABT ACN ADBE NFLX CRM ORCL
      AMD INTC QCOM TXN IBM CSCO NOW INTU SNPS ADI PANW KLAC
      MRK PFE TMO MDT DHR LIN SYK REGN VRTX GILD ISRG
      AXP GS JPM BLK USB WFC TFC
      NEE SO DUK SRE AEP
      BA CAT DE HON UNH UPS RTX LMT GE
      ANET FSLR ENPH
      CAVA RKLB ARM PLTR SOFI HOOD RBLX
    ].freeze

    def top_off_movers(movers, universe, cfg)
      min_kept = (cfg['min_kept_after_filter'] || 20).to_i
      return movers if movers.size >= min_kept

      universe_syms = universe.map { |a| a['symbol'] }.compact.to_set
      have = movers.filter_map { |m| m['symbol'] if m.is_a?(Hash) }.to_set
      needed = min_kept - movers.size

      # Prefer the curated liquid list, then fill with alphabetical
      # universe names that are NOT in the curated list. This gives
      # the chain lookup a much better chance of finding a live
      # 30-DTE option for each name.
      curated_pick = LIQUID_OPTIONABLES.select { |s| universe_syms.include?(s) && !have.include?(s) }
      alphabetical_pick = universe_syms.reject { |s| have.include?(s) || LIQUID_OPTIONABLES.include?(s) }.to_a
      fill = (curated_pick + alphabetical_pick).first(needed)

      activity.logger.warn "[build_plan] only #{movers.size} movers survived universe filter, " \
                        "topping off with #{fill.size} (curated=#{curated_pick.size}, alphabetical=#{alphabetical_pick.size})"
      fill.each do |sym|
        movers << { 'symbol' => sym, 'price' => 0, 'change' => 0, 'percent_change' => 0 }
      end
      movers
    end

    # Filter the live movers feed to just the optionable universe
    # symbols. Done in the activity (rather than letting the
    # strategy do it) so the post-filter count is visible here —
    # needed to decide whether to top off to `min_kept_after_filter`.
    # The strategy's `filter_movers` would also do this, but it
    # doesn't know about the top-off.
    #
    # Defensive: skip non-Hash entries (the MCP can occasionally
    # return a malformed row, e.g. a plain string in a degenerate
    # feed; we don't want that to crash the whole activity).
    def filter_to_optionable(movers, universe)
      syms = universe.map { |a| a['symbol'] }.compact.to_set
      movers.select { |m| m.is_a?(Hash) && syms.include?(m['symbol']) }
    end

    def fetch_options_buying_power
      PortfolioSnapshot.recent.first&.options_buying_power.to_d
    rescue StandardError => e
      activity.logger.warn "[build_plan] PortfolioSnapshot fetch failed: #{e.message}"
      0
    end
  end
end
