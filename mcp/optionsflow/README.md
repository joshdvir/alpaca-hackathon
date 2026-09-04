# mcp-optionsflow

Wraps the upstream [twolven/mcp-optionsflow](https://github.com/twolven/mcp-optionsflow)
for use as a Yield-paca data source.

## What it provides

- Unusual options activity (block trades, sweeps)
- Open interest change feeds
- Volume vs OI ratios

Useful as a sentiment signal for the debate phase — large call
buying before earnings, put sweeps at support, etc.

## Env vars

None by default. Check the upstream README for any new required
keys before deploying.

## Transport

`MCP_TRANSPORT=streamable-http` on port 8003 by default.
