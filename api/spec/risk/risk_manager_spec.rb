# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Risk::RiskManager do
  let(:manager) { described_class.new }

  before do
    # Defaults: 0 open positions, no daily loss, no kill switch file
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(Rails.root.join('tmp/kill_switch')).and_return(false)
    allow(Position).to receive(:open).and_return(Position.none)
    allow(PortfolioSnapshot).to receive_message_chain(:where, :order, :first).and_return(nil)
  end

  describe '#check' do
    it 'approves a normal proposal' do
      proposal = create_proposal
      decision = manager.check(proposal)
      expect(decision.approved?).to be true
      expect(decision.reasons).to be_empty
    end

    it 'rejects when kill switch is on' do
      allow_any_instance_of(Risk::RiskManager).to receive(:kill_switch_on?).and_return(true)
      proposal = create_proposal
      decision = manager.check(proposal)
      expect(decision.approved?).to be false
      expect(decision.reasons).to include(/kill switch/i)
    end

    it 'rejects when max_open_positions would be exceeded' do
      allow(Position).to receive(:open).and_return(Position.where('1=1'))
      stub_const('Risk::RiskManager::LIMITS',
                 TradingConfig.fetch(:risk_limits).merge(max_open_positions: 0))
      proposal = create_proposal
      decision = manager.check(proposal)
      expect(decision.approved?).to be false
      expect(decision.reasons.join).to match(/max_open_positions/)
    end

    it 'rejects when notional exceeds max_notional_per_trade' do
      proposal = create_proposal(max_loss: TradingConfig.fetch(:risk_limits, :max_notional_per_trade).to_i + 1)
      decision = manager.check(proposal)
      expect(decision.approved?).to be false
      expect(decision.reasons.join).to match(/notional/)
    end

    it 'rejects when daily loss exceeds max_daily_loss' do
      snap = double('PortfolioSnapshot', daily_pl: -TradingConfig.fetch(:risk_limits, :max_daily_loss).to_i)
      allow(PortfolioSnapshot).to receive_message_chain(:where, :order, :first).and_return(snap)
      proposal = create_proposal
      decision = manager.check(proposal)
      expect(decision.approved?).to be false
      expect(decision.reasons.join).to match(/daily_loss/)
    end

    it 'does not count roll/close proposals against max_open_positions' do
      allow(Position).to receive(:open).and_return(Position.where('1=1'))
      stub_const('Risk::RiskManager::LIMITS',
                 TradingConfig.fetch(:risk_limits).merge(max_open_positions: 0))
      proposal = create_proposal(kind: 'roll')
      decision = manager.check(proposal)
      expect(decision.reasons.join).not_to match(/max_open_positions/)
    end

    it 'persists a RiskDecision for every check' do
      proposal = create_proposal
      expect { manager.check(proposal) }.to change { RiskDecision.count }.by(1)
      last = RiskDecision.last
      expect(last.trade_proposal).to eq(proposal)
      expect(last.decision).to eq('approved')
    end

    it 'persists a rejected RiskDecision with reasons' do
      allow_any_instance_of(Risk::RiskManager).to receive(:kill_switch_on?).and_return(true)
      proposal = create_proposal
      manager.check(proposal)
      last = RiskDecision.last
      expect(last.decision).to eq('rejected')
      reasons = JSON.parse(last.reasons)
      expect(reasons).to include(/kill switch/i)
    end

    describe 'multi-leg GCD pre-flight (broker rule code=42210000)' do
      it 'approves a multi-leg order with coprime ratio_qty' do
        proposal = TradeProposal.create!(
          ticker: 'SPY', kind: 'new', strategy_type: 'iron_condor',
          legs: [
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'SPY260116P00500000', 'limit_price' => '1.0', 'net_limit_price' => '-1.5' },
            { 'side' => 'buy_to_open',  'ratio_qty' => 1, 'option_symbol' => 'SPY260116P00490000', 'limit_price' => '0.5' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 1, 'option_symbol' => 'SPY260116C00520000', 'limit_price' => '1.0' },
            { 'side' => 'buy_to_open',  'ratio_qty' => 1, 'option_symbol' => 'SPY260116C00530000', 'limit_price' => '0.5' }
          ],
          max_loss: 500, max_profit: 500, status: 'pending'
        )
        expect(manager.check(proposal).approved?).to be true
      end

      it 'rejects a multi-leg order whose ratio_qty GCD > 1 (the broker rule)' do
        # Iron condor with ratio_qty=2 on every leg → GCD = 2.
        # This is exactly what produced the live "API rejected the
        # order (leg ratio quantities should be relatively prime:
        # GCD[2 2 2 2] = 2) [code=42210000]" rejection.
        proposal = TradeProposal.create!(
          ticker: 'MA', kind: 'new', strategy_type: 'iron_condor',
          legs: [
            { 'side' => 'sell_to_open', 'ratio_qty' => 2, 'option_symbol' => 'MA261016P00555000', 'limit_price' => '0', 'net_limit_price' => '-3.0' },
            { 'side' => 'buy_to_open',  'ratio_qty' => 2, 'option_symbol' => 'MA261016P00545000', 'limit_price' => '0' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 2, 'option_symbol' => 'MA261016C00620000', 'limit_price' => '0' },
            { 'side' => 'buy_to_open',  'ratio_qty' => 2, 'option_symbol' => 'MA261016C00630000', 'limit_price' => '0' }
          ],
          max_loss: 1500, max_profit: 600, status: 'pending'
        )
        decision = manager.check(proposal)
        expect(decision.approved?).to be false
        expect(decision.reasons.join).to match(/relatively prime|GCD/)
      end

      it 'rejects GCD=3 (any common factor > 1, not just even numbers)' do
        proposal = TradeProposal.create!(
          ticker: 'SPY', kind: 'new', strategy_type: 'iron_condor',
          legs: [
            { 'side' => 'sell_to_open', 'ratio_qty' => 3, 'option_symbol' => 'A', 'limit_price' => '0' },
            { 'side' => 'buy_to_open',  'ratio_qty' => 3, 'option_symbol' => 'B', 'limit_price' => '0' },
            { 'side' => 'sell_to_open', 'ratio_qty' => 3, 'option_symbol' => 'C', 'limit_price' => '0' },
            { 'side' => 'buy_to_open',  'ratio_qty' => 3, 'option_symbol' => 'D', 'limit_price' => '0' }
          ],
          max_loss: 500, max_profit: 500, status: 'pending'
        )
        decision = manager.check(proposal)
        expect(decision.approved?).to be false
        expect(decision.reasons.join).to match(/relatively prime|GCD/)
      end

      it 'does not run the GCD check for single-leg orders' do
        # A single leg is allowed any ratio_qty; the GCD of a
        # single number is itself, but we only run the check for
        # 2+ legs (single-leg "multi-leg" would be a degenerate
        # case and the broker doesn't have a notion of a 1-leg
        # mleg order).
        proposal = TradeProposal.create!(
          ticker: 'SPY', kind: 'new', strategy_type: 'long_call',
          legs: [
            { 'side' => 'buy_to_open', 'ratio_qty' => 5, 'option_symbol' => 'SPY260116C00500000', 'limit_price' => '1.0' }
          ],
          max_loss: 500, max_profit: 500, status: 'pending'
        )
        expect(manager.check(proposal).approved?).to be true
      end

      it 'persists the GCD rejection on the RiskDecision for audit' do
        proposal = TradeProposal.create!(
          ticker: 'SPY', kind: 'new', strategy_type: 'iron_condor',
          legs: [
            { 'side' => 'sell_to_open', 'ratio_qty' => 2, 'option_symbol' => 'A', 'limit_price' => '0' },
            { 'side' => 'buy_to_open',  'ratio_qty' => 2, 'option_symbol' => 'B', 'limit_price' => '0' }
          ],
          max_loss: 500, max_profit: 500, status: 'pending'
        )
        manager.check(proposal)
        last = RiskDecision.last
        expect(last.decision).to eq('rejected')
        reasons = JSON.parse(last.reasons)
        expect(reasons.join).to match(/relatively prime|GCD/)
      end
    end
  end
end
