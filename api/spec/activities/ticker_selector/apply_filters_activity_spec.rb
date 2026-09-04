# frozen_string_literal: true

require "rails_helper"

# rubocop:disable Metrics/BlockLength
RSpec.describe TickerSelector::ApplyFiltersActivity do
  let(:info) { instance_double(Temporalio::Activity::Info, workflow_id: "wf-1", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Rails.logger, info: info) }
  let(:heartbeats) { [] }

  before do
    allow(activity).to receive(:heartbeat) { |detail| heartbeats << detail }
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
  end

  let(:filter_spec) { { name: "test_filter", enabled: true, criteria: {}, prompt: "x" } }
  let(:tickers) { %w[SPY QQQ AAPL] }

  it "processes one chunk of tickers with one filter" do
    expected_results = [
      TickerSelector::FilterEngine::Result.new(
        ticker: "SPY", scores: { iv_rank: 30.0 }, source_filter: "test_filter"
      )
    ]
    allow(TickerSelector::FilterEngine).to receive(:apply)
      .with(filter_spec, tickers)
      .and_return(expected_results)

    result = described_class.new.execute(tickers, filter_spec)
    # Activity converts Data.define results to plain Hashes so they
    # round-trip through Temporal's default JSON converter.
    expect(result).to eq([{ ticker: "SPY", scores: { iv_rank: 30.0 }, source_filter: "test_filter" }])
  end

  it "sends a heartbeat after running the filter" do
    allow(TickerSelector::FilterEngine).to receive(:apply).and_return([])

    described_class.new.execute(tickers, filter_spec)
    expect(heartbeats).not_to be_empty
    expect(heartbeats.first).to include("test_filter")
    expect(heartbeats.first).to include("3") # chunk_size
  end

  it "returns whatever FilterEngine.apply returns (no dedupe at this layer)" do
    # The workflow does the dedupe, not the activity. Two activity
    # calls might return results for the same ticker; the workflow's
    # dedupe picks the first one.
    allow(TickerSelector::FilterEngine).to receive(:apply).and_return(
      [
        TickerSelector::FilterEngine::Result.new(ticker: "SPY", scores: {}, source_filter: "test_filter"),
        TickerSelector::FilterEngine::Result.new(ticker: "QQQ", scores: {}, source_filter: "test_filter")
      ]
    )
    result = described_class.new.execute(tickers, filter_spec)
    expect(result.size).to eq(2)
  end
end
# rubocop:enable Metrics/BlockLength
