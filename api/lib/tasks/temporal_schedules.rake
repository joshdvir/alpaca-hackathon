# frozen_string_literal: true

# Rake tasks for managing Temporal schedules from the command line.
# Usage:
#   bin/rails temporal:schedules:sync          # create/update all schedules from trading.yml
#   bin/rails temporal:schedules:list          # list all schedules in Temporal
#   bin/rails temporal:schedules:describe[ID]  # describe a single schedule
#   bin/rails temporal:schedules:trigger[ID]   # fire a schedule immediately
#   bin/rails temporal:schedules:delete[ID]    # delete a schedule
#   bin/rails temporal:schedules:pause[ID]     # pause a schedule
#   bin/rails temporal:schedules:unpause[ID]   # unpause a schedule

namespace :temporal do
  # rubocop:disable-next Metrics/BlockLength
  namespace :schedules do
    desc 'Sync trading.yml temporal_schedules to Temporal (create + update, idempotent)'
    task sync: :environment do
      Rails.application.eager_load!
      results = Temporal::ScheduleManager.new.ensure_schedules!
      puts 'Sync complete:'
      results.each { |id, status| puts "  #{id.ljust(40)} #{status}" }
    end

    desc 'List all Temporal schedules'
    task list: :environment do
      Rails.application.eager_load!
      Temporal::ScheduleManager.new.list.each do |s|
        info = s.info
        next_at = info.next_action_times.first&.iso8601 || '(paused or done)'
        puts "  #{s.id.ljust(40)} workflow=#{s.schedule.action.workflow.ljust(40)} next=#{next_at}"
      end
    end

    desc 'Describe a Temporal schedule (use rake temporal:schedules:describe[ID])'
    task :describe, [:id] => :environment do |_t, args|
      Rails.application.eager_load!
      require 'temporalio/client'
      desc = T_CLIENT.schedule_handle(args[:id]).describe
      info = desc.info
      puts "ID:        #{desc.id}"
      puts "Workflow:  #{desc.schedule.action.workflow}"
      puts "Task Q:    #{desc.schedule.action.task_queue}"
      puts "Calendars: #{desc.schedule.spec.calendars.map(&:comment).join(', ')}"
      puts "Created:   #{info.created_at.iso8601}"
      puts "Next run:  #{info.next_action_times.first&.iso8601 || '(none)'}"
      puts "Runs:      #{info.num_actions}"
    end

    desc 'Trigger a Temporal schedule immediately (use rake temporal:schedules:trigger[ID])'
    task :trigger, [:id] => :environment do |_t, args|
      Rails.application.eager_load!
      Temporal::ScheduleManager.new.trigger(args[:id])
      puts "Triggered #{args[:id]}"
    end

    desc 'Delete a Temporal schedule (use rake temporal:schedules:delete[ID])'
    task :delete, [:id] => :environment do |_t, args|
      Rails.application.eager_load!
      Temporal::ScheduleManager.new.delete(args[:id])
      puts "Deleted #{args[:id]}"
    end

    desc 'Pause a Temporal schedule (use rake temporal:schedules:pause[ID])'
    task :pause, [:id] => :environment do |_t, args|
      Rails.application.eager_load!
      Temporal::ScheduleManager.new.pause(args[:id])
      puts "Paused #{args[:id]}"
    end

    desc 'Unpause a Temporal schedule (use rake temporal:schedules:unpause[ID])'
    task :unpause, [:id] => :environment do |_t, args|
      Rails.application.eager_load!
      Temporal::ScheduleManager.new.unpause(args[:id])
      puts "Unpaused #{args[:id]}"
    end
  end

  namespace :search_attributes do
    desc 'Ensure all required custom search attributes are registered on the Temporal namespace (idempotent)'
    task ensure: :environment do
      Rails.application.eager_load!
      added = Temporal::SearchAttributeRegistrar.new.ensure!
      if added.empty?
        puts 'All required custom search attributes already registered.'
      else
        puts "Added: #{added.sort.join(', ')}"
      end
    end

    desc 'List custom search attributes currently registered on the Temporal namespace'
    task list: :environment do
      Rails.application.eager_load!
      names = Temporal::SearchAttributeRegistrar.new.list_custom_attribute_names.to_a.sort
      if names.empty?
        puts '(no custom search attributes registered)'
      else
        names.each { |n| puts "  #{n}" }
      end
    end
  end
end
