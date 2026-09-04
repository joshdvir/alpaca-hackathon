# frozen_string_literal: true

module Api
  class WatchlistController < BaseController
    include Paginatable

    def index
      scope = WatchlistEntry.active.order(:ticker)
      scope = scope.where(ticker: params[:ticker]) if params[:ticker].present?
      render json: paginate(scope, serializer: ->(e) { serialize(e) })
    end

    def recommendations
      scope = WatchlistRecommendation.recent(7).order(recommended_on: :desc, confidence: :desc)
      scope = scope.for_ticker(params[:ticker]) if params[:ticker].present?
      scope = scope.where(source_filter: params[:filter]) if params[:filter].present?
      render json: paginate(scope, serializer: ->(r) { serialize_recommendation(r) })
    end

    private

    def serialize(e)
      {
        ticker: e.ticker,
        effective_from: e.effective_from,
        effective_until: e.effective_until,
        source: e.source,
        cycle_minutes: e.cycle_minutes,
        tags: e.tags,
        last_cycle_started_at: e.last_cycle_started_at,
        last_temporal_run_id: e.last_temporal_run_id
      }
    end

    def serialize_recommendation(r)
      {
        ticker: r.ticker,
        recommended_on: r.recommended_on,
        source_filter: r.source_filter,
        confidence: r.confidence,
        scores: r.scores,
        rationale: r.rationale
      }
    end
  end
end
