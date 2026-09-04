# Yield-paca — Multi-Agent AI Trading System on Alpaca MCP

## The Problem

Algorithmic trading is dominated by single-purpose bots that bolt a
single signal generator onto a single broker API. They don't research,
don't second-guess their own thesis, don't recompute risk under stress,
and don't expose their reasoning to a human operator. When the bot
gets it wrong, the operator is left guessing *why*.

Yield-paca solves this with a true multi-agent architecture: every trade
is the output of a structured conversation between specialized agents
(Market Data, News, Macro, Insider analysts → Bull vs Bear debate →
Research Manager synthesis → Trader → deterministic Risk Manager →
deterministic Portfolio Manager), with the broker (Alpaca) reached
exclusively through MCP tools the agents can call.

## What It Does

Yield-paca runs on a live Alpaca paper-trading account and currently
operates three production strategies:

### 1. Mid-Band Movers (deterministic, scheduled at 11:30 AM ET)
- Pulls yesterday's top movers across the optionable universe
  (Alpaca-bars fallback when TradingView MCP is rate-limited)
- Filters by daily-volume and tradability
- Sorts into three hold-time buckets: **2h / 4h / 23.5h**
- Buys ATM 0DTE/30DTE long calls on the middle band (skips the
  top/bottom tails to filter pumps and dumps)
- Spawns `SellWorkflow` per order, sleeps until planned sell time,
  submits `sell_to_close`

### 2. Overnight Reversal (deterministic, scheduled at 9:35 AM ET)
- Pulls the prior session's biggest winners + biggest losers via
  TradingView screener
- Maps winners → ATM 0DTE long calls (long bias on reversal-up)
- Maps losers → bear-call credit spreads (defined-risk short bias)
- Probes each survivor against DTE windows [0, 3, 7, 14, 30, 60]
  requiring broker `ask_size ≥ 5` contracts at the chosen strike
  so partial-fill slip is filtered out
- Spawns `CloseOvernightReversalWorkflow` to flatten everything at
  15:55 ET — broker expiry handles ITM 0DTE assignments

### 3. Bull/Bear Debate-Driven Ticker Pipeline (LLM, scheduled every 15 min during market hours)
This is the *full* multi-agent pipeline. It runs against every
watchlist ticker the TickerSelector picks each morning:

```
FetchMarketState → RunAnalystPhase (4 specialists in parallel)
  → RunDebatePhase (Bull + Bear argue; Research Manager synthesizes)
  → RunExecutionPhase (Trader LLM designs a multi-leg structure)
  → RunRiskPhase (deterministic: per-leg options_approved_level check,
                  max_position_pct, max_open_positions, decision_ttl)
  → Portfolio (deterministic: re-verify, submit via MCP)
```

- **Bull Researcher** and **Bear Researcher** agents run in
  parallel, each sees the same four analyst briefs (Market Data,
  News, Macro, Insider) and writes a 3-5 sentence case. They
  directly address each other's previous arguments.
- **Research Manager** synthesizes a typed `ResearchPlan` with
  direction (`bullish`/`bearish`/`neutral`), confidence, key
  catalysts, invalidation conditions.
- **Trader** LLM designs a concrete option structure
  (`vertical`/`iron_condor`/`straddle`/`strangle`/`calendar`/
  `hold`), sized off live `options_buying_power` and
  `max_notional_per_trade`.
- **RiskManager** is deterministic — rejects on account-level
  violations, position cap, delta/vega/theta ceiling,
  decision-TTL expiry (120s). Most rejections happen here so no
  capital ever lands at the broker unscreened.
- **PortfolioManager** is also deterministic — re-verifies the
  options_approved_level per leg, then submits via the broker MCP.
- A failed pipeline produces a structured no-trade verdict, never
  a crash, so the next cycle retries from a fresh workflow.
- Position review (every 30 min): same Bull/Bear pattern, but
  reading the *current* market context to decide whether to hold,
  close, roll, adjust, or add on each open position.

All three strategies share the same deterministic risk + portfolio
gates and the same AlpacaMirror audit loop. The only difference is
where the trade idea comes from: deterministic-screener (strategies
1-2) or LLM debate (strategy 3).

## Architecture

