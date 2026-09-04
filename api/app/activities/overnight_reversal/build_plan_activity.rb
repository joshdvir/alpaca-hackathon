# frozen_string_literal: true

# BuildPlanActivity — Overnight Reversal strategy. Pulls the *prior
# session's* top movers + optionable universe + current spot prices +
# current buying power, then hands them to the pure-Ruby
# `OvernightReversal::Strategy.plan` to produce a Plan.
#
# Sources, in order of preference:
#   1. TradingView MCP  `top_gainers` / `top_losers` filtered to
#      US equity exchanges. Fast, public, no API key required.
#   2. Alpaca MCP       `get_stock_bars` for the optionable
#      universe (2-day bars). Slower (~6K row MCP call) but always
#      available since Alpaca is the source of truth.
#
# Half-day handling: when `cfg['skip_half_days']` is true and Alpaca's
# `get_clock` reports today is a half-day OR yesterday's daily bar
# was a half-day (closed before 4:00 PM ET), we return an empty
# `Plan.empty` with `skipped_reason: 'half_day'` and the workflow
# exits without spawning a CloseWorkflow child.
#
# `ctx` is the standard {workflow_id, run_id} hash for log correlation.
# This activity NEVER raises — every error path returns a Plan with
# `skipped: true` and a structured `skipped_reason`.

