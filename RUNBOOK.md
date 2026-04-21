# RUNBOOK.md — incident playbooks for yral-rishi-sentry

> **Status (2026-04-21):** partial. The Phase 9 work item will write the full set of playbooks (see PROGRESS.md). What's below is the minimum set of commands to survive known incidents today.

## Known architectural quirk: Caddy overlay attachment is runtime-only

### The short version

Sentry is reverse-proxied by Caddy on rishi-1 and rishi-2. Caddy reaches Sentry's nginx on rishi-3 via a Swarm attachable overlay called `sentry-web`. The attachment is a `docker network connect` command — it is **not persistent across Caddy container restarts**. If Caddy restarts for any reason (reboot, crash, image upgrade), `sentry.rishi.yral.com` starts returning 502 from whichever host restarted until Caddy is re-attached.

### What we've done to mitigate

On each of rishi-1 and rishi-2, a systemd unit `sentry-caddy-reconnect.service` fires on boot (after `docker.service`), waits 30 s for Caddy to come up, and then runs `/home/deploy/caddy-reconnect.sh` which idempotently calls `docker network connect sentry-web caddy`. Installed by `scripts/bootstrap-caddy-reconnect.sh` (one-time setup from an operator's laptop).

### What's still NOT covered

Ad-hoc Caddy container restarts while the host is up — e.g. `docker restart caddy`, a cluster-wide `docker compose up` on the Caddy stack, an image pull+replace. systemd only fires the reconnect unit on boot.

### How to detect this failure mode

- `curl -I https://sentry.rishi.yral.com/_health/` returns 502 (or a specific Cloudflare error page)
- On the affected host: `docker inspect caddy --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'` does NOT include `sentry-web`

### How to fix immediately (< 30 s)

SSH to the affected host (rishi-1 or rishi-2) and run:

```
/home/deploy/caddy-reconnect.sh
```

That script is idempotent: "already attached" → exits 0, "not attached" → attaches + exits 0. Safe to run on both hosts even if only one is broken.

### How to fix permanently (template-level, out of our scope)

Move Caddy itself to a Swarm stack with declarative `networks:` entries — the network attachment becomes part of the service spec and is restored on every reconciliation. Tracked as a follow-up for Saikat on the infra-template repo (see `PROGRESS.md`).

---

## Other playbooks planned for Phase 9

Each will be a numbered step-by-step with the exact shell commands to run. Not yet written — use `sentry-admin.sh` + `docker compose logs` as a fallback.

1. **"Sentry is down — start here"** — SSH commands, `sentry-admin.sh ps` interpretation, load-bearing containers.
2. **"Events are arriving but not showing up in the UI"** — Relay → Kafka → consumer → Snuba → Clickhouse flow, lag diagnostics.
3. **"Clickhouse disk is filling up"** — retention settings, manual cleanup.
4. **"Kafka queue is backing up"** — consumer lag, worker scale.
5. **"How to upgrade Sentry"** — changelog review, dry-run, rollback path.
6. **"How to rotate the Google OAuth client secret"** — secret locations, rotation sequence.
7. **"I've lost SSO access — how do I log in as a superuser?"** — `sentry-admin.sh run --rm -it web createuser --superuser`.
8. **"Backup / restore drill"** — `scripts/backup.sh` manual trigger, restore-to-test-instance procedure.

## Until Phase 9 ships

The fastest rollback for any Sentry issue not covered above is:

- Revert the `SENTRY_DSN` GitHub Secret on the affected service to the old `apm.yral.com` DSN and redeploy that service. Events flow back to Saikat's Sentry while we debug the self-hosted one.
- Sentry on rishi-3 can be left idle without harm — the containers keep running even if no services point at them.
