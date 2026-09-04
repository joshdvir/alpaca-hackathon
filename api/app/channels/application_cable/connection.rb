# frozen_string_literal: true

# ActionCable connection — authenticates incoming WebSocket connections.
# For the hackathon we don't have user auth, so we accept all connections
# and rely on the API to enforce auth at the REST layer.

module ApplicationCable
  class Connection < ActionCable::Connection::Base
  end
end
