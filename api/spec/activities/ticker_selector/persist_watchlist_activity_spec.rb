# frozen_string_literal: true

require "rails_helper"

# Tests the contract that manual_tickers always end up on the
# watchlist, even if the LLM ranker dropped them.
RSpec.describe TickerSelector::PersistWatchlistActivity do
  let(:info) { instance_double(Temporalio::Activity::Info, workflow_id: "wf-1", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Rails.logger, info: info) }

  before do
    # The ApplicationActivity constructor calls Temporalio::Activity::Context.current
    # to wire up `activity`. We stub it so the activity can be
    # instantiated outside a real worker.
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
  end

  let(:instance) { described_class.new }

  before do
    # Don't let the activity touch the real DB rows for today's
    # workflow. The test creates its own entries below.
    WatchlistEntry.where(ticker: %w[SPY MSFT AAPL]).destroy_all
  end

  def stub_default_config
    allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :default_cycle_minutes).and_return(5)
    allow(TradingConfig).to receive(:fetch).with(:ticker_selector, :filters).and_return([])
  end

  it "inserts every ticker in ranked" do
    stub_default_config
    ranked = [
      { "ticker" => "SPY", "source_filter" => "options_liquid", "scores" => {}, "confidence" => 80, "rationale" => "ok" },
      { "ticker" => "AAPL", "source_filter" => "options_liquid", "scores" => {}, "confidence" => 70, "rationale" => "ok" }
    ]
    count = instance.execute(ranked, ranked, [])
    expect(count).to eq(2)
    expect(WatchlistEntry.where(ticker: %w[SPY AAPL], effective_until: nil).pluck(:ticker)).to match_array(%w[SPY AAPL])
  end

  it "force-includes any manual_ticker missing from ranked with the 'manual_only' tag" do
    stub_default_config
    # The ranker only returned SPY. Manual list contains SPY + MSFT.
    # SPY is already in the watchlist. MSFT must be added with
    # tag 'manual_only' even though the ranker didn't surface it.
    ranked = [{ "ticker" => "SPY", "source_filter" => "options_liquid", "scores" => {}, "confidence" => 80, "rationale" => "ok" }]
    count = instance.execute(ranked, ranked, %w[SPY MSFT])

    expect(count).to eq(2) # 1 from ranked + 1 manual-only (SPY was already there)
    rows = WatchlistEntry.where(ticker: %w[SPY MSFT], effective_until: nil)
    expect(rows.pluck(:ticker)).to match_array(%w[SPY MSFT])

    msft_row = rows.find { |r| r.ticker == "MSFT" }
    expect(msft_row.tags).to eq(["manual_only"])
    expect(msft_row.source).to eq("ticker_selector")
  end

  it "is a no-op for an empty manual_tickers list when ranked is also empty" do
    stub_default_config
    count = instance.execute([], [], [])
    expect(count).to eq(0)
  end

  it "dedupes manual_tickers before inserting (no double-insert on duplicates)" do
    stub_default_config
    ranked = []
    count = instance.execute(ranked, ranked, %w[AAPL AAPL AAPL])
    expect(count).to eq(1)
    expect(WatchlistEntry.where(ticker: "AAPL", effective_until: nil).count).to eq(1)
  end
end
