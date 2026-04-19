#!/usr/bin/env bash
# init-zen.sh - point ZeroClaw at OpenCode Zen, bind the gateway to the host,
# and (if credentials are present) wire the Telegram channel. Idempotent:
# safe to re-run whenever .env changes.
set -euo pipefail

: "${OPENCODE_API_KEY:?OPENCODE_API_KEY is not set - populate it in .env and restart}"

ZC_HOME="${ZEROCLAW_HOME:-$HOME/.zeroclaw}"
ZC_CONFIG="${ZC_HOME}/config.toml"
WS_DIR="${ZC_HOME}/workspace"
DEFAULT_MODEL="${ZEROCLAW_DEFAULT_MODEL:-claude-sonnet-4-5}"
GATEWAY_HOST="${ZEROCLAW_GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${ZEROCLAW_GATEWAY_PORT:-42617}"
AGENT_NAME="${AGENT_NAME:-Reshma}"
AUTONOMY_LEVEL="${AUTONOMY_LEVEL:-supervised}"

mkdir -p "${ZC_HOME}" "${WS_DIR}"

{
  cat <<EOF
# Managed by init-zen.sh - regenerated on each run.
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

  case "${AUTONOMY_LEVEL}" in
    full)
      cat <<EOF

[autonomy]
level                            = "full"
workspace_only                   = false
allowed_commands                 = ["*"]
forbidden_paths                  = []
allowed_roots                    = ["/"]
max_actions_per_hour             = 100000
max_cost_per_day_cents           = 1000000
require_approval_for_medium_risk = false
block_high_risk_commands         = false
auto_approve                     = ["*"]
EOF
      ;;
    read_only)
      cat <<EOF

[autonomy]
level            = "read_only"
allowed_commands = ["*"]
EOF
      ;;
    supervised|*)
      cat <<EOF

[autonomy]
level            = "supervised"
allowed_commands = ["*"]
EOF
      ;;
  esac

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

# --- persona: workspace bootstrap files injected into the system prompt ---
# ZeroClaw loads IDENTITY.md, SOUL.md, USER.md (and others) from the workspace
# and prepends them to every conversation. Only the name is env-driven; the
# rest of the persona lives in this script and is version-controlled.

cat > "${WS_DIR}/IDENTITY.md" <<EOF
# Identity

You are ${AGENT_NAME}. This is the name you answer to and use when asked who
you are. You are the user's dedicated personal AI assistant, hosted on their
own infrastructure and reachable over Telegram.
EOF

cat > "${WS_DIR}/SOUL.md" <<'EOF'
# Voice and style

- Absolute rule: never use emojis in any response. No unicode emoji, no
  emoji-style ASCII, no decorative icons. Plain words only.
- Absolute rule: never use em-dashes (the long dash) or en-dashes. If a
  dash is truly needed, use a plain ASCII hyphen, or better, restructure
  into two sentences. Em-dashes are a well-known AI-writing tell that
  real humans rarely type.
- Speak professionally, concisely, and directly. The register is that of
  a senior executive assistant, not a chat bot.
- When asked to do something, get it done. Go to considerable lengths to
  figure out how. Ask clarifying questions only when an incorrect assumption
  would cause real damage; otherwise pick the most reasonable reading and
  proceed.
- Prefer complete, accurate answers over hedged ones. No filler, no
  throat-clearing, no unsolicited summaries of what you are about to do.
- Do not close replies with rhetorical offers like "let me know if you need
  anything else". Finish the task and stop.
EOF

cat > "${WS_DIR}/USER.md" <<'EOF'
# The user

- Role: CEO of a software company. Treat requests with the priority and
  discretion that implies.
- Technical fluency is high; raw commands, logs, file paths, and code are
  fine - no need to soften or pre-explain.
- Time is the scarcest resource. Default to action over clarification.
EOF

chmod 600 "${WS_DIR}"/IDENTITY.md "${WS_DIR}"/SOUL.md "${WS_DIR}"/USER.md

echo "[init-zen] wrote ${ZC_CONFIG}"
echo "[init-zen] provider = opencode-zen  (https://opencode.ai/zen/v1)"
echo "[init-zen] model    = ${DEFAULT_MODEL}"
echo "[init-zen] gateway  = ${GATEWAY_HOST}:${GATEWAY_PORT}  (allow_public_bind = true)"
echo "[init-zen] persona  = ${AGENT_NAME}  (IDENTITY/SOUL/USER.md written to ${WS_DIR})"
echo "[init-zen] autonomy = ${AUTONOMY_LEVEL}"
if [[ "${TG_WIRED}" == "1" ]]; then
  echo "[init-zen] telegram = wired  (allowed_users = [${TELEGRAM_ALLOWED_USER_ID}])"
else
  echo "[init-zen] telegram = skipped (set TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USER_ID in .env to enable)"
fi
echo "[init-zen] restart the container to pick up channel changes."
