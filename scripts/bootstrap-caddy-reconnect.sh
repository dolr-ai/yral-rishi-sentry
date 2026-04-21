#!/usr/bin/env bash
# =============================================================================
# yral-rishi-sentry — bootstrap Caddy auto-reconnect on rishi-1 and rishi-2
# =============================================================================
#
# WHAT THIS SCRIPT DOES (one-time setup, run from Rishi's Mac):
#
# For each host in the list (rishi-1 + rishi-2):
#   1. scp caddy-reconnect.sh          → /home/deploy/caddy-reconnect.sh
#   2. scp sentry-caddy-reconnect.service → /tmp/ on the host
#   3. SSH in and interactively prompt for sudo to:
#        - Move the .service file to /etc/systemd/system/
#        - systemctl daemon-reload
#        - systemctl enable sentry-caddy-reconnect.service
#        - systemctl start sentry-caddy-reconnect.service
#        - Verify it ran successfully and Caddy is attached to sentry-web
#
# WHY THIS IS A SEPARATE SCRIPT (not part of install.sh):
#
# scripts/install.sh runs ON rishi-3 and touches only rishi-3. Caddy lives
# on rishi-1 and rishi-2, which install.sh doesn't reach. This bootstrap
# script runs on your laptop and SSHs outward.
#
# WHEN YOU NEED TO RE-RUN IT:
#
# - Once, after the initial Phase 3 deploy (this install).
# - If caddy-reconnect.sh or sentry-caddy-reconnect.service changes in
#   this repo and you want the new versions on the hosts.
# - If rishi-1 or rishi-2 is replaced/reimaged.
# - If for any reason the systemd unit is removed or disabled.
#
# SAFETY:
#
# - All operations on the remote hosts are idempotent or guarded:
#     systemctl enable/start on an already-enabled/running service is OK.
#     The caddy-reconnect.sh is itself a no-op if already attached.
# - sudo will prompt interactively on each host — your password is never
#   passed on the command line.
# - The script aborts on first error (set -e), so a failure on rishi-1
#   does NOT silently leave rishi-2 half-configured.
#
# USAGE:
#
#   bash scripts/bootstrap-caddy-reconnect.sh
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Hosts we need to configure. Pulled from the same servers.config convention
# the infra-template uses, but we hard-code here for two reasons:
#   1. yral-rishi-sentry's infra is tiny (just rishi-1 + rishi-2 for Caddy)
#      so an external config file is overkill.
#   2. If rishi-1 or rishi-2 moves to a new IP, the SSH resolution should
#      be handled via ~/.ssh/config, not via our repo.
HOSTS=(
  "deploy@138.201.137.181"   # rishi-1
  "deploy@136.243.150.84"    # rishi-2
)

SSH_KEY="${SSH_KEY:-$HOME/.ssh/rishi-hetzner-ci-key}"
SSH_OPTS=(-i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

LOCAL_SCRIPT="${REPO_DIR}/scripts/caddy-reconnect.sh"
LOCAL_UNIT="${REPO_DIR}/systemd/sentry-caddy-reconnect.service"

# Sanity checks before we touch any remote host.
if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "ERROR: $LOCAL_SCRIPT not found. Run from repo root." >&2
  exit 1
fi
if [[ ! -f "$LOCAL_UNIT" ]]; then
  echo "ERROR: $LOCAL_UNIT not found. Run from repo root." >&2
  exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH key $SSH_KEY not found. Override with SSH_KEY=<path>." >&2
  exit 1
fi

echo "==> Bootstrapping Caddy auto-reconnect on ${#HOSTS[@]} hosts"
echo "    script : $LOCAL_SCRIPT"
echo "    unit   : $LOCAL_UNIT"
echo "    key    : $SSH_KEY"
echo ""

for host in "${HOSTS[@]}"; do
  echo "────────────────────────────────────────────────────────────────"
  echo "  Host: $host"
  echo "────────────────────────────────────────────────────────────────"

  # Step 1 — copy the reconnect script to the deploy user's home.
  echo "  [1/5] scp caddy-reconnect.sh → /home/deploy/"
  scp "${SSH_OPTS[@]}" "$LOCAL_SCRIPT" "${host}:/home/deploy/caddy-reconnect.sh"
  # Make sure it's executable — scp preserves mode but defense-in-depth.
  ssh "${SSH_OPTS[@]}" "$host" "chmod +x /home/deploy/caddy-reconnect.sh"

  # Step 2 — copy the systemd unit to /tmp. We can't scp directly to
  # /etc/systemd/system/ because that requires root; use /tmp as a staging
  # dir and move with sudo.
  echo "  [2/5] scp sentry-caddy-reconnect.service → /tmp/"
  scp "${SSH_OPTS[@]}" "$LOCAL_UNIT" "${host}:/tmp/sentry-caddy-reconnect.service"

  # Step 3 — move the unit into place and reload systemd. This is the
  # ONLY sudo call; it'll prompt interactively for the deploy user's
  # password on each host (which is correct — it should).
  echo "  [3/5] sudo mv + systemctl daemon-reload (password prompt incoming)"
  # shellcheck disable=SC2029
  ssh -t "${SSH_OPTS[@]}" "$host" "
    sudo mv /tmp/sentry-caddy-reconnect.service /etc/systemd/system/sentry-caddy-reconnect.service &&
    sudo chown root:root /etc/systemd/system/sentry-caddy-reconnect.service &&
    sudo chmod 644 /etc/systemd/system/sentry-caddy-reconnect.service &&
    sudo systemctl daemon-reload
  "

  # Step 4 — enable + start the unit. Enabling makes it fire on boot;
  # starting makes it fire right now, reconciling the current state.
  echo "  [4/5] systemctl enable + start sentry-caddy-reconnect"
  # shellcheck disable=SC2029
  ssh -t "${SSH_OPTS[@]}" "$host" "
    sudo systemctl enable sentry-caddy-reconnect.service &&
    sudo systemctl start sentry-caddy-reconnect.service
  "

  # Step 5 — verify. Read back the last few log lines and the current
  # Caddy attachment state, so a failure is visible immediately.
  echo "  [5/5] verify"
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$host" "
    echo '    --- sentry-caddy-reconnect status ---' &&
    systemctl is-active sentry-caddy-reconnect.service &&
    echo '    --- last 10 log lines ---' &&
    journalctl -u sentry-caddy-reconnect.service --no-pager -n 10 &&
    echo '    --- caddy attached networks ---' &&
    docker inspect caddy --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}'
  "

  echo ""
done

echo "================================================================"
echo "DONE. Both hosts are now configured to re-attach Caddy to"
echo "sentry-web automatically on boot."
echo ""
echo "To verify on a future boot: systemctl status sentry-caddy-reconnect"
echo "To manually re-run: /home/deploy/caddy-reconnect.sh (on the host)"
echo "================================================================"
