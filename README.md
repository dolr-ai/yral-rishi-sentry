# yral-rishi-sentry

Self-hosted Sentry for Rishi's services on Hetzner bare metal. Replaces the shared `apm.yral.com` for `yral-chat-ai`, `yral-rishi-hetzner-infra-template`, `yral-hello-world-rishi`, and `yral-hello-world-counter`. Future services built from the infra template will inherit this Sentry automatically.

## What this repo does

This repo is a thin wrapper around the upstream `getsentry/self-hosted` Docker Compose deployment. Upstream ships the actual Sentry services (web, worker, relay, snuba, clickhouse, kafka, postgres, etc.). This repo holds:

1. **Our config overrides** — URL prefix, Google Workspace SSO, domain whitelist, resource limits, volume paths.
2. **Operational scripts** — install, upgrade.
3. **CI cron jobs** — 5-minute external health check + rishi-3 load-average watchdog.
4. **The systemd unit** that makes Sentry survive a rishi-3 reboot (Docker's `restart: always` doesn't).
5. **The docs** — runbook, security threat model, scaling escape hatch.

## Where it runs

| Component | Host | Notes |
|---|---|---|
| Sentry stack (Docker Compose) | **rishi-3** (IP via GitHub Secret `SENTRY_HOST_IP`) | Colocated with etcd + Patroni follower; see PRE-FLIGHT.md for capacity evidence |
| Caddy reverse proxy | rishi-1 + rishi-2 | Matches every other service in the cluster; handles TLS |
| Public URL | `https://sentry.rishi.yral.com` | |
| Auth | Google Workspace SSO, `@gobazzinga.io` only | Configured via Sentry's built-in `GOOGLE_DOMAIN_WHITELIST` |
| Version pinned | `26.4.0` | See `project.config` |

## Where to start reading

Read in this order — each doc builds on the previous one:

1. **`PROGRESS.md`** — which of the 11 rollout phases are done.
2. **`PRE-FLIGHT.md`** — rishi-3 capacity evidence (Phase 1).
3. **`project.config`** — single source of truth for version, domain, resource limits.
4. **Plan file** (local to Claude, not in repo): `~/.claude/plans/splendid-spinning-mccarthy.md` — full rollout plan.
5. **`READING-ORDER.md`** — will be written once code exists (Phase 2+).
6. **`CLAUDE.md`** — architecture cheat sheet, written alongside code.
7. **`RUNBOOK.md`** — incident playbooks (Phase 9).
8. **`SECURITY.md`** — threat model (Phase 9).
9. **`SCALING.md`** — when / how to migrate off rishi-3 (Phase 10).

## Status

**Phase 1: Pre-flight** — DONE (2026-04-21). rishi-3 confirmed capable of hosting Sentry. See `PRE-FLIGHT.md`.

**Phase 2: Install Sentry on rishi-3** — DONE (2026-04-21). `/_health/` returns ok. Superuser creation still pending. Public URL (sentry.rishi.yral.com) requires Phase 3.

**Phases 3–10** — not started. See `PROGRESS.md`.

## Running admin commands against the Sentry stack

Any one-off CLI against Sentry (create user, reset password, shell, cleanup, logs) must go through `scripts/sentry-admin.sh` — a tiny wrapper that sources `.env.custom` before calling `docker compose`. Running `docker compose run --rm web ...` directly from a fresh SSH shell will fail with `SECRET_KEY must not be empty` because the shell doesn't have `SENTRY_SYSTEM_SECRET_KEY` exported.

Examples:

```
# Create a superuser
~/yral-rishi-sentry/scripts/sentry-admin.sh run --rm web \
    createuser --email you@gobazzinga.io --password 'hunter2' --superuser

# Tail web logs
~/yral-rishi-sentry/scripts/sentry-admin.sh logs -f web

# Check status
~/yral-rishi-sentry/scripts/sentry-admin.sh ps
```

From your Mac:

```
ssh -i ~/.ssh/rishi-hetzner-ci-key deploy@<rishi-3-ip> \
    "~/yral-rishi-sentry/scripts/sentry-admin.sh ps"
```

## Why a separate repo (not an instance of `yral-rishi-hetzner-infra-template`)

The infra template assumes one FastAPI service + optional Patroni-backed Postgres behind Caddy. Sentry is a 15-container stack with its own Postgres, Clickhouse, Kafka, Redis, and Zookeeper. Forcing it into the template's shape would fight both systems. Instead: a dedicated repo that mirrors the template's *conventions* (project.config, documentation standards, GitHub Actions for health monitoring, same Caddy snippet pattern) without inheriting its *structure*.
