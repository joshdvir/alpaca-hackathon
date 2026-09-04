# frozen_string_literal: true

# TickerSelectorWorker — registers all the TickerSelector workflows and
# activities on the dedicated `ticker-selector-queue`. This queue is
# separate from the trading queue so a long-running ticker-selection
# cycle (which can take minutes to run the filter fan-out + LLM rank)
# can't starve the per-ticker trading activities. They use very
# different resource profiles (TS is bursty + MCP-heavy; trading is
# small + LLM-heavy) and previously shared the same activity slot
# pool.
#
# Run via: bin/worker TickerSelectorWorker
#   or:    bin/worker                  (runs every worker in app/workers/)

class TickerSelectorWorker < ApplicationWorker
  def self.workflows_arr
    [
      TickerSelector::TickerSelectorWorkflow
    ]
  end

  def self.activities_arr
    [
      TickerSelector::FetchUniverseActivity,
      TickerSelector::ApplyFiltersActivity,
      TickerSelector::RankCandidatesActivity,
      TickerSelector::PersistWatchlistActivity
    ]
  end

  def self.task_queues = ['ticker-selector-queue']

  # Tuner defaults for THIS worker. The ticker-selection pipeline is
  # MCP-call-heavy (bars + news + option chain per ticker, in parallel
  # inside ApplyFiltersActivity), not LLM-heavy — so the LLM-burst
  # throttle of 5 activity slots from the base class is way too tight.
  # With activity_slots: 5, the daily run takes 90+ minutes because
  # 5 slots × ~60s per ApplyFiltersActivity = 17 batches × 5 filters
  # × ~20 chunks = many hours of filter fan-out. Bumping to 20 lets
  # 20 ApplyFiltersActivity calls run in parallel; the upstream
  # Alpaca MCP easily handles 100+ req/s so the per-call latency
  # stays low, and the per-call HTTP work is small enough that 20
  # concurrent calls don't stress the worker process.
  #
  # Override at runtime via env vars (see `tuner_env_prefix`):
  #   TICKER_SELECTOR_WORKFLOW_SLOTS=20
  #   TICKER_SELECTOR_ACTIVITY_SLOTS=20
  #   TICKER_SELECTOR_LOCAL_ACTIVITY_SLOTS=100
  def self.tuner_settings
    {
      workflow_slots: 20,
      activity_slots: 20,
      local_activity_slots: 100
    }
  end
end
