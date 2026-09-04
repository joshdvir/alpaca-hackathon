# frozen_string_literal: true

module TickerSelector
  class TickerSelectorWorkflow < ApplicationWorkflow
    # Size of each ticker chunk sent to one ApplyFiltersActivity call.
    # With ~3 MCP calls per ticker (bars, chain, news) and ~200-500ms per
    # call, a chunk of 25 tickers takes ~20-40s end-to-end. Smaller
    # chunks = more parallel fan-out, larger chunks = more serial work
    # per activity slot. 25 is the sweet spot for the hackathon.
    CHUNK_SIZE = 25

    # Per-workflow cap on the number of filter activities we'll fan out.
    # Temporal rejects workflows with > 2000 pending activities with
    # `PendingActivitiesLimitExceeded`, which kills the run. We target
    # 500 (4x safety) and shrink the input ticker list to fit.
    #
    # Math: total_activities = ceil(tickers / CHUNK_SIZE) * num_filters.
    # To stay <= MAX_FILTER_ACTIVITIES, the max tickers we accept is:
    #   (MAX_FILTER_ACTIVITIES / num_filters) * CHUNK_SIZE
    #
    # Examples (CHUNK_SIZE=25):
    #   1 filter  -> 12,500 tickers
    #   2 filters ->  6,250 tickers
    #   3 filters ->  4,166 tickers
    #   5 filters ->  2,500 tickers
    MAX_FILTER_ACTIVITIES = 500

    def execute
      activity.logger.info '[ticker_selector] starting daily run'

      tickers = T_WORKFLOW.execute_activity(
        FetchUniverseActivity,
        start_to_close_timeout: 120,
        retry_policy: T_RETRY_POLICY
      )
      activity.logger.info "[ticker_selector] universe: #{tickers.size} tickers"

      # Snapshot the manual set BEFORE filtering so we can force-include
      # any manual ticker that the filter rejects. `manual_tickers` is
      # the operator's curated list and should ALWAYS be on the
      # watchlist — see PersistWatchlistActivity for the matching
      # side of this contract.
      manual_set = Array(TradingConfig.fetch(:ticker_selector, :universe, :manual_tickers)).map(&:to_s).reject(&:empty?).to_set

      candidates = run_filters_in_parallel(tickers, manual_set)
      activity.logger.info "[ticker_selector] candidates: #{candidates.size} (manual_set=#{manual_set.size})"

      # RankCandidates and PersistWatchlist stay single-activity. The
      # LLM call is a single network round-trip (not splittable), and
      # the watchlist persist is a bulk insert (DB handles it).
      ranked = T_WORKFLOW.execute_activity(
        RankCandidatesActivity, candidates,
        start_to_close_timeout: 300,
        retry_policy: T_RETRY_POLICY
      )
      activity.logger.info "[ticker_selector] ranked: #{ranked.size}"

      count = T_WORKFLOW.execute_activity(
        PersistWatchlistActivity, ranked, candidates, manual_set.to_a,
        start_to_close_timeout: 60,
        retry_policy: T_RETRY_POLICY
      )
      activity.logger.info "[ticker_selector] persisted #{count} watchlist entries"
    end

    private

    # Fan out one ApplyFiltersActivity per (filter, chunk) pair, all
    # in parallel. Then collect + dedupe. Pattern mirrors the
    # future-of-futures dispatch in
    # fetchmedia-api/app/workflows/commands/process_input_files_workflow.rb
    def run_filters_in_parallel(tickers, manual_set)
      filters = enabled_filters
      tickers = cap_tickers(tickers, filters.size)

      chunks = tickers.each_slice(CHUNK_SIZE).to_a

      activity.logger.info(
        "[ticker_selector] fanning out: filters=#{filters.size} " \
        "chunks=#{chunks.size} total_activity_calls=#{filters.size * chunks.size}"
      )

      futures = dispatch_filter_chunks(filters, chunks)
      T_FUTURE.all_of(*futures).wait
      activity.logger.info "[ticker_selector] all filter-chunk activities complete"

      all_results = futures.flat_map(&:result)
      deduped = dedupe(all_results)

      # Force-include any manual_ticker that the filter rejected.
      # Operators expect their curated list to ALWAYS be on the
      # watchlist; if the filter rejected a manual ticker (e.g.
      # the option chain was empty on the free tier and `has_options`
      # came back false), we add it back with a special tag so the
      # downstream activities + audit trail can flag it as
      # "manual_override". This is the guarantee the user asked for.
      seen_tickers = deduped.map { |r| extract_ticker(r) }.to_set
      missing_manual = manual_set - seen_tickers
      unless missing_manual.empty?
        activity.logger.warn(
          "[ticker_selector] force-including #{missing_manual.size} manual tickers " \
          "that the filter rejected: #{missing_manual.to_a.sort.inspect}"
        )
        missing_manual.each do |ticker|
          deduped << {
            ticker: ticker,
            scores: {},
            source_filter: "manual_override:#{ticker}"
          }
        end
      end

      activity.logger.info(
        "[ticker_selector] dedupe: before=#{all_results.size} after=#{deduped.size} " \
        "manual_overrides=#{missing_manual.size}"
      )
      deduped
    end

    # Truncate the input ticker list so the fan-out stays under
    # MAX_FILTER_ACTIVITIES. With a huge universe from get_all_assets
    # (8k+ US equities), capping the input list is the only way to
    # avoid PendingActivitiesLimitExceeded. We keep the first N — this
    # is a safe default for a hackathon; production should rank by
    # market cap or volume and take the top N.
    def cap_tickers(tickers, num_filters)
      return tickers if num_filters.zero?

      max_tickers = (MAX_FILTER_ACTIVITIES / num_filters) * CHUNK_SIZE
      return tickers if tickers.size <= max_tickers

      activity.logger.warn(
        "[ticker_selector] universe has #{tickers.size} tickers, exceeds " \
        "cap of #{max_tickers} for #{num_filters} filters at CHUNK_SIZE=#{CHUNK_SIZE}. " \
        "Truncating to first #{max_tickers} to stay under " \
        "#{MAX_FILTER_ACTIVITIES} filter activities (Temporal hard cap: 2000)."
      )
      tickers.first(max_tickers)
    end

    def enabled_filters
      (TradingConfig.fetch(:ticker_selector, :filters) || []).select { |f| f[:enabled] }
    end

    # Schedule one ApplyFiltersActivity per (filter, chunk) pair. Each
    # `T_FUTURE.new { ... }` returns a promise immediately; the actual
    # activity invocation is a side-effect of the block. The whole
    # grid runs in parallel as far as Temporal's worker pool allows.
    def dispatch_filter_chunks(filters, chunks)
      futures = []
      filters.each_with_index do |filter, fi|
        chunks.each_with_index do |chunk, ci|
          activity.logger.info(
            "[ticker_selector] dispatching f[#{fi + 1}/#{filters.size}] " \
            "c[#{ci + 1}/#{chunks.size}] filter=#{filter[:name]} chunk_size=#{chunk.size}"
          )
          futures << T_FUTURE.new do
            T_WORKFLOW.execute_activity(
              ApplyFiltersActivity,
              chunk, filter,
              start_to_close_timeout: 600,
              retry_policy: T_RETRY_POLICY
            )
          end
        end
      end
      futures
    end

    # Dedupe by ticker — first filter wins, so a ticker matched by the
    # higher-priority filter (e.g. high_iv_premium_sellers) won't be
    # re-recorded by a lower-priority one (e.g. earnings_drift).
    #
    # Each `r` may be a FilterEngine::Result (Data.define), a Hash
    # (after Temporal JSON-decoding), or a plain String (if a future
    # only returned the ticker symbol). Handle all three forms.
    def dedupe(results)
      seen = {}
      results.each do |r|
        ticker = extract_ticker(r)
        seen[ticker] ||= r
      end
      seen.values
    end

    def extract_ticker(r)
      return r if r.is_a?(String)
      return r[:ticker] || r['ticker'] if r.is_a?(Hash)
      r.ticker # Data.define / Result
    end
  end
end


