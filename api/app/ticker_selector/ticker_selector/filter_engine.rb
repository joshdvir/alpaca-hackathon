# frozen_string_literal: true

# Deterministic filter engine.
# Takes a list of tickers + a filter spec from trading.yml and returns
# the tickers that pass the criteria, plus per-ticker scores.
#
# Each filter spec is a hash like:
#   {
#     name: "high_iv_premium_sellers",
#     enabled: true,
#     type: "volatility",
#     criteria: { iv_rank_min: 60, avg_dollar_volume_min: 100_000_000, max_results: 25 },
#     cycle_minutes: 5,
#     prompt: "..."
#   }
#
# We fetch a small snapshot per ticker (current quote, recent bars, IV rank
# from option snapshot) and apply the criteria.

module TickerSelector
  class FilterEngine # rubocop:disable Metrics/ClassLength
    Result = Data.define(:ticker, :scores, :source_filter)

    # How many days of news we pull per ticker. The earnings + insider
    # filters scan the last 30 days (their criterion key controls the
    # effective recency window inside the score function, but the MCP
    # call must fetch a wide enough range that the criterion has data
    # to work with). With 3 items, the `earnings_within_days_max: 5`
    # filter was effectively blind on most tickers.
    NEWS_LOOKBACK_DAYS = 30
    NEWS_LIMIT = 50

    def self.apply(filter_spec, tickers)
      return [] unless filter_spec[:enabled]
      return [] if tickers.empty?

      criteria = filter_spec[:criteria] || {}
      # For the news-based proxies, only count news inside this window.
      # `lookback_days` is the explicit knob for the insider filter;
      # `earnings_within_days_max` is the analogous one for earnings.
      news_within_days = criteria[:lookback_days] || criteria[:earnings_within_days_max] || 7

      # BATCH the MCP calls: 1 call for all bars, 1 call for all news,
      # then 1 call per ticker for the option chain (which can't be
      # batched because each ticker has its own chain). Net: ~2 calls
      # per filter run + N (one per ticker) instead of 3N.
      bars_by_ticker = fetch_bars_batch(tickers)
      news_items     = fetch_news_batch(tickers)

      # Parallelize the per-ticker option chain fetch. Each call to
      # the Alpaca MCP is ~3-7s, and with 25 tickers in a chunk the
      # serial version was the dominant cost (often 60+ s per
      # ApplyFiltersActivity, with 413 in flight at 5 activity slots).
      # With CHAIN_PARALLELISM threads per activity, 20 activities
      # × CHAIN_PARALLELISM threads = 80-200 concurrent MCP calls.
      # The Alpaca MCP server (HTTP transport) easily handles that.
      chains_by_ticker = fetch_chains_parallel(tickers)

      passing = []

      tickers.each do |ticker|
        snapshot = {
          ticker:           ticker,
          bars:             bars_by_ticker[ticker] || [],
          option_snapshot:  chains_by_ticker[ticker] || {},
          news:             news_items_for(news_items, ticker)
        }

        scores = score(snapshot, criteria, news_within_days: news_within_days, filter_type: filter_spec[:type])
        next unless meets_criteria?(scores, criteria)

        passing << Result.new(
          ticker: ticker,
          scores: scores,
          source_filter: filter_spec[:name]
        )
      end

      limit = criteria[:max_results] || passing.size
      passing.first(limit)
    end

    # Batch-fetch daily bars for many tickers in a single MCP call.
    # Returns `{ ticker => [bar, bar, ...] }`. Tickers with no bars in
    # the response map to an empty array.
    def self.fetch_bars_batch(tickers)
      return {} if tickers.empty?

      resp = safe_call(
        'get_stock_bars',
        { symbols: tickers.join(','), timeframe: '1Day', limit: 30 }
      )
      # Mcp::Response.unwrap for get_stock_bars returns the inner
      # `{ "AAPL" => [...], "MSFT" => [...] }` hash directly (the
      # EXTRACTORS table strips the outer `"bars"` wrapper).
      bars = Mcp::Response.unwrap(resp, tool_name: 'get_stock_bars')
      return {} unless bars.is_a?(Hash)

      result = {}
      tickers.each do |t|
        result[t] = bars[t] || bars[t.to_sym] || []
      end
      result
    end

    # Batch-fetch news for many tickers in a single MCP call.
    # Returns a flat Array of news items, each with a `symbols` array.
    # Use `news_items_for(...)` to split by ticker downstream.
    #
    # NOTE: the Alpaca `get_news` endpoint caps `limit` at 50 (any
    # larger value returns 400). We pull 50 per batch and rely on the
    # `start` parameter to bound the time window — so the recency
    # filter (NEWS_LOOKBACK_DAYS) is the precision control, not the
    # count. This means each ticker may not get all its news in one
    # call, but the ones we DO get are the most recent.
    def self.fetch_news_batch(tickers)
      return [] if tickers.empty?

      news_start = (Time.now.utc - (NEWS_LOOKBACK_DAYS * 86_400)).iso8601
      resp = safe_call(
        'get_news',
        { symbols: tickers.join(','), start: news_start, limit: NEWS_LIMIT }
      )
      Array(Mcp::Response.unwrap(resp, tool_name: 'get_news'))
    end

    # Filter a flat news-items list (from fetch_news_batch) to just the
    # items that mention `ticker` in their `symbols` array.
    def self.news_items_for(news_items, ticker)
      news_items.select do |n|
        next false unless n.is_a?(Hash)
        syms = Array(n['symbols'] || n[:symbols])
        syms.map(&:to_s).include?(ticker)
      end
    end

    # Per-ticker option chain fetch (can't be batched: each ticker has
    # its own chain). Returns the unwrapped `{ <occ_symbol> => snapshot }`
    # hash, or `{}` on failure.
    def self.fetch_option_chain(ticker)
      resp = safe_call('get_option_chain', { underlying_symbol: ticker, limit: 3 })
      Mcp::Response.unwrap(resp, tool_name: 'get_option_chain') || {}
    end

    # Threads per ApplyFiltersActivity for parallel option-chain
    # fetches. With activity_slots=20 on TickerSelectorWorker, this
    # caps the MCP concurrency at 20 × CHAIN_PARALLELISM.
    #
    # CHAIN_PARALLELISM=10 → up to 200 concurrent get_option_chain
    # calls. The Alpaca MCP (HTTP) handles that fine; lowering to 5
    # cuts the worker process's thread count to 100 if you see the
    # worker OOMing or heavy context-switching.
    CHAIN_PARALLELISM = 10

    # Fetch option chains for many tickers in parallel. Returns
    # `{ ticker => chain_hash }`. Threads are bounded by
    # `CHAIN_PARALLELISM` so a 100-ticker chunk doesn't spawn 100
    # threads. The MCP calls are I/O bound, not CPU bound, so a
    # small thread pool is more efficient than one-thread-per-ticker.
    def self.fetch_chains_parallel(tickers)
      return {} if tickers.empty?

      queue = tickers.dup
      result = {}
      mutex = Mutex.new

      threads = CHAIN_PARALLELISM.times.map do
        Thread.new do
          loop do
            ticker = mutex.synchronize { queue.shift }
            break if ticker.nil?

            chain = fetch_option_chain(ticker)
            mutex.synchronize { result[ticker] = chain }
          end
        end
      end
      threads.each(&:join)
      result
    end

    # Single-ticker fetch (kept for callers that need one ticker at a
    # time, e.g. ad-hoc smoke tests). Internally uses the batch helpers
    # so the MCP call shape stays consistent.
    def self.fetch_snapshot(ticker)
      bars = fetch_bars_batch([ticker])
      news = fetch_news_batch([ticker])
      {
        ticker:           ticker,
        bars:             bars[ticker] || [],
        option_snapshot:  fetch_option_chain(ticker),
        news:             news_items_for(news, ticker)
      }
    end

    # Unwrap the option-chain MCP response. `get_option_chain` returns
    # { "snapshots": { "<occ_symbol>": { ... greeks ... } } }; we keep
    # that whole hash so `iv_rank` can pick whichever snapshot has Greeks.
    def self.extract_option_chain(content)
      Mcp::Response.unwrap(content, tool_name: 'get_option_chain') || {}
    end

    # get_stock_bars returns { "bars": { "SPY": [bar, bar, ...] } } — we
    # only want the array for this ticker.
    def self.extract_bars(content, ticker)
      payload = Mcp::Response.unwrap(content, tool_name: 'get_stock_bars')
      return [] unless payload.is_a?(Hash)

      payload[ticker] || payload[ticker.to_sym] || []
    end

    def self.extract_news(content)
      Array(Mcp::Response.unwrap(content, tool_name: 'get_news'))
    end

    def self.score(snapshot, _criteria, news_within_days: 7, filter_type: nil)
      scores = {}
      closes = (snapshot[:bars] || []).pluck('c').compact
      # pct_change clamps to available data, so we can always set the
      # key when we have >= 2 closes (and 0.0 is a valid "flat" reading).
      # Without this, the criteria check (`scores[:pct_change_7d].to_f >= v`)
      # silently turns missing data into "0 < threshold" → false → filter out.
      scores.merge!(price_scores(snapshot, closes))
      scores.merge!(options_scores(snapshot))
      scores.merge!(news_scores(Array(snapshot[:news]), news_within_days))
      # Real insider data from SEC EDGAR (replaces the news-keyword proxy
      # for the insider_buying_cluster filter). The score key is the same
      # name as the news one so the criteria handler doesn't have to care
      # which source fed the value. ONLY call this for the insider filter —
      # every other filter would otherwise burn 1 SEC EDGAR HTTP request
      # per ticker per chunk (was the dominant cost on the volatility and
      # earnings filters where the score is discarded anyway).
      scores.merge!(edgar_scores(snapshot)) if filter_type.to_s == 'insider'
      scores
    end

    # Scores derived from the price/bar series. pct_change keys are set
    # whenever we have >= 2 closes (clamping to available data). RSI is
    # only set when we have enough bars for the period. avg_dollar_volume
    # needs the full snapshot (not just closes) because it uses bar volume.
    def self.price_scores(snapshot, closes)
      scores = {}
      scores[:pct_change_7d]    = pct_change(closes, 7)  if closes.size >= 2
      scores[:pct_change_30d]   = pct_change(closes, 30) if closes.size >= 2
      scores[:avg_dollar_volume] = avg_dollar_volume(snapshot)
      scores[:rsi_3]            = rsi(closes, period: 3) if closes.size >= 4
      scores
    end

    # Scores derived from the option chain. On free tier the snapshots
    # don't carry greeks, so iv_rank is always nil. We still set
    # `has_options` so the `has_options: true` criterion can pass for
    # tickers that have any chain data.
    #
    # `avg_open_interest` and `avg_bid_ask_spread_pct` are computed
    # across the strikes the chain returned (whatever the MCP server
    # gave us). On a paid tier the chain is wide; on free tier it may
    # be just a handful of strikes — the average is still meaningful
    # for the `min_open_interest` / `max_bid_ask_spread_pct` filters,
    # which target the existence of *some* tradeable strikes, not
    # every strike in the chain.
    def self.options_scores(snapshot)
      opt = snapshot[:option_snapshot]
      {
        iv_rank:                 opt ? iv_rank(opt) : nil,
        has_options:             opt.is_a?(Hash) && opt.any?,
        avg_open_interest:       opt ? avg_open_interest(opt) : nil,
        avg_bid_ask_spread_pct:  opt ? avg_bid_ask_spread_pct(opt) : nil
      }
    end

    # Average open interest across the strikes in the chain. nil if the
    # chain has no strikes with a populated OI value (which is the
    # common free-tier outcome — be defensive, return nil, let the
    # criterion handler decide whether nil passes).
    #
    # The Alpaca MCP server exposes OI as either `open_interest` (REST
    # shape) or `openInterest` (camelCase) depending on the underlying
    # tool. We accept both.
    def self.avg_open_interest(option_chain)
      return nil unless option_chain.is_a?(Hash) && option_chain.any?

      ois = option_chain.values.filter_map do |snap|
        next nil unless snap.is_a?(Hash)
        # OI key candidates: snake_case REST, camelCase MCP, short alias.
        oi = snap['open_interest'] || snap['openInterest'] || snap['oi']
        oi.nil? ? nil : oi.to_i
      end
      return nil if ois.empty?

      (ois.sum.to_f / ois.size).round(1)
    end

    # Average bid/ask spread (as % of mid) across the strikes in the
    # chain. A spread of 0.10 means the bid/ask is 10% of the mid.
    # nil if no strike has a populated bid/ask quote.
    #
    # Alpaca's option snapshot nests the quote under `latestQuote`
    # (camelCase MCP shape) or `latest_quote` (snake_case REST shape).
    # Ask/bid keys: `ap`/`bp` (MCP), `ask_price`/`bid_price` (REST).
    def self.avg_bid_ask_spread_pct(option_chain)
      return nil unless option_chain.is_a?(Hash) && option_chain.any?

      spreads = option_chain.values.filter_map do |snap|
        next nil unless snap.is_a?(Hash)
        bid, ask = option_bid_ask(snap)
        next nil if bid.nil? || ask.nil?
        next nil if bid <= 0 || ask <= 0
        mid = (ask + bid) / 2.0
        next nil if mid <= 0
        # Spread % is (ask - bid) / mid. The chain-level average
        # smooths out a single weirdly-wide strike.
        ((ask - bid) / mid)
      end
      return nil if spreads.empty?

      (spreads.sum / spreads.size).round(4)
    end

    # Pull (bid, ask) from an option snapshot, trying all the field
    # names the Alpaca MCP server / REST API use. Returns [bid, ask]
    # as floats, or [nil, nil] if either is missing.
    def self.option_bid_ask(snap)
      quote = snap['latestQuote'] || snap['latest_quote'] || snap['quote']
      return [nil, nil] unless quote.is_a?(Hash)

      bid = quote['bp'] || quote['bid_price'] || quote['bid']
      ask = quote['ap'] || quote['ask_price'] || quote['ask']
      [bid&.to_f, ask&.to_f]
    end

    # News-based proxy scores. See config/trading.yml "DATA-SOURCE NOTE"
    # for why these are weak signals. The recency window is taken from
    # the filter's criteria (`lookback_days` for the insider filter,
    # `earnings_within_days_max` for the earnings filter) and falls back
    # to 7 days if neither is set.
    def self.news_scores(news_items, within_days)
      recent = NewsProxies.recent(news_items, within_days: within_days)
      {
        news_earnings_keyword_count: NewsProxies.earnings_keyword_count(recent),
        news_insider_buy_count:      NewsProxies.insider_buy_count(recent),
        news_insider_buy_value_usd:  NewsProxies.insider_buy_value_usd(recent)
      }
    end

    # EDGAR-backed insider buy scores. We pre-compute the summary for
    # the ticker once and surface two keys: count and total $ value. The
    # criteria handler reads these (under the same `insider_buys_min`
    # and `insider_value_min` keys) — so the existing trading.yml
    # `insider_buying_cluster` spec lights up against real Form-4
    # data without any changes.
    def self.edgar_scores(snapshot)
      ticker = snapshot[:ticker].to_s
      # Cheap path: skip the network call for non-options-eligible
      # tickers (they wouldn't survive the options_liquid filter
      # anyway, and we don't want to spend EDGAR rate on every ticker).
      return default_edgar_scores unless snapshot[:has_options] == true

      summary = EdgarClient.insider_buy_summary(ticker, lookback_days: 14)
      {
        edgar_insider_buy_count:     summary[:count],
        edgar_insider_buy_value_usd: summary[:total_value_usd]
      }
    rescue StandardError => e
      Rails.logger.warn "[filter_engine] EDGAR summary failed for #{ticker}: #{e.class}: #{e.message[0, 120]}"
      default_edgar_scores
    end

    def self.default_edgar_scores
      { edgar_insider_buy_count: 0, edgar_insider_buy_value_usd: 0.0 }
    end

    # Hash-based dispatch keeps `meets_criteria?` simple and makes the
    # criterion-key → score-key wiring explicit. Each handler returns
    # true if the criterion passes. The handlers assume a missing
    # score value (e.g. nil RSI on too-short data) is the WORST case
    # for the criterion — so a `rsi_max: 30` with nil RSI fails
    # (we'd rather miss a candidate than admit one we can't evaluate).
    CRITERION_HANDLERS = {
      pct_change_7d_min:     ->(scores, v) { scores[:pct_change_7d].to_f  >= v.to_f },
      pct_change_7d_max:     ->(scores, v) { scores[:pct_change_7d].to_f  <= v.to_f },
      pct_change_30d_min:    ->(scores, v) { scores[:pct_change_30d].to_f >= v.to_f },
      pct_change_30d_max:    ->(scores, v) { scores[:pct_change_30d].to_f <= v.to_f },
      iv_rank_min:           ->(scores, v) { scores[:iv_rank].to_f          >= v.to_f },
      avg_dollar_volume_min: ->(scores, v) { scores[:avg_dollar_volume].to_f >= v.to_f },
      rsi_max:               ->(scores, v) { (scores[:rsi_3] || 100.0)     <= v.to_f },
      rsi_min:               ->(scores, v) { (scores[:rsi_3] || 0.0)       >= v.to_f },
      has_options:           ->(scores, _v) { scores[:has_options] == true },
      # Liquidity-on-the-chain: average OI across the strikes we
      # received from the MCP must be at least `v` contracts. If the
      # score is nil (chain had no OI data — common on free tier), we
      # PASS so the filter doesn't reject every name on missing data.
      # To get strict behavior, combine with `has_options: true` in the
      # criteria so the chain is required to be present.
      min_open_interest:     ->(scores, v) {
        oi = scores[:avg_open_interest]
        return true if oi.nil?   # no data → can't reject; let other criteria decide
        oi >= v.to_f
      },
      # Bid/ask tightness: average spread (as fraction of mid) must
      # be at most `v`. `v: 0.10` means 10% spread. nil score → pass
      # (same rationale as min_open_interest).
      max_bid_ask_spread_pct: ->(scores, v) {
        sp = scores[:avg_bid_ask_spread_pct]
        return true if sp.nil?
        sp <= v.to_f
      },
      earnings_within_days_max: ->(scores, _v) { (scores[:news_earnings_keyword_count] || 0) > 0 },
      # EDGAR-backed insider keys (replaced the news-keyword proxy).
      # The trading.yml `insider_buying_cluster` filter's
      # `insider_buys_min` and `insider_value_min` now read real Form 4
      # data via EdgarClient.
      insider_buys_min:      ->(scores, v) { (scores[:edgar_insider_buy_count] || 0)      >= v.to_i },
      insider_value_min:     ->(scores, v) { (scores[:edgar_insider_buy_value_usd] || 0)  >= v.to_f }
    }.freeze

    def self.meets_criteria?(scores, criteria)
      criteria.all? do |k, v|
        handler = CRITERION_HANDLERS[k]
        # Unknown criteria (e.g. max_results, lookback_days) — don't
        # filter on them; they're handled elsewhere in `apply` or are
        # knobs the score function uses directly.
        handler ? handler.call(scores, v) : true
      end
    end

    # Wilder's RSI on `closes`. Returns a 0..100 number, or nil if there's
    # not enough data. With Alpaca's free-tier 4-day bar history, this
    # 7-period RSI is rarely computable — the criterion `rsi_max: 30`
    # will return false (filter rejects) on too-short data, which is
    # the safer default (we'd rather miss a candidate than admit one
    # we can't evaluate).
    def self.rsi(closes, period: 14)
      return nil if closes.size < period + 1

      gains, losses = gain_loss_series(closes)
      avg_gain, avg_loss = wilder_averages(gains, losses, period)
      rsi_from_averages(avg_gain, avg_loss)
    end

    # Split a close-price series into gains and losses (one element per
    # pair of consecutive closes). A "gain" is the positive delta; a
    # "loss" is the absolute value of the negative delta.
    def self.gain_loss_series(closes)
      deltas = []
      closes.each_cons(2) { |a, b| deltas << (b.to_f - a.to_f) }
      gains  = deltas.map { |d| [d, 0.0].max }
      losses = deltas.map { |d| [-d, 0.0].max }
      [gains, losses]
    end

    # Wilder's smoothed averages: simple mean of the first `period`
    # elements, then EMA-style smoothing for the rest. The standard
    # smoothing constant for Wilder is 1/period.
    def self.wilder_averages(gains, losses, period)
      avg_gain = gains[0, period].sum / period.to_f
      avg_loss = losses[0, period].sum / period.to_f
      (period...gains.size).each do |i|
        avg_gain = ((avg_gain * (period - 1)) + gains[i]) / period.to_f
        avg_loss = ((avg_loss * (period - 1)) + losses[i]) / period.to_f
      end
      [avg_gain, avg_loss]
    end

    # Convert Wilder-smoothed gain/loss averages to a 0..100 RSI value.
    # Edge cases:
    #   - both zero → flat market → 50
    #   - avg_loss zero (no losses) → RSI tops out at 100
    #   - avg_gain zero (no gains) → RSI bottoms out at 0
    def self.rsi_from_averages(avg_gain, avg_loss)
      return 50.0  if avg_loss.zero? && avg_gain.zero?
      return 100.0 if avg_loss.zero?
      return 0.0   if avg_gain.zero?

      rs = avg_gain / avg_loss
      100.0 - (100.0 / (1.0 + rs))
    end

    # Weak-signal news-based proxies (earnings + insider) live in
    # TickerSelector::NewsProxies so the regex patterns and date-window
    # logic can evolve independently of the main filter. See that file
    # for why we use news keywords instead of a real earnings/insider
    # data feed, and the upgrade path.

    def self.pct_change(closes, n)
      # Need at least 2 points to compute any change.
      return 0.0 if closes.size < 2
      # Clamp the window to the data we actually have. Free-tier Alpaca
      # data only goes back ~4 daily bars in this env, so an honest
      # "7-day change" request gets clamped to a 3-day change. Better
      # to return the best estimate than 0.0 (which would fail any
      # `pct_change_*_min: 5` filter silently).
      n = [n, closes.size - 1].min
      return 0.0 if n < 1

      old = closes[-(n + 1)]
      latest = closes.last
      return 0.0 if old.to_f.zero?

      ((latest.to_f - old.to_f) / old.to_f) * 100.0
    end

    def self.iv_rank(option_chain)
      # `option_chain` is the unwrapped get_option_chain response:
      #   { "<OCC_SYMBOL>": { "greeks": { "iv": 0.30, ... }, ... } }
      # The MCP server returns IV as a fraction (0.30 == 30%). For
      # `iv_rank_min` criteria in trading.yml, callers expect a 0-100
      # number, so we multiply by 100. Without a real 52-week IV range,
      # we return IV itself as a rough rank proxy (overstates "rank"
      # but keeps the filter monotonic in IV).
      return nil unless option_chain.is_a?(Hash) && option_chain.any?

      snapshot = option_chain.values.first
      return nil unless snapshot.is_a?(Hash)

      iv = snapshot.dig('greeks', 'iv') || snapshot['impliedVolatility'] || snapshot['iv']
      return nil if iv.nil?

      (iv.to_f * 100).round(2)
    end

    # Average daily dollar volume over the bars we fetched. This is
    # actually a *liquidity* signal (dollars traded per day), not a
    # market-cap signal, despite the historical name. Renamed to be
    # honest about what it computes; the trading.yml key follows
    # (`avg_dollar_volume_min`).
    def self.avg_dollar_volume(snapshot)
      bars = snapshot[:bars] || []
      return 0.0 if bars.empty?

      bars.sum { |b| b['c'].to_f * b['v'].to_f } / bars.size.to_f
    end

    def self.has_options?(_ticker)
      # The option_snapshot tool will fail (no options) for some tickers.
      # Caller handles errors via safe_call.
      true
    end

    # Number of retries on a 429 from the upstream Alpaca data API. The
    # MCP server itself logs the 429; ruby_llm-mcp returns it to us as
    # a {error: "..."} hash in the MCP::Content body. We back off
    # exponentially with jitter so a burst of 30+ tickers (one call per
    # ticker for get_news, get_option_chain, get_stock_bars) doesn't
    # overwhelm the data API.
    MAX_429_RETRIES = 3

    # Base backoff in seconds. With MAX_429_RETRIES=3 the actual sleeps
    # are ~5s, 10s, 20s plus jitter — long enough that we let the
    # upstream rate-limit window reset before retrying.
    BACKOFF_BASE_SECONDS = 5

    # Default TTLs per tool. News and option chain data move slowly,
    # so they get longer TTLs than bars. The cache dramatically cuts
    # the call count against the upstream 200 req/min rate limit when
    # the same filter is applied to many tickers in one run.
    TOOL_TTLS = {
      'get_stock_bars'    => 5.minutes,
      'get_option_chain'  => 10.minutes,
      'get_news'          => 5.minutes
    }.freeze

    def self.safe_call(tool_name, args)
      call_args = args || {}
      ttl = TOOL_TTLS.fetch(tool_name.to_s, 5.minutes)
      cache_key = cache_key_for(tool_name, call_args)

      # Cache hit short-circuits the entire call. The cached value is
      # the post-`Mcp::Response.unwrap` payload, so callers can treat
      # cache hits and fresh responses identically. We back the cache
      # with Solid Cache (Rails.cache), so any worker can fill and any
      # worker can read — important because the ticker-selector and
      # trading workers run as separate processes.
      Rails.cache.fetch(cache_key, expires_in: ttl) do
        perform_safe_call(tool_name, call_args)
      end
    end

    # Stable, args-order-independent cache key for a (tool, args) pair.
    # We use SHA-1 so the key fits the 1024-byte limit on Solid Cache
    # and so the namespace doesn't accidentally collide on
    # structurally-different inputs.
    def self.cache_key_for(tool_name, args)
      raw = "#{tool_name}|#{stable_args_for_cache(args)}"
      "mcp:#{Digest::SHA1.hexdigest(raw)}"
    end

    # Same canonical form as the previous McpCache.stable_args — we
    # keep a local copy to avoid coupling this filter to a model class.
    def self.stable_args_for_cache(value)
      case value
      when Hash
        '{' + value.map { |k, v| "#{k.inspect}:#{stable_args_for_cache(v)}" }.sort.join(',') + '}'
      when Array
        '[' + value.map { |v| stable_args_for_cache(v) }.join(',') + ']'
      when nil
        'nil'
      else
        value.inspect
      end
    end

    # The actual MCP call + 429 retry logic. Split out so `safe_call`
    # can be tested independently of the cache.
    def self.perform_safe_call(tool_name, call_args)
      tool = ALPACA_MCP_READONLY.tool(tool_name.to_s)
      return nil unless tool

      label = call_args[:symbol] || call_args[:underlying_symbol] || '?'

      # The ruby_llm-mcp library wraps upstream errors as either:
      #   - a Content whose .text JSON is `{"error": "Tool execution error: HTTP error 429: ..."}`
      #   - or, sometimes, a raised RubyLLM::Tool::ExecutionError with the
      #     same 429 message.
      # Either way, we detect "429" / "too many requests" in the message
      # or the response body, back off, and retry up to MAX_429_RETRIES.
      attempt = 0
      begin
        attempt += 1
        result = tool.call(call_args)
        if rate_limited_response?(result)
          # After MAX_429_RETRIES attempts, give up and return nil
          # rather than handing back the error body.
          raise 'rate_limited_response' if attempt <= MAX_429_RETRIES

          return nil
        end
        result
      rescue StandardError => e
        msg = e.message.to_s
        rate_limited = msg.include?('429') || msg.downcase.include?('too many requests') ||
                       msg.include?('rate_limited_response')
        if rate_limited && attempt <= MAX_429_RETRIES
          delay = (BACKOFF_BASE_SECONDS * (2**(attempt - 1))) + (rand * BACKOFF_BASE_SECONDS)
          Rails.logger.warn do
            "[ticker_selector] #{tool_name} hit 429 (attempt #{attempt}) for #{label} — sleeping #{delay.round(1)}s"
          end
          sleep(delay)
          retry
        end
        Rails.logger.debug { "[ticker_selector] tool #{tool_name} failed for #{label}: #{msg}" }
        nil
      end
    end

    def self.rate_limited_response?(result)
      return false unless result

      text = result.respond_to?(:text) ? result.text : nil
      return false if text.nil? || text.empty?

      text.include?('429') || text.downcase.include?('too many requests')
    end

    def self.parse(content)
      Mcp::Response.unwrap(content)
    end
  end
end
