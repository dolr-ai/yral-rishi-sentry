#!/bin/bash
# Nightly backup of what it takes to rebuild Sentry on any server (Rishi's
# choice, 2026-10-04: "fast rebuild", not Sentry in the swarm). Runs on the
# server that hosts Sentry, from cron.
#   1. Sentry's own Postgres (projects, users, DSN keys, alert rules): ~90 MB.
#   2. The install folders, including .env.custom (secret key, OAuth): ~5 MB.
# Error history (ClickHouse, Kafka, files) is deliberately not backed up.
# Keeps 14 nightly copies in Garage bucket sentry-backups.
set -euo pipefail
cd "$HOME/sentry"
{ read -r ID; read -r SEC; } < .garage_backup_key
ts=$(date -u +%Y%m%dT%H%M%SZ)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
docker exec sentry-self-hosted-postgres-1 pg_dump -U postgres -d postgres -Fc > "$tmp/sentry-postgres.dump"
tar czf "$tmp/sentry-install.tgz" --exclude='*.log' --exclude='sentry_install_log-*' sentry-upstream yral-rishi-sentry
s3() { docker run --rm --network yral-v2-data-plane -v "$tmp:/b" -e AWS_ACCESS_KEY_ID="$ID" -e AWS_SECRET_ACCESS_KEY="$SEC" -e AWS_DEFAULT_REGION=garage \
  amazon/aws-cli:2.17.0 --endpoint-url http://garage:3900 "$@"; }
s3 s3 cp /b/ "s3://sentry-backups/$ts/" --recursive --only-show-errors
# Keep the newest 14 nightly folders.
for old in $(s3 s3 ls s3://sentry-backups/ | awk '{print $2}' | sort | head -n -14); do
  s3 s3 rm "s3://sentry-backups/$old" --recursive --only-show-errors
done
echo "$(date -u +%FT%TZ) sentry backup $ts: $(du -sh "$tmp" | cut -f1)"
