# frozen_string_literal: true

# SchedulerWorkflow — single-pass reconciliation workflow. Triggered by
# the `trading-scheduler-reconcile` Temporal schedule (cron */30 * * * *)
# which is managed by Temporal::ScheduleManager (see config/initializers
# /temporal_schedules.rb).
#
# Each invocation:
#   1. Re-reads the watchlist
#   2. Lists running ProcessTickerWorkflow children (Temporal visibility)
#   3. For each watchlist entry that is due AND not already running,
#      launches a new child ProcessTickerWorkflow with a unique ID
#
# The workflow exits after one pass. Temporal decides when to fire it
# again, which gives us:
#   - Survives worker restarts (Temporal persists the schedule)
#   - Backfill support (Temporal can run missed fires after a long outage)
#   - Concurrency control via the schedule's overlap policy
#
# Staggering strategy:
#   - 10 tickers per batch
#   - 30s between batches (so we don't slam the rate limiter)
#   - 200ms within a batch (so child workflow IDs are unique)
#
# Idempotency:
#   - Calls ListRunningTickerWorkflowsActivity first; tickers with a running
#     process_ticker workflow are skipped this cycle.
#   - Child workflow_id is `process-<TICKER>-<UUID>`. The UUID makes it
#     guaranteed-unique across cycles AND across same-cycle children.
#     The earlier `<cycle_started_at.to_i>` suffix collided when a watch
#     entry got re-emitted mid-cycle with the same ticker — the second
#     launch silently no-op'd as `WorkflowAlreadyStarted`.
#   - The UUID comes from `Temporalio::Workflow.random.uuid`, NOT
#     `SecureRandom.uuid`. Inside a workflow Temporal requires
#     deterministic replay; `SecureRandom` would generate a fresh
#     UUID every replay and the second pass would fail with
#     `[TMPRL1100] Nondeterminism error: Child workflow id of scheduled
#     event '...' does not match child workflow id of command '...'`.
#     `T_WORKFLOW.random` is a `Random` instance seeded by the
#     workflow's determinism seed, so the same UUID is generated on
#     every replay.

