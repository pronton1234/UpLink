#!/usr/bin/env bash
#
# Proves — or refuses to claim — that this Mac's traffic is going over the
# phone's cellular data.
#
# WHY THIS EXISTS
#
# Every informal check of this has been wrong at least once, in both directions,
# and the failures were not obvious:
#
#   - `networksetup -getairportnetwork` reported "not associated" while the
#     interface held a DHCP lease and the router answered ARP.
#   - `RouterARPVerified` reported "not associated" for a Wi-Fi network that was
#     working perfectly over IPv6, because ARP is an IPv4 question. Every
#     dual-stack site — which is every site that matters — loaded over the home
#     network while the IPv4-only evidence said the bridge was carrying it.
#     `open.spotify.com` returned 200 in 0.4s and it meant nothing.
#   - A public-IP check is not sufficient on its own: IPv4 can be bridged while
#     IPv6 goes straight out, so half the traffic tells one story and half tells
#     the other.
#
# So this script refuses to report success unless BOTH halves hold: there is no
# other way out (v4 and v6), and the specific flows it generated are visible in
# the proxy's own log as having been claimed and bridged.
set -uo pipefail
cd "$(dirname "$0")/.."

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }
warn()  { printf '\033[0;33m%s\033[0m\n' "$1"; }

IFACE="${UPLINK_WIFI_IFACE:-en0}"
REPORT="${UPLINK_REPORT:-/tmp/uplink-cellular-report.txt}"
FAILED=0

# --watch: wait for the bridge, then verify, then write a report to disk.
#
# THE OPERATOR PROBLEM. This test requires the Mac's Wi-Fi radio to be OFF,
# which is also the only path anyone driving the Mac remotely has. So the test
# cannot be watched while it runs: the moment the conditions are right, whoever
# started it is gone. Every previous attempt has been reconstructed afterwards
# from logs, badly.
#
# So: start this BEFORE turning the radio off. It waits for a session, runs the
# checks, and writes the answer somewhere that survives the outage. Turn Wi-Fi
# back on afterwards and read the file.
# --full: the whole test, hands-off, and it CANNOT strand you.
#
# Waits for a session, turns the Wi-Fi radio off itself, verifies, and turns the
# radio back on again — through a trap, so it is restored even if the script is
# killed or something throws. The operator's own connection goes down with the
# radio, which is why this has to be one unattended command rather than a
# sequence someone runs while watching.
if [[ "${1:-}" == "--full" ]]; then
    : > "$REPORT"
    exec > >(tee -a "$REPORT") 2>&1

    restore_radio() {
        networksetup -setairportpower "$IFACE" on 2>/dev/null
        echo "    Wi-Fi radio restored at $(date '+%H:%M:%S')"
    }
    trap restore_radio EXIT INT TERM

    blue "==> waiting for a bridge session (up to 10 minutes)"
    echo "    started $(date '+%H:%M:%S') — connect from the phone now"
    found=0
    for _ in $(seq 1 600); do
        last=$(/usr/bin/log show --last 1m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
               | grep -E "session started|session ENDED" | tail -1)
        if [[ "$last" == *"session started"* ]]; then found=1; break; fi
        sleep 1
    done
    if [[ $found -eq 0 ]]; then
        red "    no session appeared; nothing to test"
        exit 1
    fi
    green "    session at $(date '+%H:%M:%S')"

    blue "==> turning the Wi-Fi radio off"
    networksetup -setairportpower "$IFACE" off
    # The bridge needs a moment to become the only path: AWDL re-derives, the
    # route fallback lands, and DNS re-points.
    sleep 25
fi

if [[ "${1:-}" == "--watch" ]]; then
    : > "$REPORT"
    exec > >(tee -a "$REPORT") 2>&1
    blue "==> waiting for a bridge session (up to 10 minutes)"
    echo "    started $(date '+%H:%M:%S'); radio can go off now"
    for _ in $(seq 1 600); do
        last=$(/usr/bin/log show --last 1m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
               | grep -E "session started|session ENDED" | tail -1)
        if [[ "$last" == *"session started"* ]]; then
            green "    session detected at $(date '+%H:%M:%S')"
            # Let discovery, the route fallback and DNS settle before judging.
            sleep 20
            break
        fi
        sleep 1
    done
fi
fail() { red "    FAIL: $1"; FAILED=1; }

blue "==> 1. Is there any way out other than the bridge?"

