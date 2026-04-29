# CLAUDE.md - guidance for agents working in this repo

## Project

`0claw` is a Dockerized 24/7 AI automation hub: a single ZeroClaw daemon
backed by DeepSeek (`deepseek-v4-flash`) via its Anthropic-compatible
endpoint, chatting over Telegram, with the `claude-code` and `gemini-cli`
CLIs bundled as alternate "brains" (the `claude` CLI is pre-wired through
the same DeepSeek endpoint).

A small Node proxy (`scripts/deepseek-proxy.mjs`, listening on
`127.0.0.1:8089` inside the container, started in the background by
`scripts/start-zeroclaw.sh`) sits in front of DeepSeek and force-injects
`thinking: {type: "disabled"}` into every `/v1/messages` request. This
keeps v4-flash on the cheapest non-thinking pricing and side-steps a
ZeroClaw v0.7.3 bug where prior thinking blocks in conversation history
are not passed back to the API correctly. ZeroClaw's `default_provider`
points at the proxy, not directly at api.deepseek.com.

See [README.md](README.md) for the user-facing setup flow.

## Commit conventions

- **Do not add `Co-Authored-By: Claude …` (or any Claude/Anthropic trailer) to commit messages.** Author commits as the user only. This overrides the default Claude Code behavior - apply it without being reminded.
- Use HEREDOCs for multi-line commit bodies.
- Prefer new commits over amends once something has been pushed.

## Secrets

- `.env` holds real credentials and is gitignored. Never stage, commit, echo, or `cat` it. When wiring new providers, add a placeholder to `.env.example` and reference it by variable name only.

## Deployment hygiene (zero ephemeral state)

- During iteration on the VM, `docker cp` + `docker compose exec` is fine for fast feedback.
- **Before ending any deploy session, the VM must be in a persistent state matching `origin/main`.** That means: commit the change, push, then run `ruby deploy.rb` (which performs `git pull` + `docker compose up -d --build` + `init-deepseek.sh` + restart on the VM), and verify.
- Never hand control back to the user with the running container carrying changes that aren't baked into the image. A VM reboot, container recreate, or `docker compose down && up` must leave every working fix intact.
- The invariant: repo HEAD, latest image on the VM, and running container all correspond to the same git commit.
