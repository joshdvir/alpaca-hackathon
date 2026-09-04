# frozen_string_literal: true

# Alpaca MCP client setup.
# We create two clients pointing at the same MCP server:
#   - ALPACA_MCP_READONLY: filtered to read-only toolsets, given to LLM agents
#   - ALPACA_MCP_TRADING: full access, used only by the deterministic PortfolioManager
#
# The MCP server itself exposes the full toolset; filtering is client-side.
# The MCP server reads auth (ALPACA_API_KEY/SECRET) from its own env vars.
# We do NOT pass Authorization headers from the client.

require 'ruby_llm/mcp'

mcp_url = TradingConfig.fetch(:alpaca_mcp, :url)

ALPACA_MCP_READONLY = RubyLLM::MCP.client(
  name: 'alpaca-readonly',
  transport_type: :streamable,
  config: { url: mcp_url }
)

ALPACA_MCP_TRADING = RubyLLM::MCP.client(
  name: 'alpaca-trading',
  transport_type: :streamable,
  config: { url: mcp_url }
)

# Cache tool lists at boot — the server's tool list is stable across runs.
# Filters applied at agent registration time, not here.
Rails.application.config.after_initialize do
  Rails.logger.info "[alpaca_mcp] readonly tools: #{ALPACA_MCP_READONLY.tools.size}"
  Rails.logger.info "[alpaca_mcp] trading tools:  #{ALPACA_MCP_TRADING.tools.size}"
end
