# frozen_string_literal: true

module Api
  class AgentRunsController < BaseController
    include Paginatable

    def index
      scope = AgentRun.order(created_at: :desc)
      scope = scope.by_agent(params[:agent]) if params[:agent].present?
      scope = scope.for_ticker(params[:ticker]) if params[:ticker].present?
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(run_kind: params[:run_kind]) if params[:run_kind].present?
      render json: paginate(scope, serializer: ->(r) { serialize(r) })
    end

    def show
      run = AgentRun.find(params.expect(:id))
      render json: serialize(run).merge(
        tool_calls: run.tool_calls.map { |tc| serialize_tool_call(tc) }
      )
    end

    # Returns the set of distinct agent_name values currently in the
    # table, plus the canonical run_kinds from the model. The
    # AgentRunsView populates its filter dropdowns from this so we
    # don't hardcode agent names (and miss new agents when they're
    # added to the pipeline).
    def distinct
      render json: {
        agent_names: AgentRun.distinct.pluck(:agent_name).compact.sort,
        run_kinds: AgentRun::RUN_KINDS,
        statuses: AgentRun.distinct.pluck(:status).compact.sort
      }
    end

    private

    def serialize(r)
      {
        id: r.id,
        agent_name: r.agent_name,
        run_kind: r.run_kind,
        ticker: r.ticker,
        status: r.status,
        rationale: r.rationale,
        model_used: r.model_used,
        input_tokens: r.input_tokens,
        output_tokens: r.output_tokens,
        duration_ms: r.duration_ms,
        error_message: r.error_message,
        temporal_workflow_id: r.temporal_workflow_id,
        created_at: r.created_at
      }
    end

    def serialize_tool_call(tc)
      {
        id: tc.id,
        tool_name: tc.tool_name,
        source: tc.source,
        status: tc.status,
        http_status: tc.http_status,
        duration_ms: tc.duration_ms,
        retry_count: tc.retry_count,
        created_at: tc.created_at
      }
    end
  end
end
