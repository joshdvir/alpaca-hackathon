# frozen_string_literal: true

module Api
  class DashboardController < BaseController
    def show
      latest_snapshot = PortfolioSnapshot.order(created_at: :desc).first
      today_pl = PortfolioSnapshot
                 .where(created_at: Date.current.beginning_of_day..)
                 .order(created_at: :desc)
                 .first&.daily_pl
      last_run = AgentRun.order(created_at: :desc).first

      render json: {
        equity: latest_snapshot&.equity,
        cash: latest_snapshot&.cash,
        buying_power: latest_snapshot&.buying_power,
        options_buying_power: latest_snapshot&.options_buying_power,
        today_pl: today_pl,
        open_positions_count: Position.open.count,
        active_watchlist_count: WatchlistEntry.active.count,
        last_run_at: last_run&.created_at,
        last_run_agent: last_run&.agent_name,
        server_time: Time.current
      }
    end
  end
end
