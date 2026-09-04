# frozen_string_literal: true

# TradingView MCP client setup.
# Mirrors `alpaca_mcp.rb` but lazy-instantiates so a missing/unhealthy
# TradingView container doesn't crash boot — the overnight_reversal
# strategy (the only current caller) logs a warn and falls back to
# Alpaca bars when the server is down.
#
# Both servers expose different tool sets:
#   - Alpaca MCP: place_option_order, get_stock_bars, get_option_chain, …
#   - TradingView MCP: top_gainers, top_losers, screen_stocks, yahoo_price, …
#
# We register a single client at `TRADINGVIEW_MCP` for read-only market
# screening. No write tools exist upstream, so a separate trading client
# is unnecessary.
#
# The server URL is read from `trading.yml#mcp.servers[].url` where
# the `name: tradingview` entry lives. We resolve it at initialization
# time so a config change (server moved, port changed) only requires a
# reload — not a code change.

require 'ruby_llm/mcp'

# Resolve the TradingView server URL from the mcp.servers config. We
# tolerate a missing or disabled server (returns nil) — callers fall
# back gracefully.
TRADINGVIEW_MCP_URL = begin
  servers = TradingConfig.fetch(:mcp, :servers) || []
  entry = servers.find { |s| s[:name].to_s == 'tradingview' }
  entry && entry[:enabled] != false ? entry[:url].to_s : nil
rescue StandardError
  nil
end

# Lazy client — instance only on first call so boot succeeds when the
# TradingView container is offline.
TRADINGVIEW_MCP = Class.new do
  def initialize
    @client = nil
  end

  def client
    @client ||= begin
      raise 'tradingview MCP not configured (mcp.servers: tradingview entry missing or disabled)' if TRADINGVIEW_MCP_URL.to_s.empty?

      RubyLLM::MCP.client(
        name: 'tradingview',
        transport_type: :streamable,
        # The upstream's screener calls take 3-10 s round trips (Yahoo +
        # TradingView public endpoints). The MCP gem reads
        # `request_timeout` from the top-level kwargs (NOT from inside
        # `config:` — see MCP::Client#initialize in ruby_llm-mcp). The
        # default 8 s truncates the screener; bump to 60 s.
        request_timeout: 60_000,
        config: { url: TRADINGVIEW_MCP_URL }
      )
    end
  end

  # Return the named tool, or nil if the server is down. Catches the
  # boot-time connection failures that RubyLLM::MCP raises when the
  # upstream is unreachable so the calling activity can fall back.
  def tool(name)
    client.tool(name.to_s)
  rescue StandardError => e
    Rails.logger.warn "[tradingview_mcp] tool #{name} unavailable: #{e.class}: #{e.message[0, 200]}"
    nil
  end
end.new

Rails.application.config.after_initialize do
  if TRADINGVIEW_MCP_URL.to_s.empty?
    Rails.logger.warn '[tradingview_mcp] server not configured; screening will fall back to Alpaca bars'
  else
    begin
      size = TRADINGVIEW_MCP.client.tools.size
      Rails.logger.info "[tradingview_mcp] url=#{TRADINGVIEW_MCP_URL} tools=#{size}"
    rescue StandardError => e
      Rails.logger.warn "[tradingview_mcp] boot healthcheck failed (#{e.class}: #{e.message[0, 200]}); tool calls will retry on first use"
    end
  end
end
