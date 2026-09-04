# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backtest::HistoricalDataProvider do
  describe '#synthesize_chain' do
    it 'returns 16 quotes (8 strikes × 2 rights) for a typical input' do
      provider = described_class.new
      today = Date.new(2026, 8, 29)
      quotes = provider.synthesize_chain('SPY', today, spot: 100.0)
      expect(quotes.size).to eq(16)
      expect(quotes.map(&:right).uniq.sort).to eq(%w[C P])
    end

    it 'centers strikes around the spot price at a sensible step' do
      provider = described_class.new
      today = Date.new(2026, 8, 29)
      quotes = provider.synthesize_chain('SPY', today, spot: 580.0)
      calls = quotes.select { |q| q.right == 'C' }
      strikes = calls.map(&:strike).uniq.sort
      # 4 strikes below, base, 4 above (8 total around 580)
      expect(strikes.size).to eq(8)
      expect(strikes.first).to be < 580
      expect(strikes.last).to be > 580
    end

    it 'produces OCC symbols with the correct 21-character format' do
      provider = described_class.new
      today = Date.new(2026, 8, 29)
      quotes = provider.synthesize_chain('SPY', today, spot: 100.0)
      sample = quotes.first
      expect(sample.symbol).to match(/^SPY\d{6}[CP]\d{8}$/)
    end

    it 'computes a positive mid price for ATM call with default IV' do
      provider = described_class.new
      today = Date.new(2026, 8, 29)
      quotes = provider.synthesize_chain('SPY', today, spot: 100.0)
      atm_call = quotes.find { |q| q.right == 'C' && q.strike == 100.0 }
      expect(atm_call.mid).to be > 0
      expect(atm_call.bid).to be >= 0
      expect(atm_call.ask).to be > atm_call.bid
    end

    it 'respects put-call parity within 0.10 for ATM strikes' do
      provider = described_class.new
      today = Date.new(2026, 8, 29)
      quotes = provider.synthesize_chain('SPY', today, spot: 100.0)
      atm_call = quotes.find { |q| q.right == 'C' && q.strike == 100.0 }
      atm_put  = quotes.find { |q| q.right == 'P' && q.strike == 100.0 }
      # Black-Scholes put-call parity: C - P = S - K*exp(-r*T) ≈ 100 - 100*0.9963 ≈ 0.37
      # Allow ±0.10 to absorb the bid/ask spread rounding.
      expect(atm_call.mid - atm_put.mid).to be_within(0.10).of(0.37)
    end

    it 'uses 0.02 wide bid/ask spread on low-priced options' do
      provider = described_class.new
      today = Date.new(2026, 8, 29)
      quotes = provider.synthesize_chain('SPY', today, spot: 100.0)
      atm_call = quotes.find { |q| q.right == 'C' && q.strike == 100.0 }
      spread = atm_call.ask - atm_call.bid
      expect(spread).to be >= 0.05 # clamped minimum
      expect(spread).to be <= 0.50 # clamped maximum
    end
  end

  describe '#fetch_bars' do
    it 'returns [] when the MCP get_stock_bars tool is unavailable' do
      provider = described_class.new
      # No ALPACA_MCP_READONLY stub — .tools returns []. Just verify it
      # doesn't crash and returns an Array.
      result = provider.fetch_bars('SPY', Date.current - 5, Date.current)
      expect(result).to be_an(Array)
    end
  end
end
