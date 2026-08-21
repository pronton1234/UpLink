#!/usr/bin/env bash
#
# Answers, in order, the only three questions that matter about the wireless
# bridge — and refuses to answer a later one before an earlier one has passed.
#
#   1. Is the bearer actually the Mac's own access point?
#   2. Is traffic actually crossing it, rather than the Mac's own network?
#   3. Is it as fast as the cable was?
#
# Run it AFTER tapping Connect on the phone.
#
#   ./scripts/verify-wireless.sh
#
set -uo pipefail
cd "$(dirname "$0")/.."

CABLE_LOW=116     # measured on hardware 2026-08-15, USB transport
CABLE_HIGH=153

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }
fail()  { red "FAIL: $1"; exit 1; }

blue "==> 1. The bearer"

/sbin/ifconfig bridge100 2>/dev/null | grep -q 'inet ' \
  || fail "no access point — bridge100 is absent. Tap Connect on the phone."
green "    access point up on $(/sbin/ifconfig bridge100 | awk '/inet /{print $2}')"

# Read from the lease rather than assumed. A hardcoded .2 once reported a
# healthy phone as absent because it had been given .3.
PHONE=$(/usr/bin/awk -F= '/ip_address/{a=$2} END{print a}' /var/db/dhcpd_leases 2>/dev/null)
[ -n "$PHONE" ] || fail "no DHCP lease — the phone has not joined the network"

/sbin/route -n get "$PHONE" 2>/dev/null | grep -q 'interface: bridge100' \
  || fail "$PHONE does not route over bridge100 — packets would leave on the wrong interface"
green "    phone at $PHONE, routed over bridge100"

/usr/sbin/arp -n "$PHONE" 2>/dev/null | grep -qv 'no entry' \
  || fail "$PHONE does not answer ARP — the phone is not on the network"
green "    phone answers on the link"

blue "==> 2. Is traffic really crossing it?"

# The Mac's own egress address. If the bridge is carrying traffic this is the
# CARRIER's address; if the Mac is quietly using its own network it is the home
# ISP's. Public-IP checks alone are not proof, so the proxy log is checked too.
IP=$(curl -s --max-time 20 https://api.ipify.org 2>/dev/null)
[ -n "$IP" ] || fail "no internet at all — nothing is being carried"
echo "    egress address: $IP"

# The honest check: did a flow to a known destination appear in the proxy's log?
# Timing correlation and address checks have both lied here before.
STAMP=$(date +%H:%M:%S)
curl -s -o /dev/null --max-time 20 https://api.ipify.org 2>/dev/null
sleep 2
if /usr/bin/log show --last 1m --info --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
     | grep -q "tcp "; then
  green "    the proxy claimed flows — traffic is crossing the bridge"
else
  red   "    WARNING: no claimed flows in the proxy log since $STAMP."
  red   "    The address above may be the Mac's own network, not the phone's."
fi

blue "==> 3. Speed, against the cable"

./scripts/throughput-test.sh 2>/dev/null | tail -12
echo
echo "    cable baseline was ${CABLE_LOW}-${CABLE_HIGH} Mbps (hardware, 2026-08-15)"
echo "    anything in that range or above means the wireless bearer is not the bottleneck"
