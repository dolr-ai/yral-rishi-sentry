# RUNBOOK.md — incident playbooks for yral-rishi-sentry

Step-by-step playbooks for common incidents on the self-hosted Sentry instance. Each section is self-contained — jump to the one that matches your symptom.

**Quick reference: which playbook do I need?**

| Symptom | Go to |
|---|---|
| `sentry.rishi.yral.com` unreachable (502, timeout, Cloudflare 522/523) | [1. Sentry is down — start here](#1-sentry-is-down--start-here) |
| `sentry.rishi.yral.com` returns 502 intermittently from one host only | [2. Caddy lost overlay attachment](#2-caddy-lost-overlay-attachment) |
| Events captured by SDK but not showing in UI | [3. Events arriving but not in UI](#3-events-arriving-but-not-in-ui) |
| Disk usage alert on rishi-3 / Sentry UI slow | [4. Clickhouse disk filling up](#4-clickhouse-disk-filling-up) |
| Performance tab stale, event backlog | [5. Kafka queue backing up](#5-kafka-queue-backing-up) |
| Planned Sentry version upgrade | [6. How to upgrade Sentry](#6-how-to-upgrade-sentry) |
| Google OAuth secret compromised / expiring | [7. Rotate Google OAuth client secret](#7-rotate-google-oauth-client-secret) |
| Can't sign in via Google, need emergency access | [8. Locked out of SSO — fallback login](#8-locked-out-of-sso--fallback-login) |
| Quarterly DR drill | [9. Backup / restore drill](#9-backup--restore-drill) |

**Host quick-connect:**
```bash
ssh -i ~/.ssh/rishi-hetzner-ci-key deploy@136.243.147.225   # rishi-3 (where Sentry lives)
ssh -i ~/.ssh/rishi-hetzner-ci-key deploy@138.201.137.181   # rishi-1 (Caddy, Swarm manager)
ssh -i ~/.ssh/rishi-hetzner-ci-key deploy@136.243.150.84    # rishi-2 (Caddy)
```

**One-stop admin wrapper (runs on rishi-3):**
```bash
~/yral-rishi-sentry/scripts/sentry-admin.sh <compose-subcommand>
# examples:
~/yral-rishi-sentry/scripts/sentry-admin.sh ps
~/yral-rishi-sentry/scripts/sentry-admin.sh logs --tail=100 web
~/yral-rishi-sentry/scripts/sentry-admin.sh exec -T web sentry config get auth-google.client-id
```

---

## 1. Sentry is down — start here

**Symptoms:** `curl https://sentry.rishi.yral.com/_health/` times out, returns non-200, or Cloudflare serves a 522/523/524.

**Diagnose in this order** (outside-in — stops at the first failing layer):

```bash
# 1a. Is the public URL reachable at all?
curl -sS -o /dev/null -w "HTTP %{http_code} total=%{time_total}s\n" https://sentry.rishi.yral.com/_health/

# 1b. Cloudflare → Caddy: skip Cloudflare's cache
curl -sS --resolve sentry.rishi.yral.com:443:138.201.137.181 https://sentry.rishi.yral.com/_health/

# 1c. Caddy → Sentry nginx: from inside a Caddy container
ssh deploy@138.201.137.181 'docker exec caddy wget -qO- --timeout=3 http://sentry-self-hosted-nginx-1/_health/'

# 1d. Sentry nginx → Sentry web: on rishi-3
ssh deploy@136.243.147.225 'curl -sS http://127.0.0.1:9000/_health/'

# 1e. Container status
ssh deploy@136.243.147.225 '~/yral-rishi-sentry/scripts/sentry-admin.sh ps' | grep -v healthy
```

**Interpretation:**
- 1a fails, 1b works → Cloudflare issue (check the Cloudflare dashboard).
- 1b fails, 1c works → Caddy issue on rishi-1 or rishi-2. Check `docker logs caddy` on the bad host.
- 1c fails, 1d works → Caddy can't reach nginx. Almost always [playbook 2](#2-caddy-lost-overlay-attachment).
- 1d fails → Sentry stack itself is broken. Continue below.

**If the Sentry stack is broken:**

```bash
ssh deploy@136.243.147.225
cd ~/sentry-upstream
~/yral-rishi-sentry/scripts/sentry-admin.sh ps --format 'table {{.Service}}\t{{.Status}}'
# Any container not "healthy"? Check its logs:
~/yral-rishi-sentry/scripts/sentry-admin.sh logs --tail=100 <service-name>
```

**Load-bearing containers** (if ANY of these is unhealthy, Sentry is down):
- `postgres` / `pgbouncer` — issue metadata, user accounts
- `clickhouse` — event storage
- `kafka` + `zookeeper` — ingest queue
- `relay` — first hop for every event
- `web` — the UI
- `nginx` — reverse proxy in front of web

**Fastest recovery** (when in doubt):

```bash
ssh deploy@136.243.147.225
~/yral-rishi-sentry/scripts/sentry-admin.sh up -d --force-recreate
# Watch containers come healthy:
watch -n 5 '~/yral-rishi-sentry/scripts/sentry-admin.sh ps | grep -cv healthy'
```

If Sentry doesn't come back after a `--force-recreate`, escalate to Saikat and check the Docker daemon itself (`systemctl status docker`).

---

## 2. Caddy lost overlay attachment

**Symptom:** `sentry.rishi.yral.com` returns 502 from ONE of the two Caddy hosts intermittently, usually after a Caddy container restart.

**Cause:** `docker network connect sentry-web caddy` is a runtime-only attachment that doesn't persist across Caddy restarts. The crontab @reboot hook (installed by `scripts/bootstrap-caddy-reconnect.sh`) catches BOOT restarts, but an ad-hoc `docker restart caddy` or a cluster-wide Caddy image upgrade loses the attachment until we reconnect.

**Confirm:**

```bash
ssh deploy@138.201.137.181   # rishi-1 (try rishi-2 if symptom comes from there)
docker inspect caddy --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# sentry-web should be in the list.
```

**Fix (30 seconds):**

```bash
# On the affected host:
/home/deploy/caddy-reconnect.sh
```

The script is idempotent — no-op if already attached, reattaches if not. Run on BOTH hosts if unsure which is affected.

**Permanent prevention:** root-cause fix tracked in `PROGRESS.md` under "Follow-up items for other repos" — migrating Caddy itself to a Swarm stack with declarative `networks:`. Out of scope for this repo.

---

## 3. Events arriving but not in UI

**Symptom:** SDK's `capture_exception` succeeds (`event_id` returned, SDK flush OK, nginx access logs show 200s on `/api/2/envelope/`) but the event doesn't appear in the Sentry UI even after 1–2 minutes.

**Cause:** events flow `SDK → nginx → relay → Kafka → consumer → Snuba → Clickhouse`. A stuck link in that chain doesn't fail the ingest — it just silently buffers. Default buffers can hold hours of data before backpressure propagates.

**Diagnose:**

```bash
ssh deploy@136.243.147.225
# Is relay healthy + forwarding?
~/yral-rishi-sentry/scripts/sentry-admin.sh logs --tail=50 relay | grep -iE "error|drop|retry"

# Is Kafka healthy?
~/yral-rishi-sentry/scripts/sentry-admin.sh exec -T kafka sh -c '/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list' | head -5

# Is the events consumer running + making progress?
~/yral-rishi-sentry/scripts/sentry-admin.sh logs --tail=50 events-consumer | tail -20

# Is the event actually in Clickhouse?
ssh deploy@136.243.147.225
docker exec sentry-self-hosted-clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM default.errors_local WHERE timestamp > now() - INTERVAL 10 MINUTE GROUP BY project_id"
```

**If event is in Clickhouse but not UI:** UI caching. Hard-refresh the browser (Cmd+Shift+R). Check the URL filter (`?project=N` matches your project_id?). Check the time range selector (top-right of Sentry UI — default is "Last 24 hours", sometimes gets stuck on "Last 1 hour" after a session).

**If event is NOT in Clickhouse:** Kafka consumer lag. See [playbook 5](#5-kafka-queue-backing-up).

---

## 4. Clickhouse disk filling up

**Symptom:** `df -h /` on rishi-3 shows `/` > 75 % full and the growth is in `/var/lib/docker/volumes/sentry-clickhouse`.

**Cause:** Clickhouse stores every ingested event for 90 days by default. High-traffic services can accumulate tens of GB per day.

**Immediate relief — reduce retention in Sentry's UI:**
1. Sign in as superuser, go to `/manage/settings/?query=cleanup`.
2. Adjust `system.event-retention-days` from 90 to (say) 30.
3. The cleanup cron runs nightly; old events start disappearing within 24 h.

**If disk is at 95 %+ and you can't wait for the nightly cleanup:**

```bash
ssh deploy@136.243.147.225
~/yral-rishi-sentry/scripts/sentry-admin.sh exec -T web sentry cleanup --days 30
```

This runs the retention cleanup immediately. Can take 30 min on a large instance.

**Permanent fix:** if retention + nightly cleanup isn't keeping up, the instance has outgrown rishi-3. See `SCALING.md` for the rishi-4 migration runbook.

---

## 5. Kafka queue backing up

**Symptom:** Sentry UI is several minutes behind real-time; events from 10 min ago still aren't visible; `kafka` container logs show retention/disk warnings.

**Diagnose consumer lag:**

```bash
ssh deploy@136.243.147.225
~/yral-rishi-sentry/scripts/sentry-admin.sh exec -T kafka sh -c \
  '/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups' \
  | grep -v "TOPIC\|^---" | awk '$5 > 1000'
# Any group with LAG > 1000 is actively behind.
```

**Typical culprits:**
- `events-consumer` lagging → restart the consumer: `~/yral-rishi-sentry/scripts/sentry-admin.sh restart events-consumer`.
- `snuba-errors-consumer` lagging → Clickhouse is slow. Check disk IO + CPU on clickhouse container: `~/yral-rishi-sentry/scripts/sentry-admin.sh exec -T clickhouse top -bn1 | head -20`.

**If restart doesn't clear the lag**, scale the consumer:

```bash
# Edit docker-compose.override.yml to add a deploy: replicas: 2 entry for the struggling service,
# then: ~/yral-rishi-sentry/scripts/sentry-admin.sh up -d
```

---

## 6. How to upgrade Sentry

**Pre-flight checklist** (do ALL of these before touching anything):

1. Read the upstream CHANGELOG between current pin and target tag:
   `https://github.com/getsentry/self-hosted/blob/<TARGET_TAG>/CHANGELOG.md`
   Look for: schema migrations, breaking config changes, Kafka topic changes, deprecated services.
2. Confirm there's a recent daily backup in S3 (`.github/workflows/backup.yml` should show green).
3. Schedule the upgrade for low-traffic hours. Sentry is down 5–20 min during the upgrade.

**Upgrade steps:**

```bash
# On your laptop:
cd ~/"Claude Projects/yral-rishi-sentry"
# Edit project.config: bump SENTRY_VERSION to the target tag, commit, push.

# Dry-run first — shows what would change without touching the running stack:
CONFIRMED_READ_CHANGELOG=1 bash scripts/upgrade.sh --dry-run

# If dry-run looks right, real upgrade:
CONFIRMED_READ_CHANGELOG=1 bash scripts/upgrade.sh
```

`scripts/upgrade.sh` takes a fresh backup first, then stops + upgrades + restarts. On failure it exits with the rollback commands printed.

**Rollback** (if upgrade fails):
1. Revert `SENTRY_VERSION` in `project.config` to the previous tag.
2. `bash scripts/install.sh` to check out the old tag + recreate containers.
3. `bash scripts/restore.sh <pre-upgrade-backup-timestamp>` if the schema is in a bad state.

---

## 7. Rotate Google OAuth client secret

**When to do this:**
- Scheduled rotation (recommend: every 6 months).
- Client secret leaked (saw it in a log, chat, screenshot).
- Employee with Google Cloud Console access leaves.

**Steps:**

1. Google Cloud Console → APIs & Services → Credentials → click into `Sentry web client` → **Reset Client Secret**. Copy the new secret (old one is invalidated immediately).
2. On rishi-3, update `.env.custom` via `install.sh` (preserves the system secret key while refreshing OAuth):
   ```
   ssh deploy@136.243.147.225
   export GOOGLE_CLIENT_ID='<existing-id-unchanged>'
   export GOOGLE_CLIENT_SECRET='<new-secret>'
   bash ~/yral-rishi-sentry/scripts/install.sh
   ```
3. Verify no-echo: `sentry config get` on `auth-google.client-id` will print the value; use `sentry config get auth-google.client-id | grep -c "^$"` instead to check presence, or hash the env var.

**If Google SSO breaks during rotation:** see [playbook 8](#8-locked-out-of-sso--fallback-login) immediately.

---

## 8. Locked out of SSO — fallback login

**Symptom:** Google SSO misconfigured, OAuth redirect broken, domain whitelist rejecting you — you can't log in via the browser.

**Fallback path:** the original superuser account (created via CLI by `sentry createuser --superuser --email rishi@gobazzinga.io`) still has a local email+password login that BYPASSES SSO.

**Steps:**

1. Open `https://sentry.rishi.yral.com/auth/login/` (the root `/` will redirect you to Google SSO; `/auth/login/` shows the email+password form).
2. Log in with `rishi@gobazzinga.io` + the local password (in Rishi's password manager, not Google).
3. Fix SSO: `/settings/sentry/auth/` → disable Google provider → re-enable once the config is correct.

**Preserve this fallback forever:** do NOT delete the local password for this account even after SSO works. It's your only un-SSO-dependent admin.

**If the local password is ALSO lost:** SSH to rishi-3 and create a fresh superuser, which gives you a new account you can use to unlock SSO:

```bash
ssh deploy@136.243.147.225
~/yral-rishi-sentry/scripts/sentry-admin.sh run --rm -it web createuser --email breakglass@gobazzinga.io --superuser
```

---

## 9. Backup / restore drill

**Quarterly exercise** to confirm backups are actually restorable. Run on a test instance, NOT production.

1. Provision a throwaway Hetzner box (or a local docker-compose stack of Sentry self-hosted).
2. Pick a recent daily backup key: `aws s3 ls --endpoint-url https://hel1.your-objectstorage.com s3://rishi-yral/yral-rishi-sentry/daily/ | tail -5`
3. On the test box, run:
   ```
   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... CONFIRMED_DESTRUCTIVE=1 \
     SENTRY_HOST=<test-box-ip> bash scripts/restore.sh <TIMESTAMP>
   ```
4. Confirm: UI loads, expected user count matches, issue IDs look reasonable.
5. Tear down the test instance.

Record the drill outcome in `PROGRESS.md` so we have a track record for incident post-mortems.