module Trading
  class SchedulerWorkflow < ApplicationWorkflow
    BATCH_SIZE    = TradingConfig.fetch(:scheduler, :batch_size)
    BATCH_GAP_S   = TradingConfig.fetch(:scheduler, :batch_gap_seconds)
    WITHIN_GAP_MS = TradingConfig.fetch(:scheduler, :within_batch_gap_ms)

    def execute
      # Temporal workflows must be deterministic. Never call
      # Time.current / Time.now / Time.zone.now inside a workflow —
      # use T_WORKFLOW.now (which is the workflow's logical clock,
      # stable across replays).
      cycle_started_at = T_WORKFLOW.now.utc
      activity.logger.info "[scheduler] starting cycle at #{cycle_started_at.iso8601}"
      run_cycle(cycle_started_at)
      activity.logger.info "[scheduler] cycle complete; exiting (Temporal will fire again per cron)"
    rescue StandardError => e
      # The scheduler should always complete cleanly so the next
      # cycle can fire. Log and re-raise — Temporal will mark the
      # cycle failed but the cron schedule will keep firing.
      activity.logger.error "[scheduler] cycle crashed: #{e.class}: #{e.message}\n" \
                              "#{e.backtrace.first(8).join("\n")}"
      raise
    end

    private

    def run_cycle(cycle_started_at) # rubocop:disable Metrics/AbcSize
      activity.logger.info "[scheduler:phase] watchlist"
      watchlist = T_WORKFLOW.execute_activity(
        FetchActiveWatchlistActivity,
        start_to_close_timeout: 30
      )
      activity.logger.info "[scheduler:phase] watchlist size=#{watchlist.size}"

      activity.logger.info "[scheduler:phase] running_workflows"
      running = T_WORKFLOW.execute_activity(
        ListRunningTickerWorkflowsActivity,
        start_to_close_timeout: 30
      )
      # Activity results come back from Temporal's JSON converter with
      # STRING keys (Temporal has no concept of symbol-keyed hashes).
      # All `watch[...]` / `running[...]` accesses below use strings.
      running_tickers = running.map { |r| r['ticker'] }.compact.to_set
      activity.logger.info "[scheduler:phase] running_workflows size=#{running_tickers.size}"

      # IO MUST be hoisted out of the workflow. The activity returns
      # `{ ticker => last_run_epoch_seconds }`; the workflow then
      # compares against T_WORKFLOW.now in deterministic time.
      activity.logger.info "[scheduler:phase] last_runs"
      last_runs = T_WORKFLOW.execute_activity(
        FetchLastAgentRunTimestampsActivity,
        start_to_close_timeout: 30
      )
      due = watchlist.select { |w| due_for_cycle?(w, last_runs, cycle_started_at) }
      due.reject! { |w| running_tickers.include?(w['ticker']) }

      activity.logger.info "[scheduler:phase] due=#{due.size} (running skipped=#{running_tickers.size})"
      launch_in_batches(due)
    end

    # A ticker is due if it has not been processed in the last
    # `cycle_minutes` minutes. We compare against a pre-fetched
    # `last_runs` hash (epoch seconds, fetched by
    # FetchLastAgentRunTimestampsActivity) and the workflow's
    # deterministic `T_WORKFLOW.now` time. No IO happens here.
    def due_for_cycle?(watch, last_runs, now)
      last_epoch = last_runs[watch['ticker']]
      return true if last_epoch.nil?

      now_epoch  = now.to_i
      cycle_secs = watch['cycle_minutes'].to_i * 60
      (now_epoch - last_epoch) >= cycle_secs
    end

    def launch_in_batches(due)
      # Launch every due ticker in parallel via T_FUTURE.new and
      # block on T_FUTURE.all_of.wait. The earlier sequential
      # launch_in_batches + T_WORKFLOW.sleep(WITHIN_GAP_MS) was
      # sequential: 11 tickers × 200ms = 2.2s of pure sleep before
      # the last ticker even started. With T_FUTURE, all 11 children
      # start within the same workflow task and the parent only
      # returns when every child has finished. The parent still
      # blocks (execute_child_workflow returns the result), so the
      # cron-driven scheduler fires a new cycle after this one
      # completes — but each cycle now runs N children in parallel
      # instead of staggering them.
      futures = due.each_with_object({}) do |watch, acc|
        ticker = watch['ticker']
        acc[ticker] = T_FUTURE.new { launch_one(watch) }
      end

      activity.logger.info "[scheduler] launched #{futures.size} children in parallel"
      T_FUTURE.all_of(*futures.values).wait
      activity.logger.info "[scheduler] all #{futures.size} children complete"
    end

    def launch_one(watch)
      # UUID suffix keeps the ID unique across cycles AND across same-
      # cycle children. `T_WORKFLOW.random.uuid` is deterministic
      # across replays; see the file-level comment in the imports
      # for why `SecureRandom` would be a determinism bug here.
      workflow_id = "process-#{watch['ticker']}-#{T_WORKFLOW.random.uuid}"
      # Temporalio::SearchAttributes.new wraps the {Key => value} hash
      # so the SDK can call `_to_proto` on it. A bare Hash triggers
      # `undefined method '_to_proto' for an instance of Hash` at
      # start_child_workflow time.
      attrs = Temporalio::SearchAttributes.new(
        TickerKey       => watch['ticker'],
        WorkflowKindKey => 'process_ticker'
      )
      # execute_child_workflow = start_child_workflow + .result. The
      # parent SchedulerWorkflow waits for each child to finish
      # before exiting. Children are parented (default
      # parent_close_policy: TERMINATE) so they get cleaned up
      # automatically if the parent itself gets cancelled.
      T_WORKFLOW.execute_child_workflow(
        'ProcessTickerWorkflow',
        watch,
        id: workflow_id,
        task_queue: TEMPORAL_TASK_QUEUE,
        search_attributes: attrs,
        retry_policy: T_RETRY_POLICY
      )
      activity.logger.info "[scheduler] launched #{workflow_id} for #{watch['ticker']}"
    rescue Temporalio::Error::WorkflowAlreadyStartedError
      # The same ticker was already running in a previous cycle that
      # hasn't finished — skip rather than fail. ListRunningTickerWorkflowsActivity
      # catches most of these up front, but there's a race window
      # between the list call and the child launch.
      activity.logger.info "[scheduler] already running: #{watch['ticker']} (skipped)"
    end
  end
end
