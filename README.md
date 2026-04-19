# 0claw - 24/7 AI Automation Hub

A Dockerized, cloud-agnostic harness for [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) that:

- runs the ZeroClaw daemon 24/7 with **Telegram** as the chat surface,
- uses **GLM** (via z.ai's Anthropic-compatible endpoint) as the reasoning backend - full tool access including web search,
- bundles the `claude-code` and `gemini-cli` CLIs so the agent can delegate to a different "brain" on demand, with `claude` pre-wired through the same GLM endpoint.

---

## Layout

```
.
├── Dockerfile              # debian:bookworm-slim + Node + ZeroClaw + CLIs + web dashboard
├── docker-compose.yml      # single service, persistent volumes, restart: unless-stopped
├── .env.example            # copy to .env and fill in
├── scripts/
│   └── init-glm.sh         # writes ~/.zeroclaw/config.toml + persona files
├── config/
│   ├── zeroclaw/           # mounted -> /root/.zeroclaw  (ZeroClaw workspace + config)
│   └── claude/             # mounted -> /root/.claude    (Claude Code state)
└── workspace/              # mounted -> /workspace       (agent work dir)
```

The `config/` and `workspace/` directories are git-ignored but their parent dirs are kept via `.gitkeep` so the bind mounts have something to attach to on a fresh clone.

---

## 1. One-time setup

```bash
# 1. Populate secrets
cp .env.example .env
$EDITOR .env      # fill in GLM_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USER_ID

# 2. Build the image (first build also compiles the React dashboard)
docker compose build
```

Pinned versions: ZeroClaw `v0.7.3`, Node.js `22`. Change `ZEROCLAW_VERSION` / `NODE_MAJOR` build args in the Dockerfile (or pass via `--build-arg`) to bump them.

---

## 2. First boot

```bash
# Start detached
docker compose up -d

# Write ~/.zeroclaw/config.toml and persona files (IDENTITY/SOUL/USER.md)
docker compose exec zeroclaw-hub init-glm.sh

# Walk through ZeroClaw's wizard if you want the TUI onboarder
docker compose exec -it zeroclaw-hub zeroclaw onboard   # optional

# Restart so the daemon picks up config.toml + channel changes
docker compose restart zeroclaw-hub
```

If you populated `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_ID` in `.env`, `init-glm.sh` auto-wires the Telegram channel - no separate `zeroclaw channel bind-telegram` call needed.

---

## 3. Verify the backend is live

```bash
# System health
docker compose exec zeroclaw-hub zeroclaw doctor

# One-shot prompt through the configured provider
docker compose exec zeroclaw-hub zeroclaw agent -m "Reply with one word: pong"

# Tail the daemon logs
docker compose logs -f zeroclaw-hub
```

Expected signals:

- `zeroclaw doctor` reports the provider as `anthropic-custom:https://api.z.ai/api/anthropic` and the credential as present.
- `zeroclaw agent -m "..."` returns a response from `glm-4.6`.
- The web dashboard is reachable at <http://localhost:42617>.

You can also smoke-test the GLM key without the container:

```bash
(set -a; . ./.env; set +a; curl -sS -w "\nHTTP %{http_code}\n" \
  -H "x-api-key: $GLM_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{"model":"glm-4.6","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
  https://api.z.ai/api/anthropic/v1/messages)
```

---

## 4. Daily use

- Chat with the bot directly in Telegram. Messages from any id listed in `TELEGRAM_ALLOWED_USER_ID` go through; anyone else is silently ignored (warning in logs).
- To switch "brains" for a specific task, invoke the bundled CLIs from inside the container:
  ```bash
  docker compose exec zeroclaw-hub claude   # Claude Code CLI, pre-wired through z.ai/GLM via ANTHROPIC_BASE_URL
  docker compose exec zeroclaw-hub gemini   # Gemini CLI (needs GEMINI_API_KEY or Google OAuth)
  ```
- Persistent state lives in `./config/zeroclaw` and `./config/claude`. Back these up to preserve memory, channel bindings, and approvals.

### Live data shell helpers (baked into the image)

Anything time-sensitive (news, prices, FX) should go through these instead of the built-in `web_search` tool, which returns cached crawl snippets and is unreliable for current numbers. The agent discovers them via the auto-injected `TOOLS.md`, but you can invoke them yourself inside the container:

```bash
docker compose exec zeroclaw-hub news-search "meta layoffs" pd    # past-day news via Brave News
docker compose exec zeroclaw-hub crypto-price BTC USD             # Binance spot
docker compose exec zeroclaw-hub stock-price AAPL                 # Yahoo last trade
docker compose exec zeroclaw-hub fx-rate EUR USD 100              # Frankfurter/ECB
```

### Picking a different model

`init-glm.sh` defaults to `glm-4.6`. To change globally, set `ZEROCLAW_DEFAULT_MODEL` in `.env` and re-run:

```bash
docker compose up -d                               # re-reads env_file
docker compose exec zeroclaw-hub init-glm.sh       # rewrites config.toml
docker compose restart zeroclaw-hub
```

z.ai's Anthropic endpoint accepts GLM model names directly (`glm-4.6`, `glm-4.5-air`, etc.) and remaps Anthropic-style names to GLM server-side.

### Adding more Telegram users

Comma-append the id in `.env`:

```
TELEGRAM_ALLOWED_USER_ID=100116514,47946531,...
```

Then `docker compose exec zeroclaw-hub init-glm.sh && docker compose restart zeroclaw-hub`.

To grab a new user's id, have them message the bot, then:

```bash
(set -a; . ./.env; set +a; docker compose logs zeroclaw-hub 2>&1 | grep -i unauthorized | tail -n1)
```

ZeroClaw logs the sender id and username for every rejected message.

### Turning autonomy up or down

`AUTONOMY_LEVEL` in `.env` controls how much the agent can do without asking:

- `supervised` (default) - medium and high-risk commands prompt for approval; all command names are allowed but risk gates apply.
- `full` - kitchen-sink unrestricted: no allowlist, no forbidden paths, no approval gates, no rate or cost caps. Use only inside a disposable sandbox like this container.
- `read_only` - agent observes, does not act.

After editing `.env`, rerun `init-glm.sh` on the host and restart.

---

## 5. Rotating the GLM key

Update `GLM_API_KEY` in `.env`, then:

```bash
docker compose up -d                               # re-reads env_file, also refreshes ANTHROPIC_AUTH_TOKEN
docker compose exec zeroclaw-hub init-glm.sh       # rewrites config.toml
docker compose restart zeroclaw-hub
```

---

## 6. Remote deployment

`deploy.rb` is a zero-dependency Ruby script that drives all remote ops over SSH. The target VM is configured at the top of the file.

```bash
# First-time setup on the VM (clones repo, copies .env once, builds, brings up)
ruby deploy.rb bootstrap

# Standard deploy loop (checks local tree is clean + pushed, then pulls + rebuilds remote)
ruby deploy.rb

# Observability
ruby deploy.rb status           # remote docker compose ps + zeroclaw status
ruby deploy.rb logs             # tail remote daemon logs
ruby deploy.rb ssh              # drop into a shell inside the repo dir on the VM

# Control
ruby deploy.rb env-refresh      # overwrite remote .env with your current local .env + restart
ruby deploy.rb down             # stop the remote container
```

Safety defaults:

- Standard `deploy` refuses to run if your local tree has uncommitted changes or if local is ahead of `origin/main`. Override with `ALLOW_DIRTY=1 ruby deploy.rb`.
- `bootstrap` copies `.env` to the VM only if the VM has no `.env` yet. To force-overwrite later, use `env-refresh`.
- The container has `restart: unless-stopped`, and the VM's Docker daemon is enabled at boot, so the agent comes back automatically after a VM reboot. No extra systemd unit is needed.

### VM preflight (one-time, before first `bootstrap`)

Before running `deploy.rb bootstrap`, make sure the VM has:

- A recent Docker Engine (`docker --version`).
- The Docker Compose V2 plugin (`docker compose version`). On hosts where `apt-get install docker-compose-plugin` doesn't work (old or EOL Ubuntu releases), grab the static binary directly:
  ```bash
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  ```
- Enough RAM + swap. On a 1 GB VM, add a 1 GB swap file:
  ```bash
  sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile
  sudo mkswap /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```
- The deploy user in the `docker` group (`groups` should include `docker`).

---

## 7. Dashboard access (SSH tunnel)

The gateway listens on `0.0.0.0:42617` inside the container, but the VM does not expose that port publicly. To reach the web dashboard from your laptop:

```bash
# via deploy.rb (convenience):
ruby deploy.rb tunnel

# or raw ssh:
ssh -N -L 42617:localhost:42617 deploy@francium.tech
```

While the tunnel is up, open <http://localhost:42617> in your browser. Ctrl-C the tunnel when done. Nothing is exposed to the public internet; everything rides the existing SSH connection.

---

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| `init-glm.sh` exits with "GLM_API_KEY is not set" | `.env` is missing or not picked up. Confirm it lives next to `docker-compose.yml`. |
| `zeroclaw doctor` flags the provider as unreachable | Container egress or corporate proxy blocking `api.z.ai`. |
| `401 Unauthorized` from the provider | Key revoked or wrong. Re-check via the curl smoke test in section 3. |
| Telegram messages are ignored | Sender id is not in the allowlist; add them to `TELEGRAM_ALLOWED_USER_ID` and regenerate. |
| Agent replies "command blocked by security policy" | Autonomy is `supervised` and the command is risk-gated. Set `AUTONOMY_LEVEL=full` in `.env` if you want unrestricted shell inside the sandbox. |
| Daemon won't stay up on boot | `docker compose logs zeroclaw-hub`, usually a missing config.toml or bad token. |

---

## References

- ZeroClaw repo and docs: <https://github.com/zeroclaw-labs/zeroclaw>
- Providers reference (custom Anthropic endpoints): `docs/reference/api/providers-reference.md`
- z.ai Anthropic-compatible endpoint: <https://api.z.ai/api/anthropic>
