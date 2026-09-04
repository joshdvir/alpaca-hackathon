# frozen_string_literal: true

# AlpacaMirrorWorkflow — single-pass reconciliation. Triggered by the
# `alpaca-mirror` Temporal schedule (cron */30s in UTC) which is
# managed by Temporal::ScheduleManager (see config/initializers
# /temporal_schedules.rb).
#
# The workflow exists only to wrap one activity invocation. Temporal
# schedules can only fire workflow types (not activities directly in
# the Ruby SDK), so the workflow is a one-liner that calls
# SyncAlpacaActivity. The actual MCP/Rails work lives in the
# activity so it can heartbeat cleanly and use the rate limiter +
# circuit breaker.
#
# Why Temporal instead of Solid Queue:
#   - The AlpacaMirrorJob + recurring.yml pattern referenced a
#     solid_queue system that was never installed. The gem wasn't in
#     the Gemfile, the tables never existed, and the job had no
#     scheduler. Without it, the DB never received fill updates
#     from the broker.
#   - Temporal is already wired (T_CLIENT, T_WORKER, ScheduleManager).
#     Adding another schedule to trading.yml is a 6-line config
#     change, not a new gem + migrations + new process.
#   - Workflows are visible in the Temporal UI — the schedule's
#     last-successful-run time, recent failures, and overlap policy
#     are all inspectable from one place.
module AlpacaMirror
  class AlpacaMirrorWorkflow < ApplicationWorkflow
    def execute
      activity.logger.info '[alpaca_mirror] tick'
      T_WORKFLOW.execute_activity(
        SyncAlpacaActivity,
        start_to_close_timeout: 60,
        retry_policy: T_RETRY_POLICY
      )
    end
  end
end
