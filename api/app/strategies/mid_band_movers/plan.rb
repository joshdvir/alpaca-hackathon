# frozen_string_literal: true

# Value objects for the mid-band-movers strategy. Pure data — no
# MCP calls, no DB, no LLM. Built by Strategy.plan and passed to
# the buy-order activity, which does the per-ticker option-chain
# lookup and computes the contract count.
#
# Plan (Hash form, as serialized by BuildPlanActivity):
#   {
#     total_options_buying_power: BigDecimal,
#     total_cash_deployed:        BigDecimal,    # sum across the 3 buckets
#     tick_date:                 "2026-09-01",   # for child workflow IDs
#     now_et:                    ISO8601,        # anchor for sell scheduling
#     a: { ...Bucket... },
#     b: { ...Bucket... },
#     c: { ...Bucket... }
#   }
#
# Each Bucket:
#   {
#     name:                  "A",
#     hold_hours:            2,
#     sell_at_offset_hours:  2,             # hours from now to sell
#     ticker_count:          4,
#     cash_per_ticker:       BigDecimal,
#     orders: [
#       { "symbol": "BABA", "cash_allocated": BigDecimal },
#       ...
#     ]
#   }
#
# Note: per-contract qty is NOT in the Plan. The buy activity
# computes qty at submit time by looking up the ATM 30-DTE call
# premium, so stale premiums (e.g., from cache) don't leak into the
# trade.
#
# Namespace is `MidBandMovers` (not `Strategies::MidBandMovers`)
# because Zeitwerk maps `app/strategies/mid_band_movers/plan.rb`
# to the constant `MidBandMovers::Plan` — anything deeper would
# require either renaming the directory or a custom
# `Rails.autoloaders.main.push_dir` config. The other namespaces
# (activities, workflows) all use `MidBandMovers::` already, so
# this is consistent.
module MidBandMovers
  Order = Struct.new(:symbol, :cash_allocated, keyword_init: true)

  Bucket = Struct.new(
    :name, :hold_hours, :sell_at_offset_hours, :ticker_count, :cash_per_ticker, :orders,
    keyword_init: true
  )

  Plan = Struct.new(
    :total_options_buying_power, :total_cash_deployed, :tick_date, :now_et,
    :a, :b, :c,
    keyword_init: true
  ) do
    # --- class methods on Plan ---

    def self.empty(now_et: Time.current)
      new(
        total_options_buying_power: 0,
        total_cash_deployed: 0,
        tick_date: now_et.to_date.to_s,
        now_et: now_et.iso8601,
        a: Bucket.empty('A'),
        b: Bucket.empty('B'),
        c: Bucket.empty('C')
      )
    end

    def self.empty_bucket(name)
      Bucket.empty(name)
    end

    # Hash form for the Temporal activity result. The workflow
    # receives this back as a JSON-decoded hash.
    def self.to_h(plan)
      {
        'total_options_buying_power' => plan.total_options_buying_power.to_s,
        'total_cash_deployed'        => plan.total_cash_deployed.to_s,
        'tick_date'                  => plan.tick_date,
        'now_et'                     => plan.now_et,
        'a' => Bucket.to_h(plan.a),
        'b' => Bucket.to_h(plan.b),
        'c' => Bucket.to_h(plan.c)
      }
    end

    def self.from_h(h)
      new(
        total_options_buying_power: BigDecimal(h['total_options_buying_power'].to_s),
        total_cash_deployed:        BigDecimal(h['total_cash_deployed'].to_s),
        tick_date:                  h['tick_date'],
        now_et:                     h['now_et'],
        a:                          Bucket.from_h(h['a']),
        b:                          Bucket.from_h(h['b']),
        c:                          Bucket.from_h(h['c'])
      )
    end
  end

  # --- class methods on Bucket ---

  class Bucket
    def self.empty(name)
      new(
        name: name,
        hold_hours: 0,
        sell_at_offset_hours: 0,
        ticker_count: 0,
        cash_per_ticker: 0,
        orders: []
      )
    end

    def self.to_h(b)
      {
        'name'                  => b.name,
        'hold_hours'            => b.hold_hours,
        'sell_at_offset_hours'  => b.sell_at_offset_hours,
        'ticker_count'          => b.ticker_count,
        'cash_per_ticker'       => b.cash_per_ticker.to_s,
        'orders' => b.orders.map do |o|
          { 'symbol' => o.symbol, 'cash_allocated' => o.cash_allocated.to_s }
        end
      }
    end

    def self.from_h(h)
      new(
        name:                 h['name'],
        hold_hours:           h['hold_hours'],
        sell_at_offset_hours: h['sell_at_offset_hours'],
        ticker_count:         h['ticker_count'],
        cash_per_ticker:      BigDecimal(h['cash_per_ticker'].to_s),
        orders: h['orders'].map do |o|
          Order.new(
            symbol:         o['symbol'],
            cash_allocated: BigDecimal(o['cash_allocated'].to_s)
          )
        end
      )
    end
  end
end
