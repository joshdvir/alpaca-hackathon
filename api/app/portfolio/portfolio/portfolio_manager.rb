# frozen_string_literal: true

# PortfolioManager — deterministic final gate. The ONLY class that actually
# calls the trading MCP tools. Lives at the bottom of:
#
#   ResearchManager (LLM) -> Trader (LLM) -> TradeProposal (DB)
#     -> RiskManager.check (deterministic) -> PortfolioManager.execute (deterministic)
#
# Responsibilities:
#   1. Verify the proposal has a fresh passing RiskDecision attached.
#   2. Build a stable client_order_id so retries are idempotent at the broker.
#   3. Translate the proposal's `legs` JSONB into an Alpaca option order
#      via the trading MCP. (For the hackathon, the Trader emits a single
#      leg, so we read `legs.first`.)
#   4. Persist the Order row and update the proposal's status.
#   5. Surface the resulting order + filled qty back to the calling workflow
#      so it can spawn a MonitorPositionWorkflow.
#
# This class is intentionally side-effect free outside the DB + MCP. It does
# NOT make scheduling decisions, does NOT call LLMs, and does NOT touch the
# rate limiter directly — activities that wrap it manage those concerns.

module Portfolio
  class PortfolioManager
    Result = Data.define(:ok, :order, :reasons) do
      def ok? = ok
      def rejected? = !ok
    end

    def self.execute(proposal, idempotency_key: nil)
      new(proposal).execute(idempotency_key: idempotency_key)
    end

    def initialize(proposal)
      @proposal = proposal
    end

    def execute(idempotency_key: nil)
      # Market-hours gate. The original purpose was to avoid generating
      # piles of queued equity orders on weekends that the broker
      # rejects Monday. That doesn't apply to:
      #   1. Closes (`kind=auto_close`) — broker accepts close orders
      #      24/7 for unexpired options. Position-flattening shouldn't
      #      wait for the next open.
      #   2. Option orders (any leg referencing an OCC symbol) — the
      #      broker accepts option limit orders after-hours.
      # We keep the gate for fresh equity orders so we don't queue a
      # pile of `new` orders on weekends that get rejected en masse
      # Monday morning.
      legs = all_legs
      option_only = legs.any? { |l| leg_is_option?(l) }
      unless @proposal.kind == 'auto_close' || option_only
        clock = MarketClock.current
        return defer_to_market_open unless clock.open?
      end

      gate = gating_risk_decision
      return Result.new(ok: false, order: nil, reasons: ['no approved risk decision']) if gate.nil?

      # Re-read legs after gating_risk_decision so the no-legs check
      # doesn't redundantly call all_legs. (gate check is non-mutating
      # but all_legs materializes the array, so we reuse the value.)
      return Result.new(ok: false, order: nil, reasons: ['proposal has no legs']) if legs.empty?

      # The Order row's `side` column stores the FIRST leg's side for
      # single-leg orders (the dominant case) and a synthetic marker
      # `multi_leg` for multi-leg orders. The legs themselves carry
      # the per-leg side in the TradeProposal.legs JSONB; the broker
      # call below uses those directly.
      first_leg = legs.first
      order_side =
        if legs.size == 1
          leg_side(first_leg)
        else
          # Persist a stable marker so the audit trail makes it
          # obvious this was a spread, not a naked single-leg. The
          # broker never sees this string; it gets the per-leg sides
          # via the `legs` array in `place_option_order`.
          'multi_leg'
        end

      client_order_id = build_client_order_id(idempotency_key)
      existing = Order.find_by(client_order_id: client_order_id)
      if existing
        # Idempotent retry — the broker has already seen this client_order_id.
        # We treat that as success and surface the prior order.
        return Result.new(ok: true, order: existing, reasons: ['idempotent_replay'])
      end

      # Symbol for the Order row: for single-leg, it's the leg's OCC
      # symbol. For multi-leg, store a comma-joined list so the
      # dashboard shows the full set in one cell (and the broker's
      # symbol is the first leg's symbol anyway since the Order is
      # a single row even for multi-leg).
      order_symbol =
        if legs.size == 1
          leg_option_symbol(first_leg)
        else
          legs.map { |l| leg_option_symbol(l) }.join(',')
        end

      order = Order.create!(
        client_order_id: client_order_id,
        trade_proposal: @proposal,
        symbol: order_symbol,
        side: order_side,
        qty: leg_qty(first_leg) || 1,
        type: 'limit',
        status: 'new'
      )

      # Server-side safety net: the broker will reject orders whose
      # side is not allowed at the account's options_approved_level
      # (e.g. naked sell_to_open on a level-3 paper account returns
      # `code=40010001: invalid side`). The Trader LLM already gets
      # the level in its prompt and is supposed to return `hold` for
      # non-conforming strategies, but we re-validate here to catch
      # LLM hallucinations and prompt-injection attempts. Catching
      # the violation BEFORE submit_to_alpaca saves the broker round
      # trip and gives a cleaner rejection_reason on the Order row.
      #
      # For multi-leg orders, we check EVERY leg's side, not just the
      # first — a mixed spread (e.g. one leg with sell_to_open and
      # another with buy_to_close) still has to satisfy the level's
      # allowlist for each side.
      legs = Array(@proposal.legs)
      level = current_options_level
      level_violation =
        if legs.size > 1
          # Multi-leg: validate every leg's side, taking the
          # spread-cover exception into account (level 3 with a
          # buy_to_open covering the sell_to_open is allowed).
          first_bad = legs.find do |l|
            side = leg_side(l)
            !multi_leg_side_allowed?(side, level, legs)
          end
          first_bad ? "multi-leg side '#{leg_side(first_bad)}' violates options_approved_level=#{level} (use a buy_to_open covering leg, or upgrade to level 4)" : nil
        else
          level_violation_reason(order.side, level, legs)
        end

      if level_violation
        order.update!(
          status: 'rejected',
          rejection_reason: level_violation
        )
        @proposal.update!(status: 'rejected', rejection_reason: level_violation) if @proposal.status == 'risk_approved'
        Rails.logger.warn "[portfolio] side/level violation order=#{order.id} side=#{order.side} level=#{level} legs=#{legs.size}: #{level_violation}"
        return Result.new(ok: false, order: order, reasons: ["side_level_violation: #{level_violation}"])
      end

      response = submit_to_alpaca(order, legs)

      if response[:ok]
        order.update!(
          alpaca_order_id: response[:id],
          status: map_status(response[:status]),
          submitted_at: Time.current,
          raw_response: response[:raw]
        )
        @proposal.update!(status: 'portfolio_approved') if @proposal.status == 'risk_approved'
        Result.new(ok: true, order: order, reasons: [])
      else
        # Broker rejected the order at submit. We record the reason
        # on the Order row and return a non-ok result so the
        # workflow can log it + move on. This is the bug fix for
        # the silent-rejection issue: previously the response had
        # no `id` key and the row stayed at status="new" with no
        # explanation, making the pipeline look like it was
        # "submitting but never filling" when in fact the broker
        # never accepted.
        order.update!(
          status: 'rejected',
          rejection_reason: response[:error_message],
          raw_response: response[:raw]
        )
        @proposal.update!(status: 'rejected', rejection_reason: response[:error_message]) if @proposal.status == 'risk_approved'
        Rails.logger.warn "[portfolio] broker rejected order #{order.id} for #{order.symbol} #{order.side} qty=#{order.qty}: #{response[:error_message]}"
        Result.new(ok: false, order: order, reasons: ["broker_rejected: #{response[:error_message]}"])
      end
    rescue StandardError => e
      Rails.logger.error "[portfolio] execute failed: #{e.class}: #{e.message}"
      Result.new(ok: false, order: nil, reasons: ["#{e.class}: #{e.message}"])
    end

    # Market is closed — don't submit. Mark the proposal as `deferred`
    # so the audit trail shows why. The proposal won't be retried by
    # this execution (the workflow's tick is the only retry mechanism);
    # it'll just be re-evaluated on the next cycle when the market
    # is open.
    def defer_to_market_open
      @proposal.update!(status: 'deferred', rejection_reason: 'market_closed') if @proposal.status == 'risk_approved'
      Result.new(ok: false, order: nil, reasons: ['market_closed'])
    end

    private

    def gating_risk_decision
      decision = @proposal.risk_decisions.where(decision: 'approved').order(created_at: :desc).first
      return nil unless decision
      # Risk decision must be fresh — within the staleness window. Stale
      # approvals are re-checked by the calling activity.
      return nil if decision.created_at < staleness_cutoff

      decision
    end

    def staleness_cutoff
      Time.current - TradingConfig.fetch(:risk_limits, :decision_ttl_seconds).to_i.seconds
    end

    def first_leg
      legs = @proposal.legs
      return nil if legs.blank?

      legs.first
    end

    # All legs from the proposal as an array of normalized hashes
    # (string keys). Returns [] for a proposal with no legs.
    def all_legs
      Array(@proposal.legs)
    end

    # client_order_id format: pm-{proposal_id}-{ticker}-{bucket}
    # `bucket` is the proposal's id suffix so re-evaluations in different
    # cycles never collide. `idempotency_key` overrides for explicit retries.
    def build_client_order_id(idempotency_key)
      return idempotency_key if idempotency_key.present?

      "pm-#{@proposal.id}-#{@proposal.ticker}-#{@proposal.created_at.to_i}"
    end

    # Submit the order to Alpaca via the trading MCP. Returns a
    # normalized response hash so the caller can tell success from
    # broker rejection:
    #
    #   { ok: true,  id:, status:, raw: <full response> }
    #     — broker accepted, returns the order id
    #
    #   { ok: false, error_message:, raw: <full response> }
    #     — broker rejected (HTTP 4xx). We still record the Order row
    #       and capture the error so the audit trail shows WHY nothing
    #       got filled. This is the fix for the silent-rejection bug.
    #
    # Raises on connection / circuit-open errors — those are NOT
    # broker rejections, they're transient and the workflow should
    # retry. Only the broker's structured `{"error": {...}}` payload
    # is treated as a rejection.
    def submit_to_alpaca(order, legs)
      # The Alpaca MCP's place_option_order tool has TWO side-related
      # fields with different value spaces:
      #   - `side`:           "buy" | "sell"         (basic order direction)
      #   - `position_intent`: "buy_to_open" | "buy_to_close" |
      #                        "sell_to_open" | "sell_to_close" (semantics)
      # Our Order.side stores the semantic string (e.g. "buy_to_open").
      # If we put that into `side`, the broker rejects with
      # `code=40010001: invalid side` (422) because it expects the
      # basic "buy" or "sell" there. Split into both fields.
      intent = order.side.to_s
      basic_side =
        case intent
        when 'buy_to_open', 'buy_to_close' then 'buy'
        when 'sell_to_open', 'sell_to_close' then 'sell'
        else intent # let the broker reject; we don't want to silently coerce unknowns
        end

      if legs.size == 1
        # Single-leg path. Use the leg's own OCC symbol and
        # limit_price, top-level symbol/side/qty.
        leg = legs.first
        params = {
          symbol: leg_option_symbol(leg),
          # The Alpaca MCP order tools (place_option_order, place_stock_order,
          # place_crypto_order) all declare `qty` as `type: "string"` — Pydantic
          # validation rejects ints with "Input should be a valid string
          # [type=string_type, input_value=10, input_type=int]". Our Order row
          # stores qty as `integer` (see db/migrate/..._create_orders.rb), so
          # we always have an Integer here and must stringify at the call site.
          qty: leg_qty(leg).to_s,
          side: basic_side_for(leg_side(leg)),
          position_intent: leg_side(leg),
          type: order.type,
          time_in_force: 'day',
          limit_price: (leg['limit_price'] || leg[:limit_price])&.to_s
        }.compact
      else
        # Multi-leg path. `order_class: 'mleg'` and a `legs` array
        # of {symbol, side (basic), position_intent, ratio_qty}.
        # Net limit_price is at the top level (positive = debit,
        # negative = credit). The broker treats the whole order as
        # one atomic execution.
        mleg = legs.map do |l|
          {
            symbol: leg_option_symbol(l),
            side: basic_side_for(leg_side(l)),
            position_intent: leg_side(l),
            # Per-leg ratio_qty MUST be 1 — the broker rejects GCD > 1.
            # The absolute size is carried on the top-level `qty:`
            # below. Read the literal `ratio_qty` field; fall back to
            # `1` for legacy proposals that don't carry one.
            ratio_qty: (l['ratio_qty'] || l[:ratio_qty] || 1).to_s
          }
        end
        # Net limit price lives on whichever leg carries the
        # `net_limit_price` key (the Trader parser attaches it to
        # the first leg, but be tolerant of any leg since the JSONB
        # is a free-form structure). Positive = debit you pay;
        # negative = credit you receive.
        net = legs.map { |l| l['net_limit_price'] || l[:net_limit_price] }.compact.first
        params = {
          order_class: 'mleg',
          type: order.type,
          time_in_force: 'day',
          legs: mleg,
          # The MCP wrapper requires top-level `qty` even for mleg.
          # All legs share the same qty by contract.
          qty: leg_qty(legs.first).to_s
        }
        params[:limit_price] = BigDecimal(net.to_s).to_s('F') if net
      end

      tool = ALPACA_MCP_TRADING.tool('place_option_order')
      raise 'alpaca_mcp: place_option_order tool not found' if tool.nil?

      raw = RATE_LIMITERS[:alpaca_mcp].with_limit do
        CIRCUIT_BREAKERS[:alpaca_mcp].call { tool.call(params) }
      end

      parsed = unwrap_mcp_response(raw)
      # The MCP envelope looks like {"data": {"result": {...success...}}}
      # or {"data": {"error": {...rejection...}}}. Some tools (like
      # get_clock / get_account_info) return the payload directly under
      # `data` without a `result` wrapper. Normalize both shapes to
      # the inner dict.
      inner =
        if parsed.is_a?(Hash) && parsed["data"].is_a?(Hash) && parsed["data"].key?("result")
          parsed["data"]["result"]
        elsif parsed.is_a?(Hash) && parsed["data"].is_a?(Hash)
          parsed["data"]
        else
          parsed
        end

      if inner.is_a?(Hash) && inner["error"].is_a?(Hash)
        # Alpaca structured error: {"error": {"http_status": 422, "message": "...", "detail": {...}}}
        err = inner["error"]
        msg = err["message"].to_s
        detail = err["detail"]
        if detail.is_a?(Hash)
          msg = "#{msg} (#{detail['message']})" if detail["message"].present?
          msg = "#{msg} [code=#{detail['code']}]" if detail["code"]
        end
        { ok: false, error_message: msg, raw: parsed }
      elsif inner.is_a?(Hash) && inner["id"]
        # Broker accepted — note that `status` may be 'new' (queued)
        # or 'filled' (instant fill) depending on market state.
        { ok: true, id: inner["id"], status: inner["status"], raw: parsed }
      else
        # Unknown response shape — be conservative, treat as rejection
        # with a useful message so we can investigate.
        { ok: false, error_message: "unexpected_response: #{inner.inspect[0,200]}", raw: parsed }
      end
    end

    # The MCP wraps the Alpaca response in `{"data": { ... }}` and
    # sometimes the broker's own error envelope. Strip the outer MCP
    # envelope (the caller unwraps `data` / `result` further).
    #
    # Tolerant of three input shapes:
    #   1. Array of MCP Content (the real-world shape) — read `.text`
    #   2. A single MCP Content (also valid)
    #   3. A bare Hash (for test stubs that pass the parsed result
    #      directly) — return it as-is
    def unwrap_mcp_response(raw)
      if raw.is_a?(Hash)
        return raw
      end

      text = if raw.is_a?(Array)
               raw.first&.respond_to?(:text) ? raw.first.text : raw.first.to_s
             elsif raw.respond_to?(:text)
               raw.text
             else
               raw.to_s
             end
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      { "_unparsed" => text.to_s[0, 500] }
    end

    def map_status(alpaca_status)
      case alpaca_status.to_s
      when 'filled' then 'filled'
      when 'partially_filled', 'partial' then 'partial'
      when 'canceled', 'cancelled' then 'cancelled'
      when 'expired' then 'expired'
      when 'new' then 'new'
      when 'accepted', 'pending_new', 'accepted_for_bidding' then 'new'
      when 'rejected' then 'rejected'
      else 'new'
      end
    end

    # ---------------------------------------------------------------
    # Account options-level safety net
    # ---------------------------------------------------------------

    # Allowed `*_to_open` / `*_to_close` sides per options_approved_level.
    # The broker (Alpaca) rejects with `code=40010001: invalid side`
    # for any side not in this list at the account's level. Source:
    # Alpaca's options approval levels documentation.
    #
    # Level 0: no options at all
    # Level 1: covered call + cash-secured put only
    #          (open: buy_to_open, sell_to_open [single-leg, covered])
    # Level 2: long calls/puts only
    #          (open: buy_to_open; close: any) — sell_to_open NOT allowed
    # Level 3: spreads. Single-leg sell_to_open is NOT allowed (naked);
    #          multi-leg sell_to_open IS allowed if a buy_to_open in the
    #          same order covers the short leg.
    # Level 4: all sides including naked writing.
    ALLOWED_SIDES_PER_LEVEL = {
      0 => [],
      1 => %w[buy_to_open buy_to_close sell_to_close sell_to_open],
      2 => %w[buy_to_open buy_to_close sell_to_close],
      3 => %w[buy_to_open buy_to_close sell_to_close],
      4 => %w[buy_to_open buy_to_close sell_to_close sell_to_open]
    }.freeze

    # Read the account's current options_approved_level from the most
    # recent broker mirror. The mirror job syncs every 30s, so this
    # is at most 30s stale — the broker rejects any change in level
    # with a manual application, so a 30s window is safe for
    # strategy decisions.
    def current_options_level
      snap = PortfolioSnapshot.order(created_at: :desc).first
      return nil if snap.nil?
      level = (snap.raw || {})['options_approved_level']
      level.is_a?(Integer) ? level : nil
    end

    # Returns a human-readable rejection reason if `side` is not
    # allowed at the account's `level` for an order with these `legs`,
    # or nil if the side is allowed.
    def level_violation_reason(side, level, legs)
      return nil if level.nil?  # no mirror yet — let the broker be the source of truth
      return nil if ALLOWED_SIDES_PER_LEVEL.fetch(level, []).include?(side)

      # Special case: at level 3, a multi-leg order with a buy_to_open
      # covering the sell_to_open is a spread and IS allowed.
      if level == 3 && side == 'sell_to_open' && legs.size > 1
        has_covering_long = legs.any? { |l| leg_side(l) == 'buy_to_open' }
        return nil if has_covering_long
      end

      case level
      when 0 then "options trading disabled (account options_approved_level=0)"
      when 1 then "side '#{side}' not allowed at options_approved_level=1 (covered call / cash-secured put only)"
      when 2 then "side '#{side}' not allowed at options_approved_level=2 (long calls/puts only; no short opening)"
      when 3
        if side == 'sell_to_open' && legs.size == 1
          "side 'sell_to_open' (naked) not allowed at options_approved_level=3 (use a multi-leg spread with a buy_to_open covering leg, or upgrade to level 4)"
        else
          "side '#{side}' not allowed at options_approved_level=3"
        end
      else "side '#{side}' not allowed at options_approved_level=#{level}"
      end
    end

    def leg_side(leg)
      leg.is_a?(Hash) ? (leg['side'] || leg[:side]) : nil
    end

    # True if the leg references an option contract (OCC symbol).
    # OCC symbols are 21 characters: SPY260904C00773000, SPY260904P00773000,
    # etc. None of the equity symbols in our universe are exactly 21
    # characters and end with 8 digits, so a regex check is reliable.
    def leg_is_option?(leg)
      sym = leg.is_a?(Hash) ? (leg['option_symbol'] || leg[:option_symbol] || leg['symbol'] || leg[:symbol]).to_s : ''
      sym.length == 21 && sym =~ /\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/
    end

    # Convert semantic side ("buy_to_open" etc.) to the broker's
    # basic-side string ("buy" | "sell"). Let unknowns through so
    # the broker (or the level check) can reject them.
    def basic_side_for(intent)
      case intent.to_s
      when 'buy_to_open', 'buy_to_close' then 'buy'
      when 'sell_to_open', 'sell_to_close' then 'sell'
      else intent.to_s
      end
    end

    # Per-leg qty — the absolute position size. Reads in priority:
    #   1. `leg['qty']` — explicit absolute size (preferred; set by
    #      OvernightReversal::SubmitOrdersActivity so the broker sees
    #      the actual qty rather than the per-leg ratio).
    #   2. `leg['ratio_qty']` — GCD-friendly ratio used by
    #      RunPositionAdjustmentActivity and mid-band-movers; when
    #      these activities only set ratio_qty (no `qty`), the ratio
    #      IS the absolute size.
    # Multiple call sites (line 94, 267, 301) read this for the
    # Order row's `qty` and the broker MCP top-level `qty:`. The
    # broker's per-leg `ratio_qty:` field (line 285) uses the
    # `ratio_qty` literal directly, NOT this helper.
    def leg_qty(leg)
      leg.is_a?(Hash) ? (leg['qty'] || leg[:qty] || leg['ratio_qty'] || leg[:ratio_qty]) : nil
    end

    # Per-leg OCC option symbol — reads `option_symbol` (proposal
    # shape) or `symbol` (Trader parser shape).
    def leg_option_symbol(leg)
      leg.is_a?(Hash) ? (leg['option_symbol'] || leg[:option_symbol] || leg['symbol'] || leg[:symbol]).to_s : ''
    end

    # True if `side` is allowed in a multi-leg order at the
    # account's `level`. Mirrors the spread-cover exception used
    # by `level_violation_reason` (level 3 with a buy_to_open
    # covering the sell_to_open is OK).
    def multi_leg_side_allowed?(side, level, legs)
      return true if level.nil? # no mirror yet — let the broker be the source of truth
      return true if ALLOWED_SIDES_PER_LEVEL.fetch(level, []).include?(side)
      if level == 3 && side == 'sell_to_open'
        return legs.any? { |l| leg_side(l) == 'buy_to_open' }
      end
      false
    end
  end
end
