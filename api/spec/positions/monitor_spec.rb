# frozen_string_literal: true

require "rails_helper"

# Tests for Positions::Monitor — the deterministic 1-min loop that
# checks hard-exit rules. The activity wrapper (RunPositionMonitorActivity)
# is a thin shim around `Monitor.check_position`, so we test the
# underlying module.
RSpec.describe Positions::Monitor do
  let(:position) do
    Position.new(
      symbol: "PLTR260911C00190000",
      qty: 1,
      avg_entry_price: 5.00,
      unrealized_pl: 0,
      snapshot_at: Time.current
    )
  end

  before do
    # Mock the hard-exits config to known values.
    allow(TradingConfig).to receive(:fetch).with(:position_monitor, :hard_exits).and_return(
      stop_loss_pct: 0.50,
      profit_target_pct: 0.10,
      dte_close_threshold: 1
    )
    allow(TradingConfig).to receive(:fetch).and_call_original
  end

  describe ".dte_close?" do
    # The dte_close? check uses Date.current, so we have to test by
    # building a symbol that expires within the threshold relative to
    # the real today. We use a known-distant symbol and stub Date.current.
    it "returns true when dte <= threshold (1 day)" do
      # Build a symbol that expires today + 0 days (dte=0).
      today = Date.current
      symbol = "SPY#{today.strftime('%y%m%d')}C00500000"
      position.symbol = symbol
      expect(described_class.dte_close?(position)).to be true
    end

    it "returns true when dte is within the threshold (1 day past today)" do
      # 0 days is within the 1-day threshold → close.
      position.symbol = "SPY#{(Date.current + 1).strftime('%y%m%d')}C00500000"
      expect(described_class.dte_close?(position)).to be true
    end

    it "returns false when dte is well above the threshold" do
      # A symbol that expires a year out.
      position.symbol = "SPY#{(Date.current + 365).strftime('%y%m%d')}C00500000"
      expect(described_class.dte_close?(position)).to be false
    end

    it "returns false for a non-OCC symbol (no parseable DTE)" do
      position.symbol = "AAPL" # not an OCC option
      expect(described_class.dte_close?(position)).to be false
    end
  end

  describe ".triggered_rules_for" do
    # `profit_target_hit?` calls `current_mark`, which queries the
    # MarketSnapshot model — that model isn't loaded in the test env
    # (it has a DB table but no app/models file). Stub it on every
    # test to keep the test focused on the rules logic.
    before do
      allow(described_class).to receive(:current_mark).and_return(5.00)
    end

    it "returns ['dte'] for an expiring position with no P/L movement" do
      position.symbol = "SPY#{Date.current.strftime('%y%m%d')}C00500000"
      expect(described_class.triggered_rules_for(position)).to include("dte")
    end

    it "returns ['stop_loss'] when unrealized loss > stop_loss_pct" do
      # avg_entry_price 5.00 (per-share premium), qty 1 contract.
      # For an OCC option, the cost basis per contract is
      # avg_entry_price × 100 (the contract multiplier), so
      # $5.00 × 100 = $500 total cost. A 60% loss = -$300 P&L.
      # (unrealized_plpc is a computed method on Position, not a
      # settable attribute — we set the underlying values instead.)
      position.avg_entry_price = 5.00
      position.qty = 1
      position.unrealized_pl = -300.00
      position.symbol = "SPY#{(Date.current + 365).strftime('%y%m%d')}C00500000"
      rules = described_class.triggered_rules_for(position)
      expect(rules).to include("stop_loss")
      expect(rules).not_to include("dte")
    end

    it "returns ['profit_target'] when gain > profit_target_pct" do
      # avg_entry_price 5.00, current_mark 4.00 → 20% gain
      position.avg_entry_price = 5.00
      allow(described_class).to receive(:current_mark).with(position).and_return(4.00)
      position.symbol = "SPY#{(Date.current + 365).strftime('%y%m%d')}C00500000"
      rules = described_class.triggered_rules_for(position)
      expect(rules).to include("profit_target")
    end

    it "returns [] when no rules trigger" do
      position.avg_entry_price = 5.00
      position.qty = 1
      position.unrealized_pl = 0
      position.symbol = "SPY#{(Date.current + 365).strftime('%y%m%d')}C00500000"
      allow(described_class).to receive(:current_mark).with(position).and_return(5.00)
      expect(described_class.triggered_rules_for(position)).to eq([])
    end
  end
end
