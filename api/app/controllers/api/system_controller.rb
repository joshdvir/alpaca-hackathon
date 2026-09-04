# frozen_string_literal: true

module Api
  class SystemController < BaseController
    def health
      db_ok    = ActiveRecord::Base.connection.execute('SELECT 1').first ? true : false
      tpl_run  = AgentRun.order(created_at: :desc).first
      watch    = WatchlistEntry.active.count
      pos      = Position.open.count

      # Probe the Temporal frontend port (best effort, don't fail the call)
      temporal_ok = temporal_reachable?

      status = db_ok && temporal_ok ? 'ok' : 'degraded'
      http_code = db_ok ? :ok : :service_unavailable

      render json: {
        status: status,
        server_time: Time.current,
        db: db_ok,
        temporal: temporal_ok,
        active_watchlist_count: watch,
        open_positions_count: pos,
        last_agent_run_at: tpl_run&.created_at,
        last_agent_name: tpl_run&.agent_name,
        kill_switch: Rails.root.join('tmp/kill_switch').exist?
      }, status: http_code
    end

    private

    def temporal_reachable?
      require 'socket'
      host = ENV.fetch('TEMPORAL_ADDRESS', 'temporal:7233').split(':').first
      port = ENV.fetch('TEMPORAL_ADDRESS', 'temporal:7233').split(':').last.to_i
      Socket.tcp(host, port, connect_timeout: 2) { true }
      true
    rescue StandardError
      false
    end
  end
end
