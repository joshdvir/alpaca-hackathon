# frozen_string_literal: true

# FredClient — fetches the latest observation for a set of FRED
# macro series from the public CSV endpoint at
# https://fred.stlouisfed.org/graph/fredgraph.csv. No API key
# required; works for the common macro series used by this
# project (DGS10, DGS2, VIXCLS, T10Y2Y, and most daily / weekly
# FRED series).
#
# We use the CSV endpoint rather than the JSON API because the
# JSON API at https://api.stlouisfed.org/series/observations is
# currently returning 404 for all callers (the endpoint shape
# changed at some point and the v1 JSON path is no longer
# reachable). The CSV endpoint is stable, no auth, and serves
# the same data with a one-line difference in the response shape.
#
# API:
#   FredClient.latest(["DGS10", "VIXCLS", "T10Y2Y"])
#     # => { "DGS10"  => {date: "2026-08-28", value: 4.45},
#     #      "VIXCLS" => {date: "2026-08-28", value: 22.1},
#     #      "T10Y2Y" => {date: "2026-08-28", value: 0.25} }
#   Missing series (FRED publishes "." for missing values) come
#   back as nil so the LLM can see which inputs were available.
#
# All HTTP calls go through the shared rate limiter + circuit
# breaker for the :fred source, so a FRED outage won't drag the
# rest of the pipeline down with it.
#
# Autoloaded by Zeitwerk from app/clients/ (Rails 8 default).

class FredClient
  CSV_BASE_URL = 'https://fred.stlouisfed.org'

  def self.latest(series_ids)
    new.latest(series_ids)
  end

  def initialize(connection: nil)
    @conn = connection || default_connection
  end

  def latest(series_ids)
    return {} if series_ids.blank?

    Array(series_ids).index_with do |id|
      fetch_one(id)
    end
  end

  private

  # CSV endpoint is occasionally slow under load; give it a more
  # generous timeout than a typical API. CSV is plain text so we
  # parse it manually (avoids the stdlib CSV gem dependency for
  # Ruby 4+).
  def default_connection
    Faraday.new(url: CSV_BASE_URL) do |f|
      f.options.timeout      = 20
      f.options.open_timeout = 10
      f.headers['User-Agent'] = 'trader-app/1.0 (macro analyst)'
      f.use Faraday::Retry::Middleware, max: 2, interval: 0.3, backoff_factor: 2
    end
  end

  def fetch_one(series_id)
    with_breaker(:fred).call do
      RATE_LIMITERS[:fred].with_limit do
        # fredgraph.csv is sorted ascending by date; the LAST
        # non-header, non-empty row is the latest observation.
        # Some series publish "." for missing values (weekends,
        # holidays); we skip those.
        res = @conn.get("/graph/fredgraph.csv?id=#{series_id}")
        raise "FRED CSV #{series_id} HTTP #{res.status}" unless res.success?

        body = res.body.to_s
        rows = body.lines
                  .reject { |l| l.start_with?('observation_date') || l.strip.empty? }
                  .reverse
        row = rows.find { |l| l.strip.split(',').last != '.' }
        return nil if row.nil?

        date, value = row.strip.split(',', 2)
        return nil if date.blank? || value.blank? || value == '.'

        { date: date, value: value.to_f }
      end
    end
  rescue StandardError => e
    Rails.logger.warn "[fred_client] #{series_id} failed: #{e.class}: #{e.message[0, 200]}"
    nil
  end

  def with_breaker(source)
    CIRCUIT_BREAKERS.fetch(source)
  end
end
