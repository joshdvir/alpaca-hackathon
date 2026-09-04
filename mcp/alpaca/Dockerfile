# Alpaca MCP server — official server, run via uvx
# https://github.com/alpacahq/alpaca-mcp-server

FROM python:3.12-slim

# Install uv (used to run the MCP server)
RUN pip install --no-cache-dir uv

# Default command: serve the MCP protocol over HTTP on port 8000
# Auth is read from ALPACA_API_KEY / ALPACA_SECRET_KEY env vars (passed by compose)
CMD ["uvx", "alpaca-mcp-server", "serve", \
  "--transport", "streamable-http", \
  "--host", "0.0.0.0", \
  "--port", "8000"]
