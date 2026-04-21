#!/usr/bin/env bash
# =============================================================================
# yral-rishi-sentry — Caddy → sentry-web overlay re-attachment (runs on rishi-1/rishi-2)
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#
# Ensures the `caddy` Docker container on THIS host is attached to the
# `sentry-web` Swarm overlay network. If it's already attached, the script
# is a no-op (idempotent). If not, the script connects it.
#
# WHY THIS SCRIPT EXISTS:
#
# Caddy's attachment to the `sentry-web` overlay is a RUNTIME property of
# the container. It does NOT persist across container restarts. A reboot,
# crash, or `docker restart caddy` forgets the attachment, after which
# sentry.rishi.yral.com returns 502 from this host.
#
# The existing dolr-ai service template (yral-rishi-hetzner-infra-template)
# hides this same gap because `scripts/ci/deploy-app.sh` re-runs
# `docker network connect` on every app deploy — and services redeploy
# frequently. Sentry doesn't have that cadence (upgrades are monthly at
# most), so it needs a separate reconnect mechanism.
#
# HOW THIS SCRIPT IS TRIGGERED:
#
# 1. On boot of rishi-1/rishi-2, via the systemd unit
#    `sentry-caddy-reconnect.service` (installed by
#    scripts/bootstrap-caddy-reconnect.sh).
# 2. Manually by an operator after an unplanned Caddy restart
#    (see yral-rishi-sentry/RUNBOOK.md).
# 3. Optionally from any remote host via SSH if you want to reconcile
#    state quickly.
#
# WHERE THIS SCRIPT LIVES ON rishi-1 / rishi-2:
#
# `/home/deploy/caddy-reconnect.sh` — installed by
# `scripts/bootstrap-caddy-reconnect.sh`. The systemd unit points to this
# fixed path so the script has a stable home regardless of where (or
# whether) the yral-rishi-sentry repo is cloned on the host.
# =============================================================================

set -euo pipefail

# Defaults can be overridden via env var for testing.
NETWORK="${SENTRY_OVERLAY_NETWORK:-sentry-web}"
CONTAINER="${SENTRY_CADDY_CONTAINER:-caddy}"

# -----------------------------------------------------------------------------
# Preflight: network must exist, container must be running.
# -----------------------------------------------------------------------------

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "ERROR: Swarm overlay '$NETWORK' does not exist on this host." >&2
  echo "" >&2
  echo "On a Swarm manager, create it once with:" >&2
  echo "  docker network create --driver overlay --attachable $NETWORK" >&2
  exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container '$CONTAINER' not running on this host." >&2
  echo "This script is meant to run on rishi-1 or rishi-2 where Caddy is deployed." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Idempotent attach. `docker network inspect` lists currently-attached
# containers; we grep for caddy. If absent, attach.
# -----------------------------------------------------------------------------

attached_containers="$(docker network inspect "$NETWORK" \
    --format '{{range $k, $v := .Containers}}{{$v.Name}} {{end}}')"

if grep -qw "$CONTAINER" <<<"$attached_containers"; then
  echo "OK: $CONTAINER already attached to $NETWORK (no action)."
  exit 0
fi

echo "INFO: $CONTAINER is NOT attached to $NETWORK. Attaching now..."
docker network connect "$NETWORK" "$CONTAINER"

# -----------------------------------------------------------------------------
# Verify the attach worked. `docker network connect` exits 0 even if the
# connect call silently failed for some reason, so re-check.
# -----------------------------------------------------------------------------
attached_containers="$(docker network inspect "$NETWORK" \
    --format '{{range $k, $v := .Containers}}{{$v.Name}} {{end}}')"

if grep -qw "$CONTAINER" <<<"$attached_containers"; then
  echo "OK: $CONTAINER now attached to $NETWORK."
  exit 0
fi

echo "ERROR: attach reported success but $CONTAINER still not in attached list." >&2
echo "Containers currently attached to $NETWORK:" >&2
echo "  $attached_containers" >&2
exit 1
