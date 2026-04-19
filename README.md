# 0claw - 24/7 AI Automation Hub

A Dockerized, cloud-agnostic harness for [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) that:

- runs the ZeroClaw daemon 24/7 with **Telegram** as the chat surface,
- uses **OpenCode Zen** (`opencode-zen` provider, Claude models) as the reasoning backend,
- bundles the `claude-code` and `gemini-cli` CLIs so the agent can delegate to a different "brain" on demand.

---

## Layout

```
.
├── Dockerfile              # debian:bookworm-slim + Node + ZeroClaw + CLIs
├── docker-compose.yml      # single service, persistent volumes, restart: unless-stopped
├── .env.example            # copy to .env and fill in
├── scripts/
│   └── init-zen.sh         # writes ~/.zeroclaw/config.toml to use opencode-zen
├── config/
│   ├── zeroclaw/           # mounted → /root/.zeroclaw  (ZeroClaw workspace + config)
│   └── claude/             # mounted → /root/.claude    (Claude Code state)
└── workspace/              # mounted → /workspace       (agent work dir)
```

The `config/` and `workspace/` directories are git-ignored but their parent dirs are kept via `.gitkeep` so the bind mounts have something to attach to on a fresh clone.

---

## 1. One-time setup

```bash
# 1. Populate secrets
cp .env.example .env
$EDITOR .env      # fill in OPENCODE_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USER_ID

# 2. Build the image
docker compose build
```

Pinned versions: ZeroClaw `v0.7.3`, Node.js `22`. Change `ZEROCLAW_VERSION` / `NODE_MAJOR` build args in the Dockerfile (or pass via `--build-arg`) to bump them.

---

## 2. First boot

Bring the container up in the background:

```bash
docker compose up -d
```

Then, inside the container, point ZeroClaw at OpenCode Zen and run the interactive onboarder:

```bash
# Write ~/.zeroclaw/config.toml (provider = opencode-zen)
docker compose exec zeroclaw-hub init-zen.sh

# Walk through ZeroClaw's setup wizard - adds the Telegram channel,
# asks for the bot token, binds your allowed user id.
docker compose exec -it zeroclaw-hub zeroclaw onboard

# Explicitly allowlist your user id (skip if onboard already did it)
docker compose exec zeroclaw-hub \
  zeroclaw channel bind-telegram "${TELEGRAM_ALLOWED_USER_ID:-<your_id>}"
```

Restart so the daemon picks up the new config:

```bash
docker compose restart zeroclaw-hub
```

---

## 3. Verify the backend is live

```bash
# System health - validates provider config, API reachability, sandbox paths
docker compose exec zeroclaw-hub zeroclaw doctor

# Send a one-shot prompt through the configured provider
docker compose exec zeroclaw-hub zeroclaw agent -m "Reply with one word: pong"

# Tail the daemon logs
docker compose logs -f zeroclaw-hub
```

Expected signals:

- `zeroclaw doctor` reports the provider as `opencode-zen` and the credential as present.
- `zeroclaw agent -m "..."` returns a response (default model: `claude-sonnet-4-5`).
- The web dashboard is reachable at <http://localhost:42617>.

You can also smoke-test the key without the container - this is what the repo's initial POC ran:

```bash
# auth check
(set -a; . ./.env; set +a; curl -sS -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $OPENCODE_API_KEY" \
  https://opencode.ai/zen/v1/models | head -c 400)

# generation check
(set -a; . ./.env; set +a; curl -sS -H "Authorization: Bearer $OPENCODE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"ping"}],"max_tokens":10}' \
  https://opencode.ai/zen/v1/chat/completions)
```

---

## 4. Daily use

- Chat with the bot directly in Telegram - messages from `TELEGRAM_ALLOWED_USER_ID` go straight through; anyone else hits the pairing gate.
- To switch "brains" for a specific task, invoke the bundled CLIs from inside the container:
  ```bash
  docker compose exec zeroclaw-hub claude   # Claude Code CLI (needs ANTHROPIC_API_KEY in .env)
  docker compose exec zeroclaw-hub gemini   # Gemini CLI (needs GEMINI_API_KEY / Google OAuth)
  ```
- Persistent state lives in `./config/zeroclaw` and `./config/claude` - back these up to preserve memory, channel bindings, and approvals.

### Picking a different model

`init-zen.sh` defaults to `claude-sonnet-4-5`. To change globally, set `ZEROCLAW_DEFAULT_MODEL` in `.env` and re-run:

```bash
docker compose up -d                               # re-reads env_file
docker compose exec zeroclaw-hub init-zen.sh       # rewrites config.toml
docker compose restart zeroclaw-hub
```

Available models (as of the POC on 2026-04-19) include `claude-opus-4-7`, `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-sonnet-4-5`, and ~24 more. Query the live list with:

```bash
(set -a; . ./.env; set +a; curl -sS -H "Authorization: Bearer $OPENCODE_API_KEY" \
  https://opencode.ai/zen/v1/models | jq '.data[].id')
```

---

## 5. Rotating the key

Update `OPENCODE_API_KEY` in `.env`, then:

```bash
docker compose up -d                               # re-reads env_file
docker compose exec zeroclaw-hub init-zen.sh       # rewrites config.toml
docker compose restart zeroclaw-hub
```

---

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| `init-zen.sh` exits with "OPENCODE_API_KEY is not set" | `.env` is missing or not picked up - confirm it lives next to `docker-compose.yml`. |
| `zeroclaw doctor` flags the provider as unreachable | Container egress / corporate proxy blocking `opencode.ai`. |
| `401 Unauthorized` from the provider | Key revoked or wrong - re-check via the curl smoke test in §3. |
| Telegram messages are ignored | Your user id is not in the allowlist; run `zeroclaw channel bind-telegram <id>`. |
| Unknown senders get a pairing code | Expected - ZeroClaw's default DM policy. Approve with `zeroclaw pairing approve telegram <code>`. |
| Daemon won't stay up on boot | `docker compose logs zeroclaw-hub` - usually a missing config.toml or bad token. |

---

## References

- ZeroClaw repo & docs: <https://github.com/zeroclaw-labs/zeroclaw>
- Providers reference: `docs/reference/api/providers-reference.md` in the repo (opencode/opencode-zen is natively supported, no custom endpoint setup required)
- OpenCode Zen endpoint: <https://opencode.ai/zen/v1>
