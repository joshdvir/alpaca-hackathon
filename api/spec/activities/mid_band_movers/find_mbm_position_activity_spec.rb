# frozen_string_literal: true

require "rails_helper"

# Tests for FindMbmPositionActivity. The activity looks up the open
# DB position by option_symbol, and (on first lookup) backfills
# planned_sell_at + strategy_bucket + origin from the matching Order
# row's `raw` payload (where SubmitBuyOrdersActivity stashed them).

RSpec.describe MidBandMovers::FindMbmPositionActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: "wf-mbm-1", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }
  let(:symbol)   { "AAPL260515C00200000" }
  let(:bucket)   { "A" }

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
  end

  def make_position(attrs = {})
    Position.create!({
      symbol: symbol,
      asset_class: "us_option",
      qty: 1,
      avg_entry_price: 5.0,
      origin: "mid_band_movers",
      snapshot_at: Time.current
    }.merge(attrs))
  end

  def make_order_with_metadata(raw_extra = {})
    Order.create!(
      symbol: symbol,
      side: "buy_to_open",
      qty: 1,
      type: "limit",
      status: "new",
      client_order_id: "test-#{SecureRandom.hex(4)}",
      raw_response: {
        'mbm_origin' => 'mid_band_movers',
        'mbm_planned_sell_at' => 2.hours.from_now.iso8601,
        'mbm_strategy_bucket' => bucket
      }.merge(raw_extra)
    )
  end

  it "returns the position id when an open position is found" do
    position = make_position
    expect(described_class.new.execute(symbol, bucket, {})).to eq(position.id)
  end

  it "returns nil when no open position exists" do
    expect(described_class.new.execute(symbol, bucket, {})).to be_nil
  end

  it "backfills planned_sell_at + strategy_bucket from the order's raw payload on first lookup" do
    position = make_position(planned_sell_at: nil, strategy_bucket: nil)
    make_order_with_metadata

    described_class.new.execute(symbol, bucket, {})
    position.reload
    expect(position.planned_sell_at).to be_present
    expect(position.strategy_bucket).to eq('A')
    expect(position.origin).to eq('mid_band_movers')
  end

  it "falls back to the workflow-supplied bucket when no order metadata exists" do
    position = make_position(planned_sell_at: nil, strategy_bucket: nil)
    described_class.new.execute(symbol, bucket, {})
    position.reload
    expect(position.strategy_bucket).to eq('A')
  end

  it "does NOT overwrite existing planned_sell_at / strategy_bucket" do
    existing = 1.hour.from_now
    position = make_position(planned_sell_at: existing, strategy_bucket: 'B')
    make_order_with_metadata # would have different values, but we shouldn't overwrite

    described_class.new.execute(symbol, bucket, {})
    position.reload
    expect(position.planned_sell_at.to_i).to eq(existing.to_i)
    expect(position.strategy_bucket).to eq('B')
  end
end
