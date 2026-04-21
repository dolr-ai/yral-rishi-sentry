# SCALING.md — when and how to grow Sentry past rishi-3

## The honest framing

Self-hosted Sentry is a 30-container stack with multiple stateful components (Postgres, Clickhouse, Kafka, Zookeeper). "Auto-scaling" it transparently — in the sense that chat-ai or a stateless FastAPI service can be auto-scaled — is not realistic and not worth the operational cost at our scale. This document describes the **manual** scaling path: a runbook for growing Sentry in a controlled way when rishi-3 runs out of room.

## Monitoring thresholds — act when ANY of these trips

The `.github/workflows/health-check.yml` watchdog catches total-outage cases but is intentionally narrow. The thresholds below are capacity signals that should drive planning, not emergency response. When one trips for a sustained period, plan the migration — don't scramble.

| Signal | Threshold | Why it matters | Where to check |
|---|---|---|---|
| rishi-3 available RAM | < 15 GB for > 10 min | Sentry's own working-set (container heaps + kernel caches) will starve the Patroni follower also on rishi-3 | `free -h` on rishi-3 |
| rishi-3 disk `/` usage | > 75 % | Clickhouse + Kafka grow silently; 75 % gives 1–2 weeks of runway | `df -h /` on rishi-3 |
| Sentry event ingestion lag | > 60 s sustained | Relay → Kafka → consumer is bottlenecked; events arriving don't show in UI immediately | Sentry UI "Admin → Queue" page, or `kafka-consumer-groups.sh --describe` |
| chat-ai P95 latency regresses with no code change | any upward drift | Sentry disk IO is bleeding into Patroni's disk IO on the same NVMe | Sentry Performance tab for chat-ai |

## Option A (preferred) — migrate Sentry to a dedicated rishi-4

When the thresholds above trip, this is the path.

**Pre-flight:**

1. Provision rishi-4 via the existing template tooling:
   ```
   # From inside yral-rishi-hetzner-infra-template:
   bash scripts/add-server.sh --name rishi-4 --ip <NEW_IP>
   ```
   This creates the deploy user, installs Docker, joins the Swarm as a worker, and opens the needed ports. Matches the pattern used for rishi-1/2/3.
2. Verify rishi-4 has **at least** 32 GB RAM, 500 GB disk, and is in the same Hetzner datacentre as rishi-3 (for low-latency rsync of volumes).

**Migration steps** (end-to-end, 2–3 hour maintenance window):

1. **Freeze incoming events briefly:**
   ```
   # On rishi-3, stop Relay so new events don't arrive mid-copy:
   ~/yral-rishi-sentry/scripts/sentry-admin.sh stop relay nginx
   ```
   Services sending to Sentry will transparently retry their SDK buffers when Sentry comes back.

2. **Take a fresh backup:**
   ```
   # From your laptop:
   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
     bash scripts/backup.sh
   ```
   Belt-and-braces. If the rsync goes wrong, we have a known-good point to restore from.

3. **Stop Sentry on rishi-3, preserving volumes:**
   ```
   ~/yral-rishi-sentry/scripts/sentry-admin.sh down
   ```

4. **rsync the volumes from rishi-3 → rishi-4.** This is the bulk of the wall-clock time.
   ```
   ssh deploy@rishi-3 \
     'sudo rsync -avz --compress-level=1 /var/lib/docker/volumes/sentry-* deploy@rishi-4:/var/lib/docker/volumes/'
   ```
   Expect 30–90 min depending on event-history size. Progress shows per-file.

5. **Update rishi-4 with the Sentry repo + `.env.custom`:**
   ```
   git clone https://github.com/dolr-ai/yral-rishi-sentry ~/yral-rishi-sentry
   # Copy .env.custom from rishi-3 (NOT re-generated — we want the same
   # system secret key so existing sessions + stored config remain valid):
   scp deploy@rishi-3:/home/deploy/sentry-upstream/.env.custom \
       deploy@rishi-4:/tmp/.env.custom.rishi3
   # On rishi-4:
   mv /tmp/.env.custom.rishi3 ~/sentry-upstream/.env.custom
   ```

6. **Run install.sh on rishi-4:**
   ```
   ssh deploy@rishi-4
   cd ~/yral-rishi-sentry
   export GOOGLE_CLIENT_ID='...'     # value from .env.custom
   export GOOGLE_CLIENT_SECRET='...'
   bash scripts/install.sh
   ```
   Because the volumes were rsync'd with the same secret key, Sentry comes up with identical state.

7. **Attach rishi-4 to the sentry-web overlay:**
   ```
   # Sentry nginx's compose override already declares `sentry-web` as an
   # external network. When compose up runs on rishi-4, Docker auto-joins
   # the Swarm overlay. Verify:
   ssh deploy@rishi-4 'docker inspect sentry-self-hosted-nginx-1 --format "{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}"'
   ```

8. **Flip Caddy on rishi-1 + rishi-2 from rishi-3 → rishi-4:**
   The Caddy snippets resolve `sentry-self-hosted-nginx-1` via Swarm DNS (not by host IP), so NO Caddy edit needed — the overlay automatically routes to whichever node is running the container. That's the beauty of the overlay pattern.

   However, double-check attachment: `ssh deploy@rishi-1 'docker exec caddy wget -qO- --timeout=3 http://sentry-self-hosted-nginx-1/_health/'`.

9. **Confirm from outside:** `curl https://sentry.rishi.yral.com/_health/` → `ok`. UI loads normally.

10. **48-hour cold-standby on rishi-3:** don't delete the old volumes right away. Keep rishi-3's Sentry containers stopped but present. If anything's wrong, we can flip back by running `up -d` on rishi-3 and `down` on rishi-4.

11. **After 48 h of clean operation on rishi-4:** run `scripts/sentry-admin.sh down -v` on rishi-3 to remove volumes. Reclaims ~50–200 GB depending on event history.

12. **Update `project.config` in this repo** to change `SENTRY_HOST=rishi-3` → `SENTRY_HOST=rishi-4`, commit, push. Future scripts now target rishi-4 by default.

## Option B — component-level scale-out (tier 2)

Applies only if the bottleneck is specifically Sentry's **workers** or **consumers** (stateless) — NOT Clickhouse, Postgres, or Kafka (stateful).

If only `taskworker`, `events-consumer`, or `snuba-*-consumer` are saturated:

1. Don't migrate the whole stack. Keep stateful services on rishi-3.
2. Add rishi-4 to the Swarm as a worker (step 1 of Option A).
3. Convert the saturated services from docker-compose to Swarm services with `replicas: 2`, pinned one per host.
4. The new instance on rishi-4 processes in parallel with rishi-3.

**When to reach for this:** Performance tab shows ingest lag, but RAM + disk on rishi-3 are still comfortable. Rare in practice — usually the stateful side fills up first.

## Option C — tune down, don't scale out

Before migrating, try:
- Dropping `SENTRY_EVENT_RETENTION_DAYS` from 90 to 30 (see RUNBOOK playbook 4). Reclaims Clickhouse disk immediately.
- Dropping `traces_sample_rate` in chat-ai from 1.0 to 0.25. Cuts performance-event volume by 4×.
- Enabling Sentry's inbound filter rules (Settings → Inbound Filters) to drop noisy browser extensions, localhost, etc.

A lot of "Sentry is slow" issues resolve at this tier.

## Current state (2026-04-21)

rishi-3 headroom per PRE-FLIGHT.md + observed usage: 3× RAM margin, 7× disk margin. No migration pressure today. This file exists as a pre-written playbook so future-Rishi has a plan ready rather than scrambling under stress.
