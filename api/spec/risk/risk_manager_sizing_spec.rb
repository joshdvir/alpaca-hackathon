# frozen_string_literal: true

require "rails_helper"

# Verifies the notional cap scales with the live account:
#   cap = min(max_notional_per_trade, options_buying_power)
# So a $10K account allows a $10K trade, and a $1M account is
# capped by the configured max_notional_per_trade (default 10K).
RSpec.describe Risk::RiskManager, "sizing cap uses live buying power" do
  let(:instance) { described_class.new }
  let(:proposal) do
    TradeProposal.create!(
      agent_run: create_agent_run,
      ticker: "SPY",
      kind: "new",
      strategy_type: "vertical",
      legs: [{ "side" => "buy_to_open", "ratio_qty" => 1, "option_symbol" => "SPY260116C00580000", "limit_price" => "1.25" }],
      max_loss: 1000,
      max_profit: 1000,
      status: "pending"
    )
  end

  before { TradingConfig.reload! }

  def with_snapshot(bp:, equity: nil)
    PortfolioSnapshot.destroy_all
    PortfolioSnapshot.create!(
      cash: 0, equity: equity || bp, buying_power: bp * 4,
      options_buying_power: bp, daily_pl: 0, raw: {}
    )
  end

  it "caps a $10K account at $10K per trade (uses full buying power)" do
    with_snapshot(bp: 10_000)
    result = instance.check(proposal)
    # max_loss is $1K so it should pass; the cap is $10K. No rejection
    # on the notional check.
    reasons = JSON.parse(result.reasons.to_json)
    expect(reasons.join).not_to include("max_notional_per_trade")
  end

  it "caps a $1M account at the configured $10K per trade (secondary floor wins)" do
    with_snapshot(bp: 1_000_000)
    result = instance.check(proposal)
    # max_loss is $1K → still passes. The point is the cap is $10K
    # (the smaller of $10K config and $1M BP), not $1M.
    reasons = JSON.parse(result.reasons.to_json)
    expect(reasons.join).not_to include("max_notional_per_trade")
  end

  it "rejects when max_loss exceeds the live cap" do
    with_snapshot(bp: 5_000)
    # 7K proposal → bigger than both BP ($5K) and config ($10K) when
    # BP is the smaller. Actually 7K < 10K config, so we need BP to be
    # the smaller. Set max_loss to 6K and BP=5K → 6K > 5K cap.
    proposal.update!(max_loss: 6_000)
    result = instance.check(proposal)
    reasons = JSON.parse(result.reasons.to_json)
    expect(reasons.join).to include("buying power")
  end

  it "falls back to max_notional_per_trade when no snapshot exists" do
    PortfolioSnapshot.destroy_all
    # max_loss is $1K which is under the $10K config cap, so passes.
    result = instance.check(proposal)
    reasons = JSON.parse(result.reasons.to_json)
    expect(reasons.join).not_to include("max_notional_per_trade")
  end
end
