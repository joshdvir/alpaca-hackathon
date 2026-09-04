# frozen_string_literal: true

# ApplicationActivity is the base class for all Temporal activities.
# Subclasses override #execute and call helpers defined here.
# Provides @activity (the current Activity::Context) plus shared utilities.

class ApplicationActivity < T_ACTIVITY_DEF
  attr_reader :activity

  def initialize
    @activity = T_ACTIVITY_CTX.current
    super
  end

  def execute(...)
    raise NotImplementedError, "#{self.class} must implement #execute"
  end
end
