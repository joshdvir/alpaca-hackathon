# frozen_string_literal: true

require "rails_helper"

# Verifies the Trader#user_payload exposes the live account snapshot
# to the LLM, and the prompt tells the LLM to use the full buying
# power. Together they make the system size orders to the actual
# account capacity (e.g. a $10K account gets a $10K single trade)
# instead of a hardcoded $5K cap.
RSpec.describe Trader, "sizing from live account" do
  before do
    TradingConfig.reload!
  end

  let(:plan) { { verdict: "trade", confidence: 80, trade_plan: { direction: "bullish" } } }
  let(:market_state) { { latest: { price: 175.0 } } }

  it "includes a live account snapshot in the user_payload" do
    PortfolioSnapshot.create!(
      cash: 10_000.0, equity: 10_000.0, buying_power: 40_000.0,
      options_buying_power: 10_000.0, daily_pl: 0.0, raw: {}
    )

    payload = described_class.new.user_payload("AAPL", plan, market_state)

    expect(payload[:account]).to include(
      cash: 10_000.0,
      equity: 10_000.0,
      options_buying_power: 10_000.0
    )
  end

  it "exposes the configured risk_limits for cross-check" do
    payload = described_class.new.user_payload("AAPL", plan, market_state)
    expect(payload[:risk_limits]).to include(:max_notional_per_trade, :max_position_pct, :max_daily_loss_pct)
  end

  it "uses the most recent PortfolioSnapshot (not a stale one)" do
    PortfolioSnapshot.create!(cash: 100.0, equity: 100.0, buying_power: 400.0,
                              options_buying_power: 100.0, daily_pl: 0.0, raw: {},
                              created_at: 1.hour.ago)
    PortfolioSnapshot.create!(cash: 50_000.0, equity: 50_000.0, buying_power: 200_000.0,
                              options_buying_power: 50_000.0, daily_pl: 0.0, raw: {})

    payload = described_class.new.user_payload("AAPL", plan, market_state)
    expect(payload[:account][:options_buying_power]).to eq(50_000.0)
  end

  it "falls back to zero on a missing snapshot (no NPE, no stale data)" do
    PortfolioSnapshot.destroy_all
    payload = described_class.new.user_payload("AAPL", plan, market_state)
    expect(payload[:account][:options_buying_power]).to eq(0.0)
    expect(payload[:account][:equity]).to eq(0.0)
  end
end
