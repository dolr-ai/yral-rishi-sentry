#!/usr/bin/env bash
# =============================================================================
# yral-rishi-sentry — bootstrap Caddy auto-reconnect on rishi-1 and rishi-2
# =============================================================================
#
# WHAT THIS SCRIPT DOES (one-time setup, run from Rishi's Mac):
#
# For each host in the list (rishi-1 + rishi-2):
#   1. scp caddy-reconnect.sh → /home/deploy/caddy-reconnect.sh
#   2. Install an `@reboot` entry in the deploy user's own crontab that
#      runs caddy-reconnect.sh on every boot. (Via crontab, not systemd,
#      because deploy doesn't have passwordless sudo on these hosts.)
#   3. Run caddy-reconnect.sh once to reconcile current state.
#
# WHY CRON NOT SYSTEMD:
#
# Installing a system-wide systemd unit under /etc/systemd/system/
# requires root access. The deploy user on rishi-1/rishi-2 does NOT
# have passwordless sudo (only Saikat holds the sudo password). An
# earlier version of this script tried sudo and locked Rishi out of
# running the bootstrap at all.
#
# cron @reboot is the well-worn Linux equivalent: it runs arbitrary
# commands at boot under the user's own identity, with no elevated
# privileges needed. cron is installed by default on Ubuntu 24.04.
# caddy-reconnect.sh itself runs `docker network connect` which needs
# access to the Docker socket; the deploy user is already in the
# `docker` group (since that's how services deploy), so that works.
#
# Limitation: cron @reboot fires when the `cron` service starts, which
# is not strictly ordered after `docker.service`. caddy-reconnect.sh
# handles this by waiting up to 3 minutes for Docker + the caddy
# container to be up before attempting the reconnect.
#
# WHEN TO RE-RUN THIS SCRIPT:
#   - Once, after the initial Phase 3 deploy.
#   - If caddy-reconnect.sh changes in this repo and you want the new
#     version on the hosts.
#   - If rishi-1 or rishi-2 is replaced/reimaged.
#   - If the crontab entry is removed or the script is deleted.
#
# USAGE:
#
#   bash scripts/bootstrap-caddy-reconnect.sh
#
# SAFETY:
#
# - No sudo. No root. Operates entirely within the deploy user's scope.
# - Idempotent: scp overwrites the same path, crontab installation checks
#   for an existing entry and avoids duplicates.
# - `set -e` aborts on first error, so a failure on rishi-1 does NOT
#   silently leave rishi-2 half-configured.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Hosts we need to configure. Pulled from the same servers.config convention
# the infra-template uses, but hard-coded here because:
#   1. yral-rishi-sentry's cluster surface is tiny (rishi-1 + rishi-2 for
#      Caddy; rishi-3 already handled by install.sh).
#   2. If host IPs change, SSH should be resolved via ~/.ssh/config, not
#      the repo.
HOSTS=(
  "deploy@138.201.137.181"   # rishi-1
  "deploy@136.243.150.84"    # rishi-2
)

SSH_KEY="${SSH_KEY:-$HOME/.ssh/rishi-hetzner-ci-key}"
SSH_OPTS=(-i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

LOCAL_SCRIPT="${REPO_DIR}/scripts/caddy-reconnect.sh"

# Unique marker string used to idempotently add/remove our crontab entry.
# We grep for this marker to detect an existing install, and appended ONLY
# if missing. Edit-safe: if we ever change the body of the crontab entry,
# grep for this exact marker + replace the line in-place.
CRON_MARKER="# yral-rishi-sentry: re-attach caddy to sentry-web overlay on boot"

# The actual crontab line. A 30-second sleep before calling the script is
# belt-and-braces on top of the script's own internal wait loop: @reboot
# jobs can fire quite early in boot. Output is appended to a log file the
# deploy user can tail: `tail -f /home/deploy/caddy-reconnect.log`.
CRON_LINE="@reboot sleep 30 && /home/deploy/caddy-reconnect.sh >> /home/deploy/caddy-reconnect.log 2>&1"

# Preflight on the operator's laptop.
if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "ERROR: $LOCAL_SCRIPT not found. Run from repo root." >&2
  exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH key $SSH_KEY not found. Override with SSH_KEY=<path>." >&2
  exit 1
fi

echo "==> Bootstrapping Caddy auto-reconnect on ${#HOSTS[@]} hosts"
echo "    script : $LOCAL_SCRIPT"
echo "    method : cron @reboot (no sudo required)"
echo "    key    : $SSH_KEY"
echo ""

for host in "${HOSTS[@]}"; do
  echo "────────────────────────────────────────────────────────────────"
  echo "  Host: $host"
  echo "────────────────────────────────────────────────────────────────"

  # Step 1 — copy the reconnect script to the deploy user's home.
  echo "  [1/4] scp caddy-reconnect.sh → /home/deploy/"
  scp "${SSH_OPTS[@]}" "$LOCAL_SCRIPT" "${host}:/home/deploy/caddy-reconnect.sh"
  # Make sure it's executable — scp preserves mode but defense-in-depth.
  ssh "${SSH_OPTS[@]}" "$host" "chmod +x /home/deploy/caddy-reconnect.sh"

  # Step 2 — idempotently install the crontab entry.
  # Reads current crontab (ignoring exit code 1 from `crontab -l` when the
  # user has no crontab yet), greps for our marker, and writes back only if
  # the marker is missing. The marker + the exact line are both emitted.
  echo "  [2/4] install crontab @reboot entry (idempotent)"
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$host" bash -s <<REMOTE_BOOTSTRAP
    set -euo pipefail
    marker='${CRON_MARKER}'
    line='${CRON_LINE}'
    existing=\$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "\${existing}" | grep -qxF "\${marker}"; then
      echo '    (marker already present; leaving crontab unchanged)'
    else
      echo '    (adding marker + @reboot line to crontab)'
      {
        # Preserve any existing crontab content unchanged…
        printf '%s\n' "\${existing}"
        # …then append our marker + line.
        printf '%s\n' "\${marker}"
        printf '%s\n' "\${line}"
      } | crontab -
    fi
REMOTE_BOOTSTRAP

  # Step 3 — run caddy-reconnect.sh once right now, to reconcile the
  # current runtime state. Without this, the fix only takes effect on
  # the next reboot. Idempotent: no-op if caddy is already attached.
  echo "  [3/4] running caddy-reconnect.sh once to reconcile current state"
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$host" "/home/deploy/caddy-reconnect.sh"

  # Step 4 — verify the crontab entry is there and caddy IS attached
  # to sentry-web. Print both so a failure is visible immediately.
  echo "  [4/4] verify"
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$host" bash -s <<'REMOTE_VERIFY'
    echo '    --- crontab entry for yral-rishi-sentry ---'
    crontab -l 2>/dev/null | grep -A1 -F 'yral-rishi-sentry' || echo '    (NOT FOUND — bug in install step)'
    echo '    --- caddy currently attached to these networks: ---'
    docker inspect caddy --format '    {{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
REMOTE_VERIFY

  echo ""
done

echo "================================================================"
echo "DONE. Both hosts are now configured to re-attach Caddy to"
echo "sentry-web automatically on boot, via cron @reboot."
echo ""
echo "To verify on a future boot: SSH in and run 'crontab -l'"
echo "Runtime logs: tail -f /home/deploy/caddy-reconnect.log"
echo "To manually re-run: /home/deploy/caddy-reconnect.sh (on the host)"
echo "================================================================"
