# frozen_string_literal: true

# TickerSelector::NewsProxies — weak-signal keyword scans over Alpaca news.
#
# Why this exists: the Alpaca MCP doesn't expose a real earnings calendar
# or SEC Form-4 insider feed. To make `earnings_within_days_max` and the
# `insider_*_min` criteria in trading.yml do SOMETHING, we count news
# headlines that match the relevant patterns. This is a noisy proxy —
# documented as such in config/trading.yml "DATA-SOURCE NOTE".
#
# When a real earnings or insider data source is wired in (SEC EDGAR,
# Alpha Vantage, Polygon, etc.), replace the bodies of these methods —
# the criterion handlers in FilterEngine will keep working unchanged.

module TickerSelector
  class NewsProxies
    EARNINGS_KEYWORDS = %w[
      earnings
      quarterly\s+results
      q[1-4]\s+(results|earnings|guidance)
      guidance
      reports?\s+(strong|weak|earnings|results)
      eps\s+(beat|miss|surprise|of)
      revenue\s+(beat|miss|of|grew|fell)
      fiscal\s+(year|quarter)
    ].freeze

    INSIDER_BUY_PATTERN = /insider.*\b(buy|buys|bought|purchase|purchases|purchased|acquire|acquired)\b/i

    DOLLAR_PATTERN = /\$([\d,.]+)\s*([KMB])?\b/i

    DOLLAR_MULTIPLIERS = { 'K' => 1_000, 'M' => 1_000_000, 'B' => 1_000_000_000 }.freeze

    def self.recent(items, within_days: 7)
      return [] if items.empty?
      cutoff = Time.now.utc - (within_days.to_i * 86_400)
      items.select { |n| within_window?(n, cutoff) }
    end

    def self.earnings_keyword_count(items)
      return 0 if items.empty?
      pattern = Regexp.new(EARNINGS_KEYWORDS.join('|'), Regexp::IGNORECASE)
      items.count { |n| n.is_a?(Hash) && n['headline'].to_s.match?(pattern) }
    end

    def self.insider_buy_count(items)
      return 0 if items.empty?
      items.count { |n| n.is_a?(Hash) && n['headline'].to_s.match?(INSIDER_BUY_PATTERN) }
    end

    def self.insider_buy_value_usd(items)
      return 0.0 if items.empty?
      total = 0.0
      items.each do |n|
        next unless n.is_a?(Hash)
        headline = n['headline'].to_s
        next unless headline.match?(INSIDER_BUY_PATTERN)
        headline.scan(DOLLAR_PATTERN).each do |num, suffix|
          amount = num.gsub(',', '').to_f
          total += amount * DOLLAR_MULTIPLIERS.fetch(suffix&.upcase, 1)
        end
      end
      total
    end

    def self.within_window?(item, cutoff)
      return false unless item.is_a?(Hash)
      created_str = item['created_at'] || item[:created_at]
      return false if created_str.blank?
      Time.parse(created_str.to_s).utc >= cutoff
    rescue ArgumentError
      false
    end
  end
end
