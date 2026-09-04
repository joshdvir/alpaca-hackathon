# frozen_string_literal: true

require "rails_helper"

# Verifies the TickerSelector::UniverseProvider uses the right
# ruby_llm-mcp 1.0+ API:
#   client.tool("name")            — fetch the tool
#   tool.call(**kwargs)            — invoke it
#   result.text                    — read the JSON response
#
# (Earlier code used client.call_tool which is not in this gem version
# and crashed at runtime with NoMethodError.)
# rubocop:disable Metrics/BlockLength
RSpec.describe TickerSelector::UniverseProvider do
  describe ".fetch" do
    let(:fake_tool) { instance_double(RubyLLM::MCP::Tool) }
    let(:fake_client) { instance_double(RubyLLM::MCP::Client) }
    # The Alpaca MCP server wraps the response as
    #   { "_alpaca_mcp_security": {...metadata...}, "data": { "result": [assets...] } }
    # `has_options` lives INSIDE the asset's `attributes` array, not as a
    # top-level boolean. Each optionable asset has `'has_options'` in
    # its `attributes` array.
    let(:assets_payload) do
      {
        '_alpaca_mcp_security' => { 'trust' => 'untrusted_tool_output' },
        'data' => {
          'result' => [
            { 'symbol' => 'AAPL', 'name' => 'Apple', 'tradable' => true, 'attributes' => ['has_options'] },
            { 'symbol' => 'MSFT', 'name' => 'Microsoft', 'tradable' => true, 'attributes' => ['has_options'] },
            { 'symbol' => 'BTC/USD', 'name' => 'Bitcoin', 'tradable' => true, 'attributes' => ['has_options'] } # filtered: contains '/'
          ]
        }
      }.to_json
    end
    let(:fake_content) { instance_double(RubyLLM::MCP::Content, text: assets_payload) }

    before do
      stub_const('ALPACA_MCP_READONLY', fake_client)
      Rails.cache.clear # ensure the cache sees a miss for each test
      # The .fetch tests exercise the MCP asset list path; the manual
      # `ticker_selector.universe.manual_tickers` override (used in
      # production for the hackathon) would short-circuit fetch and
      # bypass the MCP stubs.
      allow(described_class).to receive(:manual_tickers).and_return([])
      allow(fake_client).to receive(:tool).with('get_all_assets').and_return(fake_tool)
      allow(fake_tool).to receive(:call).and_return(fake_content)
    end

    it "fetches the tool by name and invokes it with the ASSET_QUERY hash" do
      expect(fake_client).to receive(:tool).with('get_all_assets').and_return(fake_tool)
      # `attributes: ['has_options']` is a server-side filter so the
      # MCP only returns optionable tickers. We always pass it. Note:
      # `tradable: true` is intentionally NOT in this query — the
      # upstream `get-v2-assets` endpoint doesn't accept it (and the
      # MCP logs a WARNING + silently drops unknown params).
      expected_query = {
        asset_class: 'us_equity',
        status: 'active',
        attributes: %w[has_options]
      }
      expect(fake_tool).to receive(:call).with(expected_query).and_return(fake_content)

      result = described_class.fetch
      expect(result).to eq(%w[AAPL MSFT])
    end

    it "filters out symbols containing '/'" do
      result = described_class.fetch
      expect(result).not_to include('BTC/USD')
    end

    it "filters out symbols longer than 5 chars" do
      long_payload = { 'data' => { 'result' => [{ 'symbol' => 'TOOLONGGGG', 'attributes' => ['has_options'] }] } }.to_json
      allow(fake_content).to receive(:text).and_return(long_payload)
      expect(described_class.fetch).to be_empty
    end

    it "filters out blank symbols" do
      blank_payload = { 'data' => { 'result' => [
        { 'symbol' => nil, 'attributes' => ['has_options'] },
        { 'symbol' => '', 'attributes' => ['has_options'] }
      ] } }.to_json
      allow(fake_content).to receive(:text).and_return(blank_payload)
      expect(described_class.fetch).to be_empty
    end

    it "filters out assets whose attributes array doesn't include 'has_options' (defense in depth)" do
      mixed_payload = { 'data' => { 'result' => [
        { 'symbol' => 'AAPL', 'attributes' => ['has_options', 'overnight_tradable'] },
        { 'symbol' => 'NOOPT', 'attributes' => ['fractional_eh_enabled'] },
        { 'symbol' => 'MISSG', 'attributes' => [] },
        { 'symbol' => 'NULL' } # attributes missing entirely
      ] } }.to_json
      allow(fake_content).to receive(:text).and_return(mixed_payload)
      expect(described_class.fetch).to eq(%w[AAPL])
    end

    it "returns an empty array if the tool is missing" do
      allow(fake_client).to receive(:tool).with('get_all_assets').and_return(nil)
      expect(described_class.fetch).to eq([])
    end

    it "returns an empty array if the response is not JSON" do
      allow(fake_content).to receive(:text).and_return('not json {{')
      expect(described_class.fetch).to eq([])
    end

    it "tolerates a bare array response (no wrapper)" do
      bare_payload = [
        { 'symbol' => 'AAPL', 'attributes' => ['has_options'] },
        { 'symbol' => 'MSFT', 'attributes' => ['has_options'] }
      ].to_json
      allow(fake_content).to receive(:text).and_return(bare_payload)
      expect(described_class.fetch).to eq(%w[AAPL MSFT])
    end

    it "tolerates an empty data hash" do
      allow(fake_content).to receive(:text).and_return('{"data":{}}')
      expect(described_class.fetch).to eq([])
    end

    it "tolerates an empty result array" do
      allow(fake_content).to receive(:text).and_return('{"data":{"result":[]}}')
      expect(described_class.fetch).to eq([])
    end

    context "when manual_tickers is configured in trading.yml" do
      it "composes manual + MCP universe with manual_tickers first and deduped" do
        # Manual list comes first, then any MCP names not already in manual.
        allow(described_class).to receive(:manual_tickers).and_return(%w[AAPL MSFT NVDA])
        # The MCP returns 4 names; 2 overlap with manual. The output
        # should be manual (3) + the 2 non-overlapping MCP names, in that
        # order, deduped.
        mcp_payload = [
          { 'symbol' => 'AAPL',  'attributes' => ['has_options'] }, # dup
          { 'symbol' => 'TSLA',  'attributes' => ['has_options'] },
          { 'symbol' => 'GOOGL', 'attributes' => ['has_options'] },
          { 'symbol' => 'AMZN',  'attributes' => ['has_options'] }
        ]
        allow(fake_client).to receive(:tool).with('get_all_assets').and_return(fake_tool)
        allow(fake_tool).to receive(:call).and_return(fake_content)
        bare_payload = { 'data' => { 'result' => mcp_payload } }.to_json
        allow(fake_content).to receive(:text).and_return(bare_payload)

        result = described_class.fetch
        # Manual_tickers first (priority), then MCP names that aren't
        # already in manual. AAPL is in both → appears once, at the
        # manual position.
        expect(result).to eq(%w[AAPL MSFT NVDA TSLA GOOGL AMZN])
      end

      it "dedupes overlapping tickers between manual and MCP" do
        allow(described_class).to receive(:manual_tickers).and_return(%w[AAPL MSFT])
        mcp_payload = [
          { 'symbol' => 'AAPL', 'attributes' => ['has_options'] },
          { 'symbol' => 'TSLA', 'attributes' => ['has_options'] }
        ]
        allow(fake_client).to receive(:tool).with('get_all_assets').and_return(fake_tool)
        allow(fake_tool).to receive(:call).and_return(fake_content)
        allow(fake_content).to receive(:text).and_return({ 'data' => { 'result' => mcp_payload } }.to_json)

        result = described_class.fetch
        expect(result).to eq(%w[AAPL MSFT TSLA])
      end
    end
  end

  describe ".meets_guardrails?" do
    it "returns false for a blank symbol" do
      expect(described_class.meets_guardrails?('symbol' => nil, 'attributes' => ['has_options'])).to be false
      expect(described_class.meets_guardrails?('symbol' => '', 'attributes' => ['has_options'])).to be false
    end

    it "returns false for a symbol with a slash (e.g. crypto pairs)" do
      expect(described_class.meets_guardrails?('symbol' => 'BTC/USD', 'attributes' => ['has_options'])).to be false
    end

    it "returns false for symbols longer than 5 chars" do
      expect(described_class.meets_guardrails?('symbol' => 'TOOLONGGGG', 'attributes' => ['has_options'])).to be false
    end

    it "returns true for a plain equity symbol with has_options in attributes" do
      expect(described_class.meets_guardrails?('symbol' => 'AAPL', 'attributes' => ['has_options'])).to be true
    end

    it "returns false when the asset is missing the 'symbol' key entirely" do
      expect(described_class.meets_guardrails?({})).to be false
    end

    it "returns false when 'has_options' is missing from attributes (this is an options trading system)" do
      expect(described_class.meets_guardrails?('symbol' => 'AAPL', 'attributes' => ['fractional_eh_enabled'])).to be false
      expect(described_class.meets_guardrails?('symbol' => 'AAPL', 'attributes' => [])).to be false
    end

    it "returns false when the attributes key is missing entirely" do
      expect(described_class.meets_guardrails?('symbol' => 'AAPL')).to be false
    end
  end
end
# rubocop:enable Metrics/BlockLength
