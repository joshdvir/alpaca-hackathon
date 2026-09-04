# frozen_string_literal: true

require 'rails_helper'

# Tests for the weak-signal news proxies used by FilterEngine for the
# earnings + insider criteria. These are intentionally cheap (regex
# over Alpaca news headlines) — see config/trading.yml "DATA-SOURCE
# NOTE" for the upgrade path to a real earnings/insider feed.

RSpec.describe TickerSelector::NewsProxies do # rubocop:disable Metrics/BlockLength
  let(:now) { Time.utc(2026, 8, 29, 12, 0, 0) }

  before { allow(Time).to receive(:now).and_return(now) }

  describe ".recent" do
    it "filters out items older than the window" do
      items = [
        { 'headline' => 'a', 'created_at' => (now - (1 * 86_400)).iso8601 },
        { 'headline' => 'b', 'created_at' => (now - (5 * 86_400)).iso8601 },
        { 'headline' => 'c', 'created_at' => (now - (8 * 86_400)).iso8601 }
      ]
      kept = described_class.recent(items, within_days: 7)
      expect(kept.map { |n| n['headline'] }).to eq(%w[a b])
    end

    it "is empty for empty input" do
      expect(described_class.recent([], within_days: 7)).to eq([])
    end

    it "drops items with missing/blank/malformed created_at" do
      items = [
        { 'headline' => 'a', 'created_at' => nil },
        { 'headline' => 'b' },
        { 'headline' => 'c', 'created_at' => 'not a date' }
      ]
      expect(described_class.recent(items, within_days: 7)).to eq([])
    end
  end

  describe ".earnings_keyword_count" do
    it "counts earnings-related headlines" do
      items = [
        { 'headline' => 'Apple reports strong earnings' },
        { 'headline' => 'Tesla Q3 earnings disappoint' },
        { 'headline' => 'Microsoft fiscal year guidance update' },
        { 'headline' => 'AAPL price target upgrade' }
      ]
      expect(described_class.earnings_keyword_count(items)).to eq(3)
    end

    it "is 0 for empty input" do
      expect(described_class.earnings_keyword_count([])).to eq(0)
    end
  end

  describe ".insider_buy_count" do
    it "counts insider + buy/purchase headlines" do
      items = [
        { 'headline' => 'Insider buys $5M of stock' },
        { 'headline' => 'Insider purchased 10k shares' },
        { 'headline' => 'Insider sells shares' }, # sells, not buy
        { 'headline' => 'Market moves on macro' }
      ]
      expect(described_class.insider_buy_count(items)).to eq(2)
    end

    it "is 0 for empty input" do
      expect(described_class.insider_buy_count([])).to eq(0)
    end
  end

  describe ".insider_buy_value_usd" do
    it "sums $ amounts across insider-buy headlines" do
      items = [
        { 'headline' => 'Insider buys $5M of stock' },
        { 'headline' => 'CEO insider purchase of $250,000' },
        { 'headline' => 'Insider buys $1.2B in shares' },
        { 'headline' => 'Insider sells shares' } # not a buy
      ]
      expect(described_class.insider_buy_value_usd(items)).to be_within(1.0).of(1_205_250_000.0)
    end

    it "is 0.0 for empty input" do
      expect(described_class.insider_buy_value_usd([])).to eq(0.0)
    end
  end
end
