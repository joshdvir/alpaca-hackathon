# frozen_string_literal: true

# LiveUpdates — AR concern that publishes model lifecycle events to the
# LiveUpdatesChannel. Include it in any model whose changes the front-end
# should react to in real time.
#
# Usage:
#   class TradeProposal < ApplicationRecord
#     include LiveUpdates
#   end
#
# The default stream is inferred by LiveUpdatesBroadcaster.infer_stream
# (based on the model class). Override per-model with:
#
#   def self.live_updates_stream
#     :trades
#   end
#
# The hooks are no-ops for `Rails.env.test?` (the test adapter records
# broadcasts for assertions, but the channel doesn't run unless we
# explicitly subscribe — see the channel spec).

module LiveUpdates
  extend ActiveSupport::Concern

  included do
    after_commit :_live_broadcast_create,  on: :create
    after_commit :_live_broadcast_update,  on: :update
    after_commit :_live_broadcast_destroy, on: :destroy
  end

  class_methods do
    # Override to publish to a specific stream regardless of the model
    # name (e.g. a BacktestTrade might want to ride the :backtests stream
    # even though the default inference might differ).
    def live_updates_stream
      LiveUpdatesBroadcaster.infer_stream(new) if respond_to?(:new)
    end
  end

  private

  def _live_broadcast_create
    return unless _live_should_broadcast?
    LiveUpdatesBroadcaster.publish_for(self, event: :created)
  end

  def _live_broadcast_update
    return unless _live_should_broadcast?
    LiveUpdatesBroadcaster.publish_for(self, event: :updated)
  end

  def _live_broadcast_destroy
    LiveUpdatesBroadcaster.publish_for(self, event: :destroyed)
  end

  def _live_should_broadcast?
    true
  end
end
