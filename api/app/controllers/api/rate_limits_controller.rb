# frozen_string_literal: true

module Api
  class RateLimitsController < BaseController
    def stats
      window = (params[:window] || '1h').to_s
      since  = case window
               when '1h'  then 1.hour.ago
               when '24h' then 24.hours.ago
               when '7d'  then 7.days.ago
               else 1.hour.ago
               end

      by_source = ToolCall.where(created_at: since..)
                          .group(:source, :status)
                          .count
                          .each_with_object({}) do |((source, status), count), acc|
        acc[source] ||= {}
        acc[source][status] = count
      end

      avg_latency = ToolCall.where(created_at: since..)
                            .group(:source)
                            .average(:duration_ms)

      render json: {
        window: window,
        since: since,
        by_source: by_source,
        avg_latency_ms_by_source: avg_latency,
        circuit_breakers: CIRCUIT_BREAKERS.transform_values { |cb| { state: cb.state } }
      }
    end
  end
end
