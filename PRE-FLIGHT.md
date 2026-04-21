# Phase 1 — Pre-flight capacity report for rishi-3

**Captured:** 2026-04-21 09:09:33 UTC+02:00
**Host:** rishi-3 — `deploy@136.243.147.225`
**Captured by:** SSH session from Rishi's Mac, read-only commands only.

## Why this report exists

Sentry self-hosted has a published minimum resource requirement (roughly 4 CPU / 16 GB RAM / 20 GB disk for the software alone, more in practice once Clickhouse + Kafka start accumulating events). We agreed to colocate Sentry on rishi-3 rather than provisioning a new Hetzner node. Before committing to that choice we had to prove rishi-3 actually has the headroom — otherwise we'd discover it mid-install when things start OOM-killing, which would also take down the Patroni follower that already lives there.

This report is that proof.

## Acceptance gates (from the plan)

All three gates must hold, otherwise the plan says stop and escalate to provisioning rishi-4.

| Gate | Threshold | Measured | Pass? |
|---|---|---|---|
| Free RAM | ≥ 20 GB | **61 GB available** (of 62 GB total) | YES (3× margin) |
| Free disk on `/` | ≥ 120 GB | **857 GB available** (of 954 GB; 10 % used) | YES (7× margin) |
| 1-min load average | < 2.0 | **0.34** | YES |

Result: all three gates PASS. Proceed to Phase 2.

## Raw evidence

### Memory

```
               total        used        free      shared  buff/cache   available
Mem:            62Gi       1.5Gi        46Gi        28Mi        15Gi        61Gi
Swap:             0B          0B          0B
```

Two things to note:

1. **1.5 GB used** by the current workload (3× etcd + 3× Patroni + beszel-agent + system services). Sentry will add roughly 15–25 GB at steady state with low traffic, rising with event volume. Still far under the 62 GB ceiling.
2. **0 B swap.** Hetzner's default — no swap file configured. If Sentry ever OOMs under a burst there is no soft-landing; the kernel OOM-killer will just kill a container. Mitigation (deferred per Rishi's direction 2026-04-21, revisit as capacity tightens): `fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` plus a `/etc/fstab` entry. One minute of work, no service impact.

### Disk

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme1n1p1  954G   96G  857G  10% /
```

Single NVMe SSD, single root partition. No separate `/var` or `/data`. Sentry's Postgres, Clickhouse, and Kafka will all share this disk with Patroni's WAL and etcd's data. Headroom is fine (857 GB free); IO contention is the thing to watch, not space.

### CPU

```
8 cores — Intel(R) Core(TM) i7-6700 CPU @ 3.40GHz
```

This is the older Hetzner bare-metal "EX line" consumer CPU (Skylake, 2015). It's adequate but not generous — 8 cores with no hyperthreading at ~3.4 GHz. Sentry's upstream recommends 4 CPU for 20 events/second; we're well within that envelope today.

### Load

```
09:09:33 up 2 days,  3:42,  1 user,  load average: 0.34, 0.27, 0.15
```

Machine is barely working. Uptime 2 days (last reboot was the cluster-wide one on 2026-04-19 noted in memory).

### vmstat (1-second samples)

```
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 0  0      0 48463616   3188 16305912    0    0    13   327 2468    5  1  0 99  0
 1  0      0 48465884   3188 16306088    0    0     0     0 2630 4294  0  1 99  0
```

99 % idle. No disk IO wait. No swap activity.

### Docker containers currently running

```
chat-ai-db_patroni-rishi-3.1                        Up 22 minutes
rishi-hetzner-infra-template-db_patroni-rishi-3.1   Up 19 hours
beszel-agent                                        Up 2 days
rishi-hetzner-infra-template-db_etcd-rishi-3.1      Up 2 days
chat-ai-db_etcd-rishi-3.1                           Up 2 days
counter-db_etcd-rishi-3.1                           Up 2 days
counter-db_patroni-rishi-3.1                        Up 2 days
```

Seven containers. Three Patroni followers, three etcd nodes (one per stack), and the beszel monitoring agent. All Swarm services (managed by Docker Swarm's reconciliation loop, not by `restart: always`).

### OS / kernel

```
Ubuntu 24.04.4 LTS
Kernel: 6.8.0-110-generic
```

Matches rishi-1 and rishi-2 per memory (the 2026-04-19 reboot investigation).

## Sign-off

Gates passed. We can proceed to Phase 2 (install Sentry 26.4.0 via the pinned `getsentry/self-hosted` compose stack) without provisioning a new node.

## What will trigger a re-evaluation

Per `SCALING.md` (to be written in Phase 10), we re-run this check if any of the following happen:

- rishi-3 available RAM drops below 15 GB sustained for > 10 min.
- rishi-3 disk usage crosses 75 %.
- Sentry event ingestion lag > 60 s sustained.
- chat-ai or any tenant on rishi-1/rishi-2 starts seeing P95 latencies degrade with no code change (Sentry disk IO bleeding over).

At that point the migration-to-rishi-4 runbook kicks in.
