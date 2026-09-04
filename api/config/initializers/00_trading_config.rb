# frozen_string_literal: true

# Loads the algorithm config from YAML and keeps it in sync with the
# file on disk.
#
# Path is overridable via TRADING_CONFIG_PATH env var.
# Exposes TradingConfig.fetch(:risk_limits, :max_open_positions) for
# nested-key access, plus:
#   TradingConfig.to_h                — the full frozen hash (deep-symbolized)
#   TradingConfig.reload!             — re-read the file and re-broadcast
#   TradingConfig.path                 — the resolved file path
#   TradingConfig.last_loaded_at       — Time when the last successful load ran
#
# Hot reload: when the file changes on disk, ActiveSupport::FileUpdateChecker
# (built into Rails, no extra gem needed) detects the change within ~1s
# and calls reload!. After reloading, the new config is broadcast on
# the `live_updates:config` ActionCable stream so any connected
# front-end editor auto-refreshes without a manual reload.

config_path = ENV.fetch(
  'TRADING_CONFIG_PATH',
  Rails.root.join('config/trading.yml').to_s
)

unless File.exist?(config_path)
  raise "Trading config not found at #{config_path}. " \
        'Set TRADING_CONFIG_PATH or create config/trading.yml.'
end

raw_yaml = ERB.new(File.read(config_path)).result
TRADING_CONFIG = YAML.safe_load(raw_yaml, aliases: true).deep_symbolize_keys.freeze

class TradingConfig
  @path = ENV.fetch(
    'TRADING_CONFIG_PATH',
    Rails.root.join('config/trading.yml').to_s
  )
  @mutex = Mutex.new
  @last_loaded_at = Time.current
  @listeners = []

  class << self
    # Nested-key fetch: TradingConfig.fetch(:risk_limits, :max_open_positions)
    def fetch(*path)
      path.reduce(TRADING_CONFIG) { |acc, key| acc.is_a?(Hash) ? acc&.dig(key) : nil }
    end

    # Whole config (read-only). Returns a frozen deep-symbolized hash.
    def to_h
      TRADING_CONFIG
    end

    # Resolved config file path.
    def path
      @path
    end

    # Time the most recent successful load happened. Useful for the
    # front-end to show "loaded at 03:14 UTC" without re-reading the
    # filesystem.
    def last_loaded_at
      @last_loaded_at
    end

    # Re-read the file from disk, parse + symbolize, replace the
    # constant, and broadcast. Safe to call from any thread/process
    # context; the mutex serializes reloads.
    #
    # Returns the new config hash on success, raises on parse error.
    def reload!
      @mutex.synchronize do
        raw = ERB.new(File.read(@path)).result
        parsed = YAML.safe_load(raw, aliases: true)
        raise "Trading config is not a Hash (got #{parsed.class})" unless parsed.is_a?(Hash)
        new_config = parsed.deep_symbolize_keys.freeze
        # Mutate the constant in place — code that does
        # `TRADING_CONFIG[:foo]` keeps working without re-requiring.
        Object.send(:remove_const, :TRADING_CONFIG) if Object.const_defined?(:TRADING_CONFIG)
        Object.const_set(:TRADING_CONFIG, new_config)
        @last_loaded_at = Time.current
        broadcast_reload!(new_config)
        new_config
      end
    end

    # Register a block to be called after every successful reload.
    # Used by the front-end's ConfigView to refresh its editor and by
    # the test suite to observe reload events.
    def on_reload(&block)
      @listeners << block
    end

    private

    def broadcast_reload!(config)
      # ActionCable broadcast — the front-end subscribes to
      # live_updates:config and re-fetches the YAML when this fires.
      ActionCable.server.broadcast(
        'live_updates:config',
        {
          event: 'reloaded',
          path: @path,
          loaded_at: @last_loaded_at.iso8601,
          config: config.deep_stringify_keys
        }
      )
    rescue StandardError => e
      # Don't let a broadcast failure prevent the in-memory reload.
      Rails.logger.warn "[trading_config] broadcast failed: #{e.class}: #{e.message}"
    ensure
      # Always notify in-process listeners (tests, side effects).
      @listeners.each do |fn|
        begin
          fn.call(config)
        rescue StandardError => e
          Rails.logger.warn "[trading_config] listener raised: #{e.class}: #{e.message}"
        end
      end
    end
  end
end

# File watcher — uses ActiveSupport::FileUpdateChecker which is
# built into Rails (no extra gem required). It polls the file mtime
# every second; if it changed since the last check, it calls reload!
# which re-parses, replaces TRADING_CONFIG, and broadcasts to
# ActionCable.
#
# The watcher is started in an after_initialize hook so it only runs
# inside the worker/web process, not during rake tasks or console
# (the latter can still call TradingConfig.reload! by hand).
Rails.application.config.after_initialize do
  # Only run in long-lived server processes, not in rake/console
  # where the watcher would block the foreground.
  next unless defined?(Rails::Server) || ENV['TRADING_CONFIG_WATCHER'] == '1'

  begin
    checker = ActiveSupport::FileUpdateChecker.new([TradingConfig.path]) do
      Rails.logger.info "[trading_config] file change detected, reloading"
      begin
        TradingConfig.reload!
      rescue StandardError => e
        Rails.logger.error "[trading_config] reload failed: #{e.class}: #{e.message}"
      end
    end
    # Run on a 1s interval; the watcher's own mtime check decides
    # whether to fire the block.
    Thread.new do
      loop do
        checker.execute_if_updated
        sleep 1
      rescue StandardError => e
        Rails.logger.error "[trading_config] watcher crashed: #{e.class}: #{e.message}"
        sleep 5 # back off before retrying
      end
    end
  rescue StandardError => e
    Rails.logger.warn "[trading_config] could not start file watcher: #{e.class}: #{e.message}"
  end
end
