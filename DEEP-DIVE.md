# DEEP-DIVE.md — visual walkthrough of how yral-rishi-sentry works

> **Status (2026-04-21):** stub. Will be written alongside the Phase 2 code so that the ASCII diagrams match the actual deployment.

## What this file will contain (Phase 2–3)

- **Request flow diagram** — user browser → Cloudflare → Caddy (rishi-1 or rishi-2) → Sentry nginx (rishi-3:9000) → Sentry web/relay/worker.
- **Event ingestion diagram** — an SDK (chat-ai) firing an event → `POST /api/<proj>/envelope/` → Caddy → Relay → Kafka → post-process-forwarder → Snuba → Clickhouse (for search) + Postgres (for issue metadata).
- **Deploy flow diagram** — pushing a new pin of `SENTRY_VERSION` in `project.config` → `scripts/upgrade.sh` → SSH to rishi-3 → `git checkout <tag>` in `/opt/sentry-upstream` → `./install.sh` → `docker compose up -d`.
- **Backup flow diagram** — daily GitHub Actions trigger → SSH to rishi-3 → `pg_dump` Sentry's Postgres → encrypted upload to S3 (`rishi-yral/yral-rishi-sentry/daily/`).
- **Auth flow diagram** — user clicks "Sign in with Google" → redirect to Google → Google returns to `sentry.rishi.yral.com/auth/sso/` → Sentry verifies email domain is `@gobazzinga.io` → session created.

## Why ASCII (not a rendered image)?

Matches the infra template's conventions. ASCII diagrams render anywhere — GitHub UI, raw text editor, terminal — and don't rot when the code changes because they're in the repo next to the code.

## Current state

Phase 2 hasn't started. The system being diagrammed doesn't exist yet. Come back to this file when `PROGRESS.md` shows Phase 2 done.
