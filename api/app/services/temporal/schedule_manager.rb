# frozen_string_literal: true

# Temporal::ScheduleManager — creates / updates Temporal Schedules on app
# boot, idempotently. Workflows are then triggered by Temporal itself
# (via cron) — workers don't need to be running for schedules to fire.
#
# Why a service object rather than just an initializer: we want this to
# be runnable from a rake task too (`bin/rails temporal:schedules:sync`)
# for ops who want to verify schedules without bouncing the api.
#
# The cron parsing supports a subset of standard 5-field cron syntax
# (minute, hour, day-of-month, month, day-of-week). For more complex
# schedules (e.g. second precision, multiple timezones, overlap policy)
# use Temporal::Client::Schedule directly.

module Temporal
  class ScheduleManager
    def initialize(client: T_CLIENT, config: TradingConfig.fetch(:temporal_schedules) || [])
      @client = client
      @config = Array(config)
    end

    # Ensure every schedule in trading.yml exists in Temporal. Existing
    # schedules with matching config are left alone; schedules with
    # different config are updated. Schedules no longer in the config
    # are NOT deleted (so a stale api deployment doesn't wipe schedules).
    #
    # Returns a hash { id => status } where status is one of:
    #   :created, :unchanged, :updated, :skipped_disabled
    def ensure_schedules!
      results = {}
      @config.each do |raw_spec|
        # trading.yml parses top-level keys as symbols; the rest of the
        # service expects string keys. Normalize here so callers can
        # pass either shape.
        spec = raw_spec.is_a?(Hash) ? raw_spec.with_indifferent_access : raw_spec
        results[spec['id']] = ensure_one(spec)
      end
      Rails.logger.info "[schedules] sync complete: #{results.inspect}"
      results
    end

    def list
      @client.list_schedules
    end

    # Delete a schedule by id. Used by the rake task `temporal:schedules:delete[name]`.
    def delete(id)
      @client.schedule_handle(id).delete
    end

    # Trigger an immediate run. Useful for manual testing.
    def trigger(id)
      @client.schedule_handle(id).trigger
    end

    def pause(id, note: 'Paused via ScheduleManager')
      @client.schedule_handle(id).pause(note: note)
    end

    def unpause(id, note: 'Unpaused via ScheduleManager')
      @client.schedule_handle(id).unpause(note: note)
    end

    private

    def ensure_one(spec)
      id = spec.fetch('id')
      unless spec['enabled']
        Rails.logger.info "[schedules] skipping #{id} (disabled in config)"
        return :skipped_disabled
      end

      desired = build_schedule(spec)

      begin
        @client.create_schedule(id, desired)
        Rails.logger.info "[schedules] created #{id}"
        :created
      rescue Temporalio::Error::ScheduleAlreadyRunningError
        # In this temporalio version, `create_schedule` raises
        # ScheduleAlreadyRunningError (with an RPCError cause carrying
        # code ALREADY_EXISTS) when the schedule id is already
        # registered. Anything else is a real failure.
        reconcile_existing_schedule(id, desired)
        :unchanged
      rescue Temporalio::Error::RPCError => e
        # Some failures come through as a raw RPCError without the
        # higher-level wrapper. Treat ALREADY_EXISTS as "already
        # registered" and reconcile; everything else is a real error.
        if e.code != Temporalio::Error::RPCError::Code::ALREADY_EXISTS
          Rails.logger.warn "[schedules] failed to ensure #{id}: #{e.class}: #{e.message}"
          return :error
        end

        reconcile_existing_schedule(id, desired)
        :unchanged
      end
    end

    # Called from the `create_schedule` rescue branches above. Pulls
    # the existing schedule, compares it to the desired spec, and
    # updates it only if something meaningful changed.
    def reconcile_existing_schedule(id, desired)
      @client.schedule_handle(id).update do |input|
        next nil if schedules_match?(input.description.schedule, desired)

        Temporalio::Client::Schedule::Update.new(schedule: desired)
      end
      Rails.logger.info "[schedules] #{id} already exists (updated if changed)"
    end

    def build_schedule(spec)
      # Temporalio's StartWorkflow#new signature is:
      #   StartWorkflow.new(workflow, *args, id:, task_queue:, retry_policy:, ...)
      # `args` is a positional splat, NOT a keyword.
      action = Temporalio::Client::Schedule::Action::StartWorkflow.new(
        spec.fetch('workflow'),
        *Array(spec['args']),
        id: workflow_id(spec),
        task_queue: spec.fetch('task_queue'),
        retry_policy: T_RETRY_POLICY
      )

      calendar = parse_cron(spec.fetch('cron'), timezone: spec['timezone'])

      # IMPORTANT: The Calendar's time fields (second/minute/hour/etc)
      # are interpreted in the spec's `time_zone_name` by Temporal,
      # not in UTC. Without this, a cron like `*/1 8-16 * * 1-5` is
      # evaluated in UTC and fires at 8-16 UTC = 4 AM - 12:59 PM ET,
      # not 8 AM - 4:59 PM ET. Setting `time_zone_name: "America/New_York"`
      # is what actually anchors the cron to a timezone.
      Temporalio::Client::Schedule.new(
        action: action,
        spec: Temporalio::Client::Schedule::Spec.new(
          calendars: [calendar],
          time_zone_name: spec['timezone'].to_s.presence || 'UTC'
        )
      )
    end

    # Per-schedule workflow id. Most schedules want a stable id so the
    # same logical run can be tracked; if the config doesn't specify
    # one, we fall back to "schedule-<schedule-id>".
    def workflow_id(spec)
      spec['workflow_id'].to_s.presence || "schedule-#{spec['id']}"
    end

    # Parse a 5-field cron expression into a Temporal Calendar.
    # Fields: minute, hour, day_of_month, month, day_of_week.
    # Supports: `*`, `*\/N`, `N`, `N-M`, `N,M`, `N-M/S`.
    # The cron is interpreted in the supplied timezone (UTC default).
    def parse_cron(cron, timezone: 'UTC')
      _minute, _hour, _dom, _month, _dow = cron.strip.split(/\s+/)
      Temporalio::Client::Schedule::Spec::Calendar.new(
        second: [Temporalio::Client::Schedule::Range.new(0)],
        minute: parse_cron_field(_minute, 0, 59),
        hour: parse_cron_field(_hour, 0, 23),
        day_of_month: parse_cron_field(_dom, 1, 31),
        month: parse_cron_field(_month, 1, 12),
        day_of_week: parse_cron_field(_dow, 0, 6),
        # The timezone is anchored by Spec.time_zone_name, NOT the
        # comment. The comment is for human readers in the UI; the
        # timezone column there reads from Spec.time_zone_name.
        comment: "cron: #{cron}"
      )
    end

    # Parse a single cron field into one or more Range objects.
    # `*` -> [Range.new(min,max)]
    # `*/N` -> step from min..max by N
    # `N` -> [Range.new(N,N)]
    # `N-M` -> [Range.new(N,M)]
    # `N-M/S` -> [Range.new(N,M).step(S)] (approximated as multiple Ranges)
    # `A,B,C` -> recursively parse each
    def parse_cron_field(field, min, max)
      field.split(',').flat_map { |f| parse_cron_token(f.strip, min, max) }
    end

    def parse_cron_token(token, min, max)
      case token
      when '*'
        [Temporalio::Client::Schedule::Range.new(min, max)]
      when %r{\*/(\d+)}
        step = ::Regexp.last_match(1).to_i
        # Temporal Range uses step, but step=1 is the default; for N>1
        # we expand into multiple ranges. This is a hack but Temporal's
        # Range doesn't support a step argument directly.
        expand_step(min, max, step)
      when %r{(\d+)-(\d+)(?:/(\d+))?}
        a = ::Regexp.last_match(1).to_i
        b = ::Regexp.last_match(2).to_i
        s = ::Regexp.last_match(3)&.to_i
        s ? expand_step(a, b, s) : [Temporalio::Client::Schedule::Range.new(a, b)]
      when /\A\d+\z/
        n = token.to_i
        [Temporalio::Client::Schedule::Range.new(n, n)]
      else
        Rails.logger.warn "[schedules] unparseable cron token: #{token.inspect} — using full range"
        [Temporalio::Client::Schedule::Range.new(min, max)]
      end
    end

    # Expand `*/N` (or `min-max/N`) into a list of single-point ranges.
    # Earlier we emitted `Range(n, n+step-1)` which — when OR'd across
    # all steps — ended up covering the whole [min..max] window
    # (e.g. for `*/5` we got [0-4], [5-9], …, [55-59], which OR together
    # is 0-59 → every minute). Temporal's Calendar spec ORs the
    # ranges in a field, so each range must be a single discrete
    # value to actually pick every Nth minute.
    def expand_step(min, max, step)
      (min..max).step(step).map do |n|
        Temporalio::Client::Schedule::Range.new(n, n)
      end
    end

    # Two schedules are "the same" if their action.workflow + spec
    # are equivalent. We compare the cron comment string (which
    # embeds the cron expression + timezone label) and the spec's
    # time_zone_name separately, so a change to EITHER triggers a
    # reconciliation update.
    def schedules_match?(existing, desired)
      existing_cron = existing.spec.calendars.first&.comment
      desired_cron = desired.spec.calendars.first&.comment
      existing.action.workflow == desired.action.workflow &&
        existing.action.task_queue == desired.action.task_queue &&
        existing_cron == desired_cron &&
        existing.spec.time_zone_name == desired.spec.time_zone_name
    end
  end
end
