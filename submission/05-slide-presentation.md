# Yield-paca — Slide Presentation

A 10-slide deck. Each slide has a headline and 3-5 bullet points.
Export to PowerPoint / Keynote / Google Slides using the same
structure below. Total deck targets a 5-minute pitch.

---

## SLIDE 1 — Cover

**Title:** Yield-paca: Multi-Agent AI Trading System on Alpaca MCP
**Subtitle:** Hackathon submission — Alpaca AI Trading Agents, Aug-Sep 2026
**Visual:** Logo / favicon, Alpaca logo, paper account ID: PA3PR2RMFE9Y
**Speaker notes:** Hi, I'm building Yield-paca — an AI trading system where research,
debate, and execution agents collaborate through MCP. Running on Alpaca paper.

---

## SLIDE 2 — The Problem

**Title:** Trading bots don't explain themselves
**Bullets:**

- Single-signal bots → no second-guessing
- LLM bots without gates → unsafe (naked shorts on level-3 paper)
- No audit trail → operator can't tell why the bot is wrong
- No replay → can't backtest strategies before going live

**Visual:** Two-column compare: "Black-box bot" vs "Multi-agent with gates"

---

## SLIDE 3 — Solution: a Real Multi-Agent Pipeline

**Title:** Every trade = a structured conversation
**Bullets:**

- 4 specialists: Market Data, News, Macro, Insider (run in parallel)
- Bull + Bear debate, then Research Manager synthesis
- Trader LLM proposes a multi-leg structure
- RiskManager (deterministic) approves or rejects
- PortfolioManager (deterministic) submits to broker via MCP
- Idempotent, replayable, audit-ready

**Visual:** Pipeline diagram with arrows + agent icons

---

## SLIDE 4 — Why Model Context Protocol

**Title:** MCP = pluggable + safe
**Bullets:**

- Alpaca MCP exposes tool groups: `account,trading,positions` for
  PortfolioManager only; `stock-data,options-data,news,assets` for
  read-only agents
- Trading toolsets are filtered out of the LLM agent's toolbox at
  init time — agents **cannot** place orders, even via prompt
  injection
- Architecture is the safety mechanism, not rate limiters
- Swap broker by replacing `alpaca-mcp` — zero code changes

**Visual:** MCP tool matrix table

---

## SLIDE 5 — Architecture (Temporal workflows)

**Title:** Orchestrated by Temporal, not Sidekiq
**Bullets:**

- 5 worker processes / 5 task queues
- Parent + child workflow pattern (Run + Close)
- Temporal Schedules survive worker restarts
- Idempotent: re-trigger is a no-op while positions are open
- Full audit trail in Postgres `agent_runs`, `risk_decisions`,
  `trade_proposals`

**Visual:** Workflow tree with parent / child / activity boxes

---

## SLIDE 6 — Three Production Strategies

**Title:** Mid-Band Movers + Overnight Reversal + Bull/Bear Pipeline
**Bullets:**

- **Mid-Band Movers** (11:30 AM ET cron): 3 buckets (2h/4h/23.5h),
  ATM 0DTE/30DTE long calls, fully deterministic
- **Overnight Reversal** (9:35 AM ET cron): yesterday's biggest
  winners → long calls; biggest losers → bear-call credit spreads;
  close at 15:55 ET
- **Bull/Bear Debate-Driven Ticker Pipeline** (every 15 min during
  market hours): 4 analyst briefs → Bull + Bear argue →
  Research Manager synthesizes → Trader LLM designs the order →
  deterministic Risk + Portfolio
- All three share the same deterministic risk + portfolio gates
- Per-name max-position cap (`max_position_pct: 0.20`)
- Per-order qty cap (`max_qty_per_order: 500`)
- Broker `ask_size ≥ 5` filter for liquidity

**Visual:** Three columns with strategy lifecycle diagrams

---

## SLIDE 7 — Safety Architecture

**Title:** LLM creativity + Deterministic gates
**Bullets:**

- RiskManager rejects on `max_position_pct`, `max_open_positions`,
  max delta/vega/theta, `decision_ttl_seconds`
- PortfolioManager re-verifies `options_approved_level` per leg
  (level-3 paper can't naked `sell_to_open`)
- Idempotency guard prevents stacking orders on stale leftovers
- AlpacaMirror runs 24/7, catches after-hours assignments
- All audit data in Postgres

**Visual:** Gate stack diagram (Trader LLM → Risk → Portfolio → MCP)

---

## SLIDE 8 — Live Results

**Title:** Run against Alpaca paper account **PA3PR2RMFE9Y**
**Bullets:**

- Equity: $89K–$98K intraday on paper
- 60+ orders placed, 22+ filled via MCP broker calls
- **Strategy 1:** Mid-Band Movers — 3 buckets, scheduled sells
- **Strategy 2:** Overnight Reversal — 12 contracts filled, $13K
  deployed (16% of equity)
- **Strategy 3:** Bull/Bear Debate Pipeline — 50+ cycles executed,
  the multi-agent conversation produces a typed verdict every cycle
- 0 naked-short rejections on the level-3 paper account

**Visual:** Screenshot of dashboard with positions table + the
Temporal UI workflow tree

---

## SLIDE 9 — Tech Stack

**Title:** Production-grade from day one
**Bullets:**

- Ruby 4.0 + Rails 8.1 + Sidekiq + Postgres 18
- Temporal.io (5 task queues, parent/child workflows, scheduled)
- MCP servers: Alpaca, TradingView, OptionsFlow, FRED
- LLM: Anthropic Claude via ruby_llm
- Frontend: Vue 3 SPA
- Single-source-of-truth config: `config/trading.yml` (no hardcoded
  thresholds)
- Docker Compose deployment

**Visual:** Stack diagram with logos

---

## SLIDE 10 — What's Next + Open Source

**Title:** Ship what works; open the rest
**Bullets:**

- Per-strategy risk caps so a new strategy can't blow the book
- Backtest harness that consumes the same `Strategy.plan` pure-Ruby
  class as production
- Options-flow signal in analyst briefs
- Adaptive DTE window per symbol (learn which bucket fills fastest)
- **Open source under `irox/images/trader`** — `Strategy.plan` is
  broker-agnostic; drop a different MCP and the same pipeline runs

**Visual:** Roadmap timeline
**End card:** GitHub URL · Alpaca paper ID: PA3PR2RMFE9Y · Thank you

---

## Speaker Notes / Demo Script (2 min)

1. **Slide 1-2 (30s):** Problem statement.
2. **Slide 3-4 (90s):** Walk through the multi-agent pipeline,
   emphasize MCP isolation.
3. **Slide 5 (45s):** Show Temporal UI live (workflow tree, the
   process-BAC ticker, the in-flight overnight-reversal run).
4. **Slide 6-7 (60s):** All 3 strategies + safety architecture.
5. **Slide 8 (60s):** Live demo — switch to dashboard, show
   positions, show alpaca paper account at PA3PR2RMFE9Y, show
   fills.
6. **Slide 9-10 (30s):** Tech stack + roadmap.

Total: ~2 minutes.

---

## Production Notes

To export this deck to PowerPoint:

1. Each slide becomes one PowerPoint slide
2. Use a 16:9 widescreen layout (1920x1080 or 13.33"x7.5")
3. Bullet points should appear as bullet lists, not paragraphs
4. Speakers-notes section attaches to each slide for the live talk
5. Save as `.pptx` and upload alongside this `.md`
