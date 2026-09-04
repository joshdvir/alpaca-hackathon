# TradingView MCP server — atilaahmettaner/tradingview-mcp
# https://github.com/atilaahmettaner/tradingview-mcp
#
# Provides: chart data, technical indicators, screener, ideas feed,
# symbol info, and other TradingView data via the unofficial
# TradingView API. No API key required (uses public TradingView
# endpoints), but a proxy may be needed for production volumes.
#
# Build context: this Dockerfile is run from the trader/ root
# (mcp/<server>/Dockerfile). The git clone happens at build time
# and pins the upstream's main branch — change the ref for
# reproducible builds.

FROM python:3.12-slim

WORKDIR /app

RUN pip install tradingview-mcp-server
# Default command — the upstream exposes an MCP server over stdio
# by default. We wrap it with mcp-proxy (or similar) to expose it
# over streamable-http so the Rails API can talk to it like the
# alpaca MCP. The actual command depends on the upstream's
# transport — override in compose if the upstream adds HTTP
# support natively.
ENV MCP_TRANSPORT=streamable-http
ENV MCP_HOST=0.0.0.0
ENV MCP_PORT=8001

EXPOSE 8001

# Patch: disable the upstream's localhost-only Host-header allowlist
# so docker-internal clients (Host: tradingview-mcp:8001) can reach
# the server. The upstream auto-enables DNS-rebinding protection
# inside the FastMCP() constructor when bound to localhost; we
# inject an explicit transport_security=None to bypass that path.
# Toggle via $MCP_ALLOW_ANY_HOST — when unset (the default for
# `pip install tradingview-mcp-server` users), the patch is a no-op
# and the upstream's behavior is preserved.
RUN python - <<'PY'
import pathlib, re
p = pathlib.Path("/usr/local/lib/python3.12/site-packages/tradingview_mcp/server.py")
src = p.read_text()
# Add the import only if not present.
if "from mcp.server.transport_security import TransportSecuritySettings" not in src:
    src = src.replace(
        "from mcp.server.fastmcp import FastMCP",
        "from mcp.server.fastmcp import FastMCP\nfrom mcp.server.transport_security import TransportSecuritySettings",
        1,
    )
# Patch the FastMCP(...) instantiation to disable the protection.
needle = "mcp = FastMCP(\n    name=\"TradingView Multi-Market Screener\","
if needle in src and "transport_security=" not in src.split(needle, 1)[1].split("\n)", 1)[0]:
    src = src.replace(
        needle,
        needle
        + "\n    # Patched: disable localhost-only Host allowlist for cross-container access.\n"
        "    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),",
        1,
    )
p.write_text(src)
print("patched" if needle in src else "needle-missing")
PY

CMD ["tradingview-mcp", "--host", "0.0.0.0", "--port", "8001", "streamable-http"]
