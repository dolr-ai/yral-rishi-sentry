# RUNBOOK.md — incident playbooks for yral-rishi-sentry

> **Status (2026-04-21):** stub. Will be written in **Phase 9** of the rollout (see `PROGRESS.md`). Do not treat any section below as authoritative until it is marked DONE in PROGRESS.md.

## Playbooks planned for Phase 9

Each will be a numbered step-by-step with the exact shell commands to run.

1. **"Sentry is down — start here"**
   - External health check failing? Internal health check failing?
   - SSH commands to run first
   - `docker compose ps` interpretation
   - Which containers are load-bearing vs cosmetic

2. **"Events are arriving but not showing up in the UI"**
   - Where events can get stuck (Relay → Kafka → consumer → Snuba → Clickhouse)
   - How to read Kafka consumer lag
   - How to restart consumer without losing events

3. **"Clickhouse disk is filling up"**
   - Current retention settings
   - How to shrink retention safely
   - How to trigger a manual cleanup

4. **"Kafka queue is backing up"**
   - When to worry, when not to
   - How to scale the worker / consumer containers
   - Emergency: draining the queue

5. **"How to upgrade Sentry"**
   - Read CHANGELOG for every tag between current pin and target
   - Dry-run: `docker compose pull` without `up`
   - Full-run: stop → `git checkout <new-tag>` in `/opt/sentry-upstream` → `./install.sh` → `docker compose up -d`
   - Rollback path if broken

6. **"How to rotate the Google OAuth client secret"**
   - Where the old value lives (GitHub Secret + config.yml on rishi-3)
   - Steps to rotate without locking users out

7. **"I've lost SSO access — how do I log in as a superuser?"**
   - SSH to rishi-3, `docker compose run --rm web createuser --superuser`
   - Fallback superuser Rishi keeps for exactly this

8. **"Backup / restore drill"**
   - How to manually trigger `scripts/backup.sh`
   - How to restore a specific date's snapshot to a test instance before touching prod

## Until Phase 9 ships

The fastest rollback for any issue is:

- Revert the `SENTRY_DSN` GitHub Secret on an affected service to the old `apm.yral.com` DSN and redeploy. Events flow back to Saikat's Sentry while we debug the self-hosted one.
- Sentry on rishi-3 can be left idle without harm — the containers keep running even if no services point at them.
