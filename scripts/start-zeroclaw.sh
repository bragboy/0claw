#!/usr/bin/env bash
# start-zeroclaw - container entrypoint that runs the DeepSeek thinking-strip
# proxy alongside the ZeroClaw daemon. Their lifecycles are tied: if either
# child exits, the script terminates the other and exits non-zero so Docker's
# `restart: unless-stopped` policy brings the whole stack back clean.
set -euo pipefail

PROXY_PORT="${DEEPSEEK_PROXY_PORT:-8089}"

node /usr/local/bin/deepseek-proxy.mjs >&2 &
PROXY_PID=$!

# Wait for the proxy to start listening before booting ZeroClaw, so the very
# first request the daemon makes (warm-up ping) does not race the proxy.
for _ in $(seq 1 30); do
  if curl -sf -o /dev/null "http://127.0.0.1:${PROXY_PORT}/_health"; then
    break
  fi
  sleep 0.1
done

zeroclaw daemon &
ZC_PID=$!

trap 'kill -TERM "$PROXY_PID" "$ZC_PID" 2>/dev/null || true' TERM INT

while :; do
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "deepseek-proxy exited, terminating zeroclaw" >&2
    kill -TERM "$ZC_PID" 2>/dev/null || true
    wait "$ZC_PID" || true
    exit 1
  fi
  if ! kill -0 "$ZC_PID" 2>/dev/null; then
    echo "zeroclaw exited, terminating deepseek-proxy" >&2
    kill -TERM "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" || true
    exit 0
  fi
  sleep 1
done
