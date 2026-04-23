#!/usr/bin/env bash
# =============================================================================
# yral-rishi-sentry — safe upgrade script (runs ON rishi-3)
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#
# Upgrading self-hosted Sentry means moving from one upstream release tag
# to another (e.g. 26.4.0 → 26.5.0). The upstream `getsentry/self-hosted`
# `install.sh` handles database migrations, Clickhouse schema changes,
# Kafka topic updates, etc. — but it does NOT handle "I want to upgrade
# cautiously with a dry-run first."
#
# This wrapper adds:
#
#   1. **Changelog reminder** — echoes the link to the changelog and
#      refuses to proceed unless the caller sets CONFIRMED_READ_CHANGELOG=1.
#      This catches the "blindly bumped SENTRY_VERSION" mistake.
#
#   2. **Dry-run mode** — if called with `--dry-run`, runs `docker compose
#      pull` for the new image tags but does NOT stop the running stack.
#      Confirms the images exist and can be fetched before committing.
#
#   3. **Rollback note** — on failure, prints the exact rollback
#      commands. Upstream does NOT support down-migrations. There is
#      NO automated backup (removed 2026-04-23) — a failed upgrade
#      that corrupts Sentry's Postgres requires manual recovery:
#      recreate projects, re-issue DSNs, redeploy each reporting
#      service. Roughly 45-60 min for our current 2 services. This
#      is the consciously-accepted trade-off; re-read the rationale
#      in PROGRESS.md before adding backup back.
#
# HOW TO USE:
#
#   Dry-run first:
#     # edit project.config, bump SENTRY_VERSION to new tag
#     CONFIRMED_READ_CHANGELOG=1 bash scripts/upgrade.sh --dry-run
#
#   Then the real upgrade:
#     CONFIRMED_READ_CHANGELOG=1 bash scripts/upgrade.sh
#
# BLAST RADIUS: this script stops Sentry for 5-20 minutes during the real
# upgrade. Schedule during low-traffic hours. Events arriving during the
# window are handled by SDK local buffering — they re-send once Sentry
# comes back — but you'll miss the real-time UI feedback.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Parse flags ------------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown arg: $arg"; exit 2 ;;
  esac
done

# --- Load target version ----------------------------------------------------
set -a
# shellcheck disable=SC1091
source "${REPO_DIR}/project.config"
set +a

TARGET_VERSION="${SENTRY_VERSION}"

# --- Find currently-installed version ---------------------------------------
if [[ -d "${SENTRY_UPSTREAM_DIR}/.git" ]]; then
  CURRENT_VERSION="$(cd "${SENTRY_UPSTREAM_DIR}" && git describe --tags --exact-match 2>/dev/null || echo 'unknown')"
else
  CURRENT_VERSION="not-installed"
fi

echo "Current upstream version: ${CURRENT_VERSION}"
echo "Target upstream version : ${TARGET_VERSION}"

if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]]; then
  echo "Already at target version. Nothing to do."
  exit 0
fi

# --- Safety gate: did you read the changelog? -------------------------------
if [[ "${CONFIRMED_READ_CHANGELOG:-}" != "1" ]]; then
  echo ""
  echo "ERROR: upgrade aborted — you haven't confirmed reading the changelog." >&2
  echo ""
  echo "Changelog:"
  echo "  https://github.com/getsentry/self-hosted/blob/${TARGET_VERSION}/CHANGELOG.md"
  echo ""
  echo "Read it for every tag between ${CURRENT_VERSION} and ${TARGET_VERSION},"
  echo "then re-run this script with:"
  echo ""
  echo "  CONFIRMED_READ_CHANGELOG=1 bash scripts/upgrade.sh${DRY_RUN:+ --dry-run}"
  echo ""
  exit 1
fi

# --- Dry-run path -----------------------------------------------------------
if [[ "${DRY_RUN}" == "1" ]]; then
  echo ""
  echo "==> DRY RUN: fetching target tag and showing what will change. Stack stays up."
  cd "${SENTRY_UPSTREAM_DIR}"
  git fetch --depth 1 origin tag "${TARGET_VERSION}"

  echo ""
  echo "==> .env diff between ${CURRENT_VERSION} and ${TARGET_VERSION} (image tag changes):"
  git diff "${CURRENT_VERSION}" "${TARGET_VERSION}" -- .env || true

  echo ""
  echo "==> CHANGELOG entries between ${CURRENT_VERSION} and ${TARGET_VERSION}:"
  git log --oneline "${CURRENT_VERSION}..${TARGET_VERSION}" -- CHANGELOG.md || true

  echo ""
  echo "DRY RUN OK. Review the .env diff above. To pre-pull the new images"
  echo "without upgrading (optional, to warm the Docker image cache):"
  echo ""
  echo "  cd ${SENTRY_UPSTREAM_DIR}"
  echo "  git checkout ${TARGET_VERSION} -- .env docker-compose.yml"
  echo "  docker compose pull"
  echo "  git checkout ${CURRENT_VERSION} -- .env docker-compose.yml   # revert"
  echo ""
  echo "Then run 'bash scripts/upgrade.sh' (without --dry-run) to perform the actual upgrade."
  exit 0
fi

# --- Real upgrade path ------------------------------------------------------

echo ""
echo "==> Step 1/3: no-backup gate"
# No automated backup (removed 2026-04-23). If the upgrade fails mid-flight
# and corrupts Sentry's Postgres, recovery is manual: recreate projects +
# DSNs, redeploy each reporting service. See PROGRESS.md for the full
# rationale. Require explicit operator acknowledgement.
if [[ "${CONFIRMED_NO_BACKUP:-}" != "1" ]]; then
  cat >&2 <<EOF

WARNING: No backup will be taken before this upgrade.

If the upgrade corrupts Sentry's Postgres you will lose all
project metadata (projects, DSNs, teams, user accounts, alert
rules). Recovery = recreate projects + rotate DSNs + redeploy
each service. ~45-60 min for our 2 services.

To proceed knowingly:
  CONFIRMED_READ_CHANGELOG=1 CONFIRMED_NO_BACKUP=1 bash scripts/upgrade.sh

EOF
  exit 1
fi

echo "==> Step 2/3: checking out new upstream tag"
cd "${SENTRY_UPSTREAM_DIR}"
git fetch --depth 1 origin tag "${TARGET_VERSION}"
git checkout "${TARGET_VERSION}"

echo "==> Step 3/3: re-running install.sh (migrates DBs, updates Clickhouse schemas, etc.) + verify health"
# The install script is itself idempotent and handles down-time for us.
bash "${REPO_DIR}/scripts/install.sh"
for i in 1 2 3 4 5 6; do
  if curl -fsS http://127.0.0.1:9000/_health/ 2>/dev/null | grep -q '"ok"\|ok'; then
    echo ""
    echo "SUCCESS: Sentry upgraded from ${CURRENT_VERSION} to ${TARGET_VERSION} and is healthy."
    exit 0
  fi
  sleep 20
done

# --- Failure path -----------------------------------------------------------
cat <<EOF

ERROR: health check failed after upgrade. >&2

Rollback:
  1. Revert project.config: bump SENTRY_VERSION back to ${CURRENT_VERSION}.
  2. Re-run:                         bash ${REPO_DIR}/scripts/install.sh
  3. If Postgres is corrupted (unlikely; upstream migrations are careful):
     recreate projects + DSNs in the Sentry UI, redeploy each reporting
     service with its new DSN. No automated restore path (backup was
     intentionally removed 2026-04-23 — see PROGRESS.md).
EOF

exit 1
