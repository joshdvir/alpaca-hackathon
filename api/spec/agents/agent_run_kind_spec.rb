# frozen_string_literal: true

require "rails_helper"

# Smoke test: every agent subclass that creates an AgentRun row
# must declare a RUN_KIND that maps to AgentRun::RUN_KINDS. Otherwise
# the model validation will reject the create with "Run kind can't be
# blank".
RSpec.describe "Agent RUN_KIND constants" do
  let(:expected_kinds) { AgentRun::RUN_KINDS }

  it "every subclass of ::Agent declares a RUN_KIND in RUN_KINDS" do
    descendants = ObjectSpace.each_object(Class).select { |k| k < ::Agent }
    descendants.each do |klass|
      # Skip abstract intermediate base classes that aren't directly
      # invoked (e.g. Analyst::Base, Debate::Base, Positions::Base).
      # Each defines RUN_KIND that subclasses inherit, so we only
      # check the base classes.
      next unless [
        Analyst::Base, Debate::Base, Positions::Base, Trader, TickerSelectorAgent
      ].include?(klass)

      expect(klass.const_defined?(:RUN_KIND, false)).to be(true),
        "#{klass.name} must define a RUN_KIND constant"
      expect(expected_kinds).to include(klass::RUN_KIND),
        "#{klass.name}::RUN_KIND=#{klass::RUN_KIND.inspect} not in #{expected_kinds.inspect}"
    end
  end

  it "AgentRun::RUN_KINDS includes the kinds our agents use" do
    [
      Analyst::Base::RUN_KIND,       # 'analyst'
      Debate::Base::RUN_KIND,       # 'research'
      Positions::Base::RUN_KIND,    # 'position'
      Trader::RUN_KIND,             # 'trader'
      TickerSelectorAgent::RUN_KIND # 'selector'
    ].each do |kind|
      expect(expected_kinds).to include(kind),
        "AgentRun::RUN_KINDS=#{expected_kinds.inspect} missing #{kind.inspect}"
    end
  end
end
