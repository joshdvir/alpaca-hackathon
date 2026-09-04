# Options flow MCP server — twolven/mcp-optionsflow
# https://github.com/twolven/mcp-optionsflow
#
# Provides unusual options activity (large block trades, sweep
# orders, open interest changes) — useful signals for the
# ResearchManager's debate.
#
# No API key by default; the upstream scrapes a public flow feed.
# If a paid API key is required in a future release, add
# OPTIONSFLOW_API_KEY to the env list.

FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
  git build-essential \
  && rm -rf /var/lib/apt/lists/*

ARG REPO_URL=https://github.com/twolven/mcp-optionsflow.git
ARG REPO_REF=main

RUN git clone --depth 1 --branch ${REPO_REF} ${REPO_URL} . && \
  pip install --no-cache-dir .

ENV PYTHONDONTWRITEBYTECODE=1 \
  PYTHONUNBUFFERED=1 \
  UV_COMPILE_BYTECODE=1 \
  UV_LINK_MODE=copy \
  PATH="/app/.venv/bin:$PATH" \
  MCP_TRANSPORT=streamable-http \
  MCP_HOST=0.0.0.0 \
  MCP_PORT=8003 \
  MCP_PATH=/mcp

RUN groupadd --system --gid 10001 mcp \
  && useradd --system --uid 10001 --gid mcp --create-home --home-dir /home/mcp mcp

RUN uv sync --frozen --no-dev --no-editable \
  && chown -R mcp:mcp /app /home/mcp

USER 10001:10001
EXPOSE 8003
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read()"
ENTRYPOINT ["python", "optionsflow.py"]
