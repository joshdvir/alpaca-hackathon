# frozen_string_literal: true

require "rails_helper"

# Unit test for the ApplicationWorkflow helpers. Doesn't require a
# live Temporal server — just exercises the `activity` shim that
# workflow code uses for `activity.logger.info`.
#
# Note: the shim's `#logger` returns `T_WORKFLOW.logger`, which is
# only resolvable inside a real workflow environment. So we test the
# shim's *shape* (responds to :logger, memoized) here, and rely on
# end-to-end worker runs to verify the logger path actually returns
# a usable Logger.
RSpec.describe ApplicationWorkflow do
  # A minimal concrete subclass for testing.
  let(:test_class) do
    Class.new(ApplicationWorkflow) do
      def execute
        # No-op; just here so we can instantiate.
      end
    end
  end

  describe "#activity" do
    it "returns a shim object with a #logger method" do
      instance = test_class.new
      expect(instance.activity).to respond_to(:logger)
    end

    it "memoizes the shim per instance" do
      instance = test_class.new
      expect(instance.activity).to be(instance.activity)
    end

    it "exposes the workflow-scoped logger" do
      # Stub T_WORKFLOW.logger so the test doesn't need a workflow
      # environment. The real logger (from `Temporalio::Workflow.logger`)
      # is documented to auto-append workflow context and skip replays.
      fake_logger = Logger.new(File::NULL)
      allow(T_WORKFLOW).to receive(:logger).and_return(fake_logger)
      instance = test_class.new
      expect(instance.activity.logger).to be(fake_logger)
    end
  end
end
