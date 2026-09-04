# frozen_string_literal: true

# Mcp::Response — unwraps the wrapped JSON payloads that the Alpaca MCP
# server returns from every data tool. Every tool we use returns:
#
#   {
#     "_alpaca_mcp_security": { trust:, tool_name:, risk:, instructions: },
#     "data": { <shape varies by tool> }
#   }
#
# The `data` value shape depends on the tool:
#   - get_all_assets:           { "result": [asset, asset, ...] }
#   - get_stock_bars:           { "bars": { "SPY": [bar, bar, ...] } }
#   - get_news:                 { "news": [item, item, ...], "next_page_token": ... }
#   - get_stock_snapshot:       { "SPY": { dailyBar:, latestQuote:, ... } }
#   - get_stock_latest_quote:   { "quotes": { "SPY": {...} } }
#   - get_option_chain:         { "snapshots": { "SPY...C00450000": {...} } }
#   - get_option_contracts:     { ... }
#   - get_clock:                { timestamp:, is_open:, ... }
#
# This helper unwraps that envelope and returns the "interesting" data
# for each known tool. Unknown tools fall back to a recursive search
# for the first Array of hashes.

module Mcp
  class Response
    # The `_alpaca_mcp_security` envelope key used by the Alpaca MCP
    # server. Exposed for tests and for callers that want to inspect
    # the security metadata.
    ENVELOPE_KEY = "_alpaca_mcp_security".freeze

    # Tool-specific extractors. Each takes the parsed `data` Hash and
    # returns the meaningful payload (or nil).
    EXTRACTORS = {
      "get_all_assets"         => ->(data) { data["result"] },
      "get_stock_bars"         => ->(data) { data["bars"] },
      "get_news"               => ->(data) { data["news"] },
      "get_stock_snapshot"     => ->(data) { data }, # keyed by ticker; return whole hash
      "get_stock_latest_quote" => ->(data) { data["quotes"] },
      "get_stock_latest_trade" => ->(data) { data["trades"] },
      "get_stock_latest_bar"   => ->(data) { data["bars"] },
      "get_option_chain"       => ->(data) { data["snapshots"] },
      "get_option_contracts"   => ->(data) { data },
      "get_option_snapshot"    => ->(data) { data["snapshots"] },
      "get_option_bars"        => ->(data) { data["bars"] },
      "get_account_info"       => ->(data) { data },
      "get_clock"              => ->(data) { data },
      "get_calendar"           => ->(data) { data }
    }.freeze

    # The wrapped content returned by `tool.call(...)`. Either the raw
    # MCP::Content (with a `.text` JSON string) or a Hash with an
    # `:error` key when the tool returned a structured error.
    def self.unwrap(content, tool_name: nil)
      return nil if content.nil?
      return content if structured_error?(content)

      parsed = parse_text(extract_text(content))
      return nil if parsed.nil?
      return parsed unless parsed.is_a?(Hash)

      extract_data(parsed, tool_name)
    rescue JSON::ParserError
      nil
    end

    def self.structured_error?(content)
      content.is_a?(Hash) && content.key?(:error)
    end

    def self.extract_text(content)
      content.is_a?(String) ? content : content.text
    end

    def self.parse_text(text)
      return nil if text.nil? || text.empty?

      JSON.parse(text)
    end

    def self.extract_data(parsed, tool_name)
      data = parsed["data"] || parsed
      extractor = tool_name && EXTRACTORS[tool_name]
      return extractor.call(data) if extractor

      # Fallback: find the first Array value at any depth, or return
      # the whole `data` hash if nothing looks like a list.
      find_array(data) || data
    end

    # Recursively walk the structure and return the first Array value.
    # Used as the fallback for tools without a registered extractor.
    def self.find_array(obj)
      case obj
      when Array
        obj if !obj.empty? # first array we hit
      when Hash
        obj.each do |_k, v|
          found = find_array(v)
          return found if found
        end
        nil
      end
    end
  end
end
