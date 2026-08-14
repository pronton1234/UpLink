#!/usr/bin/env bash
#
# Measures how fast the bridge actually is, and compares it to what the phone's
# own radio says it is getting.
#
# `coverage-test.sh` answers "did the traffic go through the phone?". It says
# nothing about speed, and a bridge that is correct and unusably slow still
# fails the user. This turns "night and day difference" into a number.
#
#   ./scripts/throughput-test.sh            # measure and print
#   ./scripts/throughput-test.sh --baseline # measure WITHOUT the bridge, to compare
#
# The comparison that matters is bridge throughput vs. the phone's own reported
# cellular bandwidth. The phone publishes that itself:
#
#   CommCenter: Setting interface bandwidth for 'pdp_ip0':
#               uplink: 750000 bps, downlink: 19181250 bps, rat: kLTE
#
# so the radio's own estimate is read from the device log rather than guessed at.
set -uo pipefail
cd "$(dirname "$0")/.."

BASELINE=0
[[ "${1:-}" == "--baseline" ]] && BASELINE=1

green() { printf '\033[0;32m%s\033[0m' "$1"; }
red()   { printf '\033[0;31m%s\033[0m' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

# Cloudflare's own speed endpoint: no signup, no redirect chain, and it serves
# an exact byte count so the arithmetic is honest.
DOWN_URL="https://speed.cloudflare.com/__down?bytes="
UP_URL="https://speed.cloudflare.com/__up"

# ── Refuse to measure a dead session ──────────────────────────────────────
# Same rule as coverage-test.sh, and for the same reason: numbers taken from a
# session that has already ended look like a catastrophically slow bridge and
# are really a measurement of nothing.
if [[ $BASELINE -eq 0 ]]; then
  blue "==> Checking the bridge is actually up"
  # Compare the LATEST start against the LATEST end over a wide window.
  # An earlier version required a start within the last 2 minutes, which
  # rejected a perfectly healthy session that had simply been up for a while —
  # the better the bridge works, the more certainly that check failed.
  LIVE=$(log show --last 45m --predicate 'subsystem == "com.uplink.app"' --info --debug 2>/dev/null \
    | grep -E "session started with|session ENDED with" \
    | tail -1 | grep -c "session started with" || true)
  if [[ "${LIVE:-0}" -ne 1 ]]; then
    red "    no live session — the last event was not a session start"; echo
    echo "    Connect from the phone first, then re-run. Measuring a dead"
    echo "    session produces confident, wrong numbers."
    exit 2
  fi
  green "    session is live"; echo
fi

# ── Download ──────────────────────────────────────────────────────────────
# Three sizes. A single small transfer measures TCP slow-start, not bandwidth;
# a single large one hides a stall behind an average. Rising numbers across the
# three is itself the signature of a window-limited link.
blue "==> Download"
for BYTES in 1000000 10000000 25000000; do
  MB=$(echo "scale=1; $BYTES/1000000" | bc)
  # Read the byte count too. An earlier version timed the transfer and divided,
  # without checking anything arrived — so a failed DNS lookup that returned
  # zero bytes after 30s was reported as a confident "0.26 Mbps", which reads as
  # a slow bridge and was really a total failure. Never rate a transfer that
  # moved nothing.
  READ=$(curl -s -o /dev/null --max-time 120 -w '%{time_total} %{size_download}' "${DOWN_URL}${BYTES}" 2>/dev/null)
  SECS=$(echo "$READ" | awk '{print $1}')
  GOT=$(echo "$READ" | awk '{print $2}')
  if [[ -z "$SECS" || "$SECS" == "0.000000" || "${GOT:-0}" -eq 0 ]]; then
    red "    ${MB} MB: FAILED — ${GOT:-0} bytes after ${SECS:-?}s (not a speed result)"; echo
    continue
  fi
  BYTES=$GOT
  MBPS=$(echo "scale=2; ($BYTES*8)/($SECS*1000000)" | bc)
  printf '    %6s MB in %6ss  =  ' "$MB" "$SECS"; green "${MBPS} Mbps"; echo
done

# ── Upload ────────────────────────────────────────────────────────────────
blue "==> Upload"
UPBYTES=5000000
TMP=$(mktemp)
dd if=/dev/zero of="$TMP" bs=1000000 count=5 2>/dev/null
UPREAD=$(curl -s -o /dev/null --max-time 120 -w '%{time_total} %{http_code}' -X POST --data-binary "@$TMP" "$UP_URL" 2>/dev/null)
SECS=$(echo "$UPREAD" | awk '{print $1}')
CODE=$(echo "$UPREAD" | awk '{print $2}')
if [[ -n "$SECS" && "$SECS" != "0.000000" && "${CODE:-000}" != "000" ]]; then
  MBPS=$(echo "scale=2; ($UPBYTES*8)/($SECS*1000000)" | bc)
  printf '    %6s MB in %6ss  =  ' "5.0" "$SECS"; green "${MBPS} Mbps"; echo
else
  red "    upload failed"; echo
fi
rm -f "$TMP"

# ── Latency ───────────────────────────────────────────────────────────────
# Round-trip time is what caps a windowed link: throughput can never exceed
# window / RTT, so a high RTT here explains a low number above.
blue "==> Round-trip time to the destination"
RTT=$(curl -s -o /dev/null --max-time 30 -w '%{time_connect}' "${DOWN_URL}1000" 2>/dev/null)
if [[ -n "$RTT" && "$RTT" != "0.000000" ]]; then
  RTTMS=$(echo "scale=1; $RTT*1000" | bc)
  echo "    TCP connect (Mac → phone → destination): ${RTTMS} ms"
  echo
  # Deliberately NOT presented as a window ceiling. The multiplexer's 256 KiB
  # per-stream window governs the Mac↔phone hop only — the phone dials the
  # destination on a separate socket — so the credit loop turns around at AWDL
  # latency (single-digit ms), not at the figure above. Dividing the window by
  # this RTT would overstate the window's role and send you tuning the wrong
  # knob; that mistake was made once already.
  echo "    Note: this RTT spans the whole path. The mux window applies only to"
  echo "    the Mac↔phone hop, so do not divide one by the other. If throughput"
  echo "    is far below the phone's own downlink, suspect the cellular dial or"
  echo "    the AWDL hop before the window."
fi

# ── What the phone's own radio reports ────────────────────────────────────
blue "==> The phone's own view of its cellular link"
if command -v idevicesyslog >/dev/null 2>&1; then
  echo "    (reading pdp_ip0 bandwidth from the device log, 15s sample)"
  SAMPLE=$( (idevicesyslog --no-colors -p CommCenter 2>/dev/null & SP=$!; sleep 15; kill $SP 2>/dev/null) \
            | grep -aE "Setting interface bandwidth for 'pdp_ip0'" | tail -3 )
  if [[ -n "$SAMPLE" ]]; then
    echo "$SAMPLE" | sed 's/^/    /'
  else
    echo "    no bandwidth report seen in the sample window"
  fi
else
  echo "    idevicesyslog not installed — skipping"
fi

echo
echo "Compare the download number against the phone's own downlink figure."
echo "If the bridge is far below it, the link is the bottleneck, not the radio."
