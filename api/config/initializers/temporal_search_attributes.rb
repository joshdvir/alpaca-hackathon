# frozen_string_literal: true

# On Rails boot, register any missing custom search attributes with the
# Temporal namespace. This is the boot-time companion to the per-app
# `TickerKey` / `WorkflowKindKey` definitions in config/initializers/temporal.rb.
#
# Without registration, any visibility query that filters by these
# attributes (e.g. `WorkflowKind = 'process_ticker'` from
# Trading::ListRunningTickerWorkflowsActivity) fails with:
#   "invalid query: column name 'WorkflowKind' is not a valid search attribute"
#
# `add_search_attributes` is an additive idempotent operation in Temporal,
# so calling this on every app start is safe.
#
# Set ENV["DISABLE_TEMPORAL_SCHEDULES"]=1 (or the umbrella
# ENV["DISABLE_TEMPORAL_BOOT"]=1) to skip — useful in CI / tests where
# there is no live Temporal server.

unless ENV['DISABLE_TEMPORAL_BOOT'] == '1' || ENV['DISABLE_TEMPORAL_SCHEDULES'] == '1'
  Rails.application.config.after_initialize do
    next if Rails.env.test? # tests set up their own Temporal stubs
    next unless defined?(T_CLIENT) && T_CLIENT

    Rails.application.executor.wrap do
      Temporal::SearchAttributeRegistrar.new.ensure!
    rescue StandardError => e
      # We don't want a flaky Temporal connection to crash the app on
      # boot. Log and continue — the api can still serve HTTP and the
      # `bin/rails temporal:search_attributes:ensure` rake task can
      # re-run once Temporal is reachable.
      Rails.logger.warn "[temporal:search_attributes] ensure failed: #{e.class}: #{e.message}"
    end
  end
end
