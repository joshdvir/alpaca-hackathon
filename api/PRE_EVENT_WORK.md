# Pre-Event Work Disclosure

This document discloses the work done before the official **Alpaca AI Trading Agents Hackathon** measurement window (Mon Aug 31 9:30am ET → Fri Sep 4 9:30am ET), per the hackathon FAQ's disclosure requirement.

## Timeline

| Date (ET) | Activity | Notes |
|---|---|---|
| 2026-08-28 (Fri ~6pm) | Folder structure + docker-compose + MCP Dockerfile + .env + .gitignore | Pure scaffolding, no business logic |
| 2026-08-28 (Fri ~7pm) | `rails new` via disposable container, initializers, 21 migrations | Rails 8 skeleton + Postgres schema |
| 2026-08-28 (Fri ~7:30pm) | `api/config/trading.yml` with all prompts/thresholds/cycles | Algorithm config; not committed with secrets |
| 2026-08-28 (Fri ~8pm) | `Risk::RiskManager`, `Position::Monitor`, `Position::Review`, `Position::Adjustment` | Deterministic gates, no LLM yet |
| 2026-08-28 (Fri ~8:30pm) | `TickerSelector` workflow + 4 activities + agent + filter engine + universe provider | Daily ticker selection pipeline |
| 2026-08-28 (Fri ~9pm) | `trading_worker.rb` boots the Temporal worker | Worker ready to run |

## What was built pre-event

- **Infrastructure**: Docker Compose (postgres, temporal, alpaca-mcp, api), MCP Dockerfile, Rails 8 app skeleton
- **Schema**: 21 migrations covering market data, agent audit, debate, trade pipeline, position management, execution, portfolio, watchlist, backtest
- **Algorithm config**: All prompts, thresholds, cycles, filters, rate limits, circuit breaker params in `api/config/trading.yml`
- **Deterministic gates**: `Risk::RiskManager`, `Position::Monitor`, `Position::Review` orchestration, `Position::Adjustment` validation
- **TickerSelector**: full daily pipeline — universe fetch, deterministic filter engine, LLM ranker, persist watchlist
- **Temporal worker**: boots, registers TickerSelector workflow + its 4 activities

## What was NOT built pre-event

- 4 Analyst agents (MarketDataAnalyst, NewsAnalyst, MacroAnalyst, InsiderAnalyst)
- 3 Debate agents (Bull, Bear, ResearchManager)
- Trader agent
- PositionReviewAgent + AdjustmentAgent (LLM versions; orchestration shells are present)
- PortfolioManager (deterministic executor)
- SchedulerWorkflow + ProcessTickerWorkflow
- MonitorPositionWorkflow + ReviewPositionWorkflow
- Backtest engine + BacktestWorkflow
- Front-end Vue SPA
- RSpec tests (scaffolding only)

## Notes on fairness

- The pre-event work is infrastructure + the TickerSelector (which selects the universe but does not place trades).
- No pre-event work performed any trading decisions, evaluations, or order placements against the official paper account.
- The official trading window starts Mon Aug 31 9:30am ET. All trading agents, order placement, position management, and risk evaluation happen within the window.
- Pre-event work was limited to ~3 hours of scaffolding and was disclosed in this file per the FAQ.

## Build commands (reproducible)

```bash
# Init Rails via disposable container
docker run --rm -v "$(pwd)/api:/app" -w /app ruby:3.3-slim \
  bash -c "gem install rails -v '~> 8.0' --no-document && rails new . -d postgresql"

# Inside the api container:
bundle install
bundle exec rails db:create db:migrate

# Start everything
docker compose up -d

# Trigger a TickerSelector run manually (within the api container):
docker compose exec api bash
> bundle exec ruby -e "require_relative 'config/environment'; TickerSelector::TickerSelectorWorkflow.new.execute"
```

## Disclosure summary

Total LOC pre-event: ~1,500 (excluding generated Rails skeleton).
Of that, ~1,200 is infrastructure/scaffolding/config and ~300 is the TickerSelector pipeline.
Zero trading decisions or order placements occurred pre-event.