module OvernightReversal
  class BuildPlanActivity < ApplicationActivity
    UNIVERSE_CACHE_KEY = 'ovn:optionable_universe:v1'.freeze
    UNIVERSE_CACHE_TTL = 15.minutes

    # Override the Temporal activity name. The default uses the
    # unqualified Ruby class name (`BuildPlanActivity`) which collides
    # with `MidBandMovers::BuildPlanActivity` when both strategies
    # register on the same task queue. Using a strategy-prefixed name
    # keeps both strategies live without renaming the underlying
    # classes (which would break Zeitwerk conventions).
    activity_name 'OvernightBuildPlanActivity'

    def execute(ctx = {})
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id] || 'ovn'
      started = Time.current
      # Use Temporal's activity logger (routes through the worker to
      # STDOUT) rather than Rails.logger, which writes to
      # log/development.log and never reaches the worker's terminal.
      log = activity.logger
      log.info "[ovn:build:start] workflow_id=#{workflow_id}"

      cfg = (TradingConfig.fetch(:overnight_reversal) || {}).deep_stringify_keys
      now = Time.current
      now_et = now.in_time_zone('America/New_York')

      log.info "[ovn:build] half_day_check begin, skip_half_days=#{cfg['skip_half_days']}"
      half_day = half_day?(cfg, now_et)
      log.info "[ovn:build] half_day_check result=#{half_day}"
      if half_day
        log.info "[ovn:build] skipped (half_day)"
        return OvernightReversal::Plan.to_h(
          OvernightReversal::Plan.empty(now_et: now_et, skipped_reason: 'half_day')
        )
      end

      # Idempotency guard: if we already have open positions from a
      # prior run of this strategy (today or any earlier session that
      # didn't close for some reason), skip the run. Multiple triggers
      # of the same workflow should not stack 5+5 positions on top
      # of existing ones. The check runs before any expensive work
      # so a duplicate trigger is essentially a no-op.
      open_count = open_strategy_position_count
      if open_count.positive?
        log.info "[ovn:build] skipped (already_open=#{open_count})"
        return OvernightReversal::Plan.to_h(
          OvernightReversal::Plan.empty(now_et: now_et, skipped_reason: 'already_open')
        )
      end

      log.info "[ovn:build] calling fetch_yesterday_movers"
      yesterday_movers = fetch_yesterday_movers(cfg)
      # Liquidity filter: drop movers whose latest daily volume is
      # below cfg['min_daily_volume'] (default 500K). TradingView
      # rows carry `indicators.volume`; Alpaca-bars rows don't, so
      # the filter is a no-op for that source.
      yesterday_movers = filter_movers_by_volume(yesterday_movers, cfg)
      log.info "[ovn:build] after_volume_filter movers=#{yesterday_movers.size}"
      log.info "[ovn:build] calling fetch_optionable_universe"
      optionable = fetch_optionable_universe

      # Always-on base underlyings — appended to the screener output
      # twice (once positive, once negative) so they top both the
      # winners and losers pools. These are mega-caps (SPY/QQQ/IWM/DIA)
      # with deep 0DTE/3DTE liquidity that fill the bucket even on
      # days when the screener returns illiquid small-caps. The +9999
      # and -9999 pct_change values guarantee they always top the
      # sorted pick list in Strategy.plan, so they always end up in
      # both the winners and losers pools regardless of what the
      # screener returned. Each base name gets 1 winner + 1 loser
      # slot — the activity's per-name cap and the Strategy.plan's
      # size math cap how much capital each name gets.
      base_syms = Array(cfg['base_underlyings']).map(&:to_s)
      if base_syms.any?
        existing = yesterday_movers.map { |m| m['symbol'] }.compact.to_set
        before = yesterday_movers.size
        base_syms.each do |sym|
          next if existing.include?(sym)
          # One entry with huge positive change → guaranteed top of winners
          yesterday_movers << { 'symbol' => sym, 'pct_change' =>  9999.0 }
          # One entry with huge negative change → guaranteed top of losers
          yesterday_movers << { 'symbol' => sym, 'pct_change' => -9999.0 }
        end
        log.info "[ovn:build] base_underlyings added=#{yesterday_movers.size - before} (2 per symbol) total=#{yesterday_movers.size}"
      end

      # Pre-filter movers to the universe's `tradable: true` +
      # `marginable: true` asset records. TradingView's
      # top_gainers/top_losers is dominated by OTC + micro-cap
      # tickers that the broker either can't trade or has no
      # options for. Without this filter, 30+ of 34 movers probe
      # as `no_chain` and we end up with 0–3 eligible names.
      yesterday_movers = filter_movers_to_tradable(yesterday_movers, optionable)
      log.info "[ovn:build] raw_movers=#{yesterday_movers.size} first3=#{yesterday_movers.first(3).inspect}"
      log.info "[ovn:build] optionable_universe.size=#{optionable.size} first3=#{optionable.first(3).inspect}"

      log.info "[ovn:build] calling fetch_spot_prices"
      spot_prices = fetch_spot_prices(yesterday_movers)
      log.info "[ovn:build] spot_prices.size=#{spot_prices.size} first3=#{spot_prices.first(3).inspect}"

      log.info "[ovn:build] calling fetch_options_buying_power"
      options_buying_power = fetch_options_buying_power
      log.info "[ovn:build] buying_power=#{options_buying_power.to_f.round(2)}"

      log.info "[ovn:build] calling Strategy.plan"
      plan = OvernightReversal::Strategy.plan(
        yesterday_movers:     yesterday_movers,
        optionable_universe:  optionable,
        spot_prices_now:      spot_prices,
        options_buying_power: options_buying_power,
        cfg:                  cfg,
        now:                  now_et
      )

      # Runtime eligibility probe — for every name on the plan, probe
      # the broker's chain at each `dte_target` value (scalar or Array).
      # The first DTE that has a usable chain wins; the chosen DTE is
      # stamped on each WinnerOrder/SpreadOrder so the order-time
      # caller picks the right expiry. Cost: 1 chain call per (name,
      # DTE) pair (cacheable for 60s); a 5+5 plan against [0,3,7]
      # is ~6-15 s in the cold path.
      dte_targets = OvernightReversal::Strategy.parse_dte_target(cfg.fetch('dte_target', 0))
      log.info "[ovn:build] eligibility probe for dte_targets=#{dte_targets} on #{plan.winners.size + plan.losers.size} candidates"
      @cfg = cfg # expose to run_eligibility_probe + helpers below
      unless plan.skipped
        plan, eligible_winners, eligible_losers = run_eligibility_probe(plan, dte_targets, log)
      end
      log.info "[ovn:build:post-probe] winners=#{plan.winners.size} losers=#{plan.losers.size} skipped=#{plan.skipped} reason=#{plan.skipped_reason.inspect}"

      hash = OvernightReversal::Plan.to_h(plan)
      log.info(
        "[ovn:build:done] raw_movers=#{yesterday_movers.size} universe=#{optionable.size} " \
        "spot_prices=#{spot_prices.size} " \
        "winners=#{plan.winners.size} losers=#{plan.losers.size} " \
        "bp=#{options_buying_power.to_f.round(2)} deployed=#{plan.total_cash_deployed.to_f.round(2)} " \
        "skipped=#{plan.skipped} reason=#{plan.skipped_reason.inspect} " \
        "elapsed_ms=#{((Time.current - started) * 1000).to_i}"
      )
      hash
    rescue StandardError => e
      activity.logger.error "[ovn:build:FAIL] #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
      empty = OvernightReversal::Plan.empty(now_et: Time.current, skipped_reason: 'exception')
      OvernightReversal::Plan.to_h(empty)
    end

    private

    # Probe option chains at each candidate DTE for every name in the
    # wider candidate pool (passed in as `plan.winners + plan.losers`;
    # Strategy.plan intentionally returns more candidates than the
    # configured counts so the probe can backfill after drops). The
    # probe walks each DTE per name and stamps the chosen one on
    # the resulting order. After probing, we slice the head of each
    # bucket up to cfg['winners_count']/cfg['losers_count'] so the
    # caller always sees a fully-populated plan (when the
    # screener gives us enough eligible symbols).
    def run_eligibility_probe(plan, dte_targets, log)
      winners_count = @cfg.fetch('winners_count', 5).to_i
      losers_count  = @cfg.fetch('losers_count', 5).to_i

      survivors_w = []
      survivors_l = []
      probed = []      # [symbol, status] for the log line
      (plan.winners + plan.losers).each do |order|
        sym = order.symbol
        chosen_dte = nil
        dte_targets.each do |dte|
          if probe_dte_eligibility(sym, dte)
            chosen_dte = dte
            break
          end
        end

        if chosen_dte
          bucket = order.is_a?(OvernightReversal::WinnerOrder) ? :winners : :losers
          new_order =
            if order.is_a?(OvernightReversal::WinnerOrder)
              OvernightReversal::WinnerOrder.new(
                symbol: order.symbol, pct_change: order.pct_change,
                cash_allocated: order.cash_allocated, strike: order.strike,
                side: order.side, dte_target: [chosen_dte]
              )
            else
              OvernightReversal::SpreadOrder.new(
                symbol: order.symbol, pct_change: order.pct_change,
                cash_allocated: order.cash_allocated,
                short_strike: order.short_strike, long_strike: order.long_strike, width: order.width,
                short_leg_side: order.short_leg_side, long_leg_side: order.long_leg_side,
                dte_target: [chosen_dte]
              )
            end
          (bucket == :winners ? survivors_w : survivors_l) << new_order
          probed << [sym, "dte=#{chosen_dte}"]
        else
          probed << [sym, 'no_chain']
        end
      end

      # Pick exactly winners_count/losers_count survivors; anything
      # past the cap is dropped (still picked from best-pct_change
      # first because the strategy sorted them).
      final_w = survivors_w.first(winners_count)
      final_l = survivors_l.first(losers_count)

      activity.logger.info "[ovn:build] probe: pool_w=#{(plan.winners || []).size} pool_l=#{(plan.losers || []).size} " \
                 "candidates=pool; selected_w=#{final_w.size}/#{winners_count} selected_l=#{final_l.size}/#{losers_count}"
      probed.each { |sym, status| activity.logger.info "[ovn:build] probe: #{sym.ljust(6)} #{status}" }

      if final_w.empty? && final_l.empty?
        skipped = OvernightReversal::Plan.empty(now_et: Time.current, skipped_reason: 'no_eligible_contracts')
        return [skipped, [], []]
      end

      # Re-budget the survivors: divide each bucket across however
      # many names actually survived (up to the configured cap).
      winner_budget = plan.winner_bucket_budget
      loser_budget  = plan.loser_bucket_budget
      winner_cash = distribute_evenly_amount(winner_budget, final_w.size)
      loser_cash  = distribute_evenly_amount(loser_budget, final_l.size)

      new_winners = final_w.each_with_index.map do |w, i|
        OvernightReversal::WinnerOrder.new(
          symbol: w.symbol, pct_change: w.pct_change,
          cash_allocated: winner_cash[i], strike: w.strike,
          side: w.side, dte_target: w.dte_target
        )
      end
      new_losers = final_l.each_with_index.map do |l, i|
        OvernightReversal::SpreadOrder.new(
          symbol: l.symbol, pct_change: l.pct_change,
          cash_allocated: loser_cash[i],
          short_strike: l.short_strike, long_strike: l.long_strike, width: l.width,
          short_leg_side: l.short_leg_side, long_leg_side: l.long_leg_side,
          dte_target: l.dte_target
        )
      end

      new_plan = OvernightReversal::Plan.new(
        total_options_buying_power: plan.total_options_buying_power,
        total_cash_deployed:        winner_budget + loser_budget,
        winner_bucket_budget:       winner_budget,
        loser_bucket_budget:        loser_budget,
        tick_date:                  plan.tick_date,
        now_et:                     plan.now_et,
        close_at_et:                plan.close_at_et,
        skipped:                    false,
        skipped_reason:             nil,
        winners:                    new_winners,
        losers:                     new_losers
      )
      [new_plan, new_winners, new_losers]
    end

    # True iff `symbol` has at least one call contract expiring
    # around `dte_target` calendar days from today. The probe is
    # permissive ("any contract row exists") — finer premium and
    # spread checks happen at submit time.
    def probe_dte_eligibility(symbol, dte_target)
      # Use the next *available* expiry as the center — at 22:43 ET,
      # today's expiry is dead (closed at 4 PM ET), so probing today
      # returns an empty chain for every symbol. Brokers list the
      # *next* trading day's expirations after the current day's
      # close, so the first call needs to walk to the next business
      # day and add the requested DTE on top of that.
      today_et = Time.current.in_time_zone('America/New_York').to_date
      if past_market_close?(today_et)
        # Skip to the next business day for the dte=0 base, then add
        # the requested offset. 1 calendar day ≈ enough for almost
        # every case; the gte/lte ±1 window absorbs weekend skips.
        center = next_business_day(today_et) + dte_target.days
      else
        center = today_et + dte_target.days
      end
      args = {
        underlying_symbol:   symbol,
        expiration_date_gte: center.iso8601,
        expiration_date_lte: (center + 1).iso8601,
        type:                'call',
        limit:               25
      }
      chain = mcp_get_option_chain(args)
      # Acceptance criteria: at least one contract row in the chain
      # has BOTH a positive bid (`bp`) AND a positive ask (`ap`),
      # AND the broker's ask size (`as`) meets `min_ask_size`. The
      # `as` field is the broker's inventory at that strike; filtering
      # on it prevents us from picking a chain that the broker can only
      # fill 1-2 contracts of (we'd send qty=170 and the broker would
      # silently fill 1). The default `min_ask_size: 5` is the
      # conservative floor; for liquid mega-caps like SPY/QQQ the
      # broker has 100+ contracts at the ATM strike, so the filter
      # doesn't bind. For illiquid micro-caps with as=1 the probe
      # falls through to higher DTE windows (14/30/60) until the
      # broker has inventory at the picked strike.
      min_ask = (@cfg['probe_min_ask_size'] || 5).to_i
      liquid = chain.is_a?(Hash) && chain.any? do |_occ, snap|
        next false unless snap.is_a?(Hash)
        lq = snap['latestQuote'] || snap['latest_quote'] || {}
        ap  = lq['ap']
        bp  = lq['bp']
        asz = lq['as']
        next false unless ap.is_a?(Numeric) && bp.is_a?(Numeric) && asz.is_a?(Numeric)
        next false unless ap.positive? && bp.positive? && asz >= min_ask
        true
      end
      activity.logger.info "[ovn:probe] #{symbol} dte=#{dte_target} chain.size=#{chain.is_a?(Hash) ? chain.size : 'n/a'} liquid=#{liquid} (min_ask_size=#{min_ask})"
      liquid
    rescue StandardError => e
      activity.logger.warn "[ovn:probe] #{symbol} dte=#{dte_target} failed: #{e.class}: #{e.message}"
      false
    end

    # Crude "is the market closed for the day" check. After 8 PM ET
    # the next trading day's 0DTE contracts are typically listed and
    # probing "today" returns an empty chain. We shift forward.
    def past_market_close?(_today)
      now_et = Time.current.in_time_zone('America/New_York')
      hour = now_et.hour
      # Simple bucket: weekdays before 4 PM ET we treat as "during
      # market"; otherwise "after market". Weekends are always after.
      wday = now_et.wday
      return true if wday.zero? || wday == 6
      return true if hour >= 20 # safely past 4 PM ET, after broker rollover
      false
    end

    # Walk forward until we land on a weekday. Used by
    # `probe_dte_eligibility` to skip weekends.
    def next_business_day(date)
      d = date + 1
      d += 1 while d.saturday? || d.sunday?
      d
    end

    # Idempotency guard helper. Returns the count of currently-open
    # positions for this strategy. Used in `execute` to short-circuit
    # when a prior run already has open positions from an *earlier
    # session* (opened before today's market open at 9:30 AM ET) —
    # keeps a duplicate trigger from stacking 5+5 orders on top of
    # positions that should have been closed by the 15:55 close
    # workflow. Same-day re-attempts during the current session are
    # NOT blocked — only stale positions from prior sessions.
    def open_strategy_position_count
      market_open = Time.current.in_time_zone('America/New_York')
                                    .beginning_of_day + (9 * 60 + 30) * 60  # 9:30 AM
      Position.where(origin: 'overnight_reversal')
              .where(closed_at: nil)
              .where('opened_at < ?', market_open)
              .count
    rescue StandardError
      0
    end

    # Volume filter on the screener output. TradingView rows carry
    # `indicators.volume` (latest daily volume for the symbol);
    # Alpaca-bars rows don't, so the filter is a no-op for that
    # source. Drop any row whose volume is below cfg['min_daily_volume']
    # (default 500K) — pumps in illiquid tickers with no 0DTE chain
    # otherwise dominate the probe output.
    def filter_movers_by_volume(movers, cfg)
      min_vol = cfg['min_daily_volume'].to_f
      return movers if min_vol <= 0

      before = movers.size
      kept = movers.select do |m|
        ind = m['indicators']
        vol = ind.is_a?(Hash) ? ind['volume'].to_f : 0
        vol <= 0 || vol >= min_vol
      end
      activity.logger.info "[ovn:build] volume_filter min=#{min_vol.to_i} dropped=#{before - kept.size} kept=#{kept.size} of=#{before}"
      kept
    end

    # Even-dollar distribution over `n` slots. Rounding loss stays
    # in the unallocated remainder.
    def distribute_evenly_amount(total, n)
      return [] if n <= 0
      base = (total / n).floor(2)
      amounts = Array.new(n, base)
      remainder = total - amounts.sum
      amounts[0] += remainder if remainder.positive? && amounts.any?
      amounts
    end

    # Local copy of `mcp_get_option_chain` — a real implementation
    # also exists in SubmitOrdersActivity for the submit-time strike
    # pick. We define a copy here because the per-name eligibility
    # probe runs from BuildPlanActivity (without that copy the
    # probe raises NoMethodError). If we ever want to share the
    # implementation, lift it into a small `OvernightReversal::Mcp`
    # concern that both activities include.
    def mcp_get_option_chain(args)
      cache_key = "ovn:probe_chain:#{Digest::SHA1.hexdigest(args.inspect)}"
      Rails.cache.fetch(cache_key, expires_in: 1.minute) do
        tool = ALPACA_MCP_READONLY.tool('get_option_chain')
        return {} unless tool

        raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
          CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(**args) }
        end
        Mcp::Response.unwrap(raw, tool_name: 'get_option_chain') || {}
      end
    end

    # Detect a half-day: either today is a half-day OR yesterday's
    # session was a half-day (early close before a holiday). We rely
    # on Alpaca's calendar since TradingView's half-day feed is
    # unreliable. If the calendar lookup fails we conservatively fall
    # through — better to over-trade a half-day than to skip a normal one.
    def half_day?(cfg, now_et)
      return false unless cfg.fetch('skip_half_days', true)

      cal = fetch_alpaca_calendar
      return false if cal.nil? || cal.empty?

      today = now_et.to_date
      yest  = prev_business_day(today)

      today_entry = cal.find { |d| date_within?(date_field(d), today) }
      yest_entry  = cal.find { |d| date_within?(date_field(d), yest) }

      half_day_entry?(today_entry) || half_day_entry?(yest_entry)
    rescue StandardError => e
      activity.logger.warn "[build_plan] half_day check failed (treating as full day): #{e.message}"
      false
    end

    def date_within?(a, b)
      return false if a.nil? || b.nil?
      # Date#- returns a Rational of days. |..| <= 1 is "within ±1 calendar day".
      (a - b).abs <= 1
    end

    # Walk backwards from `date` skipping weekends. Not using the
    # `prev_business_day` extension (not loaded in test env).
    def prev_business_day(date)
      d = date - 1
      while d.saturday? || d.sunday?
        d -= 1
      end
      d
    end

    def date_field(entry)
      return nil unless entry.is_a?(Hash)
      raw = entry['date'] || entry[:date]
      return nil if raw.nil?
      Date.parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    def half_day_entry?(entry)
      return false if entry.nil?
      closes_at = entry['closes_at'] || (entry[:closes_at] if entry.respond_to?(:[]))
      return false if closes_at.nil?

      # early close: closes_at is before 16:00 ET (full close is 16:00 ET)
      # The clock returns UTC ISO8601; convert to ET hour/minute.
      closes_et = Time.iso8601(closes_at.to_s).in_time_zone('America/New_York')
      closes_et.hour < 16 || (closes_et.hour == 15 && closes_et.min < 30)
    end

    # Yesterday's movers via TradingView MCP. Returns an Array of
    # { symbol, pct_change } hashes; pct_change is the prior trading
    # session's daily %change.
    #
    # The TradingView MCP's `top_gainers` / `top_losers` accept an
    # `exchange` filter. We aggregate from AMEX, NASDAQ, and NYSE
    # (the three US equity exchanges) and combine gainers+losers
    # sorted by their native `change_percent` field. The fallback
    # is Alpaca's `get_stock_bars` (always works), and finally an
    # empty array (which makes the strategy skip).
    def fetch_yesterday_movers(cfg)
      source = cfg.fetch('screen_source', 'tradingview').to_s
      movers =
        case source
        when 'tradingview'  then tradingview_yesterday_movers(cfg)
        when 'alpaca_bars'  then alpaca_yesterday_movers
        else []
        end
      # Only fall back to the other source if it returns empty (e.g. the
      # chosen source's MCP server is down). Don't double-fetch both
      # unconditionally — would waste MCP budget and pollute the cache.
      if movers.empty?
        fallback = (source == 'tradingview' ? :alpaca_bars : :tradingview)
        movers = (fallback == :alpaca_bars ? alpaca_yesterday_movers : tradingview_yesterday_movers(cfg))
      end
      movers
    rescue StandardError => e
      activity.logger.warn "[ovn:build] yesterday_movers fetch failed: #{e.class}: #{e.message}"
      []
    end

    # TradingView's MCP server supports a curated list of stock
    # exchanges documented in its `instructions` block (NASDAQ, NYSE,
    # EGX, BIST, …). AMEX is NOT supported — the upstream returns
    # `NO_DATA` for it, so we skip it explicitly.
    EXCHANGES = %w[NASDAQ NYSE].freeze

    def tradingview_yesterday_movers(cfg = nil)
      movers = []
      limit = (cfg && cfg['tv_top_n_per_exchange']) || 20
      EXCHANGES.each do |exch|
        gainers = tv_call('top_gainers', exchange: exch, timeframe: '1D', limit: limit)
        losers  = tv_call('top_losers',  exchange: exch, timeframe: '1D', limit: limit)
        movers.concat(gainers)
        movers.concat(losers)
      end
      movers.uniq
    rescue StandardError => e
      activity.logger.warn "[ovn:build] TradingView screening failed, falling back to Alpaca bars: #{e.class}: #{e.message}"
      []
    end

    # MCP `tools/call` returns a single result with the rows nested
    # as ONE-JSON-PER-LINE inside `content[].text`, plus a structured
    # `structuredContent.result` array as an alternate path. We parse
    # each text blob on its own — the array path is also covered as a
    # fallback.
    def tv_call(tool_name, **kwargs)
      tool = TRADINGVIEW_MCP.tool(tool_name)
      return [] unless tool

      raw = RATE_LIMITERS[:tradingview_mcp].with_limit do
        CIRCUIT_BREAKERS[:tradingview_mcp].call { tool.call(**kwargs) }
      end
      text = unwrap_text(raw)
      parsed = JSON.parse(text.to_s) rescue {}

      # Three shapes come back depending on the caller:
      #   1. Bare Array<Hash>           — test mocks, simplest shape
      #   2. MCP envelope               — what the upstream returns:
      #        { "result": { "content":          [...text blobs...],
      #                     "structuredContent": { "result": [...] } } }
      #   3. Bare Hash                  — defensive: look inside
      rows =
        case parsed
        when Array
          parsed.select { |r| r.is_a?(Hash) }
        when Hash
          inner = parsed['result'].is_a?(Hash) ? parsed['result'] : parsed
          sc = inner['structuredContent']
          if sc.is_a?(Hash) && sc['result'].is_a?(Array)
            sc['result'].select { |r| r.is_a?(Hash) }
          elsif inner['content'].is_a?(Array)
            inner['content'].map do |entry|
              next nil unless entry.is_a?(Hash) && entry['type'] == 'text'
              JSON.parse(entry['text'].to_s) rescue nil
            end.compact
          else
            []
          end
        else
          []
        end

      rows.map { |r| normalize_tv_row(r) }.compact
    end

    # Convert a single TradingView row into our { symbol, pct_change }
    # shape. The upstream's `symbol` field is exchange-prefixed
    # (e.g. "NASDAQ:NOEMU"); we strip the prefix so the symbol
    # matches the universe / order tickets. The MCP server returns
    # a `changePercent` (NOT `change_percent`) field — that's the
    # daily %move for the latest closed bar.
    def normalize_tv_row(row)
      sym_raw = row['symbol'].to_s
      return nil if sym_raw.empty?
      _, bare = sym_raw.split(':', 2) if sym_raw.include?(':')
      sym = bare || sym_raw
      pct = row['changePercent']
      pct = row['change_percent'] if pct.nil?
      pct = pct.to_f if pct
      return nil if pct.nil? || pct.zero?

      { 'symbol' => sym.to_s, 'pct_change' => pct }
    end

    def alpaca_yesterday_movers
      # Pull 5 daily bars for every name in the universe. For each
      # symbol, yesterday's %change = (close_y - close_y-1) / close_y-1 × 100.
      # The MCP's `get_stock_bars` requires `symbols` to be a CSV
      # string (not an Array). We batch in chunks of 50 to stay well
      # under the typical MCP payload limit.
      universe = fetch_optionable_universe
      all_syms = universe.map { |a| a['symbol'] }.compact.uniq
      return [] if all_syms.empty?

      result = []
      all_syms.each_slice(50) do |batch|
        bars = mcp_get_stock_bars(symbols: batch.join(','), timeframe: '1Day', limit: 5)
        next if bars.nil? || !bars.is_a?(Hash)
        bars.each do |sym, days|
          next unless days.is_a?(Array) && days.size >= 2
          prev = days[-2]['c'].to_f
          last = days[-1]['c'].to_f
          next if prev <= 0 || last <= 0
          pct = (last - prev) / prev * 100.0
          result << { 'symbol' => sym, 'pct_change' => pct } if pct.nonzero?
        end
      end
      result
    rescue StandardError => e
      activity.logger.warn "[ovn:build] alpaca_yesterday_movers failed: #{e.class}: #{e.message}"
      []
    end

    # Fetch the optionable universe via the Alpaca MCP. Same pattern
    # as the mid-band-movers activity: cached 15 minutes and capped
    # to cfg['universe_top_n'] (default: hardcoded 1000) to avoid
    # iterating 6,300 names through the strategy every tick.
    def fetch_optionable_universe
      cap = 1000
      cache_key = UNIVERSE_CACHE_KEY
      assets = Rails.cache.fetch(cache_key, expires_in: UNIVERSE_CACHE_TTL) do
        tool = ALPACA_MCP_READONLY.tool('get_all_assets')
        next [] unless tool

        Array(
          Mcp::Response.unwrap(
            tool.call(asset_class: 'us_equity', status: 'active', attributes: %w[has_options]),
            tool_name: 'get_all_assets'
          )
        )
      end
      assets.is_a?(Array) ? assets.first(cap) : []
    rescue StandardError => e
      activity.logger.warn "[build_plan] optionable universe fetch failed: #{e.message}"
      []
    end

    # Best-effort current spot prices for every name in the movers
    # pool. Fails silently — names whose spot we couldn't fetch just
    # get a `nil` price (the strategy treats `spot = 0` as "no quote")
    # and the runtime chain probe is the source of truth for whether
    # a name is tradeable.
    def fetch_spot_prices(movers)
      return {} if movers.empty?
      symbols = movers.map { |m| m['symbol'] }.compact.uniq
      result = {}
      symbols.each do |sym|
        price = fetch_one_spot(sym)
        result[sym] = price if price&.positive?
      end
      activity.logger.info "[ovn:build] spot_prices requested=#{symbols.size} resolved=#{result.size}"
      result
    rescue StandardError
      {}
    end

    # Drop movers that the broker can't actually trade, or that
    # don't have a marginable book. The asset record carries both
    # `tradable` (broker: "you can place orders on this") and
    # `marginable` ("margin is supported"). Most OTC + pink-sheet
    # tickers come back with both `false` even when the screener
    # reports a huge %-change for them — the broker has the chain
    # metadata but refuses to fill the order. Filter upfront so the
    # runtime chain probe only sees names that can actually fill.
    def filter_movers_to_tradable(movers, optionable_universe)
      asset_by_sym = optionable_universe.each_with_object({}) do |a, h|
        h[a['symbol']] = a if a['symbol']
      end
      before = movers.size
      kept = movers.select do |m|
        sym = m['symbol']
        asset = asset_by_sym[sym]
        next false if asset.nil? # not in universe at all
        next false if asset['tradable'] == false
        next false if asset['marginable'] == false
        true
      end
      activity.logger.info "[ovn:build] tradable_filter dropped=#{before - kept.size} kept=#{kept.size} of=#{before}"
      kept
    end

    def fetch_one_spot(symbol)
      tool = ALPACA_MCP_READONLY.tool('get_stock_latest_trade')
      return nil unless tool

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(symbols: symbol) }
      end
      text = unwrap_text(raw)
      parsed = JSON.parse(text) rescue {}
      trade = parsed.dig('data', 'trades', symbol) || parsed.dig('trades', symbol)
      trade.is_a?(Hash) ? trade['p'].to_f : nil
    rescue StandardError
      nil
    end

    # Pull a multi-day daily bar set for the given symbols via Alpaca.
    # Returns Hash<symbol, Array<bar>> where bar = { o, h, l, c, v, t }.
    def mcp_get_stock_bars(symbols:, timeframe:, limit:)
      cache_key = "ovn:bars:#{Digest::SHA1.hexdigest(symbols)}_#{timeframe}_#{limit}"
      Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        tool = ALPACA_MCP_READONLY.tool('get_stock_bars')
        return {} unless tool

        raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
          CIRCUIT_BREAKERS[:alpaca_mcp].call do
            tool.call(symbols: symbols, timeframe: timeframe, limit: limit)
          end
        end
        Mcp::Response.unwrap(raw, tool_name: 'get_stock_bars') || {}
      end
    end

    def fetch_alpaca_clock
      tool = ALPACA_MCP_READONLY.tool('get_clock')
      return nil unless tool

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call }
      end
      text = unwrap_text(raw)
      JSON.parse(text) rescue nil
    rescue StandardError
      nil
    end

    def fetch_alpaca_calendar
      tool = ALPACA_MCP_READONLY.tool('get_calendar')
      return nil unless tool

      start = (Date.current - 5).iso8601
      end_  = (Date.current + 5).iso8601
      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call do
          tool.call(start: start, end: end_)
        end
      end
      text = unwrap_text(raw)
      parsed = JSON.parse(text) rescue []
      # Calendar may arrive wrapped in { "calendar": [...] }
      parsed.is_a?(Hash) ? Array(parsed['calendar'] || parsed[:calendar] || parsed) : Array(parsed)
    rescue StandardError
      nil
    end

    def fetch_options_buying_power
      PortfolioSnapshot.order(created_at: :desc).first&.options_buying_power.to_d
    rescue StandardError => e
      activity.logger.warn "[build_plan] PortfolioSnapshot fetch failed: #{e.message}"
      BigDecimal('0')
    end

    def unwrap_text(raw)
      return raw if raw.is_a?(String)
      raw.respond_to?(:text) ? raw.text : raw.to_s
    end
  end
end
