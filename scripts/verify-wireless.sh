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

# THE SAME RULE THE APP USES: newest lease by expiry, not last in the file.
#
# This script used to take whichever entry appeared last, and reported a working
# bridge as broken because of it. iOS randomises its MAC per join, so every join
# leaves another entry behind, and the file accumulates dead ones -- here, a .2
# that expired two days ago sitting after a live .3. The app picks by expiry
# (DHCPLease.mostRecent), so the two disagreed about which address was the
# phone, and only the script was wrong.
# Hex is converted in the shell because macOS awk has no strtonum -- a GNU
# extension. Written with it, this printed nothing at all and the script then
# failed on an empty address, which is a worse answer than the wrong one.
PHONE=$(
  /usr/bin/awk -F= '/ip_address/{ip=$2} /lease=/{print $2, ip}' \
      /var/db/dhcpd_leases 2>/dev/null |
  while read -r hex ip; do printf '%d %s\n' "$hex" "$ip"; done |
  sort -rn | head -1 | cut -d' ' -f2
)
[ -n "$PHONE" ] || fail "no DHCP lease — the phone has not joined the network"

/sbin/route -n get "$PHONE" 2>/dev/null | grep -q 'interface: bridge100' \
  || fail "$PHONE does not route over bridge100 — packets would leave on the wrong interface"
green "    phone at $PHONE, routed over bridge100"

# NOT A FAILURE, and it used to be one. An ARP entry expires after a few
# minutes of no traffic to that host, so its absence means "nobody has spoken to
# the phone recently", not "the phone is gone" -- and this script is usually run
# when nothing has. It reported a bridge that was carrying data as broken.
#
# What settles it is the session, checked next. This line is a hint, not a gate.
if /usr/sbin/arp -n "$PHONE" 2>/dev/null | grep -q 'no entry'; then
  echo "    (no ARP entry for $PHONE — normal when the link has been idle)"
else
  green "    phone answers on the link"
fi

# LINK QUALITY, because range is what fails in a car and nothing else here
# would show it. A bridge that works at arm's length and not from the boot is
# not a logic fault, and every check above passes in both cases.
echo "    link quality (10 pings):"
/sbin/ping -c 10 -i 0.3 -W 1000 "$PHONE" 2>/dev/null | tail -2 | sed 's/^/      /' \
  || echo "      (no reply — iOS may be ignoring ICMP; not conclusive on its own)"
echo "      loss above a few percent, or RTT in the tens of ms, means the radio"
echo "      is struggling. 5 GHz does not go through seat backs; a 2.4 GHz"
echo "      channel in Wi-Fi Options trades speed for reach."

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

blue "==> 3. Which traffic classes actually work"

# EACH CLASS SEPARATELY, because "the internet is broken" and "names do not
# resolve" look identical from a browser and have nothing in common underneath.
#
# This exists because of a real report: Chrome worked while everything else
# failed. Chrome resolves over DNS-over-HTTPS, so it never touches the system
# resolver — which makes it exactly the wrong thing to test with, and the only
# thing that had been tested with.
klass() {
    printf '    %-22s ' "$1"
    if eval "$2" >/dev/null 2>&1; then green OK; else red FAILED; fi
}

klass "DNS (system)"        "dscacheutil -q host -a name example.com | grep -q ip_address"
klass "DNS (direct 1.1.1.1)" "dig +time=5 +tries=1 @1.1.1.1 example.com +short"
klass "TCP by name"          "curl -s --max-time 15 -o /dev/null https://example.com"
klass "TCP by IP (no DNS)"   "curl -s --max-time 15 -o /dev/null https://1.1.1.1"
klass "IPv6"                 "curl -s --max-time 15 -o /dev/null -6 https://ipv6.google.com"
klass "QUIC / HTTP-3"        "/opt/homebrew/opt/curl/bin/curl --http3-only -s --max-time 20 -o /dev/null https://dl.google.com"
echo
echo "    If DNS (system) fails while TCP by IP passes, names are the fault —"
echo "    which is exactly the shape of 'Chrome works and nothing else does'."

blue "==> 4. Speed, against the cable"

./scripts/throughput-test.sh 2>/dev/null | tail -12
echo
echo "    cable baseline was ${CABLE_LOW}-${CABLE_HIGH} Mbps (hardware, 2026-08-15)"
echo "    anything in that range or above means the wireless bearer is not the bottleneck"
