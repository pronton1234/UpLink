#!/usr/bin/env bash
#
# Makes the Mac usable with NO network of its own — the configuration this
# product exists for, and the one it did not work in.
#
# THE PROBLEM, measured 2026-08-14 with Wi-Fi disconnected and the bridge live:
#
#     IPv4 default route : NONE
#     flows claimed      : 0        <- handleNewFlow never fired at all
#     curl by IP         : exitcode 7
#     scutil --dns       : empty    <- no resolver, so names cannot be tried
#
# Controlled comparison on the same machine, same second:
#
#     curl --interface en0 (has route) -> http 301, 2 flows claimed
#     curl --interface en9 (no route)  -> exitcode 7, 0 flows claimed
#
# NETransparentProxyProvider only ever receives flows the system was already
# going to route. With no route, connect() fails before any NECP policy match,
# so there is nothing to intercept: the bridge sits connected, healthy and
# completely idle while every request dies in the socket layer.
#
# THE FIX. Both missing pieces — a route and a resolver — come from having a
# configured network service. Wi-Fi's interface stays UP and RUNNING when it is
# not associated with anything; it simply has no address. Giving it a manual
# address, a router and a DNS server therefore leaves a primary service, a
# default route and a resolver in place whether or not a network is joined.
#
# Nothing is ever sent to that router. The proxy claims the flow first and
# carries it to the phone; the address only has to exist so the flow does.
# 169.254.0.0/16 is used deliberately: link-local, never routable off the
# machine, so if the proxy ever fails to claim a flow the packet dies here
# instead of leaking onto a real network.
#
#   sudo ./scripts/standalone-mode.sh on     # survive with no network
#   sudo ./scripts/standalone-mode.sh off    # back to DHCP
#   ./scripts/standalone-mode.sh status
#
set -uo pipefail
cd "$(dirname "$0")/.."

SERVICE="${UPLINK_WIFI_SERVICE:-Wi-Fi}"

# Link-local on purpose: 169.254/16 is never routable off this machine, so a
# flow the proxy fails to claim dies here instead of leaking onto a real
# network. Verified working — with this applied and the bridge live:
#
#     route: 169.254.99.1 via en0      <- a gateway that goes nowhere
#     https://1.1.1.1      http 301
#     https://example.com  http 200    <- DNS resolving too
#     public IP            216.77.46.31 (carrier, not this Mac's ISP)
#     flows claimed/20s    39
#
# Do not be fooled into thinking this has not worked: macOS takes a few seconds
# to install the default route after `-setmanual` returns. Checked immediately
# it reports `IPv4 default : NONE`, which reads as total failure and is really
# just an early look. That cost one wrong diagnosis — the `status` call below
# waits, and prints the route explicitly so the wait is visible.
SELF_IP="169.254.99.2"
SELF_MASK="255.255.0.0"
SELF_ROUTER="169.254.99.1"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

status() {
  blue "==> Current state"
  echo "    service        : $SERVICE"
  networksetup -getinfo "$SERVICE" 2>/dev/null | sed 's/^/    /' | head -6
  echo "    DNS            : $(networksetup -getdnsservers "$SERVICE" 2>/dev/null | tr '\n' ' ')"
  local route
  route=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2" via "$NF; exit}')
  echo "    IPv4 default   : ${route:-NONE}"
  echo "    resolvers      : $(scutil --dns 2>/dev/null | grep -c 'nameserver\[0\]') entries"
}

case "${1:-status}" in

  on)
    [[ $EUID -ne 0 ]] && { red "Needs root: sudo $0 on"; exit 1; }

    # Auto-revert, and it is not optional. If this does not work, the operator
    # loses the connection they would need in order to undo it — and undoing it
    # needs root. So the machine undoes it by itself unless told otherwise.
    KEEP_FLAG=/tmp/.uplink-standalone-keep
    rm -f "$KEEP_FLAG"
    REVERT_AFTER="${UPLINK_REVERT_AFTER:-180}"
    (
      sleep "$REVERT_AFTER"
      [[ -f "$KEEP_FLAG" ]] && exit 0
      /usr/sbin/networksetup -setdhcp "$SERVICE"
      /usr/sbin/networksetup -setdnsservers "$SERVICE" 1.1.1.1 1.0.0.1
      logger -t uplink "standalone-mode auto-reverted after ${REVERT_AFTER}s"
    ) >/dev/null 2>&1 &
    disown
    amber "    auto-revert armed: back to DHCP in ${REVERT_AFTER}s unless you run"
    amber "      sudo $0 keep"
    echo

    blue "==> Giving $SERVICE a standing address, router and resolver"
    networksetup -setmanual "$SERVICE" "$SELF_IP" "$SELF_MASK" "$SELF_ROUTER" \
      || { red "    could not set a manual address"; exit 1; }
    # Cloudflare, matching UpLinkDNS.primary. Reachable only THROUGH the bridge,
    # which is the point: the query is an ordinary public destination, so the
    # capture policy carries it to the phone and it resolves over cellular.
    networksetup -setdnsservers "$SERVICE" 1.1.1.1 1.0.0.1
    green "    address $SELF_IP, router $SELF_ROUTER, DNS 1.1.1.1"
    echo
    # Wait for the route rather than glancing at it. macOS installs it a few
    # seconds after -setmanual returns, and reporting "NONE" in the meantime
    # reads as a total failure of the very thing this script exists to do.
    blue "==> Waiting for the default route to appear"
    for _ in $(seq 1 20); do
      ROUTE=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2" via "$NF; exit}')
      [[ -n "$ROUTE" ]] && break
      sleep 1
    done
    if [[ -n "${ROUTE:-}" ]]; then
      green "    $ROUTE"
    else
      red "    no default route appeared after 20s — this has NOT worked"
    fi
    echo
    status
    echo
    amber "Nothing is ever sent to $SELF_ROUTER. It exists so that connect()"
    amber "succeeds and the flow reaches the proxy, which carries it to the phone."
    echo
    echo "Revert with:  sudo $0 off"
    ;;

  off)
    [[ $EUID -ne 0 ]] && { red "Needs root: sudo $0 off"; exit 1; }
    blue "==> Restoring $SERVICE to DHCP"
    networksetup -setdhcp "$SERVICE"
    networksetup -setdnsservers "$SERVICE" "Empty"
    green "    back to DHCP with automatic DNS"
    sleep 2
    status
    ;;

  keep)
    [[ $EUID -ne 0 ]] && { red "Needs root: sudo $0 keep"; exit 1; }
    touch /tmp/.uplink-standalone-keep
    green "==> Auto-revert cancelled. Standalone mode stays until you turn it off."
    ;;

  status) status ;;

  *) red "usage: $0 on|off|keep|status"; exit 1 ;;
esac
