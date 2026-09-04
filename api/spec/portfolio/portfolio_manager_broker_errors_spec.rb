# frozen_string_literal: true

require "rails_helper"

# Verifies the silent-rejection fix: when the broker returns
# {"error": {...}}, the Order row must transition to status="rejected"
# with the rejection_reason populated. This is the test that would
# have caught the "I never see any orders get filled" bug.
RSpec.describe Portfolio::PortfolioManager, "broker rejection handling" do
  let(:risk_decision) { instance_double(RiskDecision, created_at: Time.current, decision: "approved") }
  let(:leg) do
    { "side" => "buy_to_open", "ratio_qty" => 1, "option_symbol" => "SPY260116C00580000", "limit_price" => "1.25" }
  end
  let(:proposal) do
    TradeProposal.create!(
      agent_run: create_agent_run,
      ticker: "SPY",
      kind: "new",
      strategy_type: "vertical",
      legs: [leg],
      max_loss: 500,
      max_profit: 500,
      status: "risk_approved"
    )
  end
  let(:mock_mcp_tool) { double("MCPTool", name: "place_option_order") }

  before do
    # Each test starts with a clean Order table so the Order.count
    # assertion in the "deferred" test isn't polluted by the
    # backfilled rejected orders in the dev DB. Delete in FK order:
    # orders -> risk_decisions -> trade_proposals.
    Order.destroy_all
    RiskDecision.destroy_all
    TradeProposal.destroy_all
    # Make sure MarketClock reports OPEN so the gate doesn't defer.
    allow(MarketClock).to receive(:current).and_return(
      MarketClock::Clock.new(open: true, next_open_at: nil, next_close_at: nil, timestamp: Time.current, source: "test")
    )
    allow(ALPACA_MCP_TRADING).to receive(:tool).with("place_option_order").and_return(mock_mcp_tool)
    allow(RATE_LIMITERS[:alpaca_mcp]).to receive(:with_limit).and_yield
    allow(CIRCUIT_BREAKERS[:alpaca_mcp]).to receive(:call).and_yield
  end

  # The PortfolioManager reads its risk decision from the proposal's
  # `risk_decisions` association, NOT by calling Risk::RiskManager#check.
  # So we need a fake decision row on the proposal, not a stub on the
  # risk manager. (The `gating_risk_decision` helper does the read.)
  def stub_risk_approved(proposal)
    decision = RiskDecision.create!(
      trade_proposal: proposal,
      decision: "approved",
      reasons: "[]",
      limit_snapshot: {}
    )
    # Backdate so it doesn't look stale under the decision_ttl window.
    decision.update_columns(created_at: Time.current)
  end

  it "marks the order as rejected and records the broker error message" do
    stub_risk_approved(proposal)
    # Simulate Alpaca's 422 envelope: {"data": {"error": {"http_status": 422, "message": "API rejected the order", "detail": {"code": 40010001, "message": "invalid side"}}}}
    body = {
      "data" => {
        "error" => {
          "http_status" => 422,
          "message" => "API rejected the order",
          "detail" => { "code" => 40010001, "message" => "invalid side" }
        }
      }
    }
    allow(mock_mcp_tool).to receive(:call).and_return(instance_double(RubyLLM::MCP::Content, text: body.to_json))

    result = described_class.execute(proposal)
    expect(result.ok?).to be false
    expect(result.reasons.first).to include("broker_rejected")
    expect(result.reasons.first).to include("invalid side")

    order = Order.find_by(trade_proposal: proposal)
    expect(order.status).to eq("rejected")
    expect(order.rejection_reason).to include("invalid side")
    expect(order.rejection_reason).to include("40010001")
    expect(order.alpaca_order_id).to be_nil

    proposal.reload
    expect(proposal.status).to eq("rejected")
  end

  it "marks the order filled when the broker accepts" do
    stub_risk_approved(proposal)
    body = {
      "data" => {
        "result" => { "id" => "broker-1", "status" => "filled" }
      }
    }
    allow(mock_mcp_tool).to receive(:call).and_return(instance_double(RubyLLM::MCP::Content, text: body.to_json))

    result = described_class.execute(proposal)
    expect(result.ok?).to be true
    order = Order.find_by(trade_proposal: proposal)
    expect(order.status).to eq("filled")
    expect(order.alpaca_order_id).to eq("broker-1")
  end

  it "defers the proposal when the market is closed" do
    stub_risk_approved(proposal)
    allow(MarketClock).to receive(:current).and_return(
      MarketClock::Clock.new(open: false, next_open_at: 1.day.from_now, next_close_at: nil, timestamp: Time.current, source: "test")
    )
    # Tool should NOT be called
    expect(mock_mcp_tool).not_to receive(:call)

    result = described_class.execute(proposal)
    expect(result.ok?).to be false
    expect(result.reasons).to eq(["market_closed"])

    proposal.reload
    expect(proposal.status).to eq("deferred")
    expect(proposal.rejection_reason).to eq("market_closed")
    expect(Order.count).to eq(0) # no order row created
  end
end
