#!/usr/bin/env bash
# =============================================================================
# yral-rishi-sentry — install / bootstrap script (runs ON rishi-3)
# =============================================================================
#
# WHAT THIS SCRIPT DOES, IN NUMBERED STEPS:
#
#   1. Sanity-check we're running on rishi-3 as the deploy user.
#   2. Load our project.config (SENTRY_VERSION, paths, etc.).
#   3. Clone `getsentry/self-hosted` at the pinned tag into
#      ${SENTRY_UPSTREAM_DIR} (default /opt/sentry-upstream) — or fast-forward
#      if already cloned to a different tag.
#   4. Copy our sentry/config.yml INTO the upstream sentry/ directory so
#      upstream's ensure-files-from-examples step keeps our version.
#   5. Append our sentry/sentry.conf.override.py to upstream's
#      sentry/sentry.conf.py (wrapped in markers for idempotent re-run).
#   6. Symlink our docker-compose.override.yml into the upstream root so
#      Compose auto-merges our resource limits + localhost bind.
#   7. Write `.env.custom` with the Google OAuth client ID + secret (read
#      from GitHub Secrets or the equivalent env vars on this shell).
#   8. Run upstream `./install.sh --skip-user-prompt` — this does the heavy
#      lifting: pulls images, generates Sentry's system.secret-key, migrates
#      Postgres, bootstraps Clickhouse and Snuba, etc. Takes 20-40 minutes
#      on first run.
#   9. Bring the stack up with `docker compose up -d`.
#  10. Verify `curl http://127.0.0.1:9000/_health/` returns "ok".
#
# HOW TO USE (first install):
#
#   On rishi-3, logged in as `deploy`:
#     cd /home/deploy/yral-rishi-sentry
#     export GOOGLE_CLIENT_ID="<from-GitHub-secret>"
#     export GOOGLE_CLIENT_SECRET="<from-GitHub-secret>"
#     bash scripts/install.sh
#
# HOW TO USE (re-run after config change):
#
#   Exactly the same command. The script is IDEMPOTENT — safe to run
#   repeatedly. On re-run it:
#     - leaves the upstream clone alone (unless SENTRY_VERSION changed,
#       in which case it checks out the new tag — that's the upgrade path,
#       handled more carefully by scripts/upgrade.sh)
#     - re-writes our config files (any local edits on rishi-3 get lost)
#     - re-runs upstream install.sh (which is itself idempotent)
#     - re-ups docker compose
#
# SAFETY: this script does NOT delete data volumes. `docker compose up -d`
# keeps existing Postgres/Clickhouse/Kafka state. Destructive operations
# (wiping a volume, rolling back a schema) are separate tools — see
# RUNBOOK.md once Phase 9 writes it.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Step 0: find the directory this script lives in, so we work with absolute
# paths regardless of where the user runs the script from.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# Step 1: sanity checks. Bail fast with a clear message rather than crashing
# halfway through.
# -----------------------------------------------------------------------------

# 1a. We need to be running on a Linux host with docker + docker compose v2.
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not on PATH. Aborting." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose v2 plugin not available. Run 'docker compose version' to debug." >&2
  exit 1
fi

# 1b. We need the two Google OAuth values in the environment. Without these
# Sentry will boot but SSO will be silently broken, which is worse than
# failing loudly.
: "${GOOGLE_CLIENT_ID:?GOOGLE_CLIENT_ID env var is required. Export it before running this script, or source it from ~/.config/yral-rishi-sentry/secrets.}"
: "${GOOGLE_CLIENT_SECRET:?GOOGLE_CLIENT_SECRET env var is required. See project.config commentary for where this comes from.}"

# -----------------------------------------------------------------------------
# Step 2: load project.config. `set -a` exports every variable the sourced
# file sets, so `$SENTRY_VERSION` etc. become available below.
# -----------------------------------------------------------------------------
set -a
# shellcheck disable=SC1091
source "${REPO_DIR}/project.config"
set +a

