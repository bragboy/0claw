#!/usr/bin/env bash
# init-zen.sh — point ZeroClaw at OpenCode Zen, bind the gateway to the host,
# and (if credentials are present) wire the Telegram channel. Idempotent:
# safe to re-run whenever .env changes.
set -euo pipefail

: "${OPENCODE_API_KEY:?OPENCODE_API_KEY is not set — populate it in .env and restart}"

ZC_HOME="${ZEROCLAW_HOME:-$HOME/.zeroclaw}"
ZC_CONFIG="${ZC_HOME}/config.toml"
DEFAULT_MODEL="${ZEROCLAW_DEFAULT_MODEL:-claude-sonnet-4-5}"
GATEWAY_HOST="${ZEROCLAW_GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${ZEROCLAW_GATEWAY_PORT:-42617}"

mkdir -p "${ZC_HOME}"

{
  cat <<EOF
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

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]]; then
    cat <<EOF

[channels_config.telegram]
enabled       = true
bot_token     = "${TELEGRAM_BOT_TOKEN}"
allowed_users = ["${TELEGRAM_ALLOWED_USER_ID}"]
mention_only  = false
EOF
    TG_WIRED=1
  else
    TG_WIRED=0
  fi
} > "${ZC_CONFIG}"

chmod 600 "${ZC_CONFIG}"

echo "[init-zen] wrote ${ZC_CONFIG}"
echo "[init-zen] provider = opencode-zen  (https://opencode.ai/zen/v1)"
echo "[init-zen] model    = ${DEFAULT_MODEL}"
echo "[init-zen] gateway  = ${GATEWAY_HOST}:${GATEWAY_PORT}  (allow_public_bind = true)"
if [[ "${TG_WIRED}" == "1" ]]; then
  echo "[init-zen] telegram = wired  (allowed_users = [${TELEGRAM_ALLOWED_USER_ID}])"
else
  echo "[init-zen] telegram = skipped (set TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USER_ID in .env to enable)"
fi
echo "[init-zen] restart the container to pick up channel changes."
