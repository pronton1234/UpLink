#!/usr/bin/env bash
#
# Answers one question: does giving the Mac a default route make the
# transparent proxy start receiving flows when it has no network?
#
# Measured 2026-08-14 with Wi-Fi disconnected and the bridge live:
#
#     default route : NONE
#     flows claimed : 0        <- handleNewFlow never fired at all
#     curl by IP    : err 7, could not connect
#     scutil --dns  : empty    <- no resolver, so names cannot even be tried
#
# NETransparentProxyProvider intercepts flows the system was already going to
# route. With no route, connect() fails before any policy match, so there is
# nothing to intercept and the bridge — healthy, connected, idle — never sees a
# packet. This script tests the cheapest possible fix: give the system a route
# that goes nowhere, so the flow exists for the proxy to claim.
#
# lo0 on purpose. If the proxy claims the flow it is bridged; if it does not,
# the packet is dropped rather than leaking out of some other interface.
#
#   1. Disconnect Wi-Fi from its network (leave the radio ON).
#   2. sudo ./scripts/probe-noroute.sh
#
# Reverts itself on any exit, including Ctrl-C.
set -uo pipefail

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

if [[ $EUID -ne 0 ]]; then
  red "Needs root to add a route: sudo $0"
  exit 1
fi

IFACE="${1:-lo0}"
ADDED=0
cleanup() {
  if [[ $ADDED -eq 1 ]]; then
    blue "==> Removing the test route"
    route -n delete -inet default -interface "$IFACE" >/dev/null 2>&1
    green "    removed; routing is back to how it was"
  fi
}
trap cleanup EXIT INT TERM

claims() {
  /usr/bin/log show --last "${1}s" --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
    | grep -cE "claim (tcp|udp)"
}

blue "==> Preconditions"
# -inet matters. This box keeps IPv6 default routes via idle utun tunnels even
# with the network down, so a family-less `route get default` succeeds and this
# check refused to run in exactly the state it exists to measure. The IPv4
# default is the one that disappears, and it is the one that breaks browsing.
if route -n get -inet default >/dev/null 2>&1; then
  red "    An IPv4 default route already exists — disconnect Wi-Fi first."
  red "    With a working route this measures nothing."
  netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print "    current: "$0}'
  exit 2
fi
green "    no IPv4 default route, which is the state under test"

STATE=$(/usr/bin/log show --last 10m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
        | grep -E "session started|session ENDED" | tail -1)
case "$STATE" in
  *"session started"*) green "    bridge session is live" ;;
  *) red "    no live bridge session — connect from the phone first"; exit 2 ;;
esac

blue "==> Baseline with no route (expect everything to fail, 0 claims)"
BEFORE=$(claims 15)
curl -s --max-time 6 -o /dev/null -w '    curl https://1.1.1.1     -> http=%{http_code}\n' https://1.1.1.1
echo "    flows claimed in the last 15s: $BEFORE"

blue "==> Adding a default route via $IFACE"
if ! route -n add -inet default -interface "$IFACE" >/dev/null 2>&1; then
  red "    could not add the route"
  exit 1
fi
ADDED=1
green "    added"
sleep 2

blue "==> The same probes, now that a route exists"
# By IP, so DNS cannot be blamed.
curl -s --max-time 12 -o /dev/null -w '    curl https://1.1.1.1     -> http=%{http_code}\n' https://1.1.1.1
# Straight at a resolver, which needs no system resolver configuration. This
# separates "DNS is unconfigured" from "UDP does not cross".
dig +short +time=6 +tries=1 @1.1.1.1 example.com 2>/dev/null \
  | head -1 | sed 's/^/    dig @1.1.1.1 example.com -> /'
# Through the system resolver, which is absent — expected to fail, and its
# failure is what justifies also installing DNS.
curl -s --max-time 8 -o /dev/null -w '    curl https://example.com -> http=%{http_code}\n' https://example.com

sleep 1
AFTER=$(claims 20)
echo
echo "    flows claimed in the last 20s: $AFTER"
echo
if [[ "${AFTER:-0}" -gt 0 ]]; then
  green "VERDICT: a default route is enough to make flows reach the extension."
  echo "         Fix = the extension installs a route (and a resolver) while a"
  echo "         session is live, and removes both on teardown."
else
  red "VERDICT: still no flows. A route alone is not enough, and the Mac side"
  echo "         needs a real virtual interface (NEPacketTunnelProvider) to"
  echo "         become the primary network service."
fi
