# frozen_string_literal: true

require "rails_helper"

# Unit test for MonitorPositionWorkflow. Verifies the one-shot shape:
# the workflow calls RunPositionMonitorActivity EXACTLY ONCE and
# returns the activity result, instead of looping with a sleep. The
# scheduler (AlpacaMirrorWorkflow's self-heal) is responsible for
# re-starting a fresh execution each minute, so the workflow itself
# must not loop.
RSpec.describe Positions::MonitorPositionWorkflow do
  before do
    # `activity.logger.info` at the top of `execute` resolves
    # `T_WORKFLOW.logger`, which only exists inside a real workflow
    # environment. Stub it with a no-op logger so the test can run
    # outside one.
    allow(T_WORKFLOW).to receive(:logger).and_return(Logger.new(File::NULL))
  end

  describe "#execute" do
    it "calls RunPositionMonitorActivity exactly once and returns the result" do
      # Stub the Temporal execute_activity call so we can verify the
      # workflow doesn't loop or sleep.
      expected_result = { position_id: 42, status: "open", auto_close_proposal_id: nil, monitored_at: Time.current }
      workflow = described_class.new
      activity_calls = 0

      # The workflow class uses `T_WORKFLOW.execute_activity(...)` via
      # the Temporal SDK. Stub the SDK method on T_WORKFLOW for the
      # duration of the test.
      allow(T_WORKFLOW).to receive(:execute_activity) do |_klass, _arg, **_opts|
        activity_calls += 1
        expected_result
      end

      result = workflow.execute(42)

      expect(activity_calls).to eq(1)
      expect(result).to eq(expected_result)
    end

    it "does not call T_WORKFLOW.sleep (no internal loop)" do
      workflow = described_class.new
      allow(T_WORKFLOW).to receive(:execute_activity).and_return({})
      expect(T_WORKFLOW).not_to receive(:sleep)

      workflow.execute(42)
    end

    it "returns the activity result directly (no wrapping)" do
      expected = { position_id: 99, status: "closed", auto_close_proposal_id: 7, monitored_at: Time.current }
      workflow = described_class.new
      allow(T_WORKFLOW).to receive(:execute_activity).and_return(expected)

      expect(workflow.execute(99)).to eq(expected)
    end
  end
end
