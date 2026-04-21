#!/usr/bin/env bash
# =============================================================================
# backup.sh — manual / on-demand Sentry DB backup (runs from any host with SSH)
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Takes a one-off backup of Sentry's Postgres (issue metadata, projects,
#   users, DSNs, etc.) and uploads it to Hetzner Object Storage at
#   s3://rishi-yral/yral-rishi-sentry/daily/<timestamp>.sql.gz — the same
#   bucket + prefix as the scheduled daily backup (.github/workflows/backup.yml)
#   so both sources of backup land in the same place and restore.sh treats
#   them uniformly.
#
# WHEN TO RUN:
#   - Before a Sentry version upgrade (scripts/upgrade.sh already calls
#     this as a pre-flight; verify it's executable on rishi-3 first).
#   - Before any destructive operation (docker volume rm, manual SQL, etc.).
#   - If the scheduled daily backup has been failing and you want to get
#     a known-good snapshot now while you debug the workflow.
#
# REQUIRES:
#   - SSH access to rishi-3 as the deploy user.
#   - aws-cli installed on the host running this script (Mac + homebrew, or
#     the GitHub runner, or any Ubuntu box).
#   - Env vars AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY set to the
#     Hetzner Object Storage credentials (same ones the CI workflow uses).
#
# USAGE:
#   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... bash scripts/backup.sh
#
# WHY NOT SSH IN AND RUN pg_dump ON rishi-3:
#   Could — but then the dump file sits on rishi-3 and we'd have to scp
#   it back. Streaming the dump over SSH + gzipping on the client side +
#   uploading directly to S3 is simpler (no intermediate files on rishi-3,
#   which is the smallest-disk of our three hosts).
# =============================================================================

set -euo pipefail

# Sensible defaults — can be overridden by env var for testing.
SENTRY_HOST="${SENTRY_HOST:-136.243.147.225}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/rishi-hetzner-ci-key}"
S3_ENDPOINT="${S3_ENDPOINT:-https://hel1.your-objectstorage.com}"
S3_BUCKET="${S3_BUCKET:-rishi-yral}"
S3_PREFIX="${S3_PREFIX:-yral-rishi-sentry/daily}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-hel1}"

# Preflight.
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required (Hetzner S3 access key)}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required (Hetzner S3 secret key)}"
[[ -f "$SSH_KEY" ]] || { echo "ERROR: SSH key $SSH_KEY not found" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws-cli not on PATH. Install with brew install awscli" >&2; exit 1; }

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

TS="$(date -u +%Y-%m-%d_%H%M%S)"
DUMP_FILE="sentry-${TS}.sql.gz"

echo "==> Streaming pg_dump from rishi-3 → gzip → local ${DUMP_FILE}"
# Mirrors the workflow's command — single-source-of-truth of the exact
# pg_dump invocation. If this ever changes, update .github/workflows/backup.yml
# at the same time.
ssh -i "$SSH_KEY" -o BatchMode=no "deploy@${SENTRY_HOST}" \
  "cd /home/deploy/sentry-upstream && docker compose --env-file .env --env-file .env.custom exec -T postgres pg_dump -U postgres sentry" \
  | gzip -9 > "${DUMP_FILE}"

SIZE=$(stat -f%z "${DUMP_FILE}" 2>/dev/null || stat -c%s "${DUMP_FILE}")
echo "    dump size: ${SIZE} bytes"
if [[ "$SIZE" -lt 1024 ]]; then
  echo "ERROR: dump is suspiciously small (< 1 KB). pg_dump likely failed." >&2
  exit 1
fi

echo "==> Uploading to s3://${S3_BUCKET}/${S3_PREFIX}/${DUMP_FILE}"
aws s3 cp \
  --endpoint-url "$S3_ENDPOINT" \
  "${DUMP_FILE}" \
  "s3://${S3_BUCKET}/${S3_PREFIX}/${DUMP_FILE}"

echo "==> Cleaning up local dump file"
rm -f "${DUMP_FILE}"

echo ""
echo "DONE. Backup key: ${S3_PREFIX}/${DUMP_FILE}"
echo "To restore from this specific dump: bash scripts/restore.sh ${TS}"