# IPv4: a default route through a real gateway, i.e. not ours and not a tunnel.
V4_GATEWAYS=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" {print $2}' \
              | grep -v '^169\.254\.99\.1$' | grep -v '^link#' || true)
if [[ -n "$V4_GATEWAYS" ]]; then
    fail "a real IPv4 gateway exists: $(echo "$V4_GATEWAYS" | tr '\n' ' ')"
else
    green "    no real IPv4 gateway"
fi

# IPv6, AND THIS IS THE ONE THAT CAUGHT US. A Wi-Fi network with no DHCP lease
# still hands out a global address by SLAAC, and every dual-stack site then
# works without the bridge being involved at all.
V6_GLOBAL=$(ifconfig "$IFACE" 2>/dev/null | grep -E 'inet6 [23][0-9a-f]{3}:' || true)
V6_DEFAULT=$(netstat -rn -f inet6 2>/dev/null | awk -v i="$IFACE" '$1=="default" && $NF==i {print}' || true)
if [[ -n "$V6_GLOBAL" && -n "$V6_DEFAULT" ]]; then
    fail "$IFACE has a global IPv6 address AND a default route — the Wi-Fi network is working over IPv6"
    echo "$V6_GLOBAL" | sed 's/^/        /'
    warn "    Turn the Wi-Fi radio OFF, not merely disconnect it. Disconnecting"
    warn "    leaves IPv6 alive and makes the result meaningless in both directions."
else
    green "    no usable IPv6 path over $IFACE"
fi

# Belt and braces: is a router answering ARP?
if ipconfig getsummary "$IFACE" 2>/dev/null | grep -qE 'RouterARPVerified *: *TRUE'; then
    fail "a router is answering ARP on $IFACE"
else
    green "    no router answering ARP on $IFACE"
fi

blue "==> 2. Is the bridge actually up?"
SESSION=$(/usr/bin/log show --last 2m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
          | grep -E "session started|session ENDED" | tail -1)
if [[ "$SESSION" == *"session started"* ]]; then
    green "    a session is live"
else
    fail "no live session (last event: ${SESSION:-none})"
fi

PEER=$(/usr/bin/log show --last 5m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
       | grep "accept: inbound" | tail -1)
case "$PEER" in
    *%awdl0*) green "    peer link is AWDL (cable-free)" ;;
    *%en*)    fail "peer link is over a CABLE (${PEER##*from }) — unplug it, this is not the test" ;;
    *169.254*) fail "peer link is IPv4 link-local — the kernel does not count that as an AWDL socket" ;;
    *)        warn "    could not identify the peer link: ${PEER:-none}" ;;
esac

blue "==> 3. Make a real request, and prove the bridge carried it"
MARK=$(date "+%Y-%m-%d %H:%M:%S")
sleep 1

TARGET="open.spotify.com"
RESULT=$(curl -s -o /dev/null \
    -w "http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s total=%{time_total}s" \
    --max-time 30 "https://$TARGET" 2>&1)
echo "    $TARGET -> $RESULT"
case "$RESULT" in
    *http=200*|*http=30*) green "    the page loaded" ;;
    *) fail "$TARGET did not load" ;;
esac

# The half that cannot be faked: did those flows go through the proxy?
sleep 2
CLAIMED=$(/usr/bin/log show --start "$MARK" --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
          | grep -cE "tcp open " || true)
if [[ "${CLAIMED:-0}" -gt 0 ]]; then
    green "    the proxy opened $CLAIMED flow(s) during that request"
else
    fail "the proxy opened NO flows — something else carried this traffic"
fi

blue "==> 4. Where does the world think we are?"
PUBLIC=$(curl -s --max-time 20 https://api.ipify.org 2>/dev/null || true)
echo "    public IPv4: ${PUBLIC:-unavailable}"
warn "    Compare against your home IP. This is corroboration, NOT proof:"
warn "    IPv4 can be bridged while IPv6 goes straight out."

blue "==> 5. Throughput"
SPEED=$(curl -s -o /dev/null -w "%{speed_download}" --max-time 30 \
        https://speed.cloudflare.com/__down?bytes=10000000 2>/dev/null || echo 0)
MBPS=$(echo "$SPEED" | awk '{printf "%.1f", $1*8/1000000}')
echo "    ${MBPS} Mbps"

echo
if [[ $FAILED -eq 0 ]]; then
    green "PASS — no other way out, and the proxy carried the request."
else
    red "NOT PROVEN — see the failures above. Do not report this as working."
    exit 1
fi
