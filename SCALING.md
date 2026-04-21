# SCALING.md — how to grow Sentry when rishi-3 gets tight

> **Status (2026-04-21):** stub. Will be written in **Phase 10** of the rollout. The summary below captures the intent so Saikat can see we haven't forgotten his "orchestrator should expand dynamically" ask.

## The honest framing

True auto-scaling a self-hosted Sentry stack is **out of scope** for this rollout. Sentry's stateful components — Clickhouse, Kafka, Postgres — don't reshard transparently under Docker Swarm or any orchestrator without significant rework. Forcing it would be weeks of engineering for marginal benefit at our scale.

What we **can** do — and what Phase 10 will document — is:

1. **Detect when rishi-3 is tight** via thresholds added to the health-check workflow (see Phase 9).
2. **Have a tested runbook** to migrate Sentry to a dedicated rishi-4 node using the existing `scripts/add-server.sh` from the infra template.
3. **Scale out stateless components** (workers, relays) across multiple hosts when a bottleneck is specifically in those tiers — a tier-2 option, not the default.

## Thresholds (to be encoded in Phase 10)

When any of these trip for > 10 min, the runbook says "investigate within 24h, plan the migration."

| Signal | Threshold | Why |
|---|---|---|
| rishi-3 available RAM | < 15 GB | Sentry's own headroom gets eaten by kernel cache + bursts — < 15 GB means we're one event spike from OOM |
| rishi-3 `/` disk usage | > 75 % | Clickhouse + Kafka grow silently; 75 % gives us weeks to plan, not hours to panic |
| Sentry event ingestion lag | > 60 s sustained | Lag means relay → kafka → consumer is bottlenecked; first thing to try is scale workers, second is migrate |
| chat-ai P95 request latency regresses with no code change | any | Sentry disk IO is bleeding into Patroni's disk IO on the same NVMe. This one is the smoking gun for "move off rishi-3" |

## Migration runbook (to be written)

Will be step-by-step, with every exact shell command, in Phase 10. Rough shape:

1. From the infra template repo: `bash scripts/add-server.sh --name rishi-4 --ip <new-IP>`. This provisions `deploy` user, Docker, UFW, and joins the Swarm.
2. Stop Sentry on rishi-3: `docker compose down` (kept the data volumes — not a destructive stop).
3. `rsync -av` the Sentry volumes (Postgres data, Clickhouse data, Kafka data) from rishi-3 to rishi-4. Expect 30–90 min depending on data size.
4. Flip Caddy snippets on rishi-1 + rishi-2 from `reverse_proxy rishi-3:9000` to `reverse_proxy rishi-4:9000`. `systemctl reload caddy`.
5. `docker compose up -d` on rishi-4. Verify `/_health/`.
6. Leave rishi-3 idle for 48h as a cold-standby in case something goes wrong, then tear the containers down.

## Tier-2: component-level scale-out (not default)

If the bottleneck is specifically Sentry workers (Celery consumers) — stateless, parallelisable — we can run more replicas across rishi-3 + rishi-4 without the full migration. Requires the `sentry-worker` service to be reshaped into a Swarm service rather than a Compose service. Document in Phase 10 but flag as "tier 2, only if worker saturation is the specific problem."

## Current state

rishi-3 has 3× RAM margin and 7× disk margin per PRE-FLIGHT.md. No migration pressure today. This file exists so that future-Rishi (or whoever inherits this service) has a plan ready rather than scrambling under stress.
