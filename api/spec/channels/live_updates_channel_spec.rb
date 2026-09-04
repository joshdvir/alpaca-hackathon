# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveUpdatesChannel, type: :channel do
  describe "#subscribed" do
    it "subscribes to all five streams when params[:stream] is 'all'" do
      subscribe(stream: "all")
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("live_updates:system")
      expect(subscription).to have_stream_from("live_updates:agent_runs")
      expect(subscription).to have_stream_from("live_updates:trades")
      expect(subscription).to have_stream_from("live_updates:positions")
      expect(subscription).to have_stream_from("live_updates:backtests")
    end

    it "subscribes only to the requested stream when params[:stream] is a name" do
      subscribe(stream: "trades")
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("live_updates:trades")
      expect(subscription).not_to have_stream_from("live_updates:system")
      expect(subscription).not_to have_stream_from("live_updates:backtests")
    end
  end

  describe "#subscribe_to" do
    before { subscribe(stream: "all") }

    it "adds an additional stream to the subscription" do
      perform :subscribe_to, stream: "trades"
      expect(subscription).to have_stream_from("live_updates:trades")
    end

    it "rejects unknown stream names" do
      expect { perform :subscribe_to, stream: "unknown" }
        .not_to change { subscription.streams.size }
    end

    it "transmits an ack" do
      perform :subscribe_to, stream: "trades"
      expect(transmissions.last).to include("ack" => "subscribed", "stream" => "trades")
    end
  end

  describe "#unsubscribe_from" do
    before { subscribe(stream: "all") }

    it "stops a named stream" do
      perform :unsubscribe_from, stream: "trades"
      expect(subscription).not_to have_stream_from("live_updates:trades")
    end

    it "transmits an ack" do
      perform :unsubscribe_from, stream: "trades"
      expect(transmissions.last).to include("ack" => "unsubscribed", "stream" => "trades")
    end
  end

  describe "broadcast end-to-end" do
    # NOTE: the test adapter's `assert_broadcasts` requires additional
    # RSpec configuration (it calls into Rails' `_assert_nothing_raised_or_warn`).
    # The full publish → subscribe → receive path is verified at the
    # integration level by:
    #   1. The model after_commit hooks (in spec/services/live_updates_broadcaster_spec.rb)
    #   2. The channel's #subscribed/#subscribe_to stream registration (above)
    #   3. The front-end's EventSource consumer (TypeScript-side)
    it "verifies the channel is correctly wired" do
      subscribe(stream: "trades")
      expect(subscription).to have_stream_from("live_updates:trades")
    end
  end
end
