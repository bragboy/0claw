# 0claw - 24/7 AI Automation Hub

<img src="assets/Rebecca.png" alt="Rebecca" width="100%" />

**Meet Rebecca.** The default persona is a concise executive assistant: no emojis, no em-dashes, no chatbot fluff. She runs 24/7 in the container, answers Telegram messages from the allowlist, schedules reminders that fetch live data at fire time, and finishes tasks instead of offering to help with them. Her voice lives in `SOUL.md`; her name is the only bit you swap through `.env`.

---

A Dockerized, cloud-agnostic harness for [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) that:

- runs the ZeroClaw daemon 24/7 with **Telegram** as the chat surface,
- uses **DeepSeek** `deepseek-v4-flash` ($0.14/M input cache miss, $0.28/M output) via its Anthropic-compatible endpoint as the reasoning backend - full tool access including web search,
- bundles the `claude-code` and `gemini-cli` CLIs so the agent can delegate to a different "brain" on demand, with `claude` pre-wired through the same DeepSeek endpoint,
- runs a tiny in-container proxy (`scripts/deepseek-proxy.mjs`, `127.0.0.1:8089`) that injects `thinking: {type: "disabled"}` into every `/v1/messages` request and strips stale thinking blocks from history, keeping v4-flash on the cheap non-thinking path and side-stepping a ZeroClaw v0.7.3 multi-turn bug,
- supports **multi-tenancy**: one container per tenant, each with their own Telegram bot, persona, persistent state, and gateway port. Memory and cron jobs are isolated per tenant.

---

## Layout

```
.
├── Dockerfile               # debian:bookworm-slim + Node + ZeroClaw + CLIs + dashboard
├── docker-compose.yml       # tenant-aware service, parameterised by USER_SLUG
├── .env.example             # template for tenants/<slug>/.env
├── deploy.rb                # ruby driver: spawn / deploy / logs / tunnel / ...
├── scripts/                 # baked into the image, identical for all tenants
│   ├── init-deepseek.sh        # writes ~/.zeroclaw/config.toml + persona files
│   ├── deepseek-proxy.mjs      # node proxy that strips thinking from API calls
│   ├── start-zeroclaw.sh       # entrypoint: launches proxy + zeroclaw daemon
│   ├── do-task.sh              # deferred-execution helper for cron jobs
│   ├── news-search.sh, crypto-price.sh, stock-price.sh, fx-rate.sh, weather-for.sh
└── tenants/                 # one subdirectory per tenant; everything inside is gitignored
    └── <slug>/
        ├── .env                  # tenant secrets (DeepSeek, Brave, Telegram, persona)
        ├── config/
        │   ├── zeroclaw/         # mounted -> /root/.zeroclaw  (workspace + sqlite memory)
        │   └── claude/           # mounted -> /root/.claude    (Claude Code state)
        └── workspace/            # mounted -> /workspace       (agent work dir)
```

Everything under `tenants/*/` is gitignored. The image is built once and shared; only the volume mounts and env-file change between tenants.

---

## 1. Spawn a tenant

```bash
ruby deploy.rb spawn bragboy
$EDITOR tenants/bragboy/.env    # fill in DeepSeek/Brave/Telegram keys, AGENT_NAME, USER_TIMEZONE, AUTONOMY_LEVEL
```

`spawn` scaffolds `tenants/<slug>/{config,workspace,.env}`, fills in `USER_SLUG=<slug>`, and assigns the next free `ZEROCLAW_GATEWAY_PORT` (starting at 42617). Each tenant has their own bot (DM @BotFather, paste the token in `TELEGRAM_BOT_TOKEN`) and an allowlist of one (`TELEGRAM_ALLOWED_USER_ID`). The bundled `init-deepseek.sh` reads the env at container start and regenerates `config.toml` + persona files inside the volume.

---

## 2. Deploy

```bash
# First time on the VM (clones the repo, copies the .env, builds, brings up)
ruby deploy.rb bootstrap <slug>

# Subsequent deploys (commit + push first; deploy.rb refuses if the tree is dirty)
ruby deploy.rb deploy <slug>

# Push the .env file alone after rotating a key
ruby deploy.rb env-refresh <slug>
```

