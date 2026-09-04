# frozen_string_literal: true

# MarketClock — single source of truth for "is the market open right now".
#
# Wraps the Alpaca MCP `get_clock` call. Caches the result for
# `CACHE_TTL` to avoid hammering the broker on every order
# submission. The TTL is short (1 min) so a market-open transition
# is reflected within a minute.
#
# Used by:
#   - PortfolioManager#execute to gate order submissions
#   - AlpacaSync to know whether to sync positions / open orders
#     (some data is only meaningful during market hours)
#
# During off-hours the broker queues orders or rejects them
# outright. The gate keeps us from generating a pile of "new"
# orders on a Sunday that all get rejected Monday morning.

class MarketClock
  CACHE_TTL = 60.seconds

  Clock = Data.define(:open, :next_open_at, :next_close_at, :timestamp, :source) do
    # `Data.define` doesn't auto-generate `?` predicates, so we add
    # one for `open`. This lets callers say `clock.open?` instead of
    # `clock.open` (which reads like an attribute access, not a check).
    def open? = open
  end

  class << self
    # @return [Clock] cached or fresh clock snapshot
    def current
      cached = Rails.cache.read(cache_key)
      return cached if cached.present?

      fresh = fetch
      Rails.cache.write(cache_key, fresh, expires_in: CACHE_TTL)
      fresh
    end

    # Force a refresh — used by the sync job on every cycle and by
    # tests. Don't call from the hot path; use `.current` instead.
    def refresh!
      Rails.cache.delete(cache_key)
      current
    end

    # If the market is closed and we have a known next_open, returns
    # the seconds until the next open. nil if the market is open.
    def seconds_until_next_open
      c = current
      return nil if c.open
      return nil unless c.next_open_at

      (c.next_open_at - Time.current).to_f.clamp(0, 7.days.to_f)
    end

    private

    def cache_key
      "market_clock:current"
    end

    def fetch
      tool = ALPACA_MCP_TRADING.tool("get_clock")
      return default_offline if tool.nil?

      raw = tool.call({})
      text = if raw.is_a?(Array)
               raw.first&.respond_to?(:text) ? raw.first.text : raw.first.to_s
             elsif raw.respond_to?(:text)
               raw.text
             else
               raw.to_s
             end
      parsed = JSON.parse(text.to_s)
      data = parsed.is_a?(Hash) ? (parsed["data"] || parsed) : {}

      Clock.new(
        open:          data["is_open"] == true,
        next_open_at:  parse_time(data["next_open"]),
        next_close_at: parse_time(data["next_close"]),
        timestamp:     parse_time(data["timestamp"]) || Time.current,
        source:        "alpaca"
      )
    rescue StandardError => e
      Rails.logger.warn "[market_clock] fetch failed: #{e.class}: #{e.message[0,200]}"
      default_offline
    end

    def default_offline
      # If the broker is unreachable we DON'T pretend the market is
      # open — that would let orders through. Treat as closed and
      # surface a clear source. PortfolioManager will defer.
      Clock.new(
        open: false,
        next_open_at: nil,
        next_close_at: nil,
        timestamp: Time.current,
        source: "offline"
      )
    end

    def parse_time(s)
      return nil if s.blank?
      Time.zone.parse(s.to_s)
    rescue StandardError
      nil
    end
  end
end
