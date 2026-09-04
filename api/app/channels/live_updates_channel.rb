# frozen_string_literal: true

# LiveUpdatesChannel — multiplexed ActionCable channel. The front-end
# opens one subscription and subscribes to one or more "streams" (named
# topics) via the #subscribe_to action. The channel then forwards every
# broadcast to the right client.
#
# Why one channel vs five: opening five WebSocket connections (one per
# topic) wastes server resources. The multiplexed approach is the
# standard pattern (e.g. Rails' Action Cable example chatroom with many
# "rooms" uses the same idea).
#
# Wire format:
#   client -> server: { action: "subscribe",   stream: "trades" }
#   client -> server: { action: "unsubscribe", stream: "trades" }
#   server -> client: { stream: "trades", event: "created", record: {...} }
#   server -> client: { stream: "system", event: "tick", server_time: "..." }

class LiveUpdatesChannel < ApplicationCable::Channel
  VALID_STREAMS = %w[system agent_runs trades positions backtests config].freeze

  def subscribed
    stream_from "live_updates:system"     if params[:stream] == "system"     || subscribed_to_all?
    stream_from "live_updates:agent_runs" if params[:stream] == "agent_runs" || subscribed_to_all?
    stream_from "live_updates:trades"     if params[:stream] == "trades"     || subscribed_to_all?
    stream_from "live_updates:positions"  if params[:stream] == "positions"  || subscribed_to_all?
    stream_from "live_updates:backtests"  if params[:stream] == "backtests"  || subscribed_to_all?
    stream_from "live_updates:config"     if params[:stream] == "config"     || subscribed_to_all?
  end

  def subscribe_to(data)
    name = data["stream"].to_s
    return reject unless VALID_STREAMS.include?(name)
    stream_from "live_updates:#{name}"
    transmit({ ack: "subscribed", stream: name })
  end

  def unsubscribe_from(data)
    name = data["stream"].to_s
    return reject unless VALID_STREAMS.include?(name)
    stop_stream_from "live_updates:#{name}"
    transmit({ ack: "unsubscribed", stream: name })
  end

  def speak(data)
    # No-op echo endpoint; useful for ping/pong from the front-end.
    transmit({ pong: data["payload"] })
  end

  private

  def subscribed_to_all?
    params[:stream] == "all" || params[:all].present?
  end
end
