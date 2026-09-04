# frozen_string_literal: true

# Trader — converts the ResearchManager's plan into a concrete trade proposal.
# Returns a JSON object describing a single option order:
#   - symbol:    OCC option symbol (e.g. SPY260116C00580000)
#   - side:      "buy_to_open" | "sell_to_open" | ...
#   - qty:       integer contracts. The LLM is the AUTHORITATIVE source
#               for qty — there is no default. The LLM picks qty as part
#               of its directional prediction: it scales by confidence,
#               conviction, budget, and the chosen strike's price.
#   - limit_price: decimal
#   - tif:       "day" | "gtc"
#   - rationale: short string
#
# The Trader does NOT call any MCP tools — it is pure reasoning over the
# research manager's plan. The PortfolioManager will turn this into an actual
# Alpaca order.

class Trader < Agent
  RUN_KIND = 'trader'

  # Hard minimum the LLM must respect even if its proposal is below
  # this. 1 contract is the smallest order Alpaca accepts for options,
  # so anything below 1 is a bug or a "skip" signal. The LLM is the
  # source of truth for qty; this constant only protects the parser
  # from an obviously bad value.
  MIN_QTY = 1

  # Hard cap on qty the parser will accept from the LLM. Even if the
  # model wants to go big, no single order can exceed this — it's
  # a safety floor below the deterministic risk limit. The real
  # cap is `risk_limits.max_notional_per_trade`, enforced downstream
  # by PortfolioManager. This is a parser-time guardrail against a
  # wildly-large LLM output (e.g. "qty: 1000" on a 1-lot strategy).
  MAX_QTY = 100

  def user_payload(ticker, plan, market_state)
    # Pull the live broker mirror so the LLM knows exactly how much
    # money it has to work with this minute. The mirror job syncs
    # every 30s, so a stale snapshot is at most 30s behind the
    # broker — close enough for sizing decisions.
    snap = PortfolioSnapshot.order(created_at: :desc).first
    buying_power  = snap&.options_buying_power.to_f
    equity        = snap&.equity.to_f
    cash          = snap&.cash.to_f
    # The account's options_approved_level is what determines which
    # option sides the broker will actually accept. We pass it to
    # the LLM so it doesn't propose strategies the account can't
    # fill (e.g. naked short calls on a level-3 paper account).
    # PortfolioManager re-validates this server-side as a safety
    # net (catches LLM hallucinations and prompt-injection).
    options_level = (snap&.raw || {})['options_approved_level']

    {
      ticker: ticker,
      plan: plan,
      market_state: market_state,
      # The LLM decides qty — no default is set or suggested. We
      # hand it the full account picture so it can size aggressively
      # (use the whole account) or conservatively (use a fraction)
      # based on the strategy. The `risk_limits.max_notional_per_trade`
      # cap and the daily-loss guard are still enforced downstream
      # by RiskManager.
      account: {
        cash:                  cash,
        equity:                equity,
        options_buying_power:  buying_power,
        options_approved_level: options_level
      },
      risk_limits: {
        max_notional_per_trade: TradingConfig.fetch(:risk_limits, :max_notional_per_trade),
        max_position_pct:       TradingConfig.fetch(:risk_limits, :max_position_pct),
        max_daily_loss_pct:     TradingConfig.fetch(:risk_limits, :max_daily_loss_pct)
      },
      market_state_summary: {
        spot: market_state.is_a?(Hash) ? market_state.dig('latest', 'price') || market_state['spot'] : nil
      }
    }
  end

  def parse(content)
    data = extract_json(content.to_s.strip)
    proposal = data.fetch('proposal')
    # Return the proposal wrapped under the `:proposal` key so the
    # shape matches Trader.default_brief (`{proposal: nil, _insufficient: ...}`).
    # RunExecutionPhaseActivity checks `result[:proposal].nil?` to
    # detect failure — without this wrapper every successful parse
    # would be mis-marked as "trader returned insufficient brief"
    # because the bare fields don't include a `:proposal` key.
    #
    # Two accepted shapes:
    #   1. Single-leg (legacy + long-only): {proposal: {symbol, side, qty, limit_price}}
    #   2. Multi-leg (new): {proposal: {legs: [{symbol, side, qty, limit_price}, ...]}}
    # We normalize both to {proposal: {legs: [...], tif, rationale}} so
    # the rest of the pipeline (TradeProposal + PortfolioManager) only
    # ever sees the legs-array shape.
    legs =
      if proposal['legs'].is_a?(Array) && proposal['legs'].any?
        # Multi-leg path. Each leg must have a symbol, side, and qty.
        # limit_price is optional per-leg for some strategies but
        # required for the whole order's net limit price at submission
        # (the broker treats multi-leg as a net-debit/credit).
        proposal['legs'].map do |leg|
          qty = clamp_qty(leg['qty'])
          {
            'symbol'      => leg['symbol'].to_s,
            'side'        => leg['side'].to_s,
            'qty'         => qty,
            'limit_price' => leg['limit_price']
          }
        end
      elsif proposal['symbol'] && proposal['side']
        # Single-leg path (legacy / long-only). Wrap into a one-leg
        # array so the rest of the pipeline stays shape-uniform.
        [{
          'symbol'      => proposal['symbol'].to_s,
          'side'        => proposal['side'].to_s,
          'qty'         => clamp_qty(proposal['qty']),
          'limit_price' => proposal['limit_price']
        }]
      else
        raise ParseError,
              "trader proposal must have either 'legs' (multi-leg) or " \
              "'symbol'+'side' (single-leg); got keys=#{proposal.keys.inspect}"
      end

    # For multi-leg orders, the broker uses a SINGLE net limit_price
    # (positive = debit, negative = credit). For single-leg, the
    # limit_price is the per-contract price. We accept the per-leg
    # limit_price for single-leg (stored on the leg) and the net
    # limit_price for multi-leg (stored on the proposal wrapper).
    #
    # If the LLM emits per-leg prices but no proposal-level net
    # (which is what the prompt's example shows), compute the net
    # ourselves: net = Σ(leg_limit × sign(side)) where buy legs are
    # + and sell legs are −. This produces a sensible net limit for
    # verticals, iron condors, calendars, etc., without forcing the
    # LLM to do a second mental step.
    if legs.size > 1
      net_price =
        if proposal['limit_price']
          BigDecimal(proposal['limit_price'].to_s)
        else
          legs.sum do |l|
            lp = l['limit_price']
            next 0 if lp.nil?
            sign = (l['side'].to_s.start_with?('buy') ? 1 : -1)
            sign * BigDecimal(lp.to_s)
          end
        end
      # Attach the net price to each leg so PortfolioManager can read
      # it from any of them; the broker uses the top-level
      # `limit_price` as the net when order_class='mleg'.
      legs = legs.map { |l| l.merge('net_limit_price' => net_price).compact }
    end

    {
      proposal: {
        legs: legs,
        tif: proposal.fetch('tif', 'day'),
        rationale: proposal['rationale'].to_s
      }
    }
  rescue JSON::ParserError => e
    raise ParseError, "trader returned non-JSON: #{e.message}"
  rescue KeyError, TypeError, ArgumentError => e
    raise ParseError, "trader proposal missing or malformed field: #{e.message}"
  end

  # Clamp an LLM-provided qty to [MIN_QTY, MAX_QTY]. Defends the
  # parser against obviously bad values (negative, zero, absurdly
  # large). The LLM is the source of truth for the actual qty;
  # this is a parser-time guardrail.
  def clamp_qty(raw)
    qty = Integer(raw)
    if qty < MIN_QTY || qty > MAX_QTY
      Rails.logger.warn "[trader] LLM qty #{qty} out of range [#{MIN_QTY}..#{MAX_QTY}]; clamping"
      qty = qty.clamp(MIN_QTY, MAX_QTY)
    end
    qty
  end

  def invoke(ticker, plan, market_state)
    chat = RubyLLM.chat(model: @model).with_instructions(system_prompt)
    response =
      with_breaker(:llm) do
        RATE_LIMITERS[:llm].with_limit do
          chat.ask(user_payload(ticker, plan, market_state).to_json)
        end
      end
    response.content
  end

  # Trader fallback: returns `proposal: nil` so the caller can detect
  # the failure and short-circuit. The caller is RunExecutionPhaseActivity
  # which calls Trader AFTER seeing `verdict == 'trade'`, so the cleanest
  # way to fail is to return a hash without a usable proposal.
  def self.default_brief(error, kind)
    Rails.logger.warn "[agent:debug] Trader falling back to default brief (#{kind}): #{error.class}: #{error.message[0, 200]}"
    {
      proposal: nil,
      _insufficient: true,
      _error: { kind: kind, class: error.class.name, message: error.message[0, 500] }
    }
  end
end