```
                     ┌───────────────────────────────────────────┐
                     │          Temporal Schedules              │
                     │  cron 35 9 * * 1-5  → ovn reversal       │
                     │  cron 30 11 * * 1-5 → mid-band movers    │
                     │  cron */15 8-16 * * 1-5 → trading sched  │
                     │  cron */30 8-16 * * 1-5 → position review│
                     │  cron */1 * * * *    → alpaca mirror     │
                     └────────────────┬──────────────────────────┘
                                      │
                                      ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │   Parent Workflow (e.g. RunOvernightReversalWorkflow)         │
   │     1. BuildPlanActivity      ─→ pure-Ruby planning             │
   │     2. SubmitOrdersActivity   ─→ winners (long calls) + losers │
   │        │                              (multi-leg bear-spreads)  │
   │        └─→ 3. spawn CloseChildWorkflow → sleep until 15:55 ET   │
   └─────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼ risk + portfolio gate
                                      │
   ┌─────────────────────────────────────────────────────────────────┐
   │   TradingWorkflowsWorker (task_queue=trading-queue)             │
   │   ProcessTickerWorkflow per watched ticker:                      │
   │     FetchMarketState → RunAnalystPhase (4 analysts in parallel)│
   │       → RunDebatePhase (Bull + Bear + Research Manager)        │
   │       → RunExecutionPhase (Trader LLM)                           │
   │       → RunRiskPhase (deterministic) → Portfolio (deterministic)│
   └─────────────────────────────────────────────────────────────────┘
```

### Why Model Context Protocol (MCP)?

Every broker and market-data integration goes through an MCP server.
This keeps the agent framework pluggable: swap `alpaca-mcp` for any
MCP-compatible broker without touching the agents; swap
`tradingview-mcp` for any screener source. The Alpaca MCP server
ships tool groups keyed by risk profile:
- `account, trading, positions` — PortfolioManager only
- `stock-data, options-data, news, assets` — Analyst + agents (read-only)

Agents **cannot** call trading tools even via prompt injection. The
architecture is the safety mechanism — not just rate limiters.

### Why Deterministic Risk + Portfolio Gates?

LLM agents are creative; they will propose strategies that violate the
account's `options_approved_level` (3), naked-writing rules, position
caps, or the live `options_buying_power`. Every `Trader` LLM call's
output passes through:

- **RiskManager.check** — fails-fast on `max_position_pct`,
  `max_open_positions`, `max_total_delta/vega/theta`,
  `decision_ttl_seconds`
- **PortfolioManager.execute** — re-verifies `options_approved_level`
  per leg (level-3 paper accounts can't sell_to_open a naked single
  leg), then submits to the broker via `place_option_order`

These gates have rejected every LLM-proposed naked short on the level-3
paper account so far. The agents can't burn real money by hallucinating
a long-butterfly.

### Operational Maturity

- **5 worker processes**, 5 task queues (alpaca-mirror,
  backtest, position, ticker-selector, trading)
- **Idempotent build_plan**: a fresh trigger while positions from
  the prior tick are still open short-circuits to
  `skipped=already_open`. No double-stacking 5+5 orders on a stale
  leftover.
- **AlpacaMirror** syncs account, positions, orders, fills every
  minute (24/7 incl. weekends) → catches after-hours assignments,
  preserves an audit trail in Postgres.
- **Rate limiters + circuit breakers** per MCP source; transparent
  when the upstream 429s.

## Live Results (Aug 28 – Sep 4, 2026 hackathon window)

Running on paper-trading account **PA3PR2RMFE9Y**:

| Strategy | Order attempts | Filled | Rejected | Net deployed today |
|---|---|---|---|---|
| Mid-Band Movers | 45 | 22 | 8 | (running) |
| Overnight Reversal | 19 | 12 | 0 | $13K (16% of equity) |

Equity during the run climbed from $89K to $98K intraday, with daily
P&L tracked continuously via the mirror's `PortfolioSnapshot`.

## Tech Stack

- **Backend:** Ruby 4.0 on Rails 8.1, Sidekiq for non-Temporal jobs
- **Orchestration:** Temporal.io (5 task queues, parent + child
  workflows, scheduled via Temporal Schedules — survives worker
  restarts)
- **Persistence:** PostgreSQL 18 (orders, fills, positions,
  portfolios, agent_runs, research_plans, risk_decisions,
  backtest_runs)
- **Frontend:** Vue 3 single-page app (positions view, orders view,
  agent-run timeline)
- **MCP servers:** Alpaca (`uvx alpaca-mcp-server`),
  TradingView, OptionsFlow, FRED
- **LLM:** Anthropic Claude via OpenAI-compatible endpoint
  (`ruby_llm` gem), used for analyst briefs, bull/bear debate,
  research-manager synthesis, trader output, position review

## What's Next

- **Per-strategy risk caps** so adding a new strategy can't drag the
  aggregate book past risk_limits
- **Backtest harness** that consumes the same `Strategy.plan`
  pure-Ruby class as production so all strategies can be replayed
  against historical bars before going live
- **Options-flow MCP integration** for unusual-options-activity
  signal in the analyst briefs
- **Adaptive DTE window** that learns per-symbol which DTE bucket
  fills most aggressively for the next session

## Open Source

Full source under the parent `irox/images/trader/api` repo. The
strategy-class interface (`Strategy.plan`) is the one thing that
should be re-usable across any broker — drop a new
`OvernightReversal::Mcp` concern over a different broker's MCP, and
the same `plan → probe → submit → close` pipeline runs unchanged.
