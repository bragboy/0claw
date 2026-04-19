# CLAUDE.md - guidance for agents working in this repo

## Project

`0claw` is a Dockerized 24/7 AI automation hub: a single ZeroClaw daemon
backed by GLM through z.ai's Anthropic-compatible endpoint, chatting over
Telegram, with the `claude-code` and `gemini-cli` CLIs bundled as alternate
"brains" (the `claude` CLI is pre-wired through the same GLM endpoint).

See [README.md](README.md) for the user-facing setup flow.

## Commit conventions

- **Do not add `Co-Authored-By: Claude …` (or any Claude/Anthropic trailer) to commit messages.** Author commits as the user only. This overrides the default Claude Code behavior - apply it without being reminded.
- Use HEREDOCs for multi-line commit bodies.
- Prefer new commits over amends once something has been pushed.

## Secrets

- `.env` holds real credentials and is gitignored. Never stage, commit, echo, or `cat` it. When wiring new providers, add a placeholder to `.env.example` and reference it by variable name only.
