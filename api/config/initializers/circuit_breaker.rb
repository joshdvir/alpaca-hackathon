# frozen_string_literal: true

# Per-source circuit breaker.
# States: :closed (normal) -> :half_open (probing) -> :open (fast-fail) -> :half_open after reset
#
# Wraps HTTP calls. On N consecutive failures, opens for `reset_timeout_seconds`.
# After multiple Open cycles, extends the reset timeout (back-off).

class CircuitBreaker
  STATES = %i[closed half_open open].freeze

  def initialize(source:, failure_threshold:, reset_timeout:, reset_backoff_after:, reset_backoff_to:)
    @source = source
    @failure_threshold = failure_threshold
    @reset_timeout = reset_timeout
    @reset_backoff_after = reset_backoff_after
    @reset_backoff_to = reset_backoff_to
    @state = :closed
    @failures = 0
    @cycle_count = 0
    @opened_at = nil
    @current_reset = reset_timeout
    @mutex = Mutex.new
  end

  def call
    @mutex.synchronize { maybe_half_open! }
    raise CircuitOpenError, @source if @state == :open

    begin
      result = yield
      record_success
      result
    rescue StandardError
      record_failure
      raise
    end
  end

  def state
    @mutex.synchronize { @state }
  end

  private

  def maybe_half_open!
    return unless @state == :open
    return unless @opened_at && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @opened_at) >= @current_reset

    @state = :half_open
  end

  def record_success
    @mutex.synchronize do
      @failures = 0
      @state = :closed
      @opened_at = nil
    end
  end

  def record_failure
    @mutex.synchronize do
      @failures += 1
      if @state == :half_open
        open_circuit!
      elsif @failures >= @failure_threshold
        open_circuit!
      end
    end
  end

  def open_circuit!
    @state = :open
    @opened_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @cycle_count += 1
    @current_reset = @reset_backoff_to if @cycle_count >= @reset_backoff_after
  end
end

class CircuitOpenError < StandardError
  attr_reader :source

  def initialize(source)
    @source = source
    super("circuit open for source=#{source}")
  end
end

# Build a circuit breaker for each external source at boot
CIRCUIT_BREAKERS = {}
%i[alpaca_mcp fred edgar llm tradingview_mcp optionsflow_mcp].each do |source|
  # circuit_breakers.<source> in trading.yml. The whole top-level
  # hash is fetched first, then indexed by the per-source symbol
  # so a missing entry surfaces as a clear KeyError rather than
  # silently falling back to a different source's settings.
  cb_cfg = TradingConfig.fetch(:circuit_breakers, source) ||
           TradingConfig.fetch(:circuit_breaker, source) ||
           { failure_threshold: 5, reset_timeout_seconds: 30,
             reset_backoff_after_cycles: 3, reset_backoff_to_seconds: 10 }
  CIRCUIT_BREAKERS[source] = CircuitBreaker.new(
    source: source,
    failure_threshold: cb_cfg[:failure_threshold],
    reset_timeout: cb_cfg[:reset_timeout_seconds],
    reset_backoff_after: cb_cfg[:reset_backoff_after_cycles],
    reset_backoff_to: cb_cfg[:reset_backoff_to_seconds]
  )
end
