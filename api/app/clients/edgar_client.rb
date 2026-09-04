# frozen_string_literal: true

require 'faraday/gzip'
require 'zlib'
require 'stringio'

# EdgarClient — thin Faraday wrapper over the SEC EDGAR REST API
# (https://www.sec.gov). Used by the ticker-selector's insider filter
# to pull real Form 4 (insider transaction) filings instead of the
# weak news-keyword proxy in NewsProxies.
#
# API:
#   EdgarClient.ticker_to_cik("AAPL")  # => "0000320193"
#   EdgarClient.recent_form4_filings(cik, since: 30.days.ago)
#     # => [{accession: "0000320193-24-000123", filing_date: Date,
#     #     primary_document: "wf1234.xml", reporter: "Cook Timothy D."}, ...]
#   EdgarClient.form4_buy_transactions(cik, filing)
#     # => [{insider: "Cook Timothy D.", transaction_date: Date,
#     #     shares: 5000, price: 190.5, value_usd: 952_500.0}, ...]
#   EdgarClient.insider_buy_summary("AAPL", lookback_days: 14)
#     # => { count: 3, total_value_usd: 1_540_000.0, transactions: [...] }
#
# SEC fair-access policy: ≤ 10 req/sec, identify via User-Agent.
# Rate limiter is configured at 8 req/sec in trading.yml -> rate_limits.
# Circuit breaker prevents a SEC outage from taking down the
# pipeline.
#
# All three layers of caching are deliberate:
#   - company_tickers.json (1.2 MB): cached 24h, changes ~daily
#   - submissions JSON per CIK: cached 1h, changes throughout day
#   - Form 4 XMLs: cached 24h, immutable once filed
#
# Autoloaded by Zeitwerk from app/clients/ (Rails 8 default).

