#!/usr/bin/env bash
# do-task CHAT_ID "<instruction>"
#
# Defer an instruction for execution at call time. Runs the ZeroClaw CLI
# agent with <instruction> as a fresh prompt, captures the synthesized
# text response, and delivers it to the given Telegram chat as one clean
# message via `zeroclaw channel send`.
#
# Built for scheduled cron jobs where the content depends on live data.
# Instead of baking text at scheduling time, the cron command invokes
# do-task, which invokes the agent, which fetches fresh data NOW (the
# moment the cron fires) and returns the synthesized reply.
#
# Works at any time of day (morning, afternoon, evening, night). The
# instruction is plain English; it can request weather, news, prices,
# web fetches, summaries, or any combination.
#
# Usage (from a cron_add command):
#   do-task 100116514 "Give me Tres Cantos weather right now"
#   do-task 100116514 "Top 3 Claude Code news headlines from the past day"
#   do-task 100116514 "NVDA, BTC, and EUR/USD one-liners"
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: do-task <chat_id> <instruction>" >&2
  exit 1
fi

CHAT_ID="$1"
shift
INSTRUCTION="$*"

# Sideload credentials when ZeroClaw's shell sandbox has scrubbed env.
if [[ -z "${BRAVE_API_KEY:-}" && -r /root/.zeroclaw/env ]]; then
  # shellcheck disable=SC1091
  . /root/.zeroclaw/env
fi

# Prompt the agent to produce ONLY the final text, not deliver it itself,
# and fetch any live data at this moment.
PROMPT="You are generating content for a deferred delivery, not replying in a live conversation.

Instruction from the user: ${INSTRUCTION}

Strict rules for this execution:
- This runs at the scheduled fire time. 'Now' is literally now. Fetch any
  time-sensitive data at this moment using the shell helpers (weather-for,
  news-search, crypto-price, stock-price, fx-rate) or web_fetch. Do not
  fall back on cached or pre-trained knowledge for current facts.
- Return ONLY the final content as plain text, ready to show the user.
  No preamble like 'Here is' or 'I have fetched'. No trailing offers.
- DO NOT call 'zeroclaw channel send', any Telegram tool, or any other
  delivery mechanism. The caller will deliver your text to the user.
- Follow the persona in SOUL.md: no emojis, no em-dashes, professional
  tone, no filler.
- Keep it compact: a few short paragraphs at most, often less."

# CLI agent path returns ONE synthesized reply (unlike the channel agent
# path which narrates). `RUST_LOG=error` suppresses the tracing INFO lines
# that would otherwise pollute stdout. Strip ANSI color codes just in case.
RESPONSE=$(RUST_LOG=error zeroclaw agent -m "$PROMPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

if [[ -z "$RESPONSE" ]]; then
  RESPONSE="(the deferred task returned no content; try sending the instruction again)"
fi

zeroclaw channel send "$RESPONSE" --channel-id telegram --recipient "$CHAT_ID"
