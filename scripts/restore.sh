#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore Sentry's Postgres from an S3 backup
# =============================================================================
#
# DESTRUCTIVE. RUN ONLY AFTER READING THE FULL HEADER.
#
# WHAT THIS SCRIPT DOES:
#   1. Downloads the specified backup from Hetzner Object Storage to the
#      operator's laptop (or wherever this script runs).
#   2. SCPs the gzipped dump to rishi-3.
#   3. Stops the Sentry stack on rishi-3 with `docker compose down` (keeps
#      volumes — does NOT destroy data yet).
#   4. Starts ONLY the postgres service.
#   5. Drops the existing `sentry` database and recreates it empty.
#   6. Pipes the dump into `psql` to restore.
#   7. Restarts the full Sentry stack.
#   8. Runs a health check — fails loudly if Sentry doesn't come back.
#
# WHAT THIS SCRIPT DOES NOT DO:
#   - Restore Clickhouse events / transactions. Those are lost (or rolled
#     back to whatever Kafka still has buffered). If you need them, snapshot
#     Clickhouse via its own backup tool BEFORE any restore operation.
#   - Restore Sentry's "in-flight" unprocessed events. Relay → Kafka events
#     that hadn't been consumed at the time of the backup are gone.
#   - Rotate any credentials. If the restore is happening because of a
#     breach, rotate SENTRY_SYSTEM_SECRET_KEY + every DSN separately.
#
# WHEN TO USE THIS:
#   - Data loss event: someone ran destructive SQL, or Postgres corruption.
#   - Upgrade rollback: Sentry version bumped, schema migrations failed
#     mid-way, we want to go back to yesterday's snapshot.
#   - Disaster recovery drill: quarterly test of the restore path.
#
# WHEN NOT TO USE THIS:
#   - Normal Sentry UI problems. Reloading the UI, checking logs, or
#     restarting web/worker does NOT need a DB restore.
#   - "Sentry is slow". That's a Clickhouse / Kafka problem, not Postgres.
#
# USAGE:
#   bash scripts/restore.sh <TIMESTAMP>
#     where TIMESTAMP matches a dump filename's timestamp portion:
#       sentry-YYYY-MM-DD_HHMMSS.sql.gz → use YYYY-MM-DD_HHMMSS
#
#   To list available backups first:
#     AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... aws s3 ls \
#       --endpoint-url https://hel1.your-objectstorage.com \
#       s3://rishi-yral/yral-rishi-sentry/daily/
#
# REQUIRES:
#   - SSH access to rishi-3 (same key as backup.sh).
#   - aws-cli locally.
#   - Env vars AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY.
#   - Confirmation: the script refuses to run without CONFIRMED_DESTRUCTIVE=1.
#     This is belt-and-braces against accidental invocation.
# =============================================================================

set -euo pipefail

# Defaults identical to backup.sh — keep the two in sync.
SENTRY_HOST="${SENTRY_HOST:-136.243.147.225}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/rishi-hetzner-ci-key}"
S3_ENDPOINT="${S3_ENDPOINT:-https://hel1.your-objectstorage.com}"
S3_BUCKET="${S3_BUCKET:-rishi-yral}"
S3_PREFIX="${S3_PREFIX:-yral-rishi-sentry/daily}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-hel1}"

# Argument: timestamp to restore.
if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <TIMESTAMP>" >&2
  echo "  Example: $(basename "$0") 2026-04-21_030003" >&2
  exit 2
fi
TIMESTAMP="$1"
DUMP_KEY="sentry-${TIMESTAMP}.sql.gz"

# Safety gate.
if [[ "${CONFIRMED_DESTRUCTIVE:-}" != "1" ]]; then
  cat >&2 <<EOF
ERROR: This script drops and recreates Sentry's Postgres DB. All data
created since ${TIMESTAMP} will be lost — issues, resolutions, alert
rule tweaks, new user accounts, DSN rotations, everything.

To proceed, re-run with:

  CONFIRMED_DESTRUCTIVE=1 bash $0 ${TIMESTAMP}

Cancel if you're not sure. "I ran restore.sh by accident" is not a
recoverable situation.
EOF
  exit 1
fi

# Preflight.
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required}"
[[ -f "$SSH_KEY" ]] || { echo "ERROR: $SSH_KEY not found" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws-cli not on PATH" >&2; exit 1; }

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

echo "==> Step 1/8 — Download ${DUMP_KEY} locally"
aws s3 cp \
  --endpoint-url "$S3_ENDPOINT" \
  "s3://${S3_BUCKET}/${S3_PREFIX}/${DUMP_KEY}" \
  "/tmp/${DUMP_KEY}"

echo "==> Step 2/8 — SCP to rishi-3"
scp -i "$SSH_KEY" "/tmp/${DUMP_KEY}" "deploy@${SENTRY_HOST}:/tmp/${DUMP_KEY}"

# The remaining steps happen on rishi-3 in a single SSH session so the
# shell has the env vars from project.config + .env.custom loaded once.
echo "==> Steps 3–8 — executing restore on rishi-3 (this takes 2–10 min)"
# shellcheck disable=SC2087
ssh -t -i "$SSH_KEY" "deploy@${SENTRY_HOST}" bash -s <<REMOTE_RESTORE
set -euo pipefail
cd /home/deploy/sentry-upstream

echo "    [3/8] docker compose down (keeping volumes)"
docker compose --env-file .env --env-file .env.custom down

echo "    [4/8] start ONLY the postgres service so we can restore into it"
docker compose --env-file .env --env-file .env.custom up -d postgres
# Wait for postgres healthcheck to pass — otherwise the DROP will race.
for i in \$(seq 1 12); do
  if docker compose --env-file .env --env-file .env.custom exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo "    [5/8] DROP + CREATE sentry database"
docker compose --env-file .env --env-file .env.custom exec -T postgres psql -U postgres -c "DROP DATABASE IF EXISTS sentry;"
docker compose --env-file .env --env-file .env.custom exec -T postgres psql -U postgres -c "CREATE DATABASE sentry OWNER postgres;"

echo "    [6/8] pipe dump into psql"
gunzip -c "/tmp/${DUMP_KEY}" | docker compose --env-file .env --env-file .env.custom exec -T postgres psql -U postgres sentry >/tmp/restore.log 2>&1

echo "    [7/8] docker compose up -d --force-recreate (full stack)"
docker compose --env-file .env --env-file .env.custom up -d --force-recreate

echo "    [8/8] cleanup"
rm -f "/tmp/${DUMP_KEY}" /tmp/restore.log
REMOTE_RESTORE

echo "==> Waiting for /_health/ to return ok"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if curl -sS --max-time 5 https://sentry.rishi.yral.com/_health/ | grep -q ok; then
    echo "OK — Sentry is back up."
    rm -f "/tmp/${DUMP_KEY}"
    echo ""
    echo "DONE. Restore from ${TIMESTAMP} complete."
    exit 0
  fi
  sleep 20
done

cat >&2 <<EOF
ERROR: Sentry did not come back to healthy after restore.

Diagnose on rishi-3:
  cd /home/deploy/sentry-upstream
  docker compose --env-file .env --env-file .env.custom ps
  docker compose --env-file .env --env-file .env.custom logs --tail=100 web
  cat /tmp/restore.log

Recovery:
  - If the dump was bad, try the previous day's dump.
  - If volumes are corrupted, wipe them and restart (scripts/install.sh
    will re-bootstrap the schema).
EOF
exit 1