# -----------------------------------------------------------------------------
# Step 3: clone OR switch upstream to the pinned tag.
# -----------------------------------------------------------------------------
if [[ ! -d "${SENTRY_UPSTREAM_DIR}/.git" ]]; then
  echo "==> Cloning getsentry/self-hosted to ${SENTRY_UPSTREAM_DIR} at tag ${SENTRY_VERSION}"
  # --depth 1 keeps the clone small; we don't need upstream history on rishi-3.
  # --branch accepts a tag (it's a "ref").
  # No sudo: SENTRY_UPSTREAM_DIR is under the deploy user's home, so we
  # own it directly. See project.config for the rationale.
  mkdir -p "${SENTRY_UPSTREAM_DIR}"
  git clone --depth 1 --branch "${SENTRY_VERSION}" \
    https://github.com/getsentry/self-hosted "${SENTRY_UPSTREAM_DIR}"
else
  echo "==> Upstream clone exists at ${SENTRY_UPSTREAM_DIR}. Ensuring it's on tag ${SENTRY_VERSION}"
  cd "${SENTRY_UPSTREAM_DIR}"
  # fetch just the one tag we want (fast, cheap)
  git fetch --depth 1 origin tag "${SENTRY_VERSION}"
  git checkout "${SENTRY_VERSION}"
  cd "${REPO_DIR}"
fi

# -----------------------------------------------------------------------------
# Step 4: place our sentry/config.yml.
# -----------------------------------------------------------------------------
echo "==> Installing sentry/config.yml"
# `install -m 644` copies + sets permissions in one atomic step.
install -m 644 "${REPO_DIR}/sentry/config.yml" "${SENTRY_UPSTREAM_DIR}/sentry/config.yml"

# -----------------------------------------------------------------------------
# Step 5: append our sentry.conf.override.py to upstream's sentry.conf.py,
# idempotently. We use sentinel markers so re-running the script strips the
# old block and re-inserts the current one without duplicating.
# -----------------------------------------------------------------------------
echo "==> Appending sentry.conf.override.py to upstream sentry.conf.py"

UPSTREAM_CONF="${SENTRY_UPSTREAM_DIR}/sentry/sentry.conf.py"
BEGIN_MARKER="# --- BEGIN yral-rishi-sentry overrides ---"
END_MARKER="# --- END yral-rishi-sentry overrides ---"

# Upstream installs `sentry.conf.py` from `sentry.conf.example.py` only if
# `sentry.conf.py` doesn't already exist. If it doesn't exist yet (first
# install), copy the example so we have something to append to.
if [[ ! -f "${UPSTREAM_CONF}" ]]; then
  cp "${SENTRY_UPSTREAM_DIR}/sentry/sentry.conf.example.py" "${UPSTREAM_CONF}"
fi

# If a previous override block exists, strip it (everything between markers
# inclusive). `sed` in-place with a range deletion handles this cleanly.
if grep -qF "${BEGIN_MARKER}" "${UPSTREAM_CONF}"; then
  sed -i "/${BEGIN_MARKER}/,/${END_MARKER}/d" "${UPSTREAM_CONF}"
fi

# Append a fresh block: blank line, BEGIN marker, our overrides, END marker.
{
  echo ""
  echo "${BEGIN_MARKER}"
  cat "${REPO_DIR}/sentry/sentry.conf.override.py"
  echo "${END_MARKER}"
} >> "${UPSTREAM_CONF}"

# -----------------------------------------------------------------------------
# Step 6: symlink our docker-compose.override.yml. Compose auto-discovers it
# alongside docker-compose.yml.
# -----------------------------------------------------------------------------
echo "==> Linking docker-compose.override.yml"
ln -sf "${REPO_DIR}/docker-compose.override.yml" \
       "${SENTRY_UPSTREAM_DIR}/docker-compose.override.yml"

