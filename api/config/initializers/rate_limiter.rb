# frozen_string_literal: true

# Per-source token bucket rate limiter.
# Used to wrap all external HTTP calls (Alpaca MCP, FRED, EDGAR, LLM).
# Configured via trading.yml -> rate_limits.
#
# Design:
#   - One RateLimiter per source, created on demand
#   - acquire(timeout:) blocks until a token is available
#   - with_limit { ... } wraps the actual call
#
# Failures bubble up to CircuitBreaker; this layer only handles throughput.

class RateLimiter
  def initialize(source:, limit:, window:)
    @source = source
    @limit = limit.to_f
    @window = window.to_f
    @tokens = @limit
    @last_refill = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @mutex = Mutex.new
  end

  # Returns true if a token was acquired within `timeout` seconds.
  # Returns false if we couldn't get one (caller decides to skip or raise).
  def acquire(timeout: 5.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      @mutex.synchronize do
        refill!
        if @tokens >= 1.0
          @tokens -= 1.0
          return true
        end
      end
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def with_limit(timeout: 5.0)
    raise RateLimitedError.new(@source, "no tokens within #{timeout}s") unless acquire(timeout: timeout)

    yield
  end

  private

  def refill!
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = now - @last_refill
    return if elapsed <= 0

    add = elapsed * (@limit / @window)
    @tokens = [@tokens + add, @limit].min
    @last_refill = now if add.positive?
  end
end

class RateLimitedError < StandardError
  attr_reader :source

  def initialize(source, msg)
    @source = source
    super(msg)
  end
end

# Build a limiter for each configured source at boot
RATE_LIMITERS = {}
# Accept either:
#   rate_limiters:
#     fred:
#       rate_per_minute: 5        # new style
#     ...
#   rate_limits:                   # legacy alias
#     fred:
#       limit: 5
#       window: 60                 # legacy: per-N-seconds
# If `rate_per_minute` is present we synthesize a 60s window; otherwise
# we read limit/window directly.
(TradingConfig.fetch(:rate_limiters) || TradingConfig.fetch(:rate_limits) || {}).each do |source, cfg|
  cfg = cfg || {}
  if cfg[:rate_per_minute]
    limit = cfg[:rate_per_minute].to_f
    window = 60.0
  else
    limit = cfg[:limit]
    window = cfg[:window]
  end
  RATE_LIMITERS[source.to_sym] = RateLimiter.new(
    source: source,
    limit: limit,
    window: window
  )
end
