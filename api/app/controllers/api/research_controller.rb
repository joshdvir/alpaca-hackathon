# frozen_string_literal: true

module Api
  class ResearchController < BaseController
    include Paginatable

    def index
      plans = ResearchPlan.order(created_at: :desc)
      plans = plans.where(ticker: params[:ticker]) if params[:ticker].present?

      bull_cases = BullCase.order(created_at: :desc)
      bull_cases = bull_cases.where(ticker: params[:ticker]) if params[:ticker].present?

      bear_cases = BearCase.order(created_at: :desc)
      bear_cases = bear_cases.where(ticker: params[:ticker]) if params[:ticker].present?

      analyst_reports = AnalystReport.order(created_at: :desc)
      analyst_reports = analyst_reports.where(ticker: params[:ticker]) if params[:ticker].present?

      # Each collection is paginated independently so the front-end
      # can render "Recent plans" / "Recent bull cases" / etc. with
      # their own pagination controls. The user can also pass
      # `?ticker=AAPL` to filter every collection to one symbol.
      render json: {
        research_plans: paginate(plans, serializer: ->(p) { serialize_plan(p) }),
        bull_cases: paginate(bull_cases, serializer: ->(c) { serialize_case(c, 'bull') }),
        bear_cases: paginate(bear_cases, serializer: ->(c) { serialize_case(c, 'bear') }),
        analyst_reports: paginate(analyst_reports, serializer: ->(r) { serialize_report(r) })
      }
    end

    private

    def serialize_plan(p)
      {
        id: p.id,
        ticker: p.ticker,
        recommendation: p.recommendation,
        confidence: p.confidence,
        synthesis: p.synthesis,
        key_catalysts: p.key_catalysts,
        invalidation_conditions: p.invalidation_conditions,
        valid_until: p.valid_until,
        created_at: p.created_at
      }
    end

    def serialize_case(c, kind)
      {
        id: c.id,
        kind: kind,
        ticker: c.ticker,
        confidence: c.confidence,
        narrative: c.narrative,
        payload: c.payload,
        created_at: c.created_at
      }
    end

    def serialize_report(r)
      {
        id: r.id,
        analyst_name: r.analyst_name,
        ticker: r.ticker,
        confidence: r.confidence,
        data_freshness: r.data_freshness,
        thesis: r.thesis,
        summary: r.summary,
        payload: r.payload,
        created_at: r.created_at
      }
    end
  end
end
