# frozen_string_literal: true

# LiveUpdatesBroadcaster — single entry point for pushing events to the
# LiveUpdatesChannel. Models call `LiveUpdatesBroadcaster.publish(stream,
# payload)` from after_commit hooks; the channel fans out to subscribed
# clients.
#
# Topic -> stream mapping is centralized here so publishers can't typo-
# mismatch against the channel subscription.

module LiveUpdatesBroadcaster
  STREAMS = %i[system agent_runs trades positions backtests].freeze

  module_function

  # Publish a JSON-serializable payload to the named stream. Stream
  # name is one of STREAMS.
  def publish(stream, payload)
    return unless STREAMS.include?(stream.to_sym)
    ActionCable.server.broadcast("live_updates:#{stream}", payload)
  end

  # Convenience: a model can call this and we infer the stream from
  # the model's class name. Override per-model via the
  # `live_updates_stream` class method if you need to.
  def publish_for(model, event:)
    stream = infer_stream(model)
    return unless stream
    publish(stream, {
      event: event.to_s,
      model: model.class.name.demodulize.underscore,
      record: serialize(model)
    })
  end

  # Default stream mapping. Override on a per-model basis with
  # `def self.live_updates_stream; :my_stream end`.
  def infer_stream(model)
    case model.class.name
    when "AgentRun"          then :agent_runs
    when "TradeProposal"     then :trades
    when "Order"             then :trades
    when "Position"          then :positions
    when "BacktestRun"       then :backtests
    when "BacktestTrade"     then :backtests
    when "WatchlistEntry"    then :system
    when "RiskDecision"      then :trades
    end
  end

  def serialize(model)
    if model.respond_to?(:serializable_hash)
      model.serializable_hash
    else
      { id: model.id }
    end
  end
end
