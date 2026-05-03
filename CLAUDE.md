# CLAUDE.md - guidance for agents working in this repo

## Project

`0claw` is a Dockerized 24/7 AI automation hub: ZeroClaw daemons backed by
DeepSeek (`deepseek-v4-flash`) via its Anthropic-compatible endpoint,
chatting over Telegram, with the `claude-code` and `gemini-cli` CLIs
bundled as alternate "brains" (the `claude` CLI is pre-wired through the
same DeepSeek endpoint).

**Multi-tenant architecture.** One container per tenant, one Telegram bot
per tenant, isolated state under `tenants/<slug>/`. The image is shared;
only the volume mounts and env-file differ. `ruby deploy.rb spawn <slug>`
scaffolds a new tenant locally; `ruby deploy.rb deploy <slug>` brings it
up on the VM. `ruby deploy.rb deploy-all` redeploys every tenant after a
shared-file change. Memory, crons, persona, and timezone are per tenant.

A small Node proxy (`scripts/deepseek-proxy.mjs`, listening on
`127.0.0.1:8089` inside each container, started in the background by
`scripts/start-zeroclaw.sh`) sits in front of DeepSeek and force-injects
`thinking: {type: "disabled"}` into every `/v1/messages` request. It also
appends an ABSOLUTE OVERRIDE block to the system prompt forbidding
`NO_REPLY` in this DM channel and requiring cron answers to come from
`cron_list` output (not memory). This keeps v4-flash on the cheapest
non-thinking pricing and side-steps a ZeroClaw v0.7.3 bug where prior
thinking blocks in conversation history are not passed back to the API
correctly. ZeroClaw's `default_provider` points at the proxy, not directly
at api.deepseek.com.

See [README.md](README.md) for the user-facing setup flow.

## Commit conventions

- **Do not add `Co-Authored-By: Claude …` (or any Claude/Anthropic trailer) to commit messages.** Author commits as the user only. This overrides the default Claude Code behavior - apply it without being reminded.
- Use HEREDOCs for multi-line commit bodies.
- Prefer new commits over amends once something has been pushed.

## Secrets

- `tenants/<slug>/.env` holds real credentials and is gitignored (the entire `tenants/*/` tree is). Never stage, commit, echo, or `cat` any tenant env file. When wiring new providers, add a placeholder to `.env.example` (which is the template `spawn` copies from) and reference it by variable name only.

## Deployment hygiene (zero ephemeral state)

- During iteration on the VM, `docker cp` + `docker compose exec` (with the right `-p zeroclaw-<slug>` and `--env-file tenants/<slug>/.env`) is fine for fast feedback.
- **Before ending any deploy session, every touched tenant on the VM must be in a persistent state matching `origin/main`.** That means: commit the change, push, then run `ruby deploy.rb deploy <slug>` (or `deploy-all` if a shared file changed) which performs `git pull` + `docker compose up -d --build` + `init-deepseek.sh` + restart on the VM, and verify.
- Never hand control back to the user with a running container carrying changes that aren't baked into the image. A VM reboot, container recreate, or `docker compose down && up` must leave every working fix intact.
- The invariant: repo HEAD, latest image on the VM, and every running tenant container all correspond to the same git commit.
- Shared-file changes (`scripts/`, `Dockerfile`, `docker-compose.yml`, `init-deepseek.sh`, `deepseek-proxy.mjs`) require `deploy-all`, not just one tenant. Only `tenants/<slug>/.env` changes are tenant-scoped.