# -----------------------------------------------------------------------------
# Step 7: write .env.custom with our OAuth values. Upstream's install.sh
# creates/updates `.env` (system secrets, image pins); we own `.env.custom`
# which Compose reads AFTER `.env` so our values win.
# -----------------------------------------------------------------------------
echo "==> Writing .env.custom (Google OAuth + SENTRY_BIND override)"

ENV_CUSTOM="${SENTRY_UPSTREAM_DIR}/.env.custom"
cat > "${ENV_CUSTOM}" <<EOF
# Generated by scripts/install.sh on $(date -Iseconds).
# DO NOT EDIT BY HAND — your changes will be lost on the next install/upgrade.
# Source of truth for these values: GitHub Secrets on dolr-ai/yral-rishi-sentry.

# Google Workspace SSO credentials.
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}

# Force nginx to bind loopback only. Must match docker-compose.override.yml.
# Upstream uses SENTRY_BIND for the host port binding; setting it here
# ensures any upstream script that reads it (backup, health-check) uses
# the same port as our override.
SENTRY_BIND=127.0.0.1:9000
EOF
chmod 600 "${ENV_CUSTOM}"

# -----------------------------------------------------------------------------
# Step 8: run upstream's install.sh with the non-interactive flag.
# This is the long step (20-40 min on first run, 2-5 min on re-runs).
# -----------------------------------------------------------------------------
echo "==> Running upstream install.sh (this takes 20-40 min on first run)"
cd "${SENTRY_UPSTREAM_DIR}"
# Three flags needed for a fully non-interactive install (all three verified
# against upstream install/parse-cli.sh at tag 26.4.0):
#   --skip-user-creation           skip the "create first admin user" prompt.
#                                  We'll create the admin ourselves with an
#                                  explicit docker-compose command after
#                                  install finishes, so we can control the
#                                  password and it never lives in env vars.
#   --no-report-self-hosted-issues say NO to Sentry's telemetry opt-in. This
#                                  is a privacy choice — our internal infra
#                                  shouldn't phone home.
#   --apply-automatic-config-updates  let upstream silently apply any config
#                                  migrations it would otherwise prompt for.
#                                  Safe on first install (there's nothing to
#                                  migrate); on upgrades, scripts/upgrade.sh
#                                  gates this behind the dry-run + changelog
#                                  review so we never silently apply a
#                                  surprise config change.
./install.sh \
  --skip-user-creation \
  --no-report-self-hosted-issues \
  --apply-automatic-config-updates
cd "${REPO_DIR}"

# -----------------------------------------------------------------------------
# Step 9: bring the stack up.
# -----------------------------------------------------------------------------
echo "==> docker compose up -d"
(cd "${SENTRY_UPSTREAM_DIR}" && docker compose up -d)

# -----------------------------------------------------------------------------
# Step 10: verify health. Retry a few times since some containers take
# ~30 seconds to fully boot.
# -----------------------------------------------------------------------------
echo "==> Health check"
for i in 1 2 3 4 5 6; do
  if curl -fsS http://127.0.0.1:9000/_health/ 2>/dev/null | grep -q '"ok"\|ok'; then
    echo "SUCCESS: Sentry health endpoint returned ok."
    echo ""
    echo "Next steps:"
    echo "  - Create the first superuser:"
    echo "      cd ${SENTRY_UPSTREAM_DIR}"
    echo "      docker compose run --rm web createuser --email rishi@gobazzinga.io --password '<your-strong-password>' --superuser"
    echo "  - Open Phase 3 of the plan to wire Caddy on rishi-1 + rishi-2."
    exit 0
  fi
  echo "   attempt ${i}/6: not ready yet, sleeping 20s..."
  sleep 20
done

echo "ERROR: Sentry health endpoint did not return ok after 2 minutes." >&2
echo "Diagnose with:" >&2
echo "  cd ${SENTRY_UPSTREAM_DIR} && docker compose ps" >&2
echo "  cd ${SENTRY_UPSTREAM_DIR} && docker compose logs --tail=100 web relay nginx" >&2
exit 1
