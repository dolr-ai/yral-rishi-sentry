# READING-ORDER.md — which file to read first

> **Status (2026-04-21):** stub. Will be completed once Phase 2 introduces the actual code files.

## Today's reading order (while the repo is just scaffolding)

1. `README.md` — what this repo is, where it runs, what status it's in.
2. `PROGRESS.md` — which of the 11 phases are done and which are next.
3. `PRE-FLIGHT.md` — evidence that rishi-3 can host Sentry (Phase 1 output).
4. `project.config` — single source of truth for version + placement + resource limits.
5. Plan file (not in repo, in Claude's plan directory): `~/.claude/plans/splendid-spinning-mccarthy.md` — the full 11-phase rollout plan.
6. `CLAUDE.md`, `RUNBOOK.md`, `SECURITY.md`, `DEEP-DIVE.md`, `SCALING.md` — currently stubs; each will become authoritative when its phase ships.

## Future reading order (once Phase 2+ land)

This will be rewritten as a numbered walkthrough of every file in the repo, grouped by concern:

- **Config** (what you edit to change behaviour): `project.config`, `sentry/config.yml`, `sentry/sentry.config.py`, `docker-compose.override.yml`.
- **Operations** (what runs at deploy or maintenance time): `scripts/install.sh`, `scripts/upgrade.sh`, `scripts/sentry-admin.sh`, `scripts/caddy-reconnect.sh`, `scripts/bootstrap-caddy-reconnect.sh`.
- **CI** (what runs on a schedule): `.github/workflows/health-check.yml` (Sentry /_health/ + rishi-3 load-avg watchdog every 5 min).
- **Boot wiring** (how Sentry survives a reboot): `systemd/sentry.service`.
- **Docs** (how humans reason about it): the five required docs.

Each file in each group will be annotated here with a one-line "what to look at" hint so a newcomer (or future-Rishi after an ADHD break) can re-orient quickly.
