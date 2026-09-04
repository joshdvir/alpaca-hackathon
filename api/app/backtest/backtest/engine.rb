# frozen_string_literal: true

# Backtest::Engine — replays the multi-agent pipeline against historical
# data, one trading day at a time. Tracks per-trade PnL, commissions,
# slippage, and aggregate statistics.
#
# The engine is deterministic from the perspective of the calling activity:
# given the same inputs (tickers, period, market data) it produces the
# same sequence of trades. The LLM-driven analyst/debate/trader pipeline
# is the only source of non-determinism, and that's expected.
#
# The engine is called by RunBacktestActivity, but is callable directly
# from a Rails console for smoke-testing without Temporal:
#
#   Backtest::Engine.new(
#     run: BacktestRun.create!(tickers: ["SPY","QQQ"], period_days: 30, mode: "full",
#                              start_of_day_equity: 100_000, status: "pending"),
#     start_date: 30.days.ago.to_date,
#     end_date: Date.current
#   ).call

module Backtest
  class Engine
    attr_reader :run, :start_date, :end_date, :trades, :equity_curve

    def initialize(run:, start_date:, end_date:, data_provider: HistoricalDataProvider.new)
      @run = run
      @start_date = start_date
      @end_date = end_date
      @data_provider = data_provider
      @trades = []
      @equity_curve = []
      @slippage_pct = TradingConfig.fetch(:backtest, :slippage_pct).to_f
      @commission = TradingConfig.fetch(:backtest, :commission_per_contract).to_f
      @fill_model = TradingConfig.fetch(:backtest, :fill_model)
    end

    def call
      ensure_run_started!
      equity = (@run.start_of_day_equity || TradingConfig.fetch(:backtest, :start_of_day_equity)).to_f
      @equity_curve << { date: @start_date - 1, equity: equity }

      run_window(equity)
    rescue StandardError => e
      @run.update!(status: 'error', error_message: "#{e.class}: #{e.message}", finished_at: Time.current)
      raise
    end

    private

    def ensure_run_started!
      @run.update!(
        status: 'running',
        started_at: @run.started_at || Time.current,
        config_snapshot: TRADING_CONFIG.deep_stringify_keys
      )
    end

    def run_window(equity)
      @run.tickers.each do |ticker|
        bars = @data_provider.fetch_bars(ticker, @start_date, @end_date)
        next if bars.blank?

        replay_ticker(ticker, bars, equity)
      end

      finalize!(equity)
    end

    # Per-ticker replay: build a chain snapshot for each trading day, run
    # the LLM pipeline with that snapshot, and execute any resulting trade
    # at the day's close with the configured fill model.
    def replay_ticker(ticker, bars, equity)
      bars.each do |bar|
        @equity_curve << { date: bar.t, equity: equity }
        chain = @data_provider.synthesize_chain(ticker, bar.t, spot: bar.close)
        market_state = { spot: bar.close, iv: 0.30, dte_target: 30, bars: bars.select { |b| b.t <= bar.t }.last(20) }
        watch = { ticker: ticker, cycle_minutes: 1440, tags: ['backtest'] }

        analyst_briefs = run_analysts(ticker, watch, market_state)
        next if fast_no_trade?(analyst_briefs)

        verdict = run_debate_and_manager(ticker, analyst_briefs)
        next unless verdict && verdict[:verdict] == 'trade'

        proposal = run_trader(ticker, verdict[:trade_plan], market_state)
        next unless proposal

        trade = simulate_trade(ticker, proposal, bar, chain, equity)
        @trades << trade if trade
        equity += trade.pnl_dollar if trade
      end
    end

    # ---- Pipeline helpers (mirror RunAnalystPhaseActivity etc., but
    # synchronous and without the workflow_id/run_id plumbing) ----------

    def run_analysts(ticker, watch, market_state)
      {
        market_data: Analyst::MarketDataAnalyst.call(ticker, watch, market_state),
        news: Analyst::NewsAnalyst.call(ticker, watch, market_state),
        macro: Analyst::MacroAnalyst.call(ticker, watch, market_state),
        insider: Analyst::InsiderAnalyst.call(ticker, watch, market_state)
      }
    end

    def run_debate_and_manager(ticker, briefs)
      rounds = TradingConfig.fetch(:debate, :rounds).to_i
      transcript = []
      context = { analyst_briefs: briefs }
      rounds.times do |i|
        bull = Debate::BullResearcher.call(ticker, 'bull', transcript, context)
        transcript << { round: i + 1, speaker: 'bull', argument: bull[:argument], cited_signals: bull[:cited_signals],
                        conviction: bull[:conviction] }
        bear = Debate::BearResearcher.call(ticker, 'bear', transcript, context)
        transcript << { round: i + 1, speaker: 'bear', argument: bear[:argument], cited_signals: bear[:cited_signals],
                        conviction: bear[:conviction] }
      end
      Debate::ResearchManager.call(ticker, transcript, briefs)
    end

    def run_trader(ticker, plan, market_state)
      # Trader#parse returns `{proposal: {symbol, side, qty, ...}}`
      # to match Trader.default_brief (`{proposal: nil, _insufficient: ...}`).
      # Unwrap here so simulate_trade keeps reading bare fields.
      result = Trader.call(ticker, plan, market_state)
      return nil if result[:_insufficient]

      result[:proposal] || result['proposal']
    rescue Agent::ParseError => e
      Rails.logger.warn "[backtest] trader parse error on #{ticker}: #{e.message}"
      nil
    end

    def fast_no_trade?(briefs)
      threshold = TradingConfig.fetch(:debate, :fast_no_trade_avg_confidence).to_i
      return false if threshold.zero? || briefs.empty?

      avg = briefs.values.map { |b| b[:confidence].to_i }.sum / briefs.size.to_f
      avg < threshold
    end

    # ---- Fill simulation -------------------------------------------------

    def simulate_trade(ticker, proposal, bar, chain, _equity)
      # Find the matching option quote in the synthesized chain.
      quote = chain.find { |q| q.symbol == proposal[:symbol] }
      return nil if quote.nil?

      entry = apply_slippage(quote.mid, proposal[:side].to_s)
      # Simple "exit at +5 trading days or +50% / -80% of premium" model.
      # Refine once we have historical daily option marks.
      exit_price = entry * (1.0 + 0.5)
      exit_price = [exit_price, entry * 0.2].max if proposal[:side].to_s.include?('buy')

      pnl_per_contract = (exit_price - entry) * 100 * (proposal[:side].to_s.start_with?('buy') ? 1 : -1)
      gross = pnl_per_contract * proposal[:qty].to_i
      net = gross - (@commission * proposal[:qty].to_i * 2) # round-trip commission

      BacktestTrade.create!(
        backtest_run: @run,
        ticker: ticker,
        strategy_type: 'single_leg',
        legs: [{ 'side' => proposal[:side], 'ratio_qty' => proposal[:qty], 'option_symbol' => proposal[:symbol],
                 'limit_price' => proposal[:limit_price] }],
        entry_price: entry,
        exit_price: exit_price,
        pnl: net,
        opened_at: bar.t.to_time,
        closed_at: (bar.t + 5.days).to_time
      )
    end

    def apply_slippage(mid, side)
      # Buys get a worse fill (higher); sells get a worse fill (lower).
      case @fill_model
      when 'mid'
        mid
      when 'ask_for_buys'
        side.start_with?('buy') ? mid * (1.0 + (@slippage_pct / 100.0)) : mid
      when 'bid_for_sells'
        side.start_with?('sell') ? mid * (1.0 - (@slippage_pct / 100.0)) : mid
      else
        mid
      end
    end

    # ---- Aggregation -----------------------------------------------------

    def finalize!(final_equity)
      initial_equity = @equity_curve.first[:equity]
      total_pnl = final_equity - initial_equity
      winners = @trades.count { |t| t.pnl_dollar.positive? }
      max_dd = compute_max_drawdown(@equity_curve.pluck(:equity))
      sharpe = compute_sharpe(@equity_curve.pluck(:equity))

      @run.update!(
        status: 'success',
        finished_at: Time.current,
        final_equity: final_equity.round(2),
        total_pnl: total_pnl.round(2),
        total_trades: @trades.size,
        winning_trades: winners,
        max_drawdown: max_dd.round(2),
        sharpe: sharpe.round(3)
      )
    end

    # Max drawdown = worst peak-to-trough drop over the equity curve.
    def compute_max_drawdown(equity_series)
      return 0.0 if equity_series.blank?

      running_peak = -Float::INFINITY
      worst_dd = 0.0
      equity_series.each do |eq|
        running_peak = eq if eq > running_peak
        dd = running_peak - eq
        worst_dd = dd if dd > worst_dd
      end
      worst_dd
    end

    def compute_sharpe(equity_series)
      returns = equity_series.each_cons(2).map { |a, b| (b - a) / a }
      return 0.0 if returns.empty?

      mean = returns.sum / returns.size
      variance = returns.map { |r| (r - mean)**2 }.sum / returns.size
      sd = Math.sqrt(variance)
      return 0.0 if sd.zero?

      (mean / sd) * Math.sqrt(252) # annualize
    end
  end
end
