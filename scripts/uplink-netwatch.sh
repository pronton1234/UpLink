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
#   bridge live AND NO DEFAULT ROUTE  ->  manual address, dead gateway, public DNS
#   bridge not live                   ->  back to DHCP, always
#
# A FALLBACK, not the primary mechanism. The extension now ships a packet
# tunnel (`RouteProvider`) whose whole job is to supply the route and resolver,
# and when it works this daemon does nothing at all — it only acts when there
# is a live session and STILL no default route, which is precisely the case
# where NetworkExtension has declined to run a packet tunnel with no underlying
# network. That is the one assumption the tunnel design rests on and the one
# thing that cannot be checked off-device, so the fallback exists to make the
# product work either way rather than betting on the answer.
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

# The condition that actually matters: can anything on this Mac originate a
# connection? A transparent proxy only ever receives flows the system was
# already going to route, so with no default route `connect()` fails before the
# proxy is consulted and the bridge is never asked to carry anything.
#
# Checked instead of "does en0 have an address", because the packet tunnel may
# have supplied a perfectly good route while en0 has none — and in that case
# there is nothing for this daemon to do.
has_default_route() {
  [[ -n "$(netstat -rn -f inet 2>/dev/null | awk '$1 == "default" {print $2; exit}')" ]]
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
    # Only when the tunnel has NOT supplied a route. If RouteProvider is doing
    # its job there is a default route via its utun and this does nothing.
    if ! has_default_route && ! standalone_applied; then
      say "a session is live and there is still no default route — the packet tunnel did not come up, falling back"
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
