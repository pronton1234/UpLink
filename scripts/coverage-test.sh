#!/usr/bin/env bash
#
# Measures which classes of traffic ACTUALLY egress through the phone.
#
# "Universal coverage" is a claim; this turns it into a measurement. Each probe
# reaches the internet a different way an app might, and reports the public IP
# it was seen as. If that IP is the phone's carrier address, the traffic went
# through the bridge. If it is the Mac's own address, it leaked.
#
#   ./scripts/coverage-test.sh              # measure and print the matrix
#   ./scripts/coverage-test.sh --expect-bridged   # also FAIL if anything leaks
#
# Row 7 (ICMP) is expected NOT to be bridged: NETransparentProxyProvider only
# intercepts TCP and UDP. The app blocks ICMP while bridging so it cannot leak
# silently — so "blocked" is a pass and "direct" is a failure.
#
set -uo pipefail
cd "$(dirname "$0")/.."

STRICT=0
[[ "${1:-}" == "--expect-bridged" ]] && STRICT=1

green() { printf '\033[0;32m%s\033[0m' "$1"; }
red()   { printf '\033[0;31m%s\033[0m' "$1"; }
amber() { printf '\033[0;33m%s\033[0m' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

# Two independent echo services, so one being down is not mistaken for a leak.
ECHO_A="https://api.ipify.org"
ECHO_B="https://ifconfig.me/ip"
ECHO_A6="https://api64.ipify.org"

FAILURES=0

# ── Baseline: what does this Mac look like WITHOUT the bridge? ─────────────
# BOTH families. A v4-only baseline is worse than none: an IPv6 probe result
# would fail to match it and be scored as "bridged" when it actually leaked —
# the harness lying in the dangerous direction.
# ── Refuse to measure a dead session ──────────────────────────────────────
# Two runs were taken in good faith against a session that had already ended,
# and both reported "no connectivity on every row". That reads as a product
# failure and is really a measurement of nothing. A harness that can silently
# measure a corpse is worse than no harness: it produces confident, wrong
# numbers that then drive hours of debugging.
blue "==> Checking the bridge is actually up"
# A 10-minute window, not 2. A session logs when it starts and when it ends and
# says nothing in between, so a SHORT window makes a healthy long-lived session
# indistinguishable from no session at all — and this script then refuses to
# measure a bridge that is working perfectly. Observed: a run connected at
# 08:42:10 and was declared dead at 08:44:30, 140 seconds later, purely because
# it had not logged anything since.
#
# The same mistake in the opposite direction is what let two runs measure a
# session that had already ended. What matters is the LAST event, not whether
# there was a recent one.
SESSION_STATE=$(/usr/bin/log show --last 10m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null \
  | grep -E "session started|session ENDED" | tail -1)

if [[ -z "$SESSION_STATE" ]]; then
  amber "    No session start or end in the last 10 minutes."
  echo "    Connect from your iPhone first, then re-run. Measuring now would"
  echo "    report 'no connectivity' whether or not the bridge works."
  exit 2
fi
if [[ "$SESSION_STATE" == *"session ENDED"* ]]; then
  red "    The last thing the bridge logged was a session ENDING."; echo
  echo "    $SESSION_STATE"
  echo
  echo "    Reconnect from your iPhone and re-run. These probes would all fail"
  echo "    for want of a session, which looks identical to a broken bridge."
  exit 2
fi
green "    Session is live."; echo
echo

# ── Baseline ──────────────────────────────────────────────────────────────
#
# This script CANNOT measure its own baseline, and trying to inverted the whole
# matrix for as long as it has existed.
#
# It refuses to run without a live session — correctly, since probing a dead
# bridge reports "no connectivity" whether or not the product works. But that
# means by the time it gets here the transparent proxy is already in front of
# every flow on the machine, and a proxy claims flows regardless of which
# interface the socket bound to, so `--interface en0` does not escape it. The
# "baseline" came back as the CARRIER's address, and classify() then scored
# every genuinely bridged row DIRECT for matching it.
#
# The measured proof, from one run on 2026-08-13:
#
#     prove-bridge step 4:  216.77.46.31  CHANGED from the baseline —
#                                         traffic is leaving via the phone
#     coverage row 1:       DIRECT ✗ 216.77.46.31      ← the same address
#
# Two conclusions from one number, in the same run, eight lines apart. Hours
# were spent chasing a TCP path that was working.
#
# So the baseline is taken BEFORE the bridge comes up, by prove-bridge.sh, and
# passed in. Run standalone with none supplied, this says so rather than
# guessing — a harness that can silently measure the wrong thing is worse than
# no harness.
blue "==> Establishing baseline"
MAC_IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
DIRECT_V4="${UPLINK_BASELINE_V4:-}"
DIRECT_V6="${UPLINK_BASELINE_V6:-}"

if [[ -z "$DIRECT_V4" && -z "$DIRECT_V6" ]]; then
  red "    No pre-bridge baseline supplied."; echo
  echo "    UPLINK_BASELINE_V4 / UPLINK_BASELINE_V6 must be measured BEFORE the"
  echo "    bridge is up. Measuring now would go through the bridge and report"
  echo "    the carrier's address as this Mac's own, which scores every bridged"
  echo "    row as a leak."
  echo
  echo "    Run ./scripts/prove-bridge.sh, which takes the baseline at step 0"
  echo "    and passes it in. To run this alone, disconnect the bridge, then:"
  echo
  echo "      export UPLINK_BASELINE_V4=\$(curl -s -4 https://api.ipify.org)"
  echo "      export UPLINK_BASELINE_V6=\$(curl -s -6 https://api64.ipify.org)"
  echo
  exit 2
fi

echo "    Mac interface   : ${MAC_IF:-unknown}"
echo "    Mac IPv4        : ${DIRECT_V4:-none}   (measured before the bridge)"
echo "    Mac IPv6        : ${DIRECT_V6:-none}   (measured before the bridge)"

if [[ -n "$DIRECT_V6" ]]; then
  echo "    IPv6 is live here, so it is a real leak path and is probed separately."
fi

# ── Probes ────────────────────────────────────────────────────────────────
# Each prints the observed public IP on stdout, or nothing if it could not
# reach the internet at all.

probe_proxy_aware()  { curl -s --max-time 10 "$ECHO_A"; }
probe_ignores_proxy() { curl -s --max-time 10 --noproxy '*' "$ECHO_A"; }

probe_raw_socket() {
  python3 - <<'PY' 2>/dev/null
import socket, ssl, sys, re
host = "ifconfig.me"
ctx = ssl.create_default_context()
with socket.create_connection((host, 443), timeout=10) as raw:
    with ctx.wrap_socket(raw, server_hostname=host) as s:
        s.sendall(b"GET /ip HTTP/1.1\r\nHost: ifconfig.me\r\nConnection: close\r\nUser-Agent: curl\r\n\r\n")
        body = b""
        while chunk := s.recv(4096):
            body += chunk
text = body.decode(errors="replace")
# Accept IPv6 as well as IPv4 — this host may well answer over v6, and a
# v4-only pattern reports a working probe as "no connectivity".
last = text.strip().splitlines()[-1].strip() if text.strip() else ""
print(last if re.match(r"^[0-9a-fA-F:.]+$", last) else "")
PY
}

# DNS over UDP, answered by a nameserver that echoes the querying client's
# address. This is the probe that proves DNS itself crosses the bridge — the
# single most revealing thing that can leak.
probe_udp_dns() {
  dig +short +time=5 +tries=1 +notcp TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null \
    | tail -1 | tr -d '"'
}

# IPv6 is a separate leak path: a bridge that only carries IPv4 sends every
# v6-capable destination straight out the Mac's own interface.
probe_ipv6() {
  [[ -z "$DIRECT_V6" ]] && { echo "__NOIPV6__"; return; }
  curl -s --max-time 10 -6 --noproxy '*' "$ECHO_A6" 2>/dev/null
}

probe_quic() {
  # curl only speaks HTTP/3 if built with it; report "n/a" rather than a false leak.
  if curl --http3 --version >/dev/null 2>&1 || curl --version | grep -q HTTP3; then
    curl -s --max-time 10 --http3 "$ECHO_A" 2>/dev/null
  else
    echo "__NOHTTP3__"
  fi
}

probe_icmp() {
  # Not an IP — just whether ICMP escapes at all.
  if ping -c 1 -W 3000 1.1.1.1 >/dev/null 2>&1; then echo "__REACHED__"; else echo "__BLOCKED__"; fi
}

classify() {
  local observed="$1" expectation="$2" label="$3"
  local verdict

  if [[ "$observed" == "__NOHTTP3__" ]]; then
    printf '  %-34s %s\n' "$label" "$(amber 'n/a — curl has no HTTP/3')"
    return
  fi
  if [[ "$observed" == "__NOIPV6__" ]]; then
    printf '  %-34s %s\n' "$label" "$(amber 'n/a — no IPv6 on this network')"
    return
  fi

  if [[ "$expectation" == "not-bridged" ]]; then
    if [[ "$observed" == "__BLOCKED__" ]]; then
      printf '  %-34s %s\n' "$label" "$(green 'blocked ✓ (cannot leak)')"
    else
      printf '  %-34s %s\n' "$label" "$(red 'DIRECT ✗ leaking past the bridge')"
      FAILURES=$((FAILURES + 1))
    fi
    return
  fi

  if [[ -z "$observed" ]]; then
    printf '  %-34s %s\n' "$label" "$(red 'no connectivity')"
    FAILURES=$((FAILURES + 1))
  elif [[ ( -n "$DIRECT_V4" && "$observed" == "$DIRECT_V4" ) \
       || ( -n "$DIRECT_V6" && "$observed" == "$DIRECT_V6" ) ]]; then
    printf '  %-34s %s\n' "$label" "$(red "DIRECT ✗ $observed")"
    FAILURES=$((FAILURES + 1))
  else
    printf '  %-34s %s\n' "$label" "$(green "bridged ✓ $observed")"
  fi
}

echo
blue "==> Coverage matrix"
classify "$(probe_proxy_aware)"   bridged     "1. TCP, proxy-aware (curl)"
classify "$(probe_ignores_proxy)" bridged     "2. TCP, ignores proxy"
classify "$(probe_raw_socket)"    bridged     "3. TCP, raw socket"
classify "$(probe_udp_dns)"       bridged     "4. UDP (DNS)"
classify "$(probe_quic)"          bridged     "5. QUIC / HTTP-3"
classify "$(probe_ipv6)"          bridged     "6. IPv6"
classify "$(probe_icmp)"          not-bridged "7. ICMP (ping)"

# ── Throughput ────────────────────────────────────────────────────────────
# Coverage answers "did it go through the phone". This answers "was it worth
# it". Without a number, "the bridge feels slow" is unfalsifiable and so is
# "the fix worked" — which is exactly how a serialised frame loop survived in
# the shipping build while every correctness test passed.
#
# The comparison that matters is bridged-vs-the-phone-itself, not
# bridged-vs-this-Mac's-Wi-Fi: the ceiling is the cellular link, and the Mac's
# home connection is usually far faster than any phone.

DOWNLOAD_BYTES=${UPLINK_THROUGHPUT_BYTES:-25000000}
SPEED_URL="https://speed.cloudflare.com/__down?bytes=${DOWNLOAD_BYTES}"

# Bytes per second, or empty if the transfer failed.
measure_speed() {
  curl -s -o /dev/null --max-time 60 -w '%{speed_download}' "$1" 2>/dev/null
}

human_rate() {
  awk -v bps="$1" 'BEGIN {
    if (bps == "" || bps <= 0) { print "n/a"; exit }
    printf "%.1f Mbps (%.1f MB/s)", bps * 8 / 1000000, bps / 1048576
  }'
}

