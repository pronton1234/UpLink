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
# One second, not five. The gap between Wi-Fi dropping and this landing is a
# window in which the Mac has no route and nothing works — and a user who tests
# during it concludes, correctly from where they are standing, that the product
# is broken. Observed: a probe at 14:35:32 failed, and the config landed at
# 14:35:39.
INTERVAL="${UPLINK_NETWATCH_INTERVAL:-1}"

# How often the (expensive) session check is refreshed. `log show` takes the
# best part of a second, so running it every tick would put the poll interval
# back where it started. The route check below is cheap and runs every tick;
# this only decides whether the bridge is worth applying a config FOR, and that
# does not change second to second.
SESSION_REFRESH_TICKS=5

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

# Is the Mac app running at all?
#
# The daemon must be inert unless UpLink is actually in use. It owns the
# machine's network configuration, and a root daemon quietly holding a manual
# address for an app the user quit an hour ago is not a fallback, it is a fault.
app_running() {
  pgrep -f '/Applications/UpLink.app/Contents/MacOS/UpLink' >/dev/null 2>&1
}

# Has Wi-Fi joined a real network?
#
# THE CONDITION THAT WAS MISSING, and it stranded the user. Once the manual
# address is applied, en0 is static — so rejoining Wi-Fi cannot get a DHCP
# lease, and the only rule for reverting was "the session ended". With the
# session still live, the Mac sat on a dead 169.254 gateway with a perfectly
# good network available and no way back except killing this daemon by hand.
#
# `RouterARPVerified` rather than an SSID or `networksetup`, and the choice
# matters twice over.
#
# `networksetup -getairportnetwork` simply lies: measured on this machine
# reporting "You are not associated with an AirPort network" while the same
# interface held a DHCP lease of 192.168.1.185 and the router answered ARP.
# Anything built on it is built on sand.
#
# An SSID is better but still wrong for this decision: it says a network was
# joined, not that it works — a captive portal or a dead AP both have one.
#
# `RouterARPVerified : TRUE` says a router replied to an ARP request. It is
# exactly the question being asked — "does this Mac have somewhere to go that
# is not us?" — and it cannot be fooled by our own gateway, which is chosen
# precisely because nothing answers at it.
wifi_associated() {
  ipconfig getsummary en0 2>/dev/null | grep -qE 'RouterARPVerified *: *TRUE'
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

TICK=0
SESSION_LIVE=0

while true; do
  # Cheap check first, every tick. Losing the default route is the event that
  # matters and `netstat` costs microseconds, so the reaction time is set by
  # this rather than by the log query.
  if has_default_route; then
    HAS_ROUTE=1
  else
    HAS_ROUTE=0
  fi

  # Expensive check, refreshed on a slower cadence — but forced immediately
  # whenever the route has just gone, because that is exactly the moment the
  # answer has to be current rather than up to five seconds old.
  if [[ $((TICK % SESSION_REFRESH_TICKS)) -eq 0 || $HAS_ROUTE -eq 0 ]]; then
    if bridge_is_live; then SESSION_LIVE=1; else SESSION_LIVE=0; fi
  fi
  TICK=$((TICK + 1))

  # Ordered by how emphatically each says "give the network back". Every one of
  # them reverts; only the last applies. Getting this order wrong is how a
  # fallback becomes the thing the user has to fight.
  if ! app_running; then
    if standalone_applied; then
      say "UpLink is not running — handing the network back"
      revert_dhcp
    fi
  elif wifi_associated; then
    # A real network is available. Whatever the bridge is doing, the user has
    # somewhere to go and must not be held on a dead gateway.
    if standalone_applied; then
      say "Wi-Fi joined a network — handing it back to DHCP"
      revert_dhcp
    fi
  elif [[ $SESSION_LIVE -eq 0 ]]; then
    if standalone_applied; then
      say "bridge is gone — handing the network back"
      revert_dhcp
    fi
  elif [[ $HAS_ROUTE -eq 0 ]] && ! standalone_applied; then
    # The only branch that applies anything: the app is running, Wi-Fi has
    # joined nothing, a session is live, and still nothing can be routed.
    say "session live, no network joined, and no default route — falling back"
    apply_standalone
  fi
  sleep "$INTERVAL"
done
