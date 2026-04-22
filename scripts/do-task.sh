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

# Shadow `zeroclaw` for the inner agent. Historically the inner agent has
# disobeyed the "don't call zeroclaw channel send" rule and pasted the
# resulting shell envelope (status=exit status:0 / stdout:... / Message sent
# via telegram.) into its final text, producing garbage in Telegram. A stub
# in a PATH dir that comes before /usr/local/bin makes `zeroclaw ...` in the
# inner agent's shell tool error out instead of delivering anything. The
# outer script reaches the real binary via absolute path.
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/zeroclaw" <<'STUB'
#!/usr/bin/env bash
echo "zeroclaw CLI is blocked inside do-task: the outer script handles delivery. Return plain text." >&2
exit 42
STUB
chmod +x "$STUB_DIR/zeroclaw"

PROMPT="You are generating content for a deferred delivery, not replying in a live conversation.

Instruction from the user: ${INSTRUCTION}

Strict rules for this execution:
- This runs at the scheduled fire time. 'Now' is literally now. Fetch any
  time-sensitive data at this moment using the shell helpers (weather-for,
  news-search, crypto-price, stock-price, fx-rate) or web_fetch. Do not
  fall back on cached or pre-trained knowledge for current facts.
- Return ONLY the final content as plain text, ready to show the user.
  No preamble like 'Here is' or 'I have fetched'. No trailing offers.
- CRITICAL: Delivery is handled by the caller. DO NOT invoke 'zeroclaw',
  'zeroclaw channel send', or any Telegram tool. The zeroclaw CLI is
  intentionally blocked in this sandbox and will exit with status 42 if
  you call it. Do not paste any shell tool envelope ('status=exit status:',
  'stdout:', 'stderr:', 'Message sent via telegram.', or ANSI tracing
  lines) into your reply. Reply with prose only.
- Follow the persona in SOUL.md: no emojis, no em-dashes, professional
  tone, no filler.
- Keep it compact: a few short paragraphs at most, often less."

# Prepend STUB_DIR so the INNER agent's shell tool hits the stub when it
# tries `zeroclaw ...`. Use the absolute path for our own invocation so the
# stub doesn't shadow us. `RUST_LOG=error` suppresses tracing INFO lines
# that would otherwise pollute stdout; strip ANSI color codes just in case.
RESPONSE=$(PATH="$STUB_DIR:$PATH" RUST_LOG=error /usr/local/bin/zeroclaw agent -m "$PROMPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

# Belt and suspenders: if the inner agent somehow still pasted a shell
# envelope into its reply, do not forward it to the user as if it were
# real content. Fail loudly instead.
if [[ "$RESPONSE" == *"status=exit status:"* ]] \
   || [[ "$RESPONSE" == *"Message sent via telegram."* ]] \
   || [[ "$RESPONSE" == *"zeroclaw_config::"* ]]; then
  RESPONSE="(the deferred task misfired: the inner agent emitted shell tool output instead of plain text. The schedule is still active and should recover on the next fire.)"
fi

if [[ -z "$RESPONSE" ]]; then
  RESPONSE="(the deferred task returned no content; try sending the instruction again)"
fi

/usr/local/bin/zeroclaw channel send "$RESPONSE" --channel-id telegram --recipient "$CHAT_ID"
