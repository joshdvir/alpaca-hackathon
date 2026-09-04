# frozen_string_literal: true

# Value objects for the Overnight Reversal strategy. Pure data —
# no MCP, no DB, no LLM. Built by Strategy.plan and passed to the
# submit + close activities.
#
# Plan (Hash form, as serialized by BuildPlanActivity):
#   {
#     total_options_buying_power: BigDecimal,
#     total_cash_deployed:        BigDecimal,
#     winner_bucket_budget:       BigDecimal,
#     loser_bucket_budget:        BigDecimal,
#     tick_date:                  "2026-09-02",
#     now_et:                     ISO8601,
#     close_at_et:                ISO8601,    # 15:55 ET today
#     skipped_half_day:           false,
#     skipped_reason:             nil | "half_day" | "no_winners" | "no_losers",
#     winners:    [ WinnerOrder, ... ],
#     losers:     [ SpreadOrder, ... ]
#   }
#
# WinnerOrder (long call, single-leg):
#   {
#     symbol:           "AAPL",
#     pct_change:       3.45,            # yesterday's daily %change
#     cash_allocated:   BigDecimal,
#     strike:           225.0,           # target strike; filled at submit
#     side:             "buy_to_open"
#   }
#
# SpreadOrder (bear call credit spread, two-leg):
#   {
#     symbol:           "TSLA",
#     pct_change:       -4.12,           # yesterday's daily %change
#     cash_allocated:   BigDecimal,      # = max_loss budget
#     short_strike:     250.0,           # sold short call, target delta 0.20
#     long_strike:      255.0,           # bought protective call, short+width
#     side:             "sell_to_open",
#     short_leg_side:   "sell_to_open",
#     long_leg_side:    "buy_to_open"
#   }
#
# Spread contracts are sized so `cash_allocated ≈ qty × width × 100`
# (the max-loss approximation). At submit time the activity fills
# in the actual premium quotes; per-contract qty is recomputed from
# the live chain.
#
# Namespace note: Zeitwerk maps `app/strategies/overnight_reversal/plan.rb`
# to `OvernightReversal::Plan`. The `::` paths used elsewhere
# (activities, workflows) all live under `OvernightReversal::`.

module OvernightReversal
  WinnerOrder = Struct.new(
    :symbol, :pct_change, :cash_allocated, :strike, :side, :dte_target,
    keyword_init: true
  )

  SpreadOrder = Struct.new(
    :symbol, :pct_change, :cash_allocated,
    :short_strike, :long_strike, :width,
    :short_leg_side, :long_leg_side, :dte_target,
    keyword_init: true
  )

  Plan = Struct.new(
    :total_options_buying_power, :total_cash_deployed,
    :winner_bucket_budget, :loser_bucket_budget,
    :tick_date, :now_et, :close_at_et,
    :skipped, :skipped_reason,
    :winners, :losers,
    keyword_init: true
  ) do
    # Class-level "empty plan" for no-trade days (half-day, no
    # survivors, etc.). Caller must inspect `:skipped` before
    # spawning a CloseWorkflow — when true, the workflow should
    # exit immediately.
    def self.empty(now_et:, skipped_reason: 'unknown')
      new(
        total_options_buying_power: 0,
        total_cash_deployed:        0,
        winner_bucket_budget:       0,
        loser_bucket_budget:        0,
        tick_date:                  now_et.to_date.to_s,
        now_et:                     now_et.iso8601,
        close_at_et:                (now_et + 1.second).iso8601,
        skipped:                    true,
        skipped_reason:             skipped_reason,
        winners:                    [],
        losers:                     []
      )
    end

    # Hash form for Temporal activity result. The workflow receives
    # this back as a JSON-decoded hash; downstream activities
    # (`SubmitOrdersActivity`) re-hydrate it via `Plan.from_h`.
    def self.to_h(plan)
      {
        'total_options_buying_power' => plan.total_options_buying_power.to_s,
        'total_cash_deployed'        => plan.total_cash_deployed.to_s,
        'winner_bucket_budget'       => plan.winner_bucket_budget.to_s,
        'loser_bucket_budget'        => plan.loser_bucket_budget.to_s,
        'tick_date'                  => plan.tick_date,
        'now_et'                     => plan.now_et,
        'close_at_et'                => plan.close_at_et,
        'skipped'                    => plan.skipped,
        'skipped_reason'             => plan.skipped_reason,
        'winners' => plan.winners.map { |w| winner_to_h(w) },
        'losers'  => plan.losers.map  { |l| spread_to_h(l) }
      }
    end

    def self.winner_to_h(w)
      {
        'symbol'         => w.symbol,
        'pct_change'     => w.pct_change,
        'cash_allocated' => w.cash_allocated.to_s,
        'strike'         => w.strike,
        'side'           => w.side,
        # Serialize dte_target as an array even if it's a single
        # Integer — keeps the wire format uniform with multi-DTE
        # orders and lets the order-time caller iterate uniformly.
        'dte_target'     => Array(w.dte_target).map(&:to_i)
      }
    end

    def self.spread_to_h(l)
      {
        'symbol'          => l.symbol,
        'pct_change'      => l.pct_change,
        'cash_allocated'  => l.cash_allocated.to_s,
        'short_strike'    => l.short_strike,
        'long_strike'     => l.long_strike,
        'width'           => l.width,
        'short_leg_side'  => l.short_leg_side,
        'long_leg_side'   => l.long_leg_side,
        'dte_target'      => Array(l.dte_target).map(&:to_i)
      }
    end

    def self.from_h(h)
      new(
        total_options_buying_power: BigDecimal((h['total_options_buying_power'] || '0').to_s),
        total_cash_deployed:        BigDecimal((h['total_cash_deployed'] || '0').to_s),
        winner_bucket_budget:       BigDecimal((h['winner_bucket_budget'] || '0').to_s),
        loser_bucket_budget:        BigDecimal((h['loser_bucket_budget'] || '0').to_s),
        tick_date:                  h['tick_date'],
        now_et:                     h['now_et'],
        close_at_et:                h['close_at_et'],
        skipped:                    h['skipped'] == true,
        skipped_reason:             h['skipped_reason'],
        winners: Array(h['winners']).map { |w| winner_from_h(w) },
        losers:  Array(h['losers']).map  { |l| spread_from_h(l) }
      )
    end

    def self.winner_from_h(h)
      WinnerOrder.new(
        symbol:         h['symbol'],
        pct_change:     h['pct_change']&.to_f,
        cash_allocated: BigDecimal(h['cash_allocated'].to_s),
        strike:         h['strike']&.to_f,
        side:           h['side'] || 'buy_to_open',
        dte_target:     Array(h['dte_target']).map(&:to_i).reject(&:negative?).uniq.sort
      )
    end

    def self.spread_from_h(h)
      SpreadOrder.new(
        symbol:         h['symbol'],
        pct_change:     h['pct_change']&.to_f,
        cash_allocated: BigDecimal(h['cash_allocated'].to_s),
        short_strike:   h['short_strike']&.to_f,
        long_strike:    h['long_strike']&.to_f,
        width:          h['width']&.to_f,
        short_leg_side: h['short_leg_side'] || 'sell_to_open',
        long_leg_side:  h['long_leg_side'] || 'buy_to_open',
        dte_target:     Array(h['dte_target']).map(&:to_i).reject(&:negative?).uniq.sort
      )
    end
  end
end
