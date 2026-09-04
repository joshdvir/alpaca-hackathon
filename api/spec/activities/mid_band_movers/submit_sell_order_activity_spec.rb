# frozen_string_literal: true

require "rails_helper"

# Tests for SubmitSellOrderActivity. The activity closes a single
# position by submitting a market sell_to_close. We stub
# RiskManager + PortfolioManager — the activity just orchestrates
# DB writes + a couple of pipeline calls.

RSpec.describe MidBandMovers::SubmitSellOrderActivity do
  let(:info)     { instance_double(Temporalio::Activity::Info, workflow_id: "wf-mbm-sell-1", workflow_run_id: "run-1") }
  let(:activity) { instance_double(Temporalio::Activity::Context, logger: Logger.new(File::NULL), info: info) }

  let(:position) do
    Position.create!(
      symbol: "AAPL260515C00200000",
      asset_class: "us_option",
      qty: 2,
      avg_entry_price: 5.0,
      origin: "mid_band_movers",
      strategy_bucket: "A",
      planned_sell_at: 2.hours.from_now,
      snapshot_at: Time.current
    )
  end

  before do
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity)
    ok_result = instance_double('Portfolio::PortfolioManager::Result', ok?: true, reasons: [], order: nil)
    allow(Portfolio::PortfolioManager).to receive(:execute).and_return(ok_result)
  end

  describe '#execute' do
    it 'submits a sell_to_close for an open position' do
      result = described_class.new.execute(position.id, {})
      expect(result[:outcome]).to eq('submitted')
      proposal = TradeProposal.where(closes_position: position).last
      expect(proposal).to be_present
      expect(proposal.kind).to eq('auto_close')
      expect(proposal.origin).to eq('mid_band_movers')
      expect(proposal.legs.first['side']).to eq('sell_to_close')
      expect(proposal.legs.first['ratio_qty']).to eq(2)
    end

    it 'tags the proposal rationale with bucket + planned_sell_at' do
      described_class.new.execute(position.id, {})
      proposal = TradeProposal.where(closes_position: position).last
      meta = JSON.parse(proposal.rationale)
      expect(meta['origin']).to eq('mid_band_movers')
      expect(meta['bucket']).to eq('A')
      expect(meta['planned_sell_at']).to be_a(String)
    end

    it 'returns noop when the position is already closed' do
      position.update!(closed_at: Time.current, qty: 0)
      result = described_class.new.execute(position.id, {})
      expect(result[:outcome]).to eq('noop')
      expect(TradeProposal.where(closes_position: position).count).to eq(0)
    end

    it 'returns noop when the position is missing' do
      result = described_class.new.execute(999_999, {})
      expect(result[:outcome]).to eq('noop')
    end

    it 'returns noop when qty is 0' do
      position.update!(qty: 0)
      result = described_class.new.execute(position.id, {})
      expect(result[:outcome]).to eq('noop')
    end

    it 'returns rejected_by_risk when the risk check rejects' do
      decision = instance_double('Risk::Decision', rejected?: true, reasons: ['would exceed aggregate Greeks limits'])
      allow(Risk::RiskManager).to receive(:new).and_return(instance_double('Risk::RiskManager', check: decision))
      result = described_class.new.execute(position.id, {})
      expect(result[:outcome]).to eq('rejected_by_risk')
      proposal = TradeProposal.where(closes_position: position).last
      expect(proposal.status).to eq('rejected')
    end

    it 'returns broker_error when the portfolio executor fails' do
      decision = instance_double('Risk::Decision', rejected?: false, reasons: [])
      allow(Risk::RiskManager).to receive(:new).and_return(instance_double('Risk::RiskManager', check: decision))
      err_result = instance_double('Portfolio::PortfolioManager::Result', ok?: false, reasons: ['broker_rejected: 422'])
      allow(Portfolio::PortfolioManager).to receive(:execute).and_return(err_result)
      result = described_class.new.execute(position.id, {})
      expect(result[:outcome]).to eq('broker_error')
      expect(result[:reasons]).to include(match(/broker_rejected/))
    end
  end
end
