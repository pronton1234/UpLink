#!/usr/bin/env bash
#
# Keeps the Mac's network configuration in step with the bridge, so nothing has
# to be done by hand.
#
# WHY THIS EXISTS AS A DAEMON. The configuration has to change at exactly two
# moments — when the Mac loses its own network while the bridge is up, and when
# the bridge goes away — and neither the app nor the extension can make it:
#
#   - the system extension runs as root but is sandboxed, so it cannot invoke
#     `networksetup` or touch system network preferences;
#   - the containing app is deliberately not sandboxed but is not root.
#
# So a small root LaunchDaemon watches both signals and applies the change.
# Install with ./scripts/install-auto-standalone.sh.
#
# WHAT IT WATCHES
#
#   bridge live?   the extension's own log, which is the only authority on
#                  whether a session exists — the UI can be wrong, and has been
#   own network?   whether en0 holds a DHCP address
#
# WHAT IT DOES
#
#   bridge live AND no address   ->  manual address, dead gateway, public DNS
#   bridge not live              ->  back to DHCP, always
#
# The second rule is unconditional on purpose. Standalone mode points the Mac at
# a gateway only the bridge can service, so leaving it applied after the bridge
# goes away turns "the bridge stopped" into "this Mac has no network at all",
# which is far worse and outlives the app.
set -uo pipefail

SERVICE="${UPLINK_WIFI_SERVICE:-Wi-Fi}"
SELF_IP="169.254.99.2"
SELF_MASK="255.255.0.0"
SELF_ROUTER="169.254.99.1"
INTERVAL="${UPLINK_NETWATCH_INTERVAL:-5}"

say() { logger -t uplink-netwatch "$1"; echo "$(date '+%H:%M:%S') $1"; }

bridge_is_live() {
  local last
  last=$(/usr/bin/log show --last 10m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
         | grep -E "session started|session ENDED" | tail -1)
  [[ "$last" == *"session started"* ]]
}

# An address that came from a real network. The standalone address does not
# count, or the watcher would immediately decide the Mac had a network again
# and undo its own work.
has_own_network() {
  local addr
  addr=$(ipconfig getifaddr en0 2>/dev/null)
  [[ -n "$addr" && "$addr" != "$SELF_IP" ]]
}

standalone_applied() {
  [[ "$(networksetup -getinfo "$SERVICE" 2>/dev/null | awk '/^IP address:/{print $3; exit}')" == "$SELF_IP" ]]
}

apply_standalone() {
  say "bridge is live and this Mac has no network — applying standalone config"
  networksetup -setmanual "$SERVICE" "$SELF_IP" "$SELF_MASK" "$SELF_ROUTER"
  networksetup -setdnsservers "$SERVICE" 1.1.1.1 1.0.0.1
  for _ in $(seq 1 30); do
    [[ "$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2; exit}')" == "$SELF_ROUTER" ]] && break
    sleep 1
  done
  say "default route is now $(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2; exit}')"
}

revert_dhcp() {
  say "reverting to DHCP"
  networksetup -setdhcp "$SERVICE"
  networksetup -setdnsservers "$SERVICE" 1.1.1.1 1.0.0.1
}

# Whatever state a crash left behind, start from a known one.
trap 'revert_dhcp; exit 0' INT TERM

say "watching (interval ${INTERVAL}s, service ${SERVICE})"

while true; do
  if bridge_is_live; then
    if ! has_own_network && ! standalone_applied; then
      apply_standalone
    fi
  else
    if standalone_applied; then
      say "bridge is gone"
      revert_dhcp
    fi
  fi
  sleep "$INTERVAL"
done
