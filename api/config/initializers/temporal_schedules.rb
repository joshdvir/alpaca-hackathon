# frozen_string_literal: true

# On Rails boot, connect to Temporal and ensure all schedules declared in
# trading.yml -> temporal_schedules exist. This is idempotent — re-running
# it on every app start is the whole point: if a worker was down for a
# day, the schedules are still in Temporal and continue firing.
#
# Set ENV["DISABLE_TEMPORAL_SCHEDULES"]=1 (or the umbrella
# ENV["DISABLE_TEMPORAL_BOOT"]=1) to skip — useful in CI / tests where
# there is no live Temporal server.

unless ENV['DISABLE_TEMPORAL_BOOT'] == '1' || ENV['DISABLE_TEMPORAL_SCHEDULES'] == '1'
  Rails.application.config.after_initialize do
    next if Rails.env.test? # tests set up their own Temporal stubs
    next unless defined?(T_CLIENT) && T_CLIENT

    Rails.application.executor.wrap do
      Temporal::ScheduleManager.new.ensure_schedules!
    rescue StandardError => e
      # We don't want a flaky Temporal connection to crash the app on
      # boot. Log and continue — the api can still serve HTTP and the
      # `bin/rails temporal:schedules:sync` rake task can re-run.
      Rails.logger.warn "[temporal] schedule sync failed: #{e.class}: #{e.message}"
    end
  end
end
