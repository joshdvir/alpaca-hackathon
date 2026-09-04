require "json"

# Live smoke test: run the ListRunningTickerWorkflowsActivity against
# the live Temporal server. Verifies the new (no limit:) invocation
# works end-to-end.

# Stub the activity's ApplicationActivity init (T_ACTIVITY_CTX.current
# isn't available in this context).
FakeInfo = Struct.new(:activity_id, :workflow_id)
class FakeContext
  def logger
    @logger ||= Logger.new($stdout).tap { |l| l.level = Logger::INFO }
  end
  def heartbeat(*); end
  def info; @info ||= FakeInfo.new("smoke", "smoke"); end
end
T_ACTIVITY_CTX.define_singleton_method(:current) { FakeContext.new }

activity = Trading::ListRunningTickerWorkflowsActivity.new

t0 = Time.now
results = activity.execute
elapsed = Time.now - t0

puts "[smoke] ListRunningTickerWorkflowsActivity.execute:"
puts "  returned #{results.size} rows in #{elapsed.round(2)}s"
puts "  first 3: #{results.first(3).inspect[0..400]}"
puts "  schema: workflow_id=#{results.first&.dig(:workflow_id).inspect}, run_id=#{results.first&.dig(:run_id).class}, ticker=#{results.first&.dig(:ticker).inspect}"
puts "  PASS (no ArgumentError, no limit: kwarg issue)"
