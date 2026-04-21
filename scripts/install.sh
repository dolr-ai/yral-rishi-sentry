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
# Step 7: write .env.custom.
#
# Upstream install.sh calls Docker Compose with `--env-file .env.custom`
# (if .env.custom exists) which means Compose reads ONLY .env.custom for
# variable interpolation and for passing env vars to containers — it does
# NOT also read .env. So every container env var our services need MUST be
# in .env.custom, not just in .env.
#
# Specifically, Sentry's Django SECRET_KEY is read from the env var
# SENTRY_SYSTEM_SECRET_KEY (see upstream sentry/sentry.conf.example.py:
# `if env("SENTRY_SYSTEM_SECRET_KEY"): SENTRY_OPTIONS["system.secret-key"] = ...`).
# If that env var is empty, Django fails on startup with
# "The SECRET_KEY setting must not be empty."
#
# Upstream's own install/generate-secret-key.sh generates a key INTO
# sentry/config.yml (not into an env var) only if it finds the literal
# uncommented placeholder line `system.secret-key: '!!changeme!!'`. Our
# sentry/config.yml has that line commented out on purpose (we don't
# want a generated secret living in our git-tracked config file), so
# upstream's generator is a no-op for us.
#
# The fix: generate SENTRY_SYSTEM_SECRET_KEY ONCE on first install,
# persist it in .env.custom, and preserve it across re-runs so sessions
# don't get invalidated every time install.sh runs.
# -----------------------------------------------------------------------------
echo "==> Writing .env.custom"

ENV_CUSTOM="${SENTRY_UPSTREAM_DIR}/.env.custom"

