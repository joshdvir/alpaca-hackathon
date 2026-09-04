# tradingview-mcp

Wraps the upstream [atilaahmettaner/tradingview-mcp](https://github.com/atilaahmettaner/tradingview-mcp)
for use as a Yield-paca data source.

## What it provides

- Real-time and historical chart data
- Technical indicator values (RSI, MACD, Bollinger, etc.)
- Symbol search and metadata
- Screener queries
- TradingView "ideas" feed

No API key required. The upstream uses public TradingView
endpoints; the official TradingView terms of service apply to
the data retrieved.

## Env vars

None required. If you need to route through a proxy, set
`HTTPS_PROXY` / `HTTP_PROXY` in the container environment.

## Transport

The upstream exposes stdio. The Dockerfile's `CMD` runs the
server and we route traffic over HTTP via the standard
`MCP_TRANSPORT` / `MCP_HOST` / `MCP_PORT` env vars (the Rails
`alpaca-mcp` initializer configures these for the streamable
transport — add an equivalent initializer for tradingview when
you wire it into the API).
