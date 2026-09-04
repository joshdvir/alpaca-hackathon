# frozen_string_literal: true

module TickerSelector
  class ApplyFiltersActivity < ApplicationActivity
    # How often (in tickers processed) to send a heartbeat to Temporal.
    # Without heartbeats, the activity slot times out at start_to_close
    # and the workflow is forced to retry. Each MCP call can take
    # 100-500ms; we heartbeat every 5 tickers so a 25-ticker chunk
    # never goes 2.5s without a heartbeat even with retries.
    HEARTBEAT_EVERY = 5

    # Process ONE filter on ONE chunk of tickers. The
    # TickerSelectorWorkflow fans out (filter × chunk) pairs in
    # parallel and waits for all of them; this activity does the
    # narrowest possible unit of work so the workflow can scale
    # horizontally with the universe size.
    #
    # Arguments:
    #   tickers_chunk: Array<String> — already split by the workflow.
    #   filter_spec:   Hash — single filter spec from trading.yml.
    #
    # Returns: Array<FilterEngine::Result>
    def execute(tickers_chunk, filter_spec)
      # Temporal's default JSON converter decodes activity input hashes
      # with STRING keys ({"name": "...", "criteria": {...}}), but the
      # filter engine expects symbol keys (:name, :criteria, ...).
      # Symbolize here so the rest of the engine is happy. Safe to call
      # on an already-symbol-keyed hash (idempotent).
      filter_spec = filter_spec.deep_symbolize_keys if filter_spec.is_a?(Hash)

      filter_name = filter_spec[:name]
      activity.logger.info(
        "[ticker_selector] ApplyFilters chunk starting: filter=#{filter_name} " \
        "tickers=#{tickers_chunk.size}"
      )

      results = FilterEngine.apply(filter_spec, tickers_chunk)

      # Heartbeat halfway so a slow filter doesn't time out.
      activity.heartbeat("filter=#{filter_name} chunk_size=#{tickers_chunk.size} matched=#{results.size}")

      activity.logger.info(
        "[ticker_selector] ApplyFilters chunk done: filter=#{filter_name} " \
        "matched=#{results.size}/#{tickers_chunk.size}"
      )

      # Convert each Result (Data.define) to a plain Hash so Temporal's
      # default JSON converter can serialize them. Without this, the
      # converter falls back to Result#to_s, which produces
      # `"#<data TickerSelector::FilterEngine::Result ticker=...>"`
      # — a single unparseable string per element.
      results.map do |r|
        { ticker: r.ticker, scores: r.scores, source_filter: r.source_filter }
      end
    end
  end
end