echo
blue "==> Throughput"
BRIDGED_BPS=$(measure_speed "$SPEED_URL")
printf '  %-34s %s\n' "through the bridge" "$(human_rate "${BRIDGED_BPS:-0}")"

if [[ -n "$MAC_IF" ]]; then
  DIRECT_BPS=$(curl -s -o /dev/null --max-time 60 --interface "$MAC_IF" --noproxy '*' \
    -w '%{speed_download}' "$SPEED_URL" 2>/dev/null)
  printf '  %-34s %s\n' "this Mac, direct (reference)" "$(human_rate "${DIRECT_BPS:-0}")"
fi

echo
echo "  The number to judge this against is a speed test on the PHONE itself."
echo "  Close to the phone's own rate = working. Close to your throttled"
echo "  hotspot rate = the bridge is the bottleneck, not the carrier."

echo
if [[ "$FAILURES" -eq 0 ]]; then
  green "All traffic classes accounted for — nothing leaked."; echo
  echo
  echo "Record this matrix AND the throughput, dated, in docs/device-test-log.md."
  exit 0
fi

red "$FAILURES traffic class(es) did not behave as expected."; echo
echo
echo "Rows 1–6 must show the phone's carrier IP. Row 7 must be blocked."
echo "A DIRECT result means that traffic bypassed the bridge and revealed"
echo "this Mac's real address."
[[ "$STRICT" -eq 1 ]] && exit 1
exit 0
