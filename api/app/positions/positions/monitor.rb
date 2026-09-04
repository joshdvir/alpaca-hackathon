# frozen_string_literal: true

# Deterministic position monitor. Runs every 1 minute via Temporal.
# Checks hard exit rules against current position state. When a rule triggers,
# creates a trade_proposal (kind=auto_close) which goes through the normal
# RiskManager -> PortfolioManager pipeline.

module Positions
  class Monitor
    RULES = TradingConfig.fetch(:position_monitor, :hard_exits).freeze

    # Called every minute via MonitorPositionWorkflow (one-shot
    # execution per tick, started by AlpacaMirrorWorkflow's
    # self-heal). Returns array of trade_proposals created (for logging).
    def self.check_all
      created = []
      Position.open.find_each do |position|
        proposal = check_position(position)
        created << proposal if proposal
      end
      created
    end

    def self.check_position(position)
      rules = triggered_rules_for(position)
      return nil if rules.empty?

      # Build an auto-close trade_proposal. Kind=auto_close so the executor
      # knows to place a closing order (not a new one).
      proposal = TradeProposal.new(
        ticker: position.symbol.split.first, # OCC symbol starts with underlying
        kind: 'auto_close',
        strategy_type: 'hold', # not used for closes, but required
        legs: close_legs_for(position),
        max_loss: 0,
        max_profit: 0,
        rationale: "PositionMonitor auto-close: #{rules.join(', ')}",
        closes_position: position,
        status: 'pending'
      )
      proposal.save!
      Rails.logger.info "[position_monitor] auto-close proposed: #{position.symbol} reason=#{rules.join(',')}"
      proposal
    end

    def self.triggered_rules_for(position)
      rules = []
      rules << 'stop_loss' if stop_loss_hit?(position)
      rules << 'profit_target' if profit_target_hit?(position)
      rules << 'dte' if dte_close?(position)
      rules
    end

    def self.stop_loss_hit?(position)
      loss_threshold = RULES[:stop_loss_pct].to_f
      # `unrealized_plpc` is a fraction (e.g., -0.50 = -50%); compare
      # directly against the threshold without dividing.
      position.unrealized_pl.to_d.negative? &&
        position.unrealized_plpc.abs >= loss_threshold
    end

    def self.profit_target_hit?(position)
      target = RULES[:profit_target_pct].to_f
      # Realized vs max profit. Without a max_profit on Position, fall back to a
      # simpler proxy: percent of credit collected vs the premium received.
      return false unless position.avg_entry_price.to_f.positive?

      gain = (position.avg_entry_price.to_f - current_mark(position)).abs
      max_profit_estimate = position.avg_entry_price.to_f
      return false if max_profit_estimate.zero?

      (gain / max_profit_estimate) >= target
    end

    def self.dte_close?(position)
      # Days-to-expiry from the OCC symbol (positions on PLTR260911C00190000
      # expire on 2026-09-11). We trigger the DTE close when dte <= the
      # configured threshold (default 1 day). For a Friday-expiring option
      # at end-of-day Thursday, dte=1 and we close. For Monday-expiring
      # positions, dte=1 means we close Sunday — that's fine, Alpaca
      # queues the order for Monday open if we're after-hours.
      threshold = RULES[:dte_close_threshold].to_i
      dte = Positions::Occ.days_to_expiry(position.symbol)
      return false if dte.nil? # not an OCC symbol or unparseable

      dte <= threshold
    end

    def self.current_mark(position)
      # Read from latest market_snapshot for this symbol. For hackathon: best
      # effort from MCP via the executor. Returns avg entry as fallback so we
      # don't fire stop/target on stale data.
      latest = ::MarketSnapshot
               .where(symbol: position.symbol, data_type: 'option_snapshot')
               .order(captured_at: :desc)
               .first
      latest&.dig('payload', 'latestQuote', 'ap') || position.avg_entry_price.to_f
    end

    def self.close_legs_for(position)
      # Reverse the position: if qty is positive (long), we sell to close.
      [{ side: position.qty.to_i.positive? ? 'sell' : 'buy', ratio_qty: 1, option_symbol: position.symbol }]
    end
  end
end