`deploy <slug>` runs `git pull` on the VM, rebuilds the shared image, runs `init-deepseek.sh` inside the tenant's container, restarts. The container has `restart: unless-stopped` and the host's Docker daemon starts on boot, so each tenant comes back automatically after a VM reboot.

To redeploy every tenant after a code change to a shared file (e.g. `scripts/`, `Dockerfile`, `docker-compose.yml`):

```bash
ruby deploy.rb deploy-all
```

---

## 3. Day-to-day operation

```bash
ruby deploy.rb list               # list all tenants on the VM with container status
ruby deploy.rb status [<slug>]    # docker ps + zeroclaw status (omit slug for a one-line summary of all)
ruby deploy.rb logs <slug>        # tail this tenant's container logs (Ctrl-C exits)
ruby deploy.rb tunnel <slug>      # SSH tunnel from localhost:<port> to the VM
ruby deploy.rb ssh                # shell into the repo dir on the VM
ruby deploy.rb destroy <slug>     # stop + remove this tenant's container; state on disk stays
```

Each tenant chats with their own bot in Telegram. Messages from any id NOT in `TELEGRAM_ALLOWED_USER_ID` are silently ignored (warning in logs). To grab a new user's id, have them DM the bot, then:

```bash
ruby deploy.rb logs <slug> | grep -i unauthorized | tail -n1
```

ZeroClaw logs the sender id and username for every rejected message.

### Picking a different model (per tenant)

`init-deepseek.sh` defaults to `deepseek-v4-flash` (the cheapest tier: $0.14/M input cache miss, $0.28/M output). The in-container proxy at `127.0.0.1:8089` always injects `thinking: {type: "disabled"}` and strips historical thinking blocks, so non-thinking behavior is enforced by the proxy regardless of model choice. To change the model for one tenant, set `ZEROCLAW_DEFAULT_MODEL` in their `.env` and `env-refresh`:

```bash
$EDITOR tenants/<slug>/.env       # add ZEROCLAW_DEFAULT_MODEL=deepseek-v4-pro
ruby deploy.rb env-refresh <slug>
```

DeepSeek's Anthropic endpoint accepts `deepseek-v4-flash`, `deepseek-v4-pro` (more capable, ~3x cost), and the legacy `deepseek-chat` / `deepseek-reasoner` names (deprecated 2026/07/24).

### Live data shell helpers (baked into the image)

Anything time-sensitive (news, prices, FX) goes through these instead of the built-in `web_search` tool, which returns cached crawl snippets and is unreliable for current numbers. The agent discovers them via the auto-injected `TOOLS.md`:

```bash
docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env exec zeroclaw-hub news-search "meta layoffs" pd
docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env exec zeroclaw-hub crypto-price BTC USD
docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env exec zeroclaw-hub stock-price AAPL
docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env exec zeroclaw-hub fx-rate EUR USD 100
```

Or just `ruby deploy.rb ssh` and run them from the docker compose context inside the repo dir.

### Turning autonomy up or down (per tenant)

`AUTONOMY_LEVEL` in each tenant's `.env` controls how much the agent can do without asking:

- `supervised` (default) - medium and high-risk commands prompt for approval; all command names are allowed but risk gates apply.
- `full` - kitchen-sink unrestricted: no allowlist, no forbidden paths, no approval gates, no rate or cost caps. Use only inside a disposable sandbox like this container.
- `read_only` - agent observes, does not act.

After editing the env, `ruby deploy.rb env-refresh <slug>`.

---

## 4. Verify a tenant is live

```bash
ruby deploy.rb status <slug>
ruby deploy.rb ssh
# inside the VM:
docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env exec zeroclaw-hub zeroclaw doctor
docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env exec zeroclaw-hub zeroclaw agent -m "Reply with one word: pong"
docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env exec zeroclaw-hub curl -sf http://127.0.0.1:8089/_health
```

Expected signals:

