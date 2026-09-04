# frozen_string_literal: true

module TickerSelector
  class PersistWatchlistActivity < ApplicationActivity # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    def execute(ranked, candidates, manual_tickers = [])
      today = Date.current

      cycle_by_ticker = build_cycle_by_ticker(candidates)
      deactivate_active_entries(today)
      inserted = insert_new_entries(ranked, cycle_by_ticker, today)
      insert_audit_trail(ranked, today)

      # The watchlist is the OPERATOR's contract. The workflow
      # should always include every ticker in `manual_tickers` even
      # if the LLM ranker didn't surface it (e.g. the ranker dropped
      # it for low confidence). We append any missing manual tickers
      # here as a final guarantee. Idempotent — if the ranker did
      # surface a manual ticker, it's already in `ranked` and we
      # skip it.
      manual_inserted = ensure_manual_tickers_present(ranked, cycle_by_ticker, today, manual_tickers)

      activity.logger.info "[ticker_selector] persisted #{inserted} watchlist entries (incl. #{manual_inserted} manual-only)"
      inserted + manual_inserted
    end

    private

    # `candidates` is the deduped list from the workflow. Each `c`
    # is a plain Hash after JSON-decoding (ApplyFiltersActivity
    # returns Array<Hash> for round-tripping through Temporal's
    # default JSON converter).
    def build_cycle_by_ticker(candidates)
      filters = TradingConfig.fetch(:ticker_selector, :filters) || []
      default_cycle = TradingConfig.fetch(:ticker_selector, :default_cycle_minutes)
      cycle_by_ticker = {}
      candidates.each do |c|
        source_filter = c.is_a?(Hash) ? (c[:source_filter] || c['source_filter']) : c.source_filter
        ticker         = c.is_a?(Hash) ? (c[:ticker]         || c['ticker'])         : c.ticker
        cycle = (filters.find { |f| f[:name] == source_filter }&.dig(:cycle_minutes)) || default_cycle
        cycle_by_ticker[ticker] = [cycle_by_ticker[ticker] || 9999, cycle].min
      end
      cycle_by_ticker
    end

    def deactivate_active_entries(today)
      WatchlistEntry.where(effective_until: nil).update_all(effective_until: today)
    end

    def insert_new_entries(ranked, cycle_by_ticker, today)
      default_cycle = TradingConfig.fetch(:ticker_selector, :default_cycle_minutes)
      new_entries = (ranked || []).map do |pick|
        ticker = pick['ticker']
        {
          ticker: ticker,
          effective_from: today,
          effective_until: nil,
          source: 'ticker_selector',
          cycle_minutes: cycle_by_ticker[ticker] || default_cycle,
          tags: [pick['source_filter']].compact,
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      WatchlistEntry.insert_all(new_entries) if new_entries.any?
      new_entries.size
    end

    def insert_audit_trail(ranked, today)
      audit_rows = (ranked || []).map do |pick|
        {
          ticker: pick['ticker'],
          recommended_on: today,
          source_filter: pick['source_filter'] || 'unknown',
          scores: pick['scores'] || {},
          confidence: pick['confidence'] || 0,
          rationale: pick['rationale'],
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      WatchlistRecommendation.insert_all(audit_rows) if audit_rows.any?
    end

    # Last-resort guarantee: every ticker in `manual_tickers` ends up
    # on the watchlist. If the ranker already included it, we skip;
    # otherwise we insert it with the operator's default cycle and a
    # "manual_only" tag so the audit trail shows the operator forced
    # it (not the LLM).
    def ensure_manual_tickers_present(ranked, cycle_by_ticker, today, manual_tickers)
      return 0 if manual_tickers.blank?

      default_cycle = TradingConfig.fetch(:ticker_selector, :default_cycle_minutes)
      already = (ranked || []).map { |p| p['ticker'] }.compact.to_set
      missing = Array(manual_tickers).map(&:to_s).reject(&:empty?).uniq - already.to_a

      return 0 if missing.empty?

      rows = missing.map do |ticker|
        {
          ticker: ticker,
          effective_from: today,
          effective_until: nil,
          source: 'ticker_selector',
          cycle_minutes: cycle_by_ticker[ticker] || default_cycle,
          tags: ['manual_only'],
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      WatchlistEntry.insert_all(rows)
      WatchlistRecommendation.insert_all(missing.map do |ticker|
        {
          ticker: ticker,
          recommended_on: today,
          source_filter: 'manual_only',
          scores: {},
          confidence: 0,
          rationale: 'forced into watchlist by operator manual_tickers list',
          created_at: Time.current,
          updated_at: Time.current
        }
      end)
      missing.size
    end
  end
end
