#!/usr/bin/env bash
# init-zen.sh — point ZeroClaw at OpenCode Zen and bind the gateway so the
# host can reach the dashboard. Idempotent: safe to re-run whenever
# OPENCODE_API_KEY changes.
set -euo pipefail

: "${OPENCODE_API_KEY:?OPENCODE_API_KEY is not set — populate it in .env and restart}"

ZC_HOME="${ZEROCLAW_HOME:-$HOME/.zeroclaw}"
ZC_CONFIG="${ZC_HOME}/config.toml"
DEFAULT_MODEL="${ZEROCLAW_DEFAULT_MODEL:-claude-sonnet-4-5}"
GATEWAY_HOST="${ZEROCLAW_GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${ZEROCLAW_GATEWAY_PORT:-42617}"

mkdir -p "${ZC_HOME}"

cat > "${ZC_CONFIG}" <<EOF
# Managed by init-zen.sh — regenerated on each run.
default_provider = "opencode-zen"
default_model    = "${DEFAULT_MODEL}"
api_key          = "${OPENCODE_API_KEY}"

[gateway]
host              = "${GATEWAY_HOST}"
port              = ${GATEWAY_PORT}
allow_public_bind = true

[reliability]
provider_retries    = 2
provider_backoff_ms = 500
EOF

chmod 600 "${ZC_CONFIG}"

echo "[init-zen] wrote ${ZC_CONFIG}"
echo "[init-zen] provider = opencode-zen  (https://opencode.ai/zen/v1)"
echo "[init-zen] model    = ${DEFAULT_MODEL}"
echo "[init-zen] gateway  = ${GATEWAY_HOST}:${GATEWAY_PORT}  (allow_public_bind = true)"
echo "[init-zen] run 'zeroclaw doctor' to verify, then 'zeroclaw onboard' to wire Telegram."
