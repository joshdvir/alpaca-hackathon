# frozen_string_literal: true

require "rails_helper"

# Tests for Position#unrealized_plpc — the P&L percentage returned
# as a FRACTION (e.g., -0.0786 for -7.86%), matching Alpaca's
# `unrealized_plpc` convention so the front-end can multiply by 100
# once for display.
#
# The OCC option contract has a 100x multiplier. The broker sends
# `market_value` and `unrealized_pl` in per-contract dollars
# (already × 100), but we store `avg_entry_price` as the per-share
# premium. Without the 100x, a $4.45 entry on 1 contract with a
# $4.10 current price would show as a -7.86% loss expressed as
# -0.35/0.0445 = -7.86, not the wrong -786%.
RSpec.describe Position, "#unrealized_plpc" do
  def make_pos(attrs)
    Position.create!({
      symbol: "PLTR260911C00190000",
      qty: 1,
      avg_entry_price: 4.45,
      market_value: 410.0,
      unrealized_pl: -35.0,
      asset_class: "us_option",
      snapshot_at: Time.current
    }.merge(attrs))
  end

  it "applies the 100x option contract multiplier to the cost basis" do
    p = make_pos(avg_entry_price: 4.45, unrealized_pl: -35.0, qty: 1)
    # -35 / (4.45 * 1 * 100) = -0.0786...
    expect(p.unrealized_plpc).to be_within(0.001).of(-0.0786)
  end

  it "scales qty correctly with the multiplier" do
    p = make_pos(avg_entry_price: 1.8, unrealized_pl: -51.0, qty: 3)
    # -51 / (1.8 * 3 * 100) = -0.0944...
    expect(p.unrealized_plpc).to be_within(0.001).of(-0.0944)
  end

  it "uses multiplier 1 for stock positions" do
    p = make_pos(avg_entry_price: 100.0, unrealized_pl: 5.0, qty: 10, asset_class: "us_equity")
    # 5 / (100 * 10 * 1) = 0.005
    expect(p.unrealized_plpc).to be_within(0.0001).of(0.005)
  end

  it "returns 0.0 when avg_entry_price is 0 (avoid division by zero)" do
    p = make_pos(avg_entry_price: 0, qty: 1, unrealized_pl: 0)
    expect(p.unrealized_plpc).to eq(0.0)
  end

  it "returns 0.0 when qty is 0" do
    p = make_pos(avg_entry_price: 4.45, qty: 0, unrealized_pl: 0)
    expect(p.unrealized_plpc).to eq(0.0)
  end

  it "returns a positive fraction for a profitable position" do
    p = make_pos(avg_entry_price: 4.45, unrealized_pl: 89.0, qty: 1)
    # 89 / (4.45 * 100) = 0.20
    expect(p.unrealized_plpc).to be_within(0.001).of(0.20)
  end
end
