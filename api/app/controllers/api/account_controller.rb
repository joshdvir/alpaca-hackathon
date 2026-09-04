# frozen_string_literal: true

module Api
  # AccountController — exposes the Alpaca account + mirror data
  # to the front-end. Single source of truth for the dashboard's
  # "Account" panel (cash, buying_power, equity, day P&L, account
  # status, open-position summary).
  #
  # Data comes from:
  #   - PortfolioSnapshot.latest  (synced every 30s by AlpacaMirrorJob)
  #   - Position.open.count       (mirrored from broker)
  #   - Order.pending_sync.count  (orders the system has tried to
  #                                submit but hasn't heard back about)
  #   - MarketClock.current       (live is_open / next_open)
  #
  # The controller does NOT call Alpaca directly — that would let a
  # single dashboard refresh block the API thread for 1-2s on every
  # page load. The mirror job is the only thing that talks to
  # Alpaca; the controller reads the cached DB.
  class AccountController < BaseController
    def show
      snap = PortfolioSnapshot.order(created_at: :desc).first
      positions = Position.open.order(snapshot_at: :desc).limit(50)
      market = MarketClock.current
      open_orders = Order.open.order(created_at: :desc).limit(50)
      rejected_recent = Order.where(status: "rejected").where("created_at > ?", 1.day.ago).count

      render json: {
        snapshot: snap ? {
          id:                    snap.id,
          equity:                snap.equity.to_f,
          cash:                  snap.cash.to_f,
          buying_power:          snap.buying_power.to_f,
          options_buying_power:  snap.options_buying_power.to_f,
          portfolio_value:       (snap.raw || {})["portfolio_value"]&.to_f,
          last_equity:           (snap.raw || {})["last_equity"]&.to_f,
          daily_pl:              snap.daily_pl.to_f,
          status:                (snap.raw || {})["status"],
          account_number:        (snap.raw || {})["account_number"],
          options_approved_level: (snap.raw || {})["options_approved_level"],
          trading_blocked:       (snap.raw || {})["trading_blocked"] == true,
          multiplier:            (snap.raw || {})["multiplier"],
          as_of:                 snap.created_at.iso8601
        } : nil,
        positions: positions.map { |p|
          {
            symbol:           p.symbol,
            qty:              p.qty,
            avg_entry_price:  p.avg_entry_price.to_f,
            market_value:     p.market_value.to_f,
            unrealized_pl:    p.unrealized_pl.to_f,
            unrealized_plpc:  p.unrealized_plpc,
            snapshot_at:      p.snapshot_at.iso8601
          }
        },
        open_position_count:  positions.size,
        open_orders: open_orders.map { |o|
          {
            id: o.id,
            symbol: o.symbol,
            side: o.side,
            qty: o.qty,
            status: o.status,
            limit_price: o.raw_response&.dig("limit_price")&.to_f,
            created_at: o.created_at.iso8601
          }
        },
        pending_sync_order_count: Order.pending_sync.count,
        rejected_last_24h:        rejected_recent,
        market: {
          is_open:      market.open,
          next_open:    market.next_open_at&.iso8601,
          next_close:   market.next_close_at&.iso8601,
          as_of:        market.timestamp.iso8601,
          source:       market.source,
          seconds_until_next_open: market.respond_to?(:open) && !market.open && market.next_open_at ? (market.next_open_at - Time.current).to_i : nil
        },
        server_time: Time.current.iso8601
      }
    end

    # POST /api/account/refresh
    # Forces a mirror sync NOW (instead of waiting for the next
    # 30s tick). Useful when the user clicks "Refresh" on the
    # dashboard.
    def refresh
      result = AlpacaSync.sync_all
      render json: {
        ok: result[:account].ok? && result[:positions].ok? && result[:orders].ok?,
        account:   { synced: result[:account].synced,   errors: result[:account].errors },
        positions: { synced: result[:positions].synced, errors: result[:positions].errors },
        orders:    { synced: result[:orders].synced,    errors: result[:orders].errors }
      }
    rescue StandardError => e
      render json: { ok: false, error: "#{e.class}: #{e.message}" }, status: :internal_server_error
    end
  end
end
