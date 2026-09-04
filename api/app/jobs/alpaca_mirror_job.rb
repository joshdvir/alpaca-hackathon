# frozen_string_literal: true

# AlpacaMirrorJob — runs AlpacaSync on a Solid Queue schedule (every
# 30s by default). This is the single process that keeps our DB in
# sync with the broker's view of the world:
#
#   - AccountSnapshot: cash, buying_power, equity, options_buying_power
#   - Position: live open positions, market_value, unrealized_pl
#   - Order: status transitions, fills, rejection reasons
#
# Configured via `config/recurring.yml` (see config for the cron-like
# schedule). The job is intentionally idempotent — running it twice
# in 30s is safe; the second run is a no-op for unchanged data.
#
# If the sync fails (network down, circuit open), the job logs the
# error and exits cleanly. Solid Queue will retry on the next tick.
class AlpacaMirrorJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "[alpaca_mirror] tick: syncing account/positions/orders"
    result = AlpacaSync.sync_all
    acct   = result[:account]
    pos    = result[:positions]
    ords   = result[:orders]

    if acct.ok? && pos.ok? && ords.ok?
      Rails.logger.info "[alpaca_mirror] ok: account(#{acct.summary}) positions(#{pos.summary}) orders(#{ords.summary})"
    else
      Rails.logger.warn "[alpaca_mirror] partial: account(ok=#{acct.ok?}, #{acct.summary}, errs=#{acct.errors.inspect}) " \
                        "positions(ok=#{pos.ok?}, #{pos.summary}, errs=#{pos.errors.inspect}) " \
                        "orders(ok=#{ords.ok?}, #{ords.summary}, errs=#{ords.errors.inspect})"
    end

    # Broadcast the latest account snapshot to ActionCable so the
    # dashboard updates without polling the API. The snapshot is
    # pushed on the `live_updates:account` stream.
    snap = PortfolioSnapshot.order(created_at: :desc).first
    if snap
      ActionCable.server.broadcast(
        "live_updates:account",
        {
          event: "updated",
          snapshot: {
            id:                    snap.id,
            equity:                snap.equity.to_f,
            cash:                  snap.cash.to_f,
            buying_power:          snap.buying_power.to_f,
            options_buying_power:  snap.options_buying_power.to_f,
            daily_pl:              snap.daily_pl.to_f,
            created_at:            snap.created_at.iso8601
          }
        }
      )
    end

    # If we have 0 stuck/new orders, log it. The number of pending
    # orders is interesting for ops — a sudden surge means a broker
    # issue or a runaway loop.
    pending = Order.pending_sync.count
    if pending > 0
      Rails.logger.info "[alpaca_mirror] pending_sync_orders=#{pending}"
    end
  end
end
