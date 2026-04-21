# CLAUDE.md — architecture cheat sheet for yral-rishi-sentry

> **Status (2026-04-21):** stub. Will be filled in during Phase 2 once the actual Docker Compose + Caddy + systemd wiring exists. Until then, the plan file (`~/.claude/plans/splendid-spinning-mccarthy.md`) is the authoritative architecture reference.

## What this file will contain (once Phase 2 is done)

- A one-paragraph description of how the stack works end-to-end (browser → Cloudflare → Caddy on rishi-1/2 → Sentry nginx on rishi-3:9000 → Sentry's internal services).
- The list of every Docker container, what it does in plain English, and how much RAM it's capped at.
- The three "load-bearing" services (if any of these are unhealthy, Sentry is unhealthy): web, relay, kafka.
- Where Sentry's data lives on rishi-3 (Postgres volume, Clickhouse volume, Kafka volume — exact paths).
- Where Sentry's configuration lives (config.yml + sentry.config.py + docker-compose.override.yml — how they interact).
- The boot sequence (systemd unit → `docker compose up -d` → service start order).
- The request path for an incoming event (SDK → `POST /api/<project>/envelope/` → Caddy → Relay → Kafka → consumer → Postgres+Clickhouse).

## Current state

- Phase 1 complete. See `PRE-FLIGHT.md`.
- Phase 2 not started. No code exists yet.
- Version pinned to `26.4.0` in `project.config`.

Until Phase 2 is done, ignore this file — it is a placeholder that will become the canonical architecture doc.
