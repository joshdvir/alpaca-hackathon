# frozen_string_literal: true

require "rails_helper"
require "set"

# Unit tests for the parallel-dispatch logic in
# TickerSelectorWorkflow. We stub the Temporal Future mechanism so the
# test runs without a live Temporal server.

# rubocop:disable Metrics/BlockLength
RSpec.describe TickerSelector::TickerSelectorWorkflow do
  # Build a fake T_FUTURE that just records what would be executed
  # and returns the supplied result on .result. Mimics the shape of
  # Temporalio::Workflow::Future just enough for our workflow code.
  class FakeFuture
    attr_reader :result

    def initialize(result = nil, &block)
      @block = block
      @result = block ? block.call : result
    end

    def self.all_of(*futures)
      # The real all_of returns a future that's "done" when all input
      # futures are done. Since FakeFuture is synchronous, all_of just
      # collects the results and is itself a FakeFuture over the array.
      results = futures.map(&:result)
      FakeFuture.new(results)
    end

    def wait
      self
    end
  end

  let(:info) { instance_double(Temporalio::Workflow::Info, workflow_id: "wf-1", workflow_run_id: "run-1") }
  let(:heartbeats) { [] }

  before do
    # `activity.logger` in workflow code goes through the
    # WorkflowActivityShim, which calls T_WORKFLOW.logger. We don't have
    # a real workflow environment, so stub the shim's logger to be
    # the real Rails logger (which is what production does anyway).
    allow_any_instance_of(WorkflowActivityShim).to receive(:logger).and_return(Rails.logger)

    # Stub T_FUTURE (Temporalio::Workflow::Future) — the production
    # code uses `T_FUTURE.new { ... }` and `T_FUTURE.all_of(*futures)`.
    # We make both return FakeFutures that record execution eagerly.
    allow(Temporalio::Workflow::Future).to receive(:new) do |&block|
      FakeFuture.new(&block)
    end
    allow(Temporalio::Workflow::Future).to receive(:all_of) do |*futures|
      FakeFuture.new(futures.flat_map(&:result))
    end
  end

  def filter(name, enabled: true)
    { name: name, enabled: enabled, criteria: {}, prompt: "x" }
  end

  describe "#run_filters_in_parallel" do
    let(:instance) { described_class.new }

    it "fans out one activity call per (filter, chunk) pair" do
      allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
        [filter("a"), filter("b")]
      )
      # 30 tickers / 25 = 2 chunks
      tickers = (1..30).map { |i| "T#{i}" }
      expect(Temporalio::Workflow).to receive(:execute_activity)
        .with(
          TickerSelector::ApplyFiltersActivity,
          an_instance_of(Array),
          an_instance_of(Hash),
          hash_including(start_to_close_timeout: 600)
        )
        .exactly(4).times # 2 filters × 2 chunks
        .and_return([])

      result = instance.send(:run_filters_in_parallel, tickers, Set.new)
      expect(result).to eq([])
    end

    it "dispatches chunks of CHUNK_SIZE tickers each" do
      stub_const("TickerSelector::TickerSelectorWorkflow::CHUNK_SIZE", 25)
      allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
        [filter("a")]
      )
      tickers = (1..50).map { |i| "T#{i}" }
      captured_chunk_sizes = []
      allow(Temporalio::Workflow).to receive(:execute_activity) do |_act, chunk, _filter, **_opts|
        captured_chunk_sizes << chunk.size
        []
      end

      instance.send(:run_filters_in_parallel, tickers, Set.new)
      expect(captured_chunk_sizes).to eq([25, 25])
    end

    it "dedupes by ticker (first filter wins)" do
      allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
        [filter("a"), filter("b")]
      )
      allow(Temporalio::Workflow).to receive(:execute_activity) do |_act, _chunk, filter_spec|
        [
          TickerSelector::FilterEngine::Result.new(
            ticker: "SPY", scores: { v: 1 }, source_filter: filter_spec[:name]
          ),
          TickerSelector::FilterEngine::Result.new(
            ticker: filter_spec[:name].upcase, scores: { v: 2 }, source_filter: filter_spec[:name]
          )
        ]
      end

      result = instance.send(:run_filters_in_parallel, %w[SPY], Set.new)
      by_ticker = result.index_by(&:ticker)
      expect(by_ticker.keys).to contain_exactly("SPY", "A", "B")
      expect(by_ticker["SPY"].source_filter).to eq("a")
    end

    it "skips disabled filters (only iterates enabled ones)" do
      allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
        [filter("a", enabled: true), filter("b", enabled: false), filter("c", enabled: true)]
      )
      expect(Temporalio::Workflow).to receive(:execute_activity)
        .exactly(2).times
        .and_return([])

      instance.send(:run_filters_in_parallel, %w[SPY], Set.new)
    end

    it "handles a 1-ticker universe without chunking" do
      stub_const("TickerSelector::TickerSelectorWorkflow::CHUNK_SIZE", 25)
      allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
        [filter("a")]
      )
      captured_chunk_sizes = []
      allow(Temporalio::Workflow).to receive(:execute_activity) do |_act, chunk, _filter, **_opts|
        captured_chunk_sizes << chunk.size
        []
      end

      result = instance.send(:run_filters_in_parallel, %w[SPY], Set.new)
      expect(captured_chunk_sizes).to eq([1])
      expect(result).to eq([])
    end

    describe "ticker cap (PendingActivitiesLimitExceeded protection)" do
      it "truncates tickers to stay under MAX_FILTER_ACTIVITIES" do
        # 2 filters × CHUNK_SIZE=25 × target 500 → max 6,250 tickers
        stub_const("TickerSelector::TickerSelectorWorkflow::CHUNK_SIZE", 25)
        stub_const("TickerSelector::TickerSelectorWorkflow::MAX_FILTER_ACTIVITIES", 500)
        allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
          [filter("a"), filter("b")]
        )
        huge = (1..10_000).map { |i| "T#{i}" }
        captured = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |_act, chunk, _filter, **_opts|
          captured << chunk.size
          []
        end

        instance.send(:run_filters_in_parallel, huge, Set.new)
        # Total activity calls = number of chunks × 2 filters.
        # Tickers should be truncated to 6,250 → 250 chunks → 500 calls.
        expect(captured.size).to eq(500) # 250 chunks × 2 filters
        expect(captured.first(250).sum).to eq(6_250) # total tickers dispatched
      end

      it "does not truncate when the universe is small enough" do
        stub_const("TickerSelector::TickerSelectorWorkflow::CHUNK_SIZE", 25)
        stub_const("TickerSelector::TickerSelectorWorkflow::MAX_FILTER_ACTIVITIES", 500)
        allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
          [filter("a")]
        )
        small = (1..100).map { |i| "T#{i}" }
        captured = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |_act, chunk, _filter, **_opts|
          captured << chunk.size
          []
        end

        instance.send(:run_filters_in_parallel, small, Set.new)
        # No truncation: 4 chunks of 25 → 4 calls
        expect(captured.size).to eq(4)
        expect(captured.sum).to eq(100)
      end

      it "skips cap when no filters are enabled" do
        allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return([])
        # Should not raise (divides by zero protection)
        expect { instance.send(:run_filters_in_parallel, (1..1000).map { |i| "T#{i}" }, Set.new) }.not_to raise_error
        expect(Temporalio::Workflow).not_to receive(:execute_activity)
      end
    end

    describe "manual_tickers force-include" do
      it "force-includes a manual ticker that the filter rejected" do
        # The filter rejects SPY (returns no candidates). The
        # manual_set contains SPY. The output should still contain
        # SPY (marked as manual_override) so the watchlist never
        # silently drops an operator's pick.
        allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
          [filter("options_liquid")]
        )
        allow(Temporalio::Workflow).to receive(:execute_activity).and_return([])

        manual = Set.new(%w[SPY])
        result = instance.send(:run_filters_in_parallel, %w[SPY AAPL], manual)

        tickers = result.map { |r| r.is_a?(Hash) ? r[:ticker] : r.ticker }
        expect(tickers).to include("SPY")
        spy_entry = result.find { |r| (r.is_a?(Hash) ? r[:ticker] : r.ticker) == "SPY" }
        expect(spy_entry[:source_filter]).to start_with("manual_override:")
      end

      it "does not duplicate a manual ticker that the filter already accepted" do
        # The filter accepts SPY. The manual set contains SPY. The
        # output should contain SPY exactly once (no manual_override
        # entry gets added on top of the filter-accepted one).
        allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
          [filter("options_liquid")]
        )
        allow(Temporalio::Workflow).to receive(:execute_activity).and_return(
          [{ ticker: "SPY", scores: {}, source_filter: "options_liquid" }]
        )

        manual = Set.new(%w[SPY])
        result = instance.send(:run_filters_in_parallel, %w[SPY], manual)
        spy_entries = result.select { |r| (r.is_a?(Hash) ? r[:ticker] : r.ticker) == "SPY" }
        expect(spy_entries.size).to eq(1)
        expect(spy_entries.first[:source_filter]).to eq("options_liquid") # NOT manual_override
      end

      it "ignores the manual set when it's empty" do
        allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return(
          [filter("options_liquid")]
        )
        allow(Temporalio::Workflow).to receive(:execute_activity).and_return([])
        result = instance.send(:run_filters_in_parallel, %w[SPY AAPL], Set.new)
        expect(result).to be_empty
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
