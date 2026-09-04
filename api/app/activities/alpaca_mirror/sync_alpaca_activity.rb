# frozen_string_literal: true

# SyncAlpacaActivity — runs AlpacaSync.sync_all and broadcasts the
# latest account snapshot over ActionCable. The AlpacaMirrorWorkflow
# invokes this activity once per schedule tick (every 30s).
#
# This is the Temporal-native replacement for the old
# AlpacaMirrorJob + Solid Queue scheduler (see session note: solid_queue
# gem was never installed, recurring.yml was a dead config, and the
# mirror never actually ran). Temporal schedules are already wired
# via Temporal::ScheduleManager, so reusing that pattern is the
# simplest, most Rails-idiomatic way to keep the DB in sync.
module AlpacaMirror
  class SyncAlpacaActivity < ApplicationActivity
    def execute
      activity.logger.info '[alpaca_mirror] tick: syncing account/positions/orders'
      result = AlpacaSync.sync_all
      acct = result[:account]
      pos  = result[:positions]
      ords = result[:orders]

      if acct.ok? && pos.ok? && ords.ok?
        activity.logger.info "[alpaca_mirror] ok: account(#{acct.summary}) positions(#{pos.summary}) orders(#{ords.summary})"
      else
        activity.logger.warn "[alpaca_mirror] partial: account(ok=#{acct.ok?}, #{acct.summary}, errs=#{acct.errors.inspect}) " \
                             "positions(ok=#{pos.ok?}, #{pos.summary}, errs=#{pos.errors.inspect}) " \
                             "orders(ok=#{ords.ok?}, #{ords.summary}, errs=#{ords.errors.inspect})"
      end

      # Broadcast the latest account snapshot to ActionCable so the
      # dashboard updates without polling the API. The snapshot is
      # pushed on the `live_updates:account` stream.
      snap = PortfolioSnapshot.order(created_at: :desc).first
      if snap
        ActionCable.server.broadcast(
          'live_updates:account',
          {
            event: 'updated',
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

      # Pending sync ops are interesting for ops monitoring.
      pending = Order.pending_sync.count
      activity.logger.info "[alpaca_mirror] pending_sync_orders=#{pending}" if pending > 0

      # Return a small summary so the workflow can decide whether to
      # log an alert (and so the schedule's last-successful-run
      # record has something useful).
      {
        ok: acct.ok? && pos.ok? && ords.ok?,
        synced: { account: acct.synced, positions: pos.synced, orders: ords.synced },
        errors: { account: acct.errors, positions: pos.errors, orders: ords.errors },
        pending_sync_orders: pending
      }
    end
  end
end
