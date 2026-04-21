#!/usr/bin/env bash
# =============================================================================
# yral-rishi-sentry — wrapper for one-off Sentry CLI admin commands
# =============================================================================
#
# WHAT THIS WRAPPER IS FOR:
#
# Any time you want to run a one-off `docker compose` command against the
# Sentry stack on rishi-3 — for example:
#
#   - Create a new superuser
#   - Change a user's password
#   - Drop into a Sentry shell (`sentry shell`)
#   - Run a cleanup (`sentry cleanup --days 30`)
#   - Inspect container logs
#
# ...you MUST have the shell env var SENTRY_SYSTEM_SECRET_KEY set before
# invoking docker compose. Upstream's docker-compose.yml declares
# `environment: SENTRY_SYSTEM_SECRET_KEY:` (bare form) which means
# "inherit from the host shell." A fresh SSH login shell does NOT have
# that var (it only lives in ~/sentry-upstream/.env.custom), so every
# `docker compose run ...` in a naked shell produces an ephemeral
# container with empty SECRET_KEY and Django fails on boot.
#
# This wrapper sources .env.custom into the shell, then execs whatever
# `docker compose` subcommand you pass to it, with all the right env
# vars already in place.
#
# HOW TO USE (on rishi-3):
#
#   ~/yral-rishi-sentry/scripts/sentry-admin.sh <docker-compose-subcommand> [args...]
#
# EXAMPLES:
#
#   # Create a new superuser
#   ~/yral-rishi-sentry/scripts/sentry-admin.sh run --rm web \
#       createuser --email you@gobazzinga.io --password 'hunter2' --superuser
#
#   # Reset a user's password (prompted interactively)
#   ~/yral-rishi-sentry/scripts/sentry-admin.sh run --rm web \
#       sentry django changepassword you@gobazzinga.io
#
#   # Tail web container logs
#   ~/yral-rishi-sentry/scripts/sentry-admin.sh logs -f web
#
#   # Check which services are healthy
#   ~/yral-rishi-sentry/scripts/sentry-admin.sh ps
#
# HOW TO USE (from your Mac via SSH):
#
#   ssh -i ~/.ssh/rishi-hetzner-ci-key deploy@<rishi-3-ip> \
#       "~/yral-rishi-sentry/scripts/sentry-admin.sh <subcommand> [args...]"
#
# SAFETY:
#
# This wrapper takes WHATEVER arguments you pass and hands them straight
# to `docker compose`. There is no allowlist — if you pass
# `down -v` it will destructively remove volumes. Read your command
# before running.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve paths. This script lives in <repo>/scripts/, sentry-upstream is a
# sibling directory of <repo> under the deploy user's home. We hard-code the
# relationship here so the script can be run from any working directory.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# Load project.config so we get SENTRY_UPSTREAM_DIR (same source-of-truth
# as install.sh uses).
# -----------------------------------------------------------------------------
set -a
# shellcheck disable=SC1091
source "${REPO_DIR}/project.config"
set +a

# -----------------------------------------------------------------------------
# Sanity check: Sentry must already be installed. If .env.custom doesn't
# exist, the wrapper can't populate the env vars and `docker compose` would
# create a broken container. Fail fast with a useful error.
# -----------------------------------------------------------------------------
ENV_CUSTOM="${SENTRY_UPSTREAM_DIR}/.env.custom"
if [[ ! -f "${ENV_CUSTOM}" ]]; then
  cat >&2 <<EOF
ERROR: ${ENV_CUSTOM} not found.

This wrapper needs .env.custom to populate SENTRY_SYSTEM_SECRET_KEY
before invoking docker compose. That file is written by scripts/install.sh
on the very first install. If it's missing, Sentry isn't installed.

Run: ~/yral-rishi-sentry/scripts/install.sh

EOF
  exit 1
fi

# -----------------------------------------------------------------------------
# Load .env.custom into this shell. `set -a` auto-exports each variable as
# it's assigned — after this block, SENTRY_SYSTEM_SECRET_KEY / GOOGLE_* /
# SENTRY_BIND are all exported and will propagate to docker compose, and
# from there into any `environment: KEY:` bare-form declarations in the
# compose file.
# -----------------------------------------------------------------------------
set -a
# shellcheck disable=SC1090
source "${ENV_CUSTOM}"
set +a

# -----------------------------------------------------------------------------
# At least one argument is required — there's nothing to pass to
# docker compose otherwise. Print usage hint and bail.
# -----------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  echo "Usage: $(basename "$0") <docker-compose-subcommand> [args...]" >&2
  echo "  See file header for examples." >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# cd to the compose project root (where docker-compose.yml lives) and exec.
# `exec` replaces this shell with docker compose so the wrapper adds zero
# overhead after env setup. "$@" forwards all arguments verbatim, including
# quoted values containing spaces.
# -----------------------------------------------------------------------------
cd "${SENTRY_UPSTREAM_DIR}"
exec docker compose "$@"
