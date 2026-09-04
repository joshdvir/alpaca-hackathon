# frozen_string_literal: true

# BacktestsController — API for triggering backtest runs and reading
# their results. The actual work is done by Backtest::BacktestWorkflow;
# this controller is a thin shim that:
#   - creates a BacktestRun row
#   - starts the workflow (returns immediately with run id + workflow id)
#   - exposes the run + its trades for polling
#
# Front-end flow:
#   POST /api/backtests            -> { run_id, workflow_id, status: "pending" }
#   GET  /api/backtests            -> [{...}, ...]  (history)
#   GET  /api/backtests/:id        -> {...} (with stats)
#   GET  /api/backtests/:id/trades -> [{...}, ...]
#   GET  /api/backtests/:id/status -> {status, ...} (lightweight poll)

module Api
  class BacktestsController < BaseController
    include Paginatable

    before_action :set_run, only: %i[show trades status cancel]

    def index
      scope = BacktestRun.order(created_at: :desc)
      render json: paginate(scope, serializer: ->(r) { serialize_run(r) })
    end

    def show
      render json: serialize_run(@run, include_trade_count: true)
    end

    def create
      tickers = Array(params[:tickers]).map { |t| t.to_s.upcase.strip }.reject(&:empty?)
      period_days = Integer(params[:period_days] || TradingConfig.fetch(:backtest, :default_period_days))
      start_of_day_equity = BigDecimal((params[:start_of_day_equity] || TradingConfig.fetch(:backtest,
                                                                                            :start_of_day_equity)).to_s)
      mode = (params[:mode].presence || 'full').to_s
      name = params[:name].to_s.strip.presence

      if tickers.empty?
        return render json: { error: 'bad_request', message: 'tickers must be a non-empty array' }, status: :bad_request
      end
      if period_days <= 0 || period_days > 365
        return render json: { error: 'bad_request', message: 'period_days must be 1..365' }, status: :bad_request
      end
      unless BacktestRun::MODES.include?(mode)
        return render json: { error: 'bad_request', message: "mode must be one of #{BacktestRun::MODES.join(',')}" },
                      status: :bad_request
      end

      run = BacktestRun.create!(
        tickers: tickers,
        period_days: period_days,
        mode: mode,
        start_of_day_equity: start_of_day_equity,
        status: 'pending'
      )
      # `name` isn't a real column; persist it into config_snapshot so the
      # front-end can label runs in the history list.
      run.update!(config_snapshot: (run.config_snapshot || {}).merge('name' => name)) if name

      workflow_id = "backtest-#{run.id}-#{Time.current.to_i}"
      T_CLIENT.start_workflow(
        'Backtest::BacktestWorkflow',
        { backtest_run_id: run.id },
        id: workflow_id,
        task_queue: 'backtest-queue'
      )

      run.update!(
        temporal_workflow_id: workflow_id,
        status: 'pending'
      )

      render json: serialize_run(run.reload), status: :created
    rescue ArgumentError, TypeError => e
      render json: { error: 'bad_request', message: e.message }, status: :bad_request
    end

    def status
      render json: status_payload(@run)
    end

    def trades
      trades = @run.backtest_trades.chronological
      render json: trades.map { |t| serialize_trade(t) }
    end

    def cancel
      if @run.status.in?(%w[running pending])
        handle = T_CLIENT.workflow_handle(@run.temporal_workflow_id)
        begin
          handle.cancel
        rescue StandardError
          nil
        end
        @run.update!(status: 'cancelled', finished_at: Time.current)
      end
      render json: status_payload(@run)
    end

    private

    def set_run
      @run = BacktestRun.find(params.expect(:id))
    end

    def serialize_run(run, include_trade_count: false)
      payload = {
        id: run.id,
        name: run.config_snapshot.is_a?(Hash) ? run.config_snapshot['name'] : nil,
        tickers: run.tickers,
        period_days: run.period_days,
        mode: run.mode,
        status: run.status,
        start_of_day_equity: run.start_of_day_equity&.to_f,
        final_equity: run.final_equity&.to_f,
        total_pnl: run.total_pnl&.to_f,
        total_trades: run.total_trades,
        winning_trades: run.winning_trades,
        win_rate: run.win_rate.round(2),
        max_drawdown: run.max_drawdown&.to_f,
        sharpe: run.sharpe&.to_f,
        started_at: run.started_at,
        finished_at: run.finished_at,
        duration_seconds: run.duration_seconds,
        error_message: run.error_message,
        temporal_workflow_id: run.temporal_workflow_id,
        temporal_run_id: run.temporal_run_id,
        created_at: run.created_at,
        updated_at: run.updated_at
      }
      payload[:trade_count] = run.backtest_trades.count if include_trade_count
      payload
    end

    def serialize_trade(t)
      {
        id: t.id,
        ticker: t.ticker,
        strategy_type: t.strategy_type,
        legs: t.legs,
        entry_price: t.entry_price&.to_f,
        exit_price: t.exit_price&.to_f,
        pnl: t.pnl&.to_f,
        winner: t.winner?,
        holding_minutes: t.holding_minutes,
        opened_at: t.opened_at,
        closed_at: t.closed_at
      }
    end

    def status_payload(run)
      {
        id: run.id,
        status: run.status,
        total_trades: run.total_trades,
        total_pnl: run.total_pnl&.to_f,
        final_equity: run.final_equity&.to_f,
        started_at: run.started_at,
        finished_at: run.finished_at,
        error_message: run.error_message
      }
    end
  end
end
