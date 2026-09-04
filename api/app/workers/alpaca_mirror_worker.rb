# frozen_string_literal: true

# AlpacaMirrorWorker — registers the AlpacaMirrorWorkflow and
# SyncAlpacaActivity on the dedicated `alpaca-mirror-queue`. The
# Temporal `alpaca-mirror` schedule fires the workflow every 30s
# (UTC) — this worker is what picks up those workflow starts and
# runs them.
#
# Why a dedicated queue (not on the trading-queue):
#   - The mirror is a constant background tax (every 30s, ~1-2s of
#     MCP traffic). Putting it on the trading-queue would compete
#     with ProcessTickerWorkflow slots and could slow down trading
#     on a slow broker response.
#   - Independent scaling: if the mirror gets noisy (e.g. a slow
#     broker), it doesn't affect the trading pipeline.
#   - The workflow itself is trivial — one activity call — so
#     activity_slots: 2 is plenty. (Bump to 5+ if the broker is
#     flaky and we want overlap.)
#
# Run via: bin/worker AlpacaMirrorWorker
#   or:    bin/worker                  (runs every worker in app/workers/)

class AlpacaMirrorWorker < ApplicationWorker
  def self.workflows_arr
    [
      AlpacaMirror::AlpacaMirrorWorkflow
    ]
  end

  def self.activities_arr
    [
      AlpacaMirror::SyncAlpacaActivity
    ]
  end

  def self.task_queues = ['alpaca-mirror-queue']

  # Tuner defaults — the mirror workflow is tiny (1 activity call)
  # so 1-2 slots per queue is plenty. If the broker is slow and the
  # schedule starts to back up, raise to 3-5.
  def self.tuner_settings
    {
      workflow_slots: 5,
      activity_slots: 2,
      local_activity_slots: 10
    }
  end
end
