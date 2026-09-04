# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveUpdatesBroadcaster do
  describe ".publish" do
    it "broadcasts a payload to the named ActionCable stream" do
      expect(ActionCable.server).to receive(:broadcast)
        .with("live_updates:trades", { event: "created", record: { id: 1 } })
      described_class.publish(:trades, { event: "created", record: { id: 1 } })
    end

    it "ignores unknown stream names" do
      expect(ActionCable.server).not_to receive(:broadcast)
      described_class.publish(:unknown, { foo: 1 })
    end

    it "accepts string stream names" do
      expect(ActionCable.server).to receive(:broadcast)
        .with("live_updates:agent_runs", anything)
      described_class.publish("agent_runs", { foo: 1 })
    end
  end

  describe ".infer_stream" do
    it "maps TradeProposal to :trades" do
      ar = create_agent_run
      tp = TradeProposal.create!(
        agent_run: ar, ticker: "SPY", kind: "new", strategy_type: "vertical",
        legs: [], max_loss: 0, max_profit: 0, status: "pending"
      )
      expect(described_class.infer_stream(tp)).to eq(:trades)
    end

    it "maps Order to :trades" do
      ar = create_agent_run
      tp = TradeProposal.create!(
        agent_run: ar, ticker: "SPY", kind: "new", strategy_type: "vertical",
        legs: [], max_loss: 0, max_profit: 0, status: "pending"
      )
      order = Order.create!(
        client_order_id: "x", symbol: "SPY260116C00580000",
        side: "buy_to_open", qty: 1, type: "limit", status: "new",
        trade_proposal: tp
      )
      expect(described_class.infer_stream(order)).to eq(:trades)
    end

    it "maps BacktestRun to :backtests" do
      run = BacktestRun.create!(
        tickers: ["SPY"], period_days: 30, mode: "full",
        start_of_day_equity: 100_000, status: "pending"
      )
      expect(described_class.infer_stream(run)).to eq(:backtests)
    end

    it "maps BacktestTrade to :backtests" do
      run = BacktestRun.create!(
        tickers: ["SPY"], period_days: 30, mode: "full",
        start_of_day_equity: 100_000, status: "pending"
      )
      bt = BacktestTrade.create!(
        backtest_run: run, ticker: "SPY", strategy_type: "x", legs: [],
        entry_price: 1, exit_price: 1, pnl: 0,
        opened_at: Time.current, closed_at: Time.current
      )
      expect(described_class.infer_stream(bt)).to eq(:backtests)
    end

    it "maps AgentRun to :agent_runs" do
      ar = create_agent_run
      expect(described_class.infer_stream(ar)).to eq(:agent_runs)
    end

    it "returns nil for unknown models" do
      snapshot = PortfolioSnapshot.create!
      expect(described_class.infer_stream(snapshot)).to be_nil
    end
  end

  describe ".publish_for (integration with after_commit)" do
    it "fires when a TradeProposal is created" do
      ar = create_agent_run
      expect(ActionCable.server).to receive(:broadcast)
        .with("live_updates:trades", hash_including(event: "created"))
        .once
      TradeProposal.create!(
        agent_run: ar, ticker: "SPY", kind: "new", strategy_type: "vertical",
        legs: [], max_loss: 0, max_profit: 0, status: "pending"
      )
    end

    it "fires when a BacktestRun status changes" do
      run = BacktestRun.create!(
        tickers: ["SPY"], period_days: 30, mode: "full",
        start_of_day_equity: 100_000, status: "pending"
      )
      expect(ActionCable.server).to receive(:broadcast)
        .with("live_updates:backtests", hash_including(event: "updated"))
        .once
      run.update!(status: "running")
    end
  end
end
