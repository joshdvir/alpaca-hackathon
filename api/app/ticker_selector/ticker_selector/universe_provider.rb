# frozen_string_literal: true

# Wraps the MCP `get_all_assets` call to produce the candidate universe.
# We pull tradable US equities from Alpaca with listed options, then apply
# guardrails to filter out illiquid or non-tradable names.

module TickerSelector
  class UniverseProvider
    # `attributes: ['has_options']` is a SERVER-SIDE filter — the MCP only
    # returns assets that have listed options. This is the right gate for
    # an options-trading system: no options → not a candidate, period.
    # We still double-check the `has_options` field in `meets_guardrails?`
    # as a defense-in-depth against any MCP that doesn't honor the filter.
    #
    # NOTE: `tradable: true` is intentionally NOT in this query. The
    # upstream Alpaca `get-v2-assets` endpoint does NOT accept `tradable`
    # as a query param (it's a response field, not a filter). When the
    # MCP sees an unknown param it logs a WARNING and silently drops it
    # — so the filter "works" but pollutes the log. The combination of
    # `status: 'active'` + `attributes: ['has_options']` covers the
    # practical intent ("tradable optionable US equities") without the
    # unknown-param warning.
    ASSET_QUERY = {
      asset_class: 'us_equity',
      status: 'active',
      attributes: %w[has_options]
    }.freeze

    GUARDRAILS = TradingConfig.fetch(:ticker_selector, :guardrails).freeze

    # TTL for the get_all_assets cache. The asset list rarely changes
    # minute-to-minute, and the response is ~6 MB, so a 15-minute
    # cache is a major win during bursty refreshes.
    CACHE_TTL = 15.minutes

    # Returns Array<String> of tickers that pass the guardrails.
    #
    # Composition (in priority order):
    #   1. `manual_tickers` (curated in trading.yml) — ALWAYS included
    #      and processed first, so the filter engine and the watchlist
    #      always see the operator's picks. Manual tickers bypass the
    #      MCP universe source; they're operator-defined.
    #   2. The MCP asset universe, capped to `max_size` for rate-limit
    #      sanity. The MCP returns ~6,300 names alphabetically so the
    #      first 200 are OTC garbage; ranking by dollar volume on a
    #      paid tier would be a better source.
    #
    # Manual tickers are first in the returned list so the fan-out
    # activity allocates filter chunks with them at the head — they
    # have priority over the broader universe.
    def self.fetch
      manual = manual_tickers

      # The asset list rarely changes minute-to-minute, and the
      # response is ~6 MB, so a 15-minute cache is a major win during
      # bursty refreshes. Backed by Solid Cache (Rails.cache) so
      # fetch_universe and any future caller share the same row.
      cache_key = "mcp:#{Digest::SHA1.hexdigest("get_all_assets|#{ASSET_QUERY.inspect}")}"
      assets = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        tool = ALPACA_MCP_READONLY.tool('get_all_assets')
        next [] unless tool

        # ruby_llm-mcp 1.0+ exposes tools via client.tool(name); the tool
        # is invoked via tool.call(hash) (RubyLLM::Tool#call takes a single
        # hash arg) and returns an MCP::Content whose .text is the JSON
        # payload the server returned.
        result = tool.call(ASSET_QUERY)
        Array(Mcp::Response.unwrap(result, tool_name: 'get_all_assets'))
      end

      mcp_symbols = assets.filter_map { |a| a['symbol'] if meets_guardrails?(a) }
      cap = max_size
      if mcp_symbols.size > cap
        Rails.logger.warn "[ticker_selector] universe has #{mcp_symbols.size} MCP tickers, capping to first #{cap} (free-tier MCP rate limit)"
        mcp_symbols = mcp_symbols.first(cap)
      end

      # Compose: manual_tickers first (priority), then MCP universe,
      # deduped so a ticker in both lists appears once and stays at
      # its highest-priority position (manual).
      composed = []
      seen = {}
      Array(manual).each do |t|
        next if t.blank? || seen[t]
        composed << t
        seen[t] = true
      end
      mcp_symbols.each do |t|
        next if t.blank? || seen[t]
        composed << t
        seen[t] = true
      end

      Rails.logger.info(
        "[ticker_selector] universe: manual=#{manual.size} mcp=#{mcp_symbols.size} " \
        "composed=#{composed.size} cap=#{cap}"
      )
      composed
    end

    def self.meets_guardrails?(asset)
      return false unless asset.is_a?(Hash)

      symbol = asset['symbol']
      return false if symbol.blank?
      return false if symbol.include? '/'
      return false if symbol.length > 5
      # `has_options` lives INSIDE the asset's `attributes` array, not as
      # a top-level field. E.g. `{ symbol: "AAPL", attributes: ["has_options", ...] }`.
      # The MCP's `attributes: ['has_options']` query param is honored at the
      # server, but the response shape puts the value inside the array, so
      # we have to look there.
      return false if require_options? && !Array(asset['attributes']).include?('has_options')

      true
    end

    # Whether the universe should only include optionable tickers.
    # Defaults to true (this IS an options trading system after all);
    # set `ticker_selector.guardrails.options_chain_required: false`
    # in trading.yml to disable.
    def self.require_options?
      GUARDRAILS.fetch('options_chain_required', true) != false
    end

    # Hard cap on how many symbols we keep in the universe. The full
    # optionable universe is ~6,300 names; with 200 req/min on the
    # free tier, processing all of them is impractical. We keep the
    # first N (alphabetical) so a workflow cycle can finish in a few
    # minutes. Read from `ticker_selector.universe.max_size` in
    # trading.yml (default 500 — conservative for a 5-min cycle).
    def self.max_size
      config = TradingConfig.fetch(:ticker_selector, :universe) || {}
      # YAML keys load as symbols (the project's TradingConfig uses
      # `with_indifferent_access` for some paths but not all), so
      # check both string and symbol forms.
      Integer(config[:max_size] || config['max_size'] || 500)
    end

    # Read the curated `manual_tickers` list from trading.yml. When
    # present and non-empty, `fetch` uses this list INSTEAD of the
    # MCP asset list. See the comment in `fetch` for why.
    def self.manual_tickers
      config = TradingConfig.fetch(:ticker_selector, :universe) || {}
      list = config[:manual_tickers] || config['manual_tickers']
      Array(list).map(&:to_s).reject(&:empty?)
    end
  end
end