- `zeroclaw doctor` reports the provider as `anthropic-custom:http://127.0.0.1:8089` (the in-container proxy) and the credential as present.
- `zeroclaw agent -m "..."` returns a clean text response from `deepseek-v4-flash`.
- The proxy `/_health` endpoint prints `ok`.

To reach the dashboard from your laptop, open the SSH tunnel:

```bash
ruby deploy.rb tunnel <slug>
# in another terminal:
open http://localhost:<that tenant's ZEROCLAW_GATEWAY_PORT>
```

Nothing is exposed to the public internet; the tunnel rides the existing SSH connection.

---

## 5. Migrating a legacy single-tenant install

Earlier versions of this repo were single-tenant, with `config/`, `workspace/`, and `.env` directly at the repo root. To convert that into a `tenants/<slug>/` layout in place (without losing memory or cron state):

```bash
ruby deploy.rb migrate-from-single <slug>
```

This runs on the VM via SSH:

1. Stops + removes the old `zeroclaw-hub` container.
2. Moves `config/`, `workspace/`, and `.env` into `tenants/<slug>/`.
3. Appends `USER_SLUG=<slug>` and `ZEROCLAW_GATEWAY_PORT=<port>` to the migrated env (port read from the local copy).
4. Brings the tenant up under the new compose project name (`zeroclaw-<slug>`).

You only run this once per VM. Locally you can do the same `mv` by hand once.

---

## 6. VM preflight (one-time, before first `bootstrap`)

Before running `deploy.rb bootstrap`, make sure the VM has:

- A recent Docker Engine (`docker --version`).
- The Docker Compose V2 plugin (`docker compose version`). On hosts where `apt-get install docker-compose-plugin` doesn't work (old or EOL Ubuntu releases), grab the static binary directly:
  ```bash
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  ```
- Enough RAM + swap. On a 1 GB VM, add a 1 GB swap file (one tenant fits, two get tight; bump to 4 GB for 3+):
  ```bash
  sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile
  sudo mkswap /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```
- The deploy user in the `docker` group (`groups` should include `docker`).

---

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| `init-deepseek.sh` exits with "DEEPSEEK_API_KEY is not set" | `tenants/<slug>/.env` missing or has an empty key. `ruby deploy.rb env-refresh <slug>` to push a fresh copy. |
| `zeroclaw doctor` flags the provider as unreachable | Container egress or corporate proxy blocking `api.deepseek.com`, OR the deepseek-proxy is not running (`docker compose -p zeroclaw-<slug> --env-file tenants/<slug>/.env logs`). |
| Replies show thinking content or fail with `content[].thinking ... must be passed back` | The deepseek-proxy is not in the request path. Check `default_provider` in `tenants/<slug>/config/zeroclaw/config.toml` points at `127.0.0.1:8089`. |
| `start-zeroclaw` exits early with "deepseek-proxy died" | Node not in PATH or the proxy crashed on startup. `ruby deploy.rb logs <slug>` for the stderr line. |
| `401 Unauthorized` from the provider | Key revoked or wrong for this tenant. Each tenant has their own DeepSeek key in their own `.env`. |
| Telegram messages are ignored | Sender id is not in the tenant's allowlist; multi-tenant means the allowlist is one user per tenant. |
| Agent replies "command blocked by security policy" | `AUTONOMY_LEVEL=supervised` and the command is risk-gated. Set `full` and `env-refresh` if you want unrestricted shell inside the sandbox. |
| `docker compose ... up` says container name conflict | Another tenant is using the same port. Each `tenants/<slug>/.env` must have a unique `ZEROCLAW_GATEWAY_PORT`. |

---

## References

- ZeroClaw repo and docs: <https://github.com/zeroclaw-labs/zeroclaw>
- Providers reference (custom Anthropic endpoints): `docs/reference/api/providers-reference.md`
- DeepSeek API docs (Anthropic-compatible endpoint): <https://api-docs.deepseek.com/>
- DeepSeek Anthropic-compatible base URL: <https://api.deepseek.com/anthropic>
