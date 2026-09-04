# alpaca-mcp

Wraps the upstream [alpacahq/alpaca-mcp-server](https://github.com/alpacahq/alpaca-mcp-server)
for use as a Yield-paca data + trading source.

## What it provides

- US equity + options account, positions, orders
- Real-time and historical market data
- News headlines, asset metadata
- Order placement (only via the PortfolioManager, never via the LLM agents)

The upstream server exposes the full toolset; we filter
client-side in the Rails initializer so the LLM only sees
read-only toolsets (see `trading.yml#alpaca_mcp.readonly_toolsets`).
The `trading` and `positions` toolsets are reserved for the
deterministic PortfolioManager.

## Env vars

| var | required | notes |
| --- | --- | --- |
| `ALPACA_API_KEY` | yes | Paper-trading key from https://alpaca.markets |
| `ALPACA_SECRET_KEY` | yes | Paper-trading secret |
| `ALPACA_PAPER_TRADE` | no | default `true` for safety |
| `ALPACA_TOOLSETS` | no | CSV of toolsets the upstream should expose |

## Transport

`uvx alpaca-mcp-server serve --transport streamable-http` on port 8000 by default.
