# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Portfolio::PortfolioManager do
  let(:risk_decision) { instance_double(RiskDecision, created_at: Time.current, decision: 'approved') }
  let(:leg) do
    { 'side' => 'buy_to_open', 'ratio_qty' => 1, 'option_symbol' => 'SPY260116C00580000', 'limit_price' => '1.25' }
  end
  let(:proposal) do
    TradeProposal.create!(
      agent_run: create_agent_run,
      ticker: 'SPY',
      kind: 'new',
      strategy_type: 'vertical',
      legs: [leg],
      max_loss: 500,
      max_profit: 500,
      status: 'risk_approved'
    )
  end
  let(:mock_mcp_tool) { double('MCPTool', name: 'place_option_order', call: nil) }

  before do
    # The production code now uses `client.tool('place_option_order')`
    # (the singleton accessor) instead of `client.tools.find { ... }`.
    allow(ALPACA_MCP_TRADING).to receive(:tool).with('place_option_order').and_return(mock_mcp_tool)
    allow(RATE_LIMITERS[:alpaca_mcp]).to receive(:with_limit).and_yield
    allow(CIRCUIT_BREAKERS[:alpaca_mcp]).to receive(:call).and_yield
    # PortfolioManager#execute now starts with a MarketClock check.
    # Stub it as OPEN so the gate doesn't defer the proposal.
    allow(MarketClock).to receive(:current).and_return(
      MarketClock::Clock.new(open: true, next_open_at: nil, next_close_at: nil, timestamp: Time.current, source: "test")
    )
  end

  # Helper to stub the proposal's risk_decisions chain.
  def stub_risk_decisions_chain(decision)
    chain = double('RiskDecisionsChain')
    ordered = double('Ordered')
    allow(chain).to receive(:where).and_return(ordered)
    allow(ordered).to receive(:order).and_return(ordered)
    allow(ordered).to receive(:first).and_return(decision)
    allow_any_instance_of(TradeProposal).to receive(:risk_decisions).and_return(chain)
  end

  # Helper to set the account's options_approved_level by stubbing
  # the most-recent PortfolioSnapshot lookup that PortfolioManager
  # uses for its level safety net.
  def with_options_level(level)
    snap = PortfolioSnapshot.create!(
      equity: 100_000, cash: 100_000, buying_power: 200_000,
      options_buying_power: 50_000, daily_pl: 0,
      raw: { 'options_approved_level' => level }
    )
    allow(PortfolioSnapshot).to receive(:order).and_return(double(first: snap))
  end

  describe '.execute' do
    it 'returns :ok? result on success' do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'abc123', 'status' => 'filled' })
      result = described_class.execute(proposal)
      expect(result.ok?).to be true
      expect(result.order).to be_a(Order)
      expect(result.reasons).to be_empty
    end

    it 'rejects when no approved risk decision exists' do
      stub_risk_decisions_chain(nil)
      result = described_class.execute(proposal)
      expect(result.ok?).to be false
      expect(result.reasons).to include(/no approved risk decision/i)
    end

    it 'rejects when risk decision is stale (older than decision_ttl_seconds)' do
      stale = instance_double(RiskDecision, created_at: 1.hour.ago, decision: 'approved')
      stub_risk_decisions_chain(stale)
      result = described_class.execute(proposal)
      expect(result.ok?).to be false
      expect(result.reasons).to include(/no approved risk decision/i)
    end

    it 'rejects when proposal has no legs' do
      empty_proposal = TradeProposal.create!(
        agent_run: create_agent_run, ticker: 'SPY', kind: 'new', strategy_type: 'vertical',
        legs: [], max_loss: 0, max_profit: 0, status: 'risk_approved'
      )
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'filled' })
      result = described_class.execute(empty_proposal)
      expect(result.ok?).to be false
      expect(result.reasons).to include(/no legs/i)
    end

    it 'creates an Order row with the OCC symbol from the leg' do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'broker-1', 'status' => 'filled' })
      described_class.execute(proposal)
      order = Order.last
      expect(order.symbol).to eq('SPY260116C00580000')
      expect(order.side).to eq('buy_to_open')
      expect(order.qty).to eq(1)
      expect(order.type).to eq('limit')
      expect(order.status).to eq('filled')
      expect(order.alpaca_order_id).to eq('broker-1')
    end

    it 'reuses an existing Order on idempotent retry (same client_order_id)' do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'broker-1', 'status' => 'filled' })
      first  = described_class.execute(proposal)
      second = described_class.execute(proposal)
      expect(first.ok?).to be true
      expect(second.ok?).to be true
      expect(second.reasons).to include(/idempotent_replay/i)
      expect(Order.count).to eq(1)
    end

    it 'builds a deterministic client_order_id from proposal id + ticker + created_at' do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'filled' })
      described_class.execute(proposal)
      expected = "pm-#{proposal.id}-SPY-#{proposal.created_at.to_i}"
      expect(Order.last.client_order_id).to eq(expected)
    end

    it 'returns a rejected result when the broker raises' do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_raise(StandardError, 'broker 500')
      result = described_class.execute(proposal)
      expect(result.ok?).to be false
      expect(result.reasons.join).to match(/broker 500/)
    end

    it "maps broker 'filled' to Order status 'filled'" do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'filled' })
      described_class.execute(proposal)
      expect(Order.last.status).to eq('filled')
    end

    it "maps broker 'partially_filled' to Order status 'partial'" do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'partially_filled' })
      described_class.execute(proposal)
      expect(Order.last.status).to eq('partial')
    end

    it "maps broker 'canceled' to Order status 'cancelled'" do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'canceled' })
      described_class.execute(proposal)
      expect(Order.last.status).to eq('cancelled')
    end

    it "sends qty as a STRING to the Alpaca MCP (regression: Pydantic rejects int qty)" do
      # The Alpaca MCP's place_option_order tool declares qty as
      # `type: "string"`. Our Order row stores qty as `integer` (Rails
      # default), so PortfolioManager must stringify at the call site.
      # Without this, the broker returns:
      #   "1 validation error for call[place_option_order]
      #    qty  Input should be a valid string
      #    [type=string_type, input_value=10, input_type=int]"
      # and the order is recorded as rejected.
      stub_risk_decisions_chain(risk_decision)
      captured = nil
      allow(mock_mcp_tool).to receive(:call) do |params|
        captured = params
        { 'id' => 'x', 'status' => 'filled' }
      end
      described_class.execute(proposal)
      expect(captured).to have_key(:qty)
      expect(captured[:qty]).to be_a(String)
      expect(captured[:qty]).to eq('1')  # the proposal's qty in the test fixture
    end

    it "splits order.side into side='buy'/'sell' + position_intent='buy_to_open'/etc. (regression: broker 40010001 invalid side)" do
      # The Alpaca MCP's place_option_order tool has TWO side-related
      # fields with different value spaces:
      #   side:            "buy" | "sell"
      #   position_intent: "buy_to_open" | "buy_to_close" |
      #                    "sell_to_open" | "sell_to_close"
      # Our Order.side stores the semantic string ("buy_to_open"). If
      # we put that into `side`, the broker rejects with
      # `code=40010001: invalid side` (422) because it expects the
      # basic "buy" or "sell" there. Submit must split the values.
      stub_risk_decisions_chain(risk_decision)
      captured = nil
      allow(mock_mcp_tool).to receive(:call) do |params|
        captured = params
        { 'id' => 'x', 'status' => 'filled' }
      end
      described_class.execute(proposal)  # fixture uses side: 'buy_to_open'
      expect(captured[:side]).to eq('buy')
      expect(captured[:position_intent]).to eq('buy_to_open')
    end

    it 'promotes the proposal to portfolio_approved on success' do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'filled' })
      described_class.execute(proposal)
      expect(proposal.reload.status).to eq('portfolio_approved')
    end

    describe 'options_approved_level safety net' do
      # The proposal fixture uses side='buy_to_open' which is allowed
      # at every level >= 1. To test the level rejection paths we need
      # a sell_to_open proposal. Build a fresh one per example.
      let(:sell_proposal) do
        TradeProposal.create!(
          agent_run: create_agent_run,
          ticker: 'PLTR',
          kind: 'new',
          strategy_type: 'vertical',
          legs: [{ 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00190000', 'limit_price' => '3.50' }],
          max_loss: 0,
          max_profit: 0,
          status: 'risk_approved'
        )
      end

      def with_options_level(level)
        snap = PortfolioSnapshot.create!(
          equity: 100_000, cash: 100_000, buying_power: 200_000,
          options_buying_power: 50_000, daily_pl: 0,
          raw: { 'options_approved_level' => level }
        )
        # The mirror is order-by-created_at so the new snapshot wins.
        allow(PortfolioSnapshot).to receive(:order).and_return(double(first: snap))
      end

      it 'rejects single-leg sell_to_open on a level-3 account BEFORE calling the broker' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        # The mock_mcp_tool should NEVER be called.
        expect(mock_mcp_tool).not_to receive(:call)

        result = described_class.execute(sell_proposal)
        expect(result.ok?).to be false
        expect(result.reasons.first).to match(/side_level_violation/)
        expect(result.order.status).to eq('rejected')
        expect(result.order.rejection_reason).to match(/naked.*level=3/i)
        expect(sell_proposal.reload.status).to eq('rejected')
      end

      it 'allows sell_to_open on a level-4 account' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(4)
        allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'broker-1', 'status' => 'filled' })

        result = described_class.execute(sell_proposal)
        expect(result.ok?).to be true
        expect(result.order.status).to eq('filled')
      end

      it 'allows a multi-leg spread with sell_to_open on a level-3 account' do
        spread_proposal = TradeProposal.create!(
          agent_run: create_agent_run,
          ticker: 'PLTR',
          kind: 'new',
          strategy_type: 'vertical',
          legs: [
            { 'side' => 'buy_to_open',  'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00190000', 'limit_price' => '3.50' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00200000', 'limit_price' => '2.00' }
          ],
          max_loss: 150, max_profit: 50, status: 'risk_approved'
        )
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'broker-1', 'status' => 'filled' })

        result = described_class.execute(spread_proposal)
        expect(result.ok?).to be true
      end

      it 'passes through silently when the mirror has no level yet (lets the broker be the source of truth)' do
        snap = PortfolioSnapshot.create!(
          equity: 100_000, cash: 100_000, buying_power: 200_000,
          options_buying_power: 50_000, daily_pl: 0, raw: {}
        )
        allow(PortfolioSnapshot).to receive(:order).and_return(double(first: snap))
        stub_risk_decisions_chain(risk_decision)
        allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'filled' })

        result = described_class.execute(sell_proposal)
        expect(result.ok?).to be true
      end
    end

    it 'uses the explicit idempotency_key when provided' do
      stub_risk_decisions_chain(risk_decision)
      allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'x', 'status' => 'filled' })
      described_class.execute(proposal, idempotency_key: 'custom-key-1')
      expect(Order.last.client_order_id).to eq('custom-key-1')
    end

    # ----------------------------------------------------------------
    # Multi-leg (spread) path
    # ----------------------------------------------------------------

    describe 'multi-leg order submission' do
      let(:spread_proposal) do
        TradeProposal.create!(
          agent_run: create_agent_run,
          ticker: 'PLTR',
          kind: 'new',
          strategy_type: 'vertical',
          legs: [
            { 'side' => 'buy_to_open',  'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00190000', 'limit_price' => '3.50' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00200000', 'limit_price' => '2.00', 'net_limit_price' => '1.50' }
          ],
          max_loss: 150, max_profit: 50, status: 'risk_approved'
        )
      end

      it 'sets Order.side to "multi_leg" for spread orders' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'b-1', 'status' => 'filled' })

        result = described_class.execute(spread_proposal)
        expect(result.ok?).to be true
        expect(result.order.side).to eq('multi_leg')
      end

      it 'stores comma-joined OCC symbols on Order.symbol for multi-leg' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'b-2', 'status' => 'filled' })

        result = described_class.execute(spread_proposal)
        expect(result.order.symbol).to eq('PLTR260911C00190000,PLTR260911C00200000')
      end

      it 'calls place_option_order with order_class="mleg" and a legs array' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        # Capture the actual params sent to the broker.
        captured = nil
        allow(mock_mcp_tool).to receive(:call) do |args|
          captured = args
          { 'id' => 'b-3', 'status' => 'filled' }
        end

        described_class.execute(spread_proposal)
        expect(captured[:order_class]).to eq('mleg')
        expect(captured[:legs]).to be_an(Array)
        expect(captured[:legs].size).to eq(2)

        # Each leg entry must have the basic side (buy/sell) AND the
        # position_intent (buy_to_open, etc.) — the broker needs both.
        first, second = captured[:legs]
        expect(first[:symbol]).to eq('PLTR260911C00190000')
        expect(first[:side]).to eq('buy')
        expect(first[:position_intent]).to eq('buy_to_open')
        expect(first[:ratio_qty]).to eq('1')
        expect(second[:symbol]).to eq('PLTR260911C00200000')
        expect(second[:side]).to eq('sell')
        expect(second[:position_intent]).to eq('sell_to_open')
        expect(second[:ratio_qty]).to eq('1')
      end

      it 'passes the net limit_price (positive = debit) to the broker for multi-leg' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        captured = nil
        allow(mock_mcp_tool).to receive(:call) do |args|
          captured = args
          { 'id' => 'b-4', 'status' => 'filled' }
        end

        # Replace the second leg with a credit (negative net) so we
        # verify the sign convention is preserved.
        credit_proposal = TradeProposal.create!(
          agent_run: create_agent_run,
          ticker: 'PLTR',
          kind: 'new',
          strategy_type: 'vertical',
          legs: [
            { 'side' => 'buy_to_open',  'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00190000', 'limit_price' => '1.00' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00200000', 'limit_price' => '2.50', 'net_limit_price' => '-1.50' }
          ],
          max_loss: 150, max_profit: 150, status: 'risk_approved'
        )
        described_class.execute(credit_proposal)
        expect(captured[:limit_price]).to eq('-1.5')
      end

      it 'rejects a multi-leg order where the sell_to_open is NOT covered by a buy_to_open on a level-3 account' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        expect(mock_mcp_tool).not_to receive(:call)

        # Both legs are sell_to_open (naked on both sides). The level
        # check should reject because no leg is buy_to_open.
        naked_spread = TradeProposal.create!(
          agent_run: create_agent_run,
          ticker: 'PLTR',
          kind: 'new',
          strategy_type: 'vertical',
          legs: [
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00190000', 'limit_price' => '3.50' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00200000', 'limit_price' => '2.00' }
          ],
          max_loss: 0, max_profit: 0, status: 'risk_approved'
        )

        result = described_class.execute(naked_spread)
        expect(result.ok?).to be false
        expect(result.reasons.first).to match(/side_level_violation/)
        expect(result.order.status).to eq('rejected')
      end

      it 'allows a multi-leg order with sell_to_open on a level-4 account (no spread-cover needed)' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(4)
        allow(mock_mcp_tool).to receive(:call).and_return({ 'id' => 'b-5', 'status' => 'filled' })

        # Naked spread (both sell_to_open). Level 4 should allow it.
        naked_spread = TradeProposal.create!(
          agent_run: create_agent_run,
          ticker: 'PLTR',
          kind: 'new',
          strategy_type: 'vertical',
          legs: [
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00190000', 'limit_price' => '3.50' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'PLTR260911C00200000', 'limit_price' => '2.00' }
          ],
          max_loss: 0, max_profit: 0, status: 'risk_approved'
        )

        result = described_class.execute(naked_spread)
        expect(result.ok?).to be true
      end

      it 'sends qty as a STRING to the MCP wrapper for multi-leg' do
        stub_risk_decisions_chain(risk_decision)
        with_options_level(3)
        captured = nil
        allow(mock_mcp_tool).to receive(:call) do |args|
          captured = args
          { 'id' => 'b-6', 'status' => 'filled' }
        end

        # qty 3 contract spread
        qty3_spread = TradeProposal.create!(
          agent_run: create_agent_run,
          ticker: 'PLTR',
          kind: 'new',
          strategy_type: 'vertical',
          legs: [
            { 'side' => 'buy_to_open',  'ratio_qty' => 3, 'option_symbol' => 'PLTR260911C00190000', 'limit_price' => '3.50' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 3, 'option_symbol' => 'PLTR260911C00200000', 'limit_price' => '2.00' }
          ],
          max_loss: 0, max_profit: 0, status: 'risk_approved'
        )
        described_class.execute(qty3_spread)
        expect(captured[:qty]).to eq('3')
        expect(captured[:legs].first[:ratio_qty]).to eq('3')
        expect(captured[:legs].last[:ratio_qty]).to eq('3')
      end
    end
  end
end
