# frozen_string_literal: true

# Deterministic risk gate. No LLM. Reads every threshold from trading.yml.
# Called by the execution path between Trader and PortfolioManager.
#
# Usage:
#   decision = Risk::RiskManager.new.check(trade_proposal)
#   if decision.approved?
#     PortfolioManager.execute(trade_proposal)
#   end
#
# Every check is also persisted as a RiskDecision for audit.

module Risk
  class RiskManager
    LIMITS = TradingConfig.fetch(:risk_limits).freeze
    KILL_SWITCH_FLAG = 'kill_switch'

    def check(trade_proposal)
      reasons = []

      reasons << 'kill switch is on' if kill_switch_on?

      unless within_position_count?(trade_proposal)
        reasons << "would exceed max_open_positions (#{LIMITS[:max_open_positions]}); currently #{Position.open.count} open"
      end

      unless within_notional?(trade_proposal)
        reasons << "exceeds max_notional_per_trade ($#{LIMITS[:max_notional_per_trade]})"
      end

      reasons << "would exceed max_daily_loss ($#{LIMITS[:max_daily_loss]})" unless within_daily_loss?

      reasons << "would exceed max_daily_loss_pct (#{(LIMITS[:max_daily_loss_pct] * 100).round(2)}% of equity)" unless within_daily_loss_pct?

      reasons << "would exceed max_position_pct (#{(LIMITS[:max_position_pct] * 100).round(2)}% of equity)" unless within_position_pct?(trade_proposal)

      unless within_buying_power?(trade_proposal)
        snap = latest_snapshot
        bp = snap&.options_buying_power.to_f
        reasons << "would exceed available buying power ($#{bp.round(0)})"
      end

      reasons << 'would exceed aggregate Greeks limits' unless within_greeks?(trade_proposal)

      # Broker pre-flight: the Alpaca mleg order endpoint requires
      # the leg ratio_qty array to be "relatively prime" (GCD = 1).
      # If the LLM emits an iron condor with all legs at ratio_qty=2
      # the broker rejects with `code=42210000: leg ratio quantities
      # should be relatively prime: GCD[2 2 2 2] = 2`. The fix is for
      # the Trader to encode multi-leg size via the order-level qty
      # (e.g. order.qty=2, every leg.ratio_qty=1) — but until the LLM
      # is fixed, catch it here so we don't burn a broker round-trip
      # and produce a noisy 422 in the log.
      gcr = leg_ratio_gcd_violation(trade_proposal)
      reasons << gcr if gcr

      decision = Risk::Decision.new(
        approved: reasons.empty?,
        reasons: reasons,
        limit_snapshot: LIMITS.merge(equity: latest_snapshot&.equity.to_f, options_buying_power: latest_snapshot&.options_buying_power.to_f).to_h
      )

      persist!(trade_proposal, decision)
      decision
    end

    private

    def kill_switch_on?
      # Read from a DB flag table or a system-wide setting.
      # For hackathon, we use a simple Setting/redis-free flip file.
      Rails.root.join('tmp/kill_switch').exist?
    end

    def within_position_count?(proposal)
      return true if proposal.kind != 'new' # rolls/closes don't count

      Position.open.count < LIMITS[:max_open_positions]
    end

    def within_notional?(proposal)
      # The hard cap is `min(max_notional_per_trade, options_buying_power)`.
      # On a fresh mirror snapshot, `options_buying_power` is the LIVE
      # dollar capacity for the next order — the system will use up to
      # the full account (e.g. a $10K account gets a $10K single trade).
      # `max_notional_per_trade` is a SECONDARY floor that overrides
      # only when the account has grown past the configured limit
      # (so a $50M account is still capped at $10K/trade by default).
      # When the mirror hasn't run yet (no snapshot), fall back to the
      # configured `max_notional_per_trade` so the system doesn't
      # deadlock.
      snap_bp = latest_snapshot&.options_buying_power.to_f
      cap = if snap_bp.positive?
             [LIMITS[:max_notional_per_trade].to_f, snap_bp].min
           else
             LIMITS[:max_notional_per_trade].to_f
           end
      notional(proposal) <= cap
    end

    def notional(proposal)
      # Conservative estimate: max_loss as a proxy for notional exposure.
      # Refine once order qty × contract price is known.
      (proposal.max_loss || 0).to_d
    end

    def within_daily_loss?
      todays_pl = PortfolioSnapshot.where(created_at: Date.current.beginning_of_day..)
                                   .order(created_at: :desc).first&.daily_pl.to_d
      todays_pl.abs < LIMITS[:max_daily_loss].to_d
    end

    # Daily loss as a percentage of equity. The dollar cap
    # `max_daily_loss` is good as a hard floor but on a small
    # account it's irrelevant (a 5% loss on a $100k account is
    # $5k — already over the $2500 cap). On a $1M account the
    # $2500 cap is too tight (0.25%). The percentage check is
    # more scale-invariant.
    def within_daily_loss_pct?
      pct = LIMITS[:max_daily_loss_pct]
      return true if pct.nil? || pct.zero?
      equity = latest_snapshot&.equity.to_f
      return true if equity.zero? # no live data, fall through to dollar cap

      todays_pl = PortfolioSnapshot.where(created_at: Date.current.beginning_of_day..)
                                   .order(created_at: :desc).first&.daily_pl.to_d
      todays_pl.abs < (pct.to_f * equity)
    end

    # Per-position cap: no single position should exceed
    # `max_position_pct` of equity. The proposal's `max_loss` is a
    # conservative proxy for the size of the position.
    def within_position_pct?(proposal)
      pct = LIMITS[:max_position_pct]
      return true if pct.nil? || pct.zero?
      equity = latest_snapshot&.equity.to_f
      return true if equity.zero?

      notional(proposal) < (pct.to_f * equity)
    end

    # Don't submit a trade larger than the broker's options buying
    # power. The dollar cap is a theoretical max; the broker may
    # say "no" earlier because of margin / equity / option level.
    def within_buying_power?(proposal)
      bp = latest_snapshot&.options_buying_power.to_f
      return true if bp.zero? # no live data, fall through to dollar cap
      notional(proposal) <= bp
    end

    def latest_snapshot
      # Cached for the duration of this check (single proposal,
      # single RiskManager instance). Avoids 4 separate DB hits.
      @latest_snapshot ||= PortfolioSnapshot.order(created_at: :desc).first
    end

    def within_greeks?(_proposal)
      # Sum current Greeks of open positions + estimated Greeks of the new trade.
      # For hackathon: simplest version is "we don't have live Greeks, skip".
      # Refine in Phase 2 once PositionMonitor computes Greeks each minute.
      true
    end

    # Pre-flight check: the broker rejects multi-leg orders whose
    # leg ratio_qty array has GCD > 1 (e.g. [2,2,2,2] → GCD=2).
    # Only applies to orders with more than one leg. Returns a
    # rejection reason string when the GCD is > 1, nil otherwise.
    def leg_ratio_gcd_violation(proposal)
      legs = Array(proposal.legs)
      return nil if legs.size < 2

      ratios = legs.map { |l| (l['ratio_qty'] || 1).to_i.abs }
      return nil if ratios.any?(&:zero?)

      g = ratios.reduce(ratios.first) { |acc, n| acc.gcd(n) }
      return nil if g <= 1

      "leg ratio quantities must be relatively prime (GCD of #{ratios.inspect} = #{g}); " \
        "the broker rejects mleg orders with GCD > 1 (code=42210000). " \
        "Encode the position size on the order-level qty and use ratio_qty=1 on every leg."
    end

    def persist!(proposal, decision)
      RiskDecision.create!(
        trade_proposal: proposal,
        decision: decision.approved? ? 'approved' : 'rejected',
        reasons: decision.reasons.to_json,
        limit_snapshot: decision.limit_snapshot
      )
    rescue StandardError => e
      Rails.logger.warn "[risk] failed to persist decision: #{e.message}"
    end
  end
end
