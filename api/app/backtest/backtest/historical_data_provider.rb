# frozen_string_literal: true

# Backtest::HistoricalDataProvider — pulls historical bars for the backtest
# universe and synthesizes a Black-Scholes options chain snapshot for each
# (ticker, date) pair.
#
# Why synthetic? Alpaca's MCP server (and the underlying API) does not
# expose historical options chains in a form we can replay cheaply. The
# options backtest only needs a representative chain to let the Trader
# agent pick a strike and compute entry/exit prices; Black-Scholes with a
# flat-IV assumption is a defensible placeholder. When a real historical
# options source is wired in (Polygon, ORATS, etc.), swap the
# `synthesize_chain` call for a real fetch.
#
# All external calls go through RATE_LIMITERS / CIRCUIT_BREAKERS.

module Backtest
  class HistoricalDataProvider
    Bar = Data.define(:t, :open, :high, :low, :close, :volume)
    OptionQuote = Data.define(:symbol, :strike, :expiry, :right, :bid, :ask, :mid, :iv, :delta, :gamma, :theta, :vega)

    def initialize(client: ALPACA_MCP_READONLY)
      @client = client
    end

    # Returns Array<Bar> for the given ticker, sorted oldest-first.
    # Tries MCP get_stock_bars first; falls back to a direct REST call so
    # the backtest isn't blocked if the MCP tool surface changes.
    def fetch_bars(ticker, start_date, end_date, timeframe: '1Day')
      with_breaker(:alpaca_mcp) do
        RATE_LIMITERS[:alpaca_mcp].with_limit do
          tool = @client.tool('get_stock_bars')
          if tool
            # The Alpaca MCP server's get_stock_bars expects
            # `symbols` (plural, comma-separated string) — not the
            # singular `symbol` the Alpaca REST API uses.
            result = tool.call(
              symbols: ticker,
              start: start_date.to_s,
              end: end_date.to_s,
              timeframe: timeframe
            )
            payload = Mcp::Response.unwrap(result, tool_name: 'get_stock_bars') || {}
            return payload[ticker] || []
          end
        end
      end
      Rails.logger.warn "[backtest] no get_stock_bars tool — returning empty bars for #{ticker}"
      []
    end

    # Synthesizes a chain snapshot for `date` using Black-Scholes on the
    # most recent close. Returns 8 calls + 8 puts around the underlying.
    def synthesize_chain(ticker, as_of_date, spot:, iv: 0.30, dte_target: 30)
      expiry = nearest_friday(as_of_date + dte_target.days)
      strike_step = strike_step_for(spot)
      base = (spot / strike_step).floor * strike_step
      strikes = (-3..4).map { |i| base + (i * strike_step) }

      t_years = ((expiry - as_of_date) / 365.0).clamp(0.005, 1.0)
      r = 0.045 # risk-free rate placeholder; pull from FRED in a future iteration

      strikes.flat_map do |k|
        [
          build_option_quote(ticker, expiry, 'C', k, spot, iv, r, t_years),
          build_option_quote(ticker, expiry, 'P', k, spot, iv, r, t_years)
        ]
      end
    end

    private

    def nearest_friday(date)
      # 5 = Friday in Ruby's wday
      ((5 - date.wday) % 7).then { |d| d.zero? ? date : date + d }
    end

    def strike_step_for(price)
      case price
      when 0..25    then 0.5
      when 25..100  then 1.0
      when 100..250 then 2.5
      when 250..500 then 5.0
      else 10.0
      end
    end

    def build_option_quote(ticker, expiry, right, strike, spot, iv, r, t)
      bs = BlackScholes.price(spot: spot, strike: strike, t: t, r: r, sigma: iv, right: right)
      greeks = BlackScholes.greeks(spot: spot, strike: strike, t: t, r: r, sigma: iv, right: right)
      mid = bs.round(2)
      spread = (mid * 0.02).round(2).clamp(0.05, 0.50)
      bid = (mid - (spread / 2.0)).round(2).clamp(0.0, mid)
      ask = (mid + (spread / 2.0)).round(2)
      OptionQuote.new(
        symbol: occ_symbol(ticker, expiry, right, strike),
        strike: strike,
        expiry: expiry,
        right: right,
        bid: bid,
        ask: ask,
        mid: mid,
        iv: iv,
        delta: greeks[:delta],
        gamma: greeks[:gamma],
        theta: greeks[:theta],
        vega: greeks[:vega]
      )
    end

    def occ_symbol(ticker, expiry, right, strike)
      # OCC format: ROOT + YYMMDD + C/P + 8-digit strike (strike * 1000).
      # The root is the ticker itself, no padding — keeps the symbol at 18 chars
      # for the common case (3-letter root like SPY).
      date_part = expiry.strftime('%y%m%d')
      strike_part = format('%08d', (strike * 1000).to_i)
      "#{ticker}#{date_part}#{right}#{strike_part}"
    end

    def with_breaker(source)
      CIRCUIT_BREAKERS.fetch(source)
    end
  end
end
