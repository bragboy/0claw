#!/usr/bin/env bash
# init-glm.sh - point ZeroClaw at GLM via z.ai's Anthropic-compatible
# endpoint, bind the gateway to the host, and (if credentials are present)
# wire the Telegram channel. Idempotent: safe to re-run whenever .env
# changes.
set -euo pipefail

: "${GLM_API_KEY:?GLM_API_KEY is not set - populate it in .env and restart}"

ZC_HOME="${ZEROCLAW_HOME:-$HOME/.zeroclaw}"
ZC_CONFIG="${ZC_HOME}/config.toml"
WS_DIR="${ZC_HOME}/workspace"
GLM_ENDPOINT="${ANTHROPIC_BASE_URL:-https://api.z.ai/api/anthropic}"
DEFAULT_MODEL="${ZEROCLAW_DEFAULT_MODEL:-glm-4.6}"
GATEWAY_HOST="${ZEROCLAW_GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${ZEROCLAW_GATEWAY_PORT:-42617}"
AGENT_NAME="${AGENT_NAME:-Reshma}"
AUTONOMY_LEVEL="${AUTONOMY_LEVEL:-supervised}"

mkdir -p "${ZC_HOME}" "${WS_DIR}"

{
  cat <<EOF
# Managed by init-glm.sh - regenerated on each run.
default_provider = "anthropic-custom:${GLM_ENDPOINT}"
default_model    = "${DEFAULT_MODEL}"
api_key          = "${GLM_API_KEY}"

[gateway]
host              = "${GATEWAY_HOST}"
port              = ${GATEWAY_PORT}
allow_public_bind = true

[reliability]
provider_retries    = 2
provider_backoff_ms = 500
EOF

  if [[ -n "${BRAVE_API_KEY:-}" ]]; then
    cat <<EOF

[web_search]
enabled       = true
provider      = "brave"
brave_api_key = "${BRAVE_API_KEY}"
max_results   = 5
timeout_secs  = 20
EOF
    WS_WIRED=1
  else
    WS_WIRED=0
  fi

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
    IFS=',' read -ra TG_USER_IDS <<< "${TELEGRAM_ALLOWED_USER_ID}"
    TG_USER_LIST=""
    for uid in "${TG_USER_IDS[@]}"; do
      uid="${uid// /}"
      [[ -z "$uid" ]] && continue
      [[ -n "$TG_USER_LIST" ]] && TG_USER_LIST+=", "
      TG_USER_LIST+="\"${uid}\""
    done
    cat <<EOF

[channels_config.telegram]
enabled       = true
bot_token     = "${TELEGRAM_BOT_TOKEN}"
allowed_users = [${TG_USER_LIST}]
mention_only  = false
EOF
    TG_WIRED=1
  else
    TG_WIRED=0
  fi
} > "${ZC_CONFIG}"

chmod 600 "${ZC_CONFIG}"

# ZeroClaw's shell tool scrubs env vars before running subprocesses, so baked-
# in helpers (news-search, etc.) don't inherit BRAVE_API_KEY at runtime.
# Write a sideload file they can source when their env var is missing.
{
  [[ -n "${BRAVE_API_KEY:-}" ]] && echo "export BRAVE_API_KEY='${BRAVE_API_KEY}'"
} > "${ZC_HOME}/env"
chmod 600 "${ZC_HOME}/env"

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
- For CURRENT information (news, today's anything, live numbers) the
  default web_search tool returns cached crawl snippets that are often
  days stale. Never quote a date, price, or claim as "current" from a
  web_search snippet alone. Use the shell helpers documented in TOOLS.md
  (news-search, crypto-price, stock-price, fx-rate). For deeper reading
  after discovering URLs, use web_fetch to pull live HTML. If the best
  result is older than the user's stated window, say so plainly rather
  than papering over.
EOF

cat > "${WS_DIR}/USER.md" <<'EOF'
# The user

- Role: CEO of a software company. Treat requests with the priority and
  discretion that implies.
- Technical fluency is high; raw commands, logs, file paths, and code are
  fine, no need to soften or pre-explain.
- Time is the scarcest resource. Default to action over clarification.
EOF

cat > "${WS_DIR}/TOOLS.md" <<'EOF'
# Shell helpers available in this environment

These are baked into the image and always available via shell. Prefer them
over the built-in web_search tool whenever the answer depends on current
data. web_search returns cached crawl snippets and is unsafe for anything
time-sensitive.

## news-search QUERY [FRESHNESS]

Current news via Brave's news index with an explicit freshness filter.
Returns title, publication date, source, URL, and summary per article.

FRESHNESS: pd (past day, default), pw (past week), pm (past month)

    news-search "meta layoffs"
    news-search "tesla earnings" pw

Use this for news, announcements, breaking developments, or any
"latest / today / this week" question. If past-day returns nothing,
widen to pw or pm and say so.

## crypto-price SYMBOL [QUOTE]

Live spot price from Binance.

    crypto-price BTC
    crypto-price ETH USD
    crypto-price SOL USDC

## stock-price TICKER

Last trade price from Yahoo Finance.

    stock-price AAPL
    stock-price TSLA

## fx-rate FROM TO [AMOUNT]

Current FX rate from ECB via Frankfurter.

    fx-rate EUR USD
    fx-rate EUR USD 100

## Research flow

For research that goes beyond a headline, use web_search to discover URLs,
then web_fetch on the chosen URL to read live HTML. Never quote numbers
or dates from a web_search snippet without verifying via web_fetch or one
of the dedicated helpers above. If a source is unreachable or the content
looks stale, say so plainly.
EOF

chmod 600 "${WS_DIR}"/IDENTITY.md "${WS_DIR}"/SOUL.md "${WS_DIR}"/USER.md "${WS_DIR}"/TOOLS.md

echo "[init-glm] wrote ${ZC_CONFIG}"
echo "[init-glm] provider = anthropic-custom:${GLM_ENDPOINT}"
echo "[init-glm] model    = ${DEFAULT_MODEL}"
echo "[init-glm] gateway  = ${GATEWAY_HOST}:${GATEWAY_PORT}  (allow_public_bind = true)"
echo "[init-glm] persona  = ${AGENT_NAME}  (IDENTITY/SOUL/USER.md written to ${WS_DIR})"
echo "[init-glm] autonomy = ${AUTONOMY_LEVEL}"
if [[ "${WS_WIRED}" == "1" ]]; then
  echo "[init-glm] websearch = brave  (BRAVE_API_KEY present)"
else
  echo "[init-glm] websearch = disabled (set BRAVE_API_KEY in .env to enable)"
fi
if [[ "${TG_WIRED}" == "1" ]]; then
  echo "[init-glm] telegram = wired  (allowed_users = [${TG_USER_LIST}])"
else
  echo "[init-glm] telegram = skipped (set TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USER_ID in .env to enable)"
fi
echo "[init-glm] restart the container to pick up channel changes."
