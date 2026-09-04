# frozen_string_literal: true

# ApplicationCable::Channel — base class for all our channels.
# All channels inherit from this so we can add shared behavior later
# (auth, logging, instrumentation) in one place.

module ApplicationCable
  class Channel < ActionCable::Channel::Base
  end
end
