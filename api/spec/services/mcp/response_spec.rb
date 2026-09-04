# frozen_string_literal: true

require "rails_helper"

# rubocop:disable Metrics/BlockLength
RSpec.describe Mcp::Response do
  describe ".unwrap" do
    it "returns nil for nil content" do
      expect(described_class.unwrap(nil)).to be_nil
    end

    it "returns the content unchanged if it's a structured :error hash" do
      err = { error: "Tool execution error: foo" }
      expect(described_class.unwrap(err)).to be(err)
    end

    it "parses JSON from a String" do
      expect(described_class.unwrap('{"a":1}')).to eq('a' => 1)
    end

    it "parses JSON from MCP::Content#text" do
      content = instance_double(RubyLLM::MCP::Content, text: '{"a":1}')
      expect(described_class.unwrap(content)).to eq('a' => 1)
    end

    it "returns nil for empty text" do
      content = instance_double(RubyLLM::MCP::Content, text: '')
      expect(described_class.unwrap(content)).to be_nil
    end

    it "returns nil for non-JSON text" do
      content = instance_double(RubyLLM::MCP::Content, text: 'not json {{')
      expect(described_class.unwrap(content)).to be_nil
    end

    context "with a tool_name extractor" do
      let(:envelope) do
        {
          '_alpaca_mcp_security' => { 'trust' => 'untrusted_tool_output' },
          'data' => { 'result' => [{ 'symbol' => 'AAPL' }] }
        }
      end

      it "extracts data.result for get_all_assets" do
        result = described_class.unwrap(envelope.to_json, tool_name: 'get_all_assets')
        expect(result).to eq([{ 'symbol' => 'AAPL' }])
      end

      it "extracts data.bars for get_stock_bars" do
        env = { 'data' => { 'bars' => { 'SPY' => [{ 'c' => 1.0 }] } } }
        result = described_class.unwrap(env.to_json, tool_name: 'get_stock_bars')
        expect(result).to eq('SPY' => [{ 'c' => 1.0 }])
      end

      it "extracts data.news for get_news" do
        env = { 'data' => { 'news' => [{ 'id' => 1 }] } }
        result = described_class.unwrap(env.to_json, tool_name: 'get_news')
        expect(result).to eq([{ 'id' => 1 }])
      end

      it "extracts data.quotes for get_stock_latest_quote" do
        env = { 'data' => { 'quotes' => { 'SPY' => { 'ap' => 1.0 } } } }
        result = described_class.unwrap(env.to_json, tool_name: 'get_stock_latest_quote')
        expect(result).to eq('SPY' => { 'ap' => 1.0 })
      end

      it "extracts data.snapshots for get_option_chain" do
        env = { 'data' => { 'snapshots' => { 'SPY260831C00420000' => { 'delta' => 0.5 } } } }
        result = described_class.unwrap(env.to_json, tool_name: 'get_option_chain')
        expect(result).to eq('SPY260831C00420000' => { 'delta' => 0.5 })
      end
    end

    context "without a tool_name (fallback)" do
      it "finds the first Array value in nested Hash" do
        env = { 'data' => { 'result' => [{ 'a' => 1 }] } }
        result = described_class.unwrap(env.to_json)
        expect(result).to eq([{ 'a' => 1 }])
      end

      it "returns the whole data Hash if no Array is found" do
        env = { 'data' => { 'foo' => 'bar' } }
        result = described_class.unwrap(env.to_json)
        expect(result).to eq('foo' => 'bar')
      end

      it "returns the raw parsed value if it's already an Array" do
        result = described_class.unwrap('[{"a":1}]')
        expect(result).to eq([{ 'a' => 1 }])
      end
    end
  end

  describe ".find_array" do
    it "returns the array if the input is an Array" do
      expect(described_class.find_array([1, 2])).to eq([1, 2])
    end

    it "skips empty arrays and continues searching" do
      nested = { 'a' => [], 'b' => [1, 2] }
      expect(described_class.find_array(nested)).to eq([1, 2])
    end

    it "walks deep into nested hashes" do
      nested = { 'a' => { 'b' => { 'c' => [1] } } }
      expect(described_class.find_array(nested)).to eq([1])
    end

    it "returns nil if no Array is found" do
      expect(described_class.find_array('foo' => 'bar')).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
