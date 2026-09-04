# frozen_string_literal: true

# RunExecutionPhaseActivity — converts a ResearchManager verdict into a
# TradeProposal, runs the risk gate, and either routes through the
# PortfolioManager or rejects the plan. Returns the final outcome so the
# ProcessTickerWorkflow can log it.
#
# When the verdict is "no_trade", we still record the TradeProposal row
# (status: "rejected") so the audit trail is complete.
#
# TradeProposal shape (per the migration): legs is JSONB with one entry per
# option leg, e.g. [{side, ratio_qty, option_symbol, limit_price}].
# `ctx` carries {workflow_id, run_id}.
#
# RESILIENCE: this activity NEVER raises. Any failure (trader LLM
# failure, option_symbol not found, risk rejection, broker error) is
# caught, logged, and converted to a structured outcome so the
# ProcessTickerWorkflow can record it. The result is always a Hash
# with an `outcome` key.

module Trading
  class RunExecutionPhaseActivity < ApplicationActivity
    def execute(ticker, debate_result, market_state, watchlist_entry, ctx)
      workflow_id = ctx['workflow_id'] || ctx[:workflow_id]
      run_id      = ctx['run_id']      || ctx[:run_id]
      activity.logger.info "[activity:start] RunExecutionPhaseActivity ticker=#{ticker} workflow_id=#{workflow_id}"

      verdict = debate_result[:verdict] || debate_result['verdict'] || {}
      activity.logger.info "[activity:execute] ticker=#{ticker} verdict=#{verdict[:verdict] || verdict['verdict']} " \
                        "confidence=#{verdict[:confidence] || verdict['confidence']}"
      return log_no_trade(ticker, debate_result, watchlist_entry, workflow_id) unless (verdict[:verdict] || verdict['verdict']) == 'trade'

      trader_run = safe_trader(ticker, verdict, market_state, workflow_id, run_id)
      proposal_data = trader_run[:proposal] || trader_run['proposal']
      return log_trader_failed(ticker, debate_result, watchlist_entry, workflow_id) if trader_run[:_insufficient] || proposal_data.nil?

      # The Trader returns a normalized {proposal: {legs: [...], tif, rationale}}
      # shape (single-leg and multi-leg both wrap into `legs`). Map each
      # LLM leg into the TradeProposal.legs JSONB shape
      # [{side, ratio_qty, option_symbol, limit_price}]. `net_limit_price`
      # (when present) is the broker's net debit/credit for multi-leg;
      # PortfolioManager applies it on the first leg for the mleg order.
      legs = (proposal_data[:legs] || []).map do |leg|
        {
          'side' => leg[:side] || leg['side'],
          'ratio_qty' => leg[:qty] || leg['qty'],
          'option_symbol' => leg[:symbol] || leg['symbol'],
          'limit_price' => (leg[:limit_price] || leg['limit_price']).to_f,
          # multi-leg only — single-leg won't have this key
          'net_limit_price' => (leg[:net_limit_price] || leg['net_limit_price'])&.to_f
        }.compact
      end

      # Defensive: a parse that yields zero legs is a malformed
      # proposal. Treat as trader failure (logged + TradeProposal
      # row written with empty legs for audit).
      if legs.empty?
        activity.logger.warn "[activity:execute] ticker=#{ticker} trader returned proposal with no legs"
        return log_trader_failed(ticker, debate_result, watchlist_entry, workflow_id)
      end

      proposal = TradeProposal.create!(
        agent_run: AgentRun.where(temporal_workflow_id: workflow_id).order(created_at: :desc).first,
        ticker: ticker,
        kind: 'new',
        strategy_type: (verdict[:trade_plan] || verdict['trade_plan'] || {})['strategy'] || 'hold',
        legs: legs,
        max_loss: 0,
        max_profit: 0,
        rationale: proposal_data[:rationale],
        status: 'pending'
      )

      decision = safe_risk(proposal)
      if decision.nil? || decision.rejected?
        proposal.update!(status: 'rejected')
        reasons = decision&.reasons || ['risk_check_failed']
        activity.logger.info "[activity:execute] ticker=#{ticker} risk_rejected proposal=#{proposal.id} reasons=#{reasons.inspect}"
        return { outcome: 'rejected_by_risk', proposal: proposal.id, reasons: reasons }
      end

      proposal.update!(status: 'risk_approved')
      result = safe_portfolio(proposal)
      if result.nil?
        proposal.update!(status: 'cancelled')
        activity.logger.warn "[activity:execute] ticker=#{ticker} portfolio_failed proposal=#{proposal.id}"
        return { outcome: 'broker_error', proposal: proposal.id, reasons: ['portfolio_executor_failed'] }
      end

      # Market-closed is a SOFT failure: the portfolio manager has
      # already set the proposal's status to 'deferred' (see
      # PortfolioManager#defer_to_market_open), so the workflow
      # shouldn't override that to 'cancelled'. The next trading
      # cycle will re-evaluate and either re-defer or fill.
      if result.reasons&.first == 'market_closed'
        activity.logger.info "[activity:execute] ticker=#{ticker} market_closed proposal=#{proposal.id} (deferred for next open)"
        return { outcome: 'market_closed', proposal: proposal.id, reasons: result.reasons }
      end

      if result.ok?
        activity.logger.info "[activity:execute] ticker=#{ticker} submitted order=#{result.order&.id} proposal=#{proposal.id}"
        { outcome: 'submitted', order: result.order.id, proposal: proposal.id }
      else
        proposal.update!(status: 'cancelled')
        activity.logger.warn "[activity:execute] ticker=#{ticker} broker_error proposal=#{proposal.id} reasons=#{result.reasons.inspect}"
        { outcome: 'broker_error', proposal: proposal.id, reasons: result.reasons }
      end
    rescue StandardError => e
      # Last-line backstop. The individual safe_* helpers should
      # convert the most common failures into structured outcomes.
      # Anything that lands here is a real bug — log loudly and
      # return a failure outcome so the workflow can record it.
      activity.logger.error "[activity:execute] ticker=#{ticker} UNCAUGHT #{e.class}: #{e.message}\n" \
                          "#{e.backtrace.first(8).join("\n")}"
      {
        outcome: 'uncaught_error',
        error_class: e.class.name,
        error_message: e.message[0, 500]
      }
    end

    private

    def safe_trader(ticker, verdict, market_state, workflow_id, run_id)
      activity.logger.info "[activity:execute] ticker=#{ticker} trader start"
      result = Trader.call(
        ticker, verdict[:trade_plan] || verdict['trade_plan'], market_state,
        workflow_id: workflow_id, run_id: run_id
      )
      # Trader.call already rescues everything and returns
      # default_brief on failure, so `proposal: nil` is the only
      # failure signal.
      if result[:_insufficient] || result[:proposal].nil?
        activity.logger.warn "[activity:execute] ticker=#{ticker} trader returned insufficient default brief"
      else
        activity.logger.info "[activity:execute] ticker=#{ticker} trader produced #{result[:symbol]} #{result[:side]} qty=#{result[:qty]} " \
                          "limit=#{result[:limit_price]}"
      end
      result
    end

    def safe_risk(proposal)
      Risk::RiskManager.new.check(proposal)
    rescue StandardError => e
      activity.logger.error "[activity:execute] risk check raised #{e.class}: #{e.message}"
      nil
    end

    def safe_portfolio(proposal)
      Portfolio::PortfolioManager.execute(proposal)
    rescue StandardError => e
      activity.logger.error "[activity:execute] portfolio execute raised #{e.class}: #{e.message}"
      nil
    end

    def log_trader_failed(ticker, debate_result, _watchlist_entry, workflow_id)
      activity.logger.info "[activity:execute] ticker=#{ticker} trader_failed -> no_trade"
      TradeProposal.create!(
        agent_run: AgentRun.where(temporal_workflow_id: workflow_id).order(created_at: :desc).first,
        ticker: ticker,
        kind: 'auto_close',
        strategy_type: 'hold',
        legs: [],
        max_loss: 0,
        max_profit: 0,
        rationale: 'trader returned insufficient brief',
        status: 'rejected'
      )
      {
        outcome: 'no_trade',
        reasons: ['trader_insufficient_data']
      }
    end

    def log_no_trade(ticker, debate_result, _watchlist_entry, workflow_id)
      verdict = debate_result[:verdict] || debate_result['verdict'] || {}
      reasons = verdict[:no_trade_reasons] || verdict['no_trade_reasons'] || []
      activity.logger.info "[activity:execute] ticker=#{ticker} research_manager no_trade reasons=#{reasons.inspect}"
      TradeProposal.create!(
        agent_run: AgentRun.where(temporal_workflow_id: workflow_id).order(created_at: :desc).first,
        ticker: ticker,
        kind: 'auto_close',
        strategy_type: 'hold',
        legs: [],
        max_loss: 0,
        max_profit: 0,
        rationale: "research_manager: #{Array(reasons).join('; ')}",
        status: 'rejected'
      )
      { outcome: 'no_trade', reasons: reasons }
    end
  end
end