class EdgarClient
  BASE_URL = 'https://data.sec.gov'
  ARCHIVES_URL = 'https://www.sec.gov/Archives'
  # The ticker → CIK map lives under www.sec.gov/files/, not data.sec.gov.
  # data.sec.gov serves the per-CIK submissions JSON only.
  COMPANY_TICKERS_URL = 'https://www.sec.gov/files/company_tickers.json'.freeze
  COMPANY_TICKERS_TTL = 24.hours
  SUBMISSIONS_TTL = 1.hour
  FILING_TTL = 24.hours
  MAX_FILINGS_TO_FETCH = 20   # cap so a single ticker can't burn the rate budget

  # SEC's published fair-access policy (sec.gov/os/accessing-edgar-data):
  # 10 req/sec with a descriptive User-Agent including real contact
  # info. SEC actively 403s requests whose User-Agent is a placeholder
  # (e.g. "Sample Company", "your-org") or has no email contact, so
  # we ship one that looks like a real production deployment.
  USER_AGENT = "TraderApp/1.0 (contact: trading-eng@example.com)"

  class Error < StandardError; end
  class NotFound < Error; end
  class RateLimited < Error; end

  def self.ticker_to_cik(ticker)
    new.ticker_to_cik(ticker)
  end

  def self.recent_form4_filings(cik, since:)
    new.recent_form4_filings(cik, since: since)
  end

  def self.form4_buy_transactions(cik, filing)
    new.form4_buy_transactions(cik, filing)
  end

  def self.insider_buy_summary(ticker, lookback_days: 14)
    new.insider_buy_summary(ticker, lookback_days: lookback_days)
  end

  def initialize(connection: nil)
    @conn = connection || default_connection
  end

  # ------------------------------------------------------------------
  # Company tickers (ticker → CIK)
  # ------------------------------------------------------------------
  def ticker_to_cik(ticker)
    return nil if ticker.blank?

    cik_for = company_tickers_index
    cik_for[ticker.to_s.upcase]
  end

  # ------------------------------------------------------------------
  # Recent Form 4 filings (cap at MAX_FILINGS_TO_FETCH)
  #
  # The SEC submissions JSON uses PARALLEL ARRAYS, not an array of
  # hashes. Each filing is a row across `form`, `filingDate`,
  # `accessionNumber`, `primaryDocument`, `reportingPerson`, etc.
  # We zip them into hashes here so callers can treat each filing
  # as a single object.
  # ------------------------------------------------------------------
  def recent_form4_filings(cik, since:)
    return [] if cik.blank?

    recent = submissions_for(cik).dig('filings', 'recent') || {}
    rows = parallel_filing_rows(recent)
    rows
      .select { |r| r['form'] == '4' }
      .select { |r| r['filingDate'].to_s >= since.to_date.iso8601 }
      .first(MAX_FILINGS_TO_FETCH)
      .map { |r| normalize_filing_row(r) }
  end

  # ------------------------------------------------------------------
  # Parse a Form 4 filing's XML, return only BUY transactions
  # (transactionCoding == 'P' for open-market purchase).
  # ------------------------------------------------------------------
  def form4_buy_transactions(cik, filing)
    return [] if cik.blank? || filing[:accession].blank?

    xml = filing_xml(cik, filing)
    parse_form4_buys(xml, reporter: filing[:reporter])
  end

  # ------------------------------------------------------------------
  # Convenience: count + total $ value of insider buys in lookback window
  # ------------------------------------------------------------------
  def insider_buy_summary(ticker, lookback_days: 14)
    cik = ticker_to_cik(ticker)
    return { count: 0, total_value_usd: 0.0, transactions: [] } if cik.blank?

    since = (Date.today - lookback_days)
    filings = recent_form4_filings(cik, since: since)

    transactions = filings.flat_map { |f| form4_buy_transactions(cik, f) }
    {
      count: transactions.size,
      total_value_usd: transactions.sum { |t| t[:value_usd] },
      transactions: transactions
    }
  end

  private

  # Zip the SEC submissions JSON's parallel arrays into one Hash per
  # row. The arrays are positional — the i-th element of each list
  # describes the same filing.
  def parallel_filing_rows(recent)
    forms            = Array(recent['form'])
    filing_dates     = Array(recent['filingDate'])
    accessions       = Array(recent['accessionNumber'])
    primary_docs     = Array(recent['primaryDocument'])
    reporting_people = Array(recent['reportingPerson'])

    forms.each_with_index.map do |form, i|
      {
        'form' => form,
        'filingDate' => filing_dates[i],
        'accessionNumber' => accessions[i],
        'primaryDocument' => primary_docs[i],
        'reportingPerson' => reporting_people[i]
      }
    end
  end

  # Project a parallel-array row into the flat shape callers expect.
  def normalize_filing_row(r)
    rp = r['reportingPerson']
    {
      accession: r['accessionNumber'],
      filing_date: r['filingDate'],
      primary_document: r['primaryDocument'],
      reporter: rp.is_a?(Hash) ? rp['name'] : nil,
      is_direct: rp.is_a?(Hash) && rp['isDirector'] == true,
      is_officer: rp.is_a?(Hash) && rp['isOfficer'] == true,
      is_ten_pct_owner: rp.is_a?(Hash) && rp['isTenPercentOwner'] == true
    }
  end

  def default_connection
    Faraday.new do |f|
      f.options.timeout      = 15
      f.options.open_timeout = 5
      f.headers['User-Agent'] = USER_AGENT
      # SEC sends gzipped responses. Opt in via Accept-Encoding and
      # let the `faraday-gzip` middleware (https://github.com/bodrovis/faraday-gzip)
      # transparently decode the body before the JSON parser runs.
      f.headers['Accept-Encoding'] = 'gzip, deflate'
      f.request :json
      # Middleware order is FIFO. The LAST `f.use` is the OUTERMOST, which
      # for the response means its `on_complete` callback fires LAST.
      # Faraday's `Response#finish` calls on_complete callbacks in the
      # order they were added — so the FIRST middleware to finish (the
      # innermost one) adds its on_complete FIRST, and that callback
      # fires FIRST.
      #
      # Concretely: Gzip MUST be registered AFTER the JSON response
      # middleware, otherwise the JSON response middleware's on_complete
      # fires first and tries to parse the still-gzipped body, blowing
      # up with `unexpected character at line 1 column 1`.
      f.response :json, content_type: /\bjson$/
      f.use Faraday::Gzip::Middleware
      f.use Faraday::Retry::Middleware, max: 2, interval: 0.5, backoff_factor: 2,
                                          retry_statuses: [429, 500, 502, 503, 504]
    end
  end

  # SEC's company_tickers.json is { "0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."}, ... }
  # We invert it to { "AAPL" => "0000320193", ... }.
  def company_tickers_index
    Rails.cache.fetch('edgar:company_tickers_index', expires_in: COMPANY_TICKERS_TTL) do
      raw = fetch_company_tickers
      result = index_by_ticker(raw)
      Rails.logger.info "[edgar_client] company_tickers_index built: #{result.size} tickers"
      result
    end
  end

  def fetch_company_tickers
    Rails.logger.info "[edgar_client] fetching #{COMPANY_TICKERS_URL}"
    res = with_breaker { @conn.get(COMPANY_TICKERS_URL) }
    raw = res.body
    Rails.logger.info "[edgar_client] company_tickers response: status=#{res.status} " \
                      "content-encoding=#{res.headers['content-encoding'].inspect} " \
                      "body_class=#{raw.class} body_size=#{raw.to_s.bytesize}"
    if raw.is_a?(String) && raw.byteslice(0, 2) == "\x1F\x8B".b
      # Defense in depth: if the gzip middleware missed it (e.g. the
      # SEC dropped Content-Encoding), fall back to a direct decode.
      Rails.logger.warn '[edgar_client] body still gzipped after middleware — decoding manually'
      Zlib::GzipReader.new(StringIO.new(raw)).read
    else
      raw
    end
  end

  def index_by_ticker(raw)
    result = {}
    raw.each do |_idx, entry|
      next unless entry['ticker'].present? && entry['cik_str'].present?

      result[entry['ticker'].to_s.upcase] = format('%010d', entry['cik_str'].to_i)
    end
    result
  end

  def submissions_for(cik)
    cik_padded = cik.to_s.rjust(10, '0')
    cache_key = "edgar:submissions:#{cik_padded}"
    Rails.cache.fetch(cache_key, expires_in: SUBMISSIONS_TTL) do
      with_breaker { @conn.get("#{BASE_URL}/submissions/CIK#{cik_padded}.json").body }
    end
  end

  def filing_xml(cik, filing)
    cik_no_zeros = cik.to_s.sub(/\A0+/, '')
    cik_no_zeros = '0' if cik_no_zeros.empty?
    accession_dashes = filing[:accession].to_s.tr('-', '')
    # SEC submissions JSON reports the STYLESHEET path as `primaryDocument`,
    # e.g. "xslF345X06/form4.xml" or "xslF345X06/wk-form4_1787607122.xml".
    # The XSLT stylesheet renders that as the human-readable HTML filing,
    # but the underlying STRUCTURED XML lives one directory up, at the
    # same filename without the `xsl*` prefix. We want the XML, not the
    # HTML — the regex parser needs `<ownershipTransaction>` blocks.
    primary = filing[:primary_document].to_s.sub(%r{\Axsl[A-Z0-9]+/}, '')

    cache_key = "edgar:filing:#{cik}:#{accession_dashes}:#{primary}"
    Rails.cache.fetch(cache_key, expires_in: FILING_TTL) do
      url = "#{ARCHIVES_URL}/edgar/data/#{cik_no_zeros}/#{accession_dashes}/#{primary}"
      with_breaker { @conn.get(url).body }
    end
  end

  # Form 4 XML parsing.
  #
  # The actual SEC Form 4 XML (schema X0609) uses two transaction
  # wrappers around the same inner shape:
  #
  #   <nonDerivativeTable>
  #     <nonDerivativeTransaction>
  #       <transactionDate><value>2024-01-15</value></transactionDate>
  #       <transactionCoding><transactionCode>P</transactionCode></transactionCoding>
  #       <transactionAmounts>
  #         <transactionShares><value>5000</value></transactionShares>
  #         <transactionPricePerShare><value>190.50</value></transactionPricePerShare>
  #       </transactionAmounts>
  #     </nonDerivativeTransaction>
  #   </nonDerivativeTable>
  #
  #   <derivativeTable>
  #     <derivativeTransaction> ...same inner shape... </derivativeTransaction>
  #   </derivativeTable>
  #
  # Common stock purchases live in <nonDerivativeTransaction>; options
  # exercises and other derivatives live in <derivativeTransaction>.
  # We capture both because the insider-buying signal should include
  # both, and the transaction code 'P' (open-market purchase) is the
  # same in both wrappers.
  def parse_form4_buys(xml, reporter: nil)
    return [] if xml.blank?

    # Use a lightweight regex scan — Form 4s are large (often 5-10 MB
    # for funds) but we only need a handful of fields. A full
    # Nokogiri parse would work but pulls more into memory.
    text = xml.to_s

    # The SEC submissions JSON's `recent.reportingPerson` is often nil
    # (it's a parallel-array column that gets truncated in the recent
    # snapshot). The actual reporter name lives in the XML under
    # <reportingOwnerId><rptOwnerName>. Prefer the XML value when
    # available.
    xml_reporter = text[%r{<rptOwnerName>\s*([^<]+?)\s*</rptOwnerName>}m, 1]
    effective_reporter = xml_reporter.presence || reporter

    # Match each <nonDerivativeTransaction>...</nonDerivativeTransaction>
    # and <derivativeTransaction>...</derivativeTransaction> block.
    blocks = text.scan(%r{<nonDerivativeTransaction>(.*?)</nonDerivativeTransaction>}m) +
             text.scan(%r{<derivativeTransaction>(.*?)</derivativeTransaction>}m)

    blocks.flat_map do |block,|
      code = block[/<transactionCode>\s*([^<]+)\s*</, 1]&.strip
      next [] unless code == 'P'  # 'P' = open-market purchase

      shares = parse_decimal(block, %r{<transactionShares>\s*<value>\s*([^<]+)\s*</}, fallback: 0.0)
      price  = parse_decimal(block, %r{<transactionPricePerShare>\s*<value>\s*([^<]+)\s*</}, fallback: 0.0)
      next [] if shares <= 0

      date_str = block[/<transactionDate>\s*<value>\s*([^<]+)\s*</, 1]&.strip
      value = (shares * price).round(2)

      [{
        insider: effective_reporter,
        transaction_date: date_str,
        shares: shares,
        price_per_share: price,
        value_usd: value
      }]
    end
  rescue StandardError => e
    Rails.logger.warn "[edgar_client] Form 4 parse failed: #{e.class}: #{e.message}"
    []
  end

  def parse_decimal(text, pattern, fallback:)
    raw = text[pattern, 1]
    return fallback if raw.blank?

    raw.to_f
  rescue StandardError
    fallback
  end

  def with_breaker
    CIRCUIT_BREAKERS.fetch(:edgar).call { yield }
  end
end