# If a SENTRY_SYSTEM_SECRET_KEY is already in .env.custom from a previous
# install, keep it. Generating a new one every run would invalidate every
# logged-in session. We only generate on the VERY first install.
if [[ -f "${ENV_CUSTOM}" ]] && grep -q "^SENTRY_SYSTEM_SECRET_KEY=" "${ENV_CUSTOM}"; then
  echo "    preserving existing SENTRY_SYSTEM_SECRET_KEY from prior install"
  # `cut -d= -f2-` gets everything after the first `=`. We then strip one
  # layer of matching single-quotes if present (we always write the value
  # single-quoted, see below, but an externally-edited file might not be).
  SECRET_KEY="$(grep "^SENTRY_SYSTEM_SECRET_KEY=" "${ENV_CUSTOM}" | cut -d= -f2-)"
  # Strip leading/trailing single quotes if both present.
  if [[ "${SECRET_KEY}" == \'*\' ]]; then
    SECRET_KEY="${SECRET_KEY:1:-1}"
  fi
else
  echo "    generating new SENTRY_SYSTEM_SECRET_KEY (first install)"
  # WHY this alphabet? Three constraints to satisfy simultaneously:
  #   - Sentry accepts any byte string for SECRET_KEY (no real constraint).
  #   - Bash must safely source `KEY=VALUE` lines from .env.custom, which
  #     means the value must not contain shell metacharacters like
  #     `&`, `(`, `)`, `*`, `#`, `^`, `$`, backtick, `'`, `"`, `;`, `|`,
  #     newline, etc. Upstream uses `a-z0-9@#%^&*(-_=+)` which is NOT
  #     shell-safe and broke our source step in attempt 6.
  #   - Docker Compose's own env-file parser must also handle it cleanly.
  # The safe intersection: alphanumeric (upper+lower+digits) plus `-` and
  # `_`. That's 64 chars = 6 bits of entropy each. 50 chars = 300 bits of
  # entropy, which is 5x what Django needs for its SECRET_KEY.
  #
  # WHY python3? A `tr -dc '<set>' </dev/urandom | head -c 50` pipeline
  # triggers SIGPIPE on tr when head exits (see attempt 5 failure).
  # python3 is available on Ubuntu 24.04 (rishi-3's OS) and has no
  # pipe-semantics gotchas.
  SECRET_KEY="$(python3 -c 'import secrets, string
alphabet = string.ascii_letters + string.digits + "-_"
print("".join(secrets.choice(alphabet) for _ in range(50)))')"
fi

# Write the full .env.custom. This file is chmod 600 (owner read/write only)
# because it contains secrets (system key + Google OAuth client secret).
# Never commit this file to git — it's created at install time on rishi-3
# and lives only there.
#
# WHY single-quote every value? Belt-and-braces. Our current alphabet for
# the system key (a-zA-Z0-9-_) is already shell-safe so quotes aren't
# strictly needed. But the OAuth values come from GitHub Secrets which we
# don't control — if Google ever issues a client secret with a `&` or `*`
# we'd hit the same bash syntax error we saw in attempt 6. Single-quoting
# defensively makes this class of bug impossible. Docker Compose's
# env-file parser strips matching outer quotes, so there's no downside.
cat > "${ENV_CUSTOM}" <<EOF
# Generated by scripts/install.sh on $(date -Iseconds).
# DO NOT EDIT BY HAND — your changes will be lost on the next install/upgrade.
# Source of truth for OAuth values: GitHub Secrets on dolr-ai/yral-rishi-sentry.
# Source of truth for the secret key: this file itself — generated ONCE on
# first install and preserved across re-runs.

# Sentry's Django SECRET_KEY. Used to sign session cookies, CSRF tokens,
# password-reset links. Changing invalidates every currently-signed-in
# session (annoyance, not a security problem). Rotation procedure lives
# in RUNBOOK.md (Phase 9).
SENTRY_SYSTEM_SECRET_KEY='${SECRET_KEY}'

# Google Workspace SSO credentials (loaded into Sentry's auth-google.*
# settings at runtime — see sentry/config.yml in this repo for the
# interpolation references).
GOOGLE_CLIENT_ID='${GOOGLE_CLIENT_ID}'
GOOGLE_CLIENT_SECRET='${GOOGLE_CLIENT_SECRET}'

# Force nginx to bind loopback only. Upstream's docker-compose.yml maps
# "\${SENTRY_BIND}:80/tcp" so this value controls what port + interface
# the public nginx listens on inside rishi-3. Caddy on rishi-1/rishi-2
# is the only thing that should reach it.
SENTRY_BIND='127.0.0.1:9000'
EOF
chmod 600 "${ENV_CUSTOM}"

# Source .env.custom into OUR shell so subsequent commands (upstream's
# install.sh, and our docker-compose-up-d in step 9) inherit the values.
#
# WHY this is non-obvious: upstream's docker-compose.yml declares
# `environment: SENTRY_SYSTEM_SECRET_KEY:` (bare key, no value). In
# Compose V2 that form means "inherit from the SHELL environment of
# whatever process invoked `docker compose`." It does NOT auto-read
# from --env-file. --env-file is for YAML interpolation of `${VAR}`
# references, not for bare `environment: KEY:` entries.
#
# Without this sourcing, `docker compose up -d` passes empty
# SENTRY_SYSTEM_SECRET_KEY to web, web's Django initialization fails
# with "The SECRET_KEY setting must not be empty", and web stays
# unhealthy forever.
#
# `set -a` auto-exports every variable assigned until `set +a`, which
# is the sugar needed to turn .env.custom's KEY=VALUE lines into
# exported shell variables.
set -a
# shellcheck disable=SC1090
source "${ENV_CUSTOM}"
set +a

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
#
# --force-recreate is important for re-runs after a failed first install:
# if a container was created with a broken env (e.g. empty
# SENTRY_SYSTEM_SECRET_KEY before we fixed the env sourcing above),
# Compose's config-hash check doesn't always notice the bare-env-var
# change and would reuse the broken container. Forcing recreate every
# time is slightly slower (~30 seconds extra on a healthy install) but
# gives us a known-good container set on every install.sh run.
# -----------------------------------------------------------------------------
echo "==> docker compose up -d --force-recreate"
(cd "${SENTRY_UPSTREAM_DIR}" && docker compose up -d --force-recreate)

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
