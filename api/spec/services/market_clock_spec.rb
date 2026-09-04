# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketClock do
  let(:fake_client) { instance_double(RubyLLM::MCP::Client) }
  let(:fake_tool)   { instance_double(RubyLLM::MCP::Tool) }

  before do
    stub_const("ALPACA_MCP_TRADING", fake_client)
    allow(fake_client).to receive(:tool).with("get_clock").and_return(fake_tool)
    Rails.cache.clear
  end

  describe ".current" do
    it "returns a Clock with is_open=true when broker says so" do
      env = {
        "is_open" => true,
        "next_open" => "2026-09-01T13:30:00Z",
        "next_close" => "2026-09-01T20:00:00Z",
        "timestamp" => "2026-08-31T15:00:00Z"
      }
      allow(fake_tool).to receive(:call).with({}).and_return(text_envelope(env))

      clock = described_class.current
      expect(clock.open).to be true
      expect(clock.next_open_at).to be_present
      expect(clock.next_close_at).to be_present
      expect(clock.source).to eq("alpaca")
    end

    it "returns a Clock with is_open=false when broker says so" do
      env = {
        "is_open" => false,
        "next_open" => "2026-09-01T13:30:00Z",
        "next_close" => nil,
        "timestamp" => "2026-08-31T03:00:00Z"
      }
      allow(fake_tool).to receive(:call).with({}).and_return(text_envelope(env))

      clock = described_class.current
      expect(clock.open).to be false
    end

    it "caches the result for CACHE_TTL so a second call doesn't hit the broker" do
      env = { "is_open" => true, "next_open" => "2026-09-01T13:30:00Z", "next_close" => "2026-09-01T20:00:00Z", "timestamp" => "2026-08-31T15:00:00Z" }
      expect(fake_tool).to receive(:call).with({}).once.and_return(text_envelope(env))

      first  = described_class.current
      second = described_class.current
      expect(first).to eq(second)
    end

    it "falls back to a closed Clock when the broker call raises" do
      allow(fake_tool).to receive(:call).with({}).and_raise(StandardError, "network down")
      clock = described_class.current
      expect(clock.open).to be false
      expect(clock.source).to eq("offline")
    end

    it "falls back to a closed Clock when the tool is missing" do
      allow(fake_client).to receive(:tool).with("get_clock").and_return(nil)
      clock = described_class.current
      expect(clock.open).to be false
      expect(clock.source).to eq("offline")
    end

    it ".refresh! forces a refetch" do
      env1 = { "is_open" => false, "next_open" => "2026-09-01T13:30:00Z", "next_close" => nil, "timestamp" => "2026-08-31T03:00:00Z" }
      env2 = { "is_open" => true,  "next_open" => "2026-09-01T13:30:00Z", "next_close" => "2026-09-01T20:00:00Z", "timestamp" => "2026-09-01T13:31:00Z" }
      allow(fake_tool).to receive(:call).with({}).and_return(text_envelope(env1), text_envelope(env2))

      first  = described_class.current
      second = described_class.refresh!
      expect(first.open).to be false
      expect(second.open).to be true
    end
  end

  describe ".seconds_until_next_open" do
    it "returns nil when the market is open" do
      env = { "is_open" => true, "next_open" => "2026-09-01T13:30:00Z", "next_close" => "2026-09-01T20:00:00Z", "timestamp" => "2026-08-31T15:00:00Z" }
      allow(fake_tool).to receive(:call).with({}).and_return(text_envelope(env))
      expect(described_class.seconds_until_next_open).to be_nil
    end

    it "returns the seconds until the broker's next_open" do
      env = { "is_open" => false, "next_open" => (Time.current + 90.minutes).utc.iso8601, "next_close" => nil, "timestamp" => Time.current.utc.iso8601 }
      allow(fake_tool).to receive(:call).with({}).and_return(text_envelope(env))
      secs = described_class.seconds_until_next_open
      expect(secs).to be > 5000
      expect(secs).to be < 6000
    end
  end

  def text_envelope(data)
    env = { "data" => data }
    instance_double(RubyLLM::MCP::Content, text: env.to_json)
  end
end
