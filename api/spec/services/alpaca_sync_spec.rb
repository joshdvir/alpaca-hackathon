# frozen_string_literal: true

require "rails_helper"

RSpec.describe AlpacaSync do
  let(:fake_client) { instance_double(RubyLLM::MCP::Client) }

  before do
    stub_const("ALPACA_MCP_TRADING", fake_client)
    # Stub rate limiter + circuit breaker so the call paths don't raise.
    allow(RATE_LIMITERS[:alpaca_mcp]).to receive(:with_limit).and_yield
    allow(CIRCUIT_BREAKERS[:alpaca_mcp]).to receive(:call).and_yield
  end

  describe ".sync_account_snapshot" do
    it "writes a PortfolioSnapshot from the broker response" do
      stub_tool("get_account_info", {
        "id" => "acct-1",
        "account_number" => "PA36",
        "status" => "ACTIVE",
        "options_approved_level" => 3,
        "buying_power" => "4000000",
        "options_buying_power" => "1000000",
        "cash" => "1000000",
        "equity" => "1000000",
        "last_equity" => "999000",
        "portfolio_value" => "1000000",
        "multiplier" => "4",
        "trading_blocked" => false
      })
      result = described_class.sync_account_snapshot
      expect(result.ok?).to be true
      expect(result.synced).to eq(1)

      snap = PortfolioSnapshot.last
      expect(snap.cash.to_f).to eq(1_000_000.0)
      expect(snap.buying_power.to_f).to eq(4_000_000.0)
      expect(snap.options_buying_power.to_f).to eq(1_000_000.0)
      expect(snap.equity.to_f).to eq(1_000_000.0)
      # daily_pl = equity - last_equity
      expect(snap.daily_pl.to_f).to eq(1000.0)
    end

    it "returns an error result when the broker call fails" do
      stub_tool("get_account_info", nil)
      allow(fake_client).to receive(:tool).with("get_account_info").and_return(nil)
      result = described_class.sync_account_snapshot
      expect(result.ok?).to be false
      expect(result.errors.first).to include("get_account_info")
    end
  end

  describe ".sync_positions" do
    it "creates a Position row per open position" do
      stub_tool("get_all_positions", [
        { "symbol" => "AAPL260116C00150000", "qty" => "1", "avg_entry_price" => "3.50",
          "market_value" => "350", "unrealized_pl" => "20", "asset_class" => "us_option" }
      ])
      result = described_class.sync_positions
      expect(result.ok?).to be true
      expect(Position.open.where(symbol: "AAPL260116C00150000").count).to eq(1)
    end

    it "closes any open DB position not in the broker feed" do
      Position.create!(symbol: "ZZZ", qty: 1, snapshot_at: Time.current, avg_entry_price: 1.0)
      stub_tool("get_all_positions", [])
      described_class.sync_positions
      expect(Position.open.where(symbol: "ZZZ").count).to eq(0)
      expect(Position.where(symbol: "ZZZ").last.closed_at).to be_present
    end

    context "Mid-Band Movers strategy backfill" do
      let(:option_symbol) { "AAPL260515C00200000" }
      let(:planned_sell_iso) { 2.hours.from_now.iso8601 }

      def make_mbm_order(raw_extra = {})
        Order.create!(
          client_order_id: "pm-mbm-#{SecureRandom.hex(4)}",
          symbol: option_symbol,
          side: "buy_to_open",
          qty: 1,
          type: "limit",
          status: "filled",
          raw_response: {
            'mbm_origin' => 'mid_band_movers',
            'mbm_planned_sell_at' => planned_sell_iso,
            'mbm_strategy_bucket' => 'A'
          }.merge(raw_extra)
        )
      end

      it "backfills origin/strategy_bucket/planned_sell_at on a newly-created Position" do
        make_mbm_order
        stub_tool("get_all_positions", [
          { "symbol" => option_symbol, "qty" => "1", "avg_entry_price" => "5.00",
            "market_value" => "500", "unrealized_pl" => "0", "asset_class" => "us_option" }
        ])

        described_class.sync_positions
        position = Position.find_by(symbol: option_symbol)
        expect(position).to be_present
        expect(position.origin).to eq('mid_band_movers')
        expect(position.strategy_bucket).to eq('A')
        expect(position.planned_sell_at).to be_within(1.second).of(Time.iso8601(planned_sell_iso))
      end

      it "does not backfill positions that don't have a matching MBM Order" do
        stub_tool("get_all_positions", [
          { "symbol" => "OTHER260515C00100000", "qty" => "1", "avg_entry_price" => "5.00",
            "market_value" => "500", "unrealized_pl" => "0", "asset_class" => "us_option" }
        ])

        described_class.sync_positions
        position = Position.find_by(symbol: "OTHER260515C00100000")
        expect(position).to be_present
        expect(position.origin).to eq('default')
        expect(position.strategy_bucket).to be_nil
        expect(position.planned_sell_at).to be_nil
      end

      it "does not overwrite existing strategy metadata on a position update" do
        existing_position = Position.create!(
          symbol: option_symbol, qty: 1, avg_entry_price: 5.0, snapshot_at: 1.hour.ago,
          origin: 'mid_band_movers', strategy_bucket: 'B', planned_sell_at: 5.hours.from_now
        )
        make_mbm_order # would suggest bucket 'A' and 2.hours.from_now
        stub_tool("get_all_positions", [
          { "symbol" => option_symbol, "qty" => "1", "avg_entry_price" => "5.00",
            "market_value" => "500", "unrealized_pl" => "0", "asset_class" => "us_option" }
        ])

        described_class.sync_positions
        expect(existing_position.reload.strategy_bucket).to eq('B')
        expect(existing_position.planned_sell_at).to be_within(1.second).of(5.hours.from_now)
      end

      it "does not raise if the MBM Order raw_response is missing" do
        # An order without the MBM metadata is just a regular LLM-
        # driven order; the backfill should silently no-op.
        Order.create!(
          client_order_id: "pm-regular-#{SecureRandom.hex(4)}",
          symbol: option_symbol,
          side: "buy_to_open",
          qty: 1,
          type: "limit",
          status: "filled"
        )
        stub_tool("get_all_positions", [
          { "symbol" => option_symbol, "qty" => "1", "avg_entry_price" => "5.00",
            "market_value" => "500", "unrealized_pl" => "0", "asset_class" => "us_option" }
        ])

        result = nil
        expect { result = described_class.sync_positions }.not_to raise_error
        expect(result.ok?).to be true
        position = Position.find_by(symbol: option_symbol)
        expect(position.origin).to eq('default')
      end
    end
  end

  describe ".sync_orders" do
    it "updates the Order row from the broker response" do
      order = Order.create!(
        client_order_id: "pm-test-1",
        symbol: "AAPL260116C00150000",
        side: "buy_to_open",
        qty: 1,
        type: "limit",
        status: "new"
      )
      stub_tool("get_orders", [{
        "id" => "broker-1",
        "client_order_id" => "pm-test-1",
        "status" => "filled",
        "filled_qty" => 1,
        "filled_avg_price" => "3.50",
        "submitted_at" => Time.current.iso8601,
        "filled_at" => Time.current.iso8601
      }])
      result = described_class.sync_orders
      expect(result.ok?).to be true
      order.reload
      expect(order.status).to eq("filled")
      expect(order.filled_qty).to eq(1)
      expect(order.filled_avg_price.to_f).to eq(3.5)
    end

    it "ignores orders not in our DB" do
      stub_tool("get_orders", [{ "id" => "broker-unknown", "status" => "filled" }])
      result = described_class.sync_orders
      expect(result.synced).to eq(0)
    end
  end

  def stub_tool(name, payload)
    tool = instance_double(RubyLLM::MCP::Tool)
    allow(fake_client).to receive(:tool).with(name).and_return(tool)
    # Mirror the real MCP envelope. `get_account_info`/`get_clock`/
    # `get_account_config` return the dict under `data` directly.
    # `get_orders`/`get_all_positions` return `{ data: { result: [...] } }`.
    body =
      if name == "get_account_info" || name == "get_clock" || name == "get_account_config"
        { "data" => payload }
      else
        { "data" => { "result" => payload } }
      end
    allow(tool).to receive(:call).and_return(instance_double(RubyLLM::MCP::Content, text: body.to_json))
  end
end
