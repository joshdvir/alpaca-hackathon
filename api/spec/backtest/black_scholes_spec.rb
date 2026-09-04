# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Backtest::BlackScholes do
  describe '.price' do
    # Reference values computed against an external Black-Scholes calculator.
    # spot=100, strike=100, t=0.25y, r=0.05, sigma=0.20
    let(:atm) { { spot: 100, strike: 100, t: 0.25, r: 0.05, sigma: 0.20 } }

    it 'computes ATM call price within 0.01 of reference' do
      price = described_class.price(**atm, right: 'C')
      expect(price).to be_within(0.01).of(4.61)
    end

    it 'computes ATM put price within 0.01 of reference' do
      price = described_class.price(**atm, right: 'P')
      expect(price).to be_within(0.01).of(3.37)
    end

    it 'respects put-call parity: C - P = S - K * exp(-r*t)' do
      call = described_class.price(**atm, right: 'C')
      put  = described_class.price(**atm, right: 'P')
      parity = atm[:spot] - (atm[:strike] * Math.exp(-atm[:r] * atm[:t]))
      expect(call - put).to be_within(0.01).of(parity)
    end

    it 'deep ITM call is dominated by intrinsic value' do
      price = described_class.price(spot: 200, strike: 100, t: 0.25, r: 0.05, sigma: 0.20, right: 'C')
      intrinsic = 200 - (100 * Math.exp(-0.05 * 0.25))
      # call >= intrinsic, and the time-value component is small
      expect(price).to be >= intrinsic
      expect(price).to be <  intrinsic + 0.10
    end

    it 'deep OTM call approaches zero' do
      price = described_class.price(spot: 100, strike: 250, t: 0.25, r: 0.05, sigma: 0.20, right: 'C')
      expect(price).to be < 0.001
    end

    it 'handles short-dated options without crashing' do
      price = described_class.price(spot: 100, strike: 100, t: 0.005, r: 0.05, sigma: 0.20, right: 'C')
      expect(price).to be > 0
      expect(price).to be < 5.0
    end
  end

  describe '.greeks' do
    let(:args) { { spot: 100, strike: 100, t: 0.25, r: 0.05, sigma: 0.20, right: 'C' } }

    it 'returns delta near 0.57 for ATM call (S=K=100, t=0.25, r=5%, sigma=20%)' do
      g = described_class.greeks(**args)
      expect(g[:delta]).to be_within(0.05).of(0.57)
    end

    it 'returns delta between -1 and 0 for put' do
      g = described_class.greeks(**args, right: 'P')
      expect(g[:delta]).to be < 0
      expect(g[:delta]).to be > -1
    end

    it 'returns positive gamma for ATM' do
      g = described_class.greeks(**args)
      expect(g[:gamma]).to be > 0
    end

    it 'returns negative theta for long option' do
      g = described_class.greeks(**args)
      expect(g[:theta]).to be < 0
    end

    it 'returns positive vega' do
      g = described_class.greeks(**args)
      expect(g[:vega]).to be > 0
    end

    it 'is symmetric: |call_delta - 0.5| ≈ |put_delta + 0.5|' do
      call_d = described_class.greeks(**args)[:delta]
      put_d  = described_class.greeks(**args, right: 'P')[:delta]
      expect((call_d - 0.5).abs).to be_within(0.001).of((put_d + 0.5).abs)
    end
  end
end
