# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Temporal::ScheduleManager do
  # Stand-in for the Temporal client. Verifies the right calls happen
  # without needing a real Temporal server.
  let(:fake_client) { instance_double(Temporalio::Client) }
  let(:fake_handle) { instance_double(Temporalio::Client::ScheduleHandle) }
  let(:spec) do
    {
      'id' => 'ticker-selector-daily',
      'workflow' => 'TickerSelector::TickerSelectorWorkflow',
      'task_queue' => 'trading-queue',
      'cron' => '0 8 * * *',
      'timezone' => 'America/New_York',
      'enabled' => true,
      'note' => 'Daily ticker selection + watchlist refresh'
    }
  end
  let(:manager) { described_class.new(client: fake_client, config: [spec]) }

  # In this version of temporalio, "schedule already exists" is signalled
  # by an RPCError with code ALREADY_EXISTS (= 6), not by a dedicated
  # ScheduleAlreadyExistsError class.
  def already_exists_error
    Temporalio::Error::RPCError.new(
      'schedule already exists',
      code: Temporalio::Error::RPCError::Code::ALREADY_EXISTS,
      raw_grpc_status: nil
    )
  end

  # rubocop:disable-next Metrics/BlockLength
  describe '#ensure_schedules!' do
    it 'creates a new schedule when none exists' do
      expect(fake_client).to receive(:create_schedule)
        .with('ticker-selector-daily', an_instance_of(Temporalio::Client::Schedule))
      result = manager.ensure_schedules!
      expect(result).to eq('ticker-selector-daily' => :created)
    end

    it 'is a no-op when the schedule already exists and matches' do
      existing_desc = build_existing_desc(spec, action_workflow: spec['workflow'])
      allow(fake_client).to receive(:create_schedule)
        .and_raise(already_exists_error)
      allow(fake_client).to receive(:schedule_handle)
        .with('ticker-selector-daily').and_return(fake_handle)
      captured = :not_called
      allow(fake_handle).to receive(:update) do |&block|
        # Block receives Update::Input; we just invoke the block and
        # capture its return value (nil means "no update needed").
        input = Temporalio::Client::Schedule::Update::Input.new(description: existing_desc)
        captured = block.call(input)
      end

      result = manager.ensure_schedules!
      expect(result).to eq('ticker-selector-daily' => :unchanged)
      # When schedules match, ensure_one's block should return nil.
      expect(captured).to be_nil
    end

    it 'is a no-op when the schedule raises ScheduleAlreadyRunningError' do
      # In this temporalio version, the higher-level wrapper is what
      # actually surfaces in production when a schedule id is already
      # registered.
      existing_desc = build_existing_desc(spec, action_workflow: spec['workflow'])
      allow(fake_client).to receive(:create_schedule)
        .and_raise(Temporalio::Error::ScheduleAlreadyRunningError.new)
      allow(fake_client).to receive(:schedule_handle)
        .with('ticker-selector-daily').and_return(fake_handle)
      captured = :not_called
      allow(fake_handle).to receive(:update) do |&block|
        input = Temporalio::Client::Schedule::Update::Input.new(description: existing_desc)
        captured = block.call(input)
      end

      result = manager.ensure_schedules!
      expect(result).to eq('ticker-selector-daily' => :unchanged)
      expect(captured).to be_nil
    end

    it 'updates the schedule when the cron has changed' do
      existing_desc = build_existing_desc(
        spec,
        action_workflow: spec['workflow'],
        cron_string: '0 9 * * *' # different cron
      )
      allow(fake_client).to receive(:create_schedule)
        .and_raise(already_exists_error)
      allow(fake_client).to receive(:schedule_handle)
        .with('ticker-selector-daily').and_return(fake_handle)
      updated = nil
      allow(fake_handle).to receive(:update) do |&block|
        input = Temporalio::Client::Schedule::Update::Input.new(description: existing_desc)
        updated = block.call(input)
      end

      result = manager.ensure_schedules!
      expect(result).to eq('ticker-selector-daily' => :unchanged) # always :unchanged after ALREADY_EXISTS
      expect(updated).to be_a(Temporalio::Client::Schedule::Update)
    end

    it 'skips disabled schedules' do
      spec['enabled'] = false
      expect(fake_client).not_to receive(:create_schedule)
      result = manager.ensure_schedules!
      expect(result).to eq('ticker-selector-daily' => :skipped_disabled)
    end

    it 'logs and continues when Temporal raises an RPC error other than ALREADY_EXISTS' do
      unavailable = Temporalio::Error::RPCError.new(
        'server down',
        code: Temporalio::Error::RPCError::Code::UNAVAILABLE,
        raw_grpc_status: nil
      )
      allow(fake_client).to receive(:create_schedule).and_raise(unavailable)
      result = manager.ensure_schedules!
      expect(result).to eq('ticker-selector-daily' => :error)
    end

    it 'handles multiple schedules in one call' do
      second_spec = spec.merge(
        'id' => 'trading-scheduler',
        'cron' => '*/5 * * * *',
        'workflow' => 'Trading::SchedulerWorkflow'
      )
      manager = described_class.new(client: fake_client, config: [spec, second_spec])
      expect(fake_client).to receive(:create_schedule).with('ticker-selector-daily', anything)
      expect(fake_client).to receive(:create_schedule).with('trading-scheduler', anything)
      result = manager.ensure_schedules!
      expect(result.keys).to match_array(%w[ticker-selector-daily trading-scheduler])
    end
  end

  describe '#list / #trigger / #pause / #unpause / #delete' do
    it 'delegates #list to the client' do
      expect(fake_client).to receive(:list_schedules).and_return([])
      manager.list
    end

    it 'delegates #trigger to the handle' do
      allow(fake_client).to receive(:schedule_handle).with('x').and_return(fake_handle)
      expect(fake_handle).to receive(:trigger)
      manager.trigger('x')
    end

    it 'delegates #pause with a note' do
      allow(fake_client).to receive(:schedule_handle).with('x').and_return(fake_handle)
      expect(fake_handle).to receive(:pause).with(note: 'Paused via ScheduleManager')
      manager.pause('x')
    end

    it 'delegates #unpause with a note' do
      allow(fake_client).to receive(:schedule_handle).with('x').and_return(fake_handle)
      expect(fake_handle).to receive(:unpause).with(note: 'Unpaused via ScheduleManager')
      manager.unpause('x')
    end

    it 'delegates #delete to the handle' do
      allow(fake_client).to receive(:schedule_handle).with('x').and_return(fake_handle)
      expect(fake_handle).to receive(:delete)
      manager.delete('x')
    end
  end

  describe '#parse_cron' do
    let(:mgr) { described_class.new(client: fake_client, config: []) }

    it 'parses `*` into a full range' do
      cal = mgr.send(:parse_cron, '* * * * *')
      expect(cal.minute.first).to eq(Temporalio::Client::Schedule::Range.new(0, 59))
      expect(cal.hour.first).to eq(Temporalio::Client::Schedule::Range.new(0, 23))
    end

    it 'parses `0 8 * * *` (8am daily)' do
      cal = mgr.send(:parse_cron, '0 8 * * *')
      expect(cal.minute.first).to eq(Temporalio::Client::Schedule::Range.new(0, 0))
      expect(cal.hour.first).to eq(Temporalio::Client::Schedule::Range.new(8, 8))
    end

    it 'parses `*/5 * * * *` (every 5 min) into stepped ranges' do
      cal = mgr.send(:parse_cron, '*/5 * * * *')
      # Temporal's Calendar spec ORs the ranges in a field, so a stepped
      # cron like `*/5` must emit single-point ranges [0,0], [5,5], ...
      # (NOT [0,4], [5,9], ... which would OR together to [0..59] =
      # every minute, not every 5th minute).
      expect(cal.minute.length).to eq(12)
      expect(cal.minute.first).to eq(Temporalio::Client::Schedule::Range.new(0, 0))
      expect(cal.minute.last).to eq(Temporalio::Client::Schedule::Range.new(55, 55))
      # The OR'd set should be {0, 5, 10, 15, ..., 55} — every 5th minute.
      starts = cal.minute.map(&:start).sort
      expect(starts).to eq([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55])
    end

    it 'parses comma-separated lists' do
      cal = mgr.send(:parse_cron, '0,15,30,45 * * * *')
      expect(cal.minute.length).to eq(4)
      expect(cal.minute.first.start).to eq(0)
      expect(cal.minute[1].start).to eq(15)
      expect(cal.minute[2].start).to eq(30)
      expect(cal.minute.last.start).to eq(45)
    end

    it 'parses range with step' do
      # `0-30/10` -> 0..9, 10..19, 20..29, 30..30 (capped at 30)
      cal = mgr.send(:parse_cron, '0-30/10 * * * *')
      expect(cal.minute.length).to eq(4)
      expect(cal.minute.map(&:start)).to eq([0, 10, 20, 30])
    end
  end

  # Helper to build a fake existing description. We can't go through
  # `Temporalio::Client::Schedule::Description.new` because its real
  # constructor requires `id:, raw_description:, data_converter:` —
  # but the production code only reads `description.schedule.*` and
  # `description.id`/`info`/`raw_description` for the OpenStruct
  # case. Using a Struct keeps the test self-contained.
  def build_existing_desc(spec, action_workflow:, cron_string: nil)
    cron = cron_string || spec['cron']
    action = Temporalio::Client::Schedule::Action::StartWorkflow.new(
      action_workflow,
      id: 'wf-1',
      task_queue: spec['task_queue']
    )
    calendar = Temporalio::Client::Schedule::Spec::Calendar.new(
      second: [Temporalio::Client::Schedule::Range.new(0)],
      minute: [Temporalio::Client::Schedule::Range.new(0)],
      hour: [Temporalio::Client::Schedule::Range.new(8)],
      day_of_month: [Temporalio::Client::Schedule::Range.new(1, 31)],
      month: [Temporalio::Client::Schedule::Range.new(1, 12)],
      day_of_week: [Temporalio::Client::Schedule::Range.new(0, 6)],
      # Match the production `build_schedule`/`parse_cron` format
      # (just `"cron: <expr>"`). The timezone is anchored by
      # `Spec.time_zone_name`, NOT the comment. Without setting both
      # the comment and time_zone_name to match, `schedules_match?`
      # in production will always return `Update` because the
      # existing schedule's `time_zone_name` is `nil` (defaults to
      # UTC) while the desired one carries the configured timezone.
      comment: "cron: #{cron}"
    )
    schedule = Temporalio::Client::Schedule.new(
      action: action,
      spec: Temporalio::Client::Schedule::Spec.new(
        calendars: [calendar],
        time_zone_name: spec['timezone'].to_s.presence || 'UTC'
      )
    )
    FakeDescription.new(
      id: spec['id'],
      schedule: schedule,
      info: nil,
      raw_description: nil
    )
  end
end

# Stand-in for Temporalio::Client::Schedule::Description (whose real
# constructor requires raw proto fields we don't want to fabricate).
# Production code only reads .schedule / .id / .info / .raw_description.
FakeDescription = Struct.new(:id, :schedule, :info, :raw_description, keyword_init: true)
