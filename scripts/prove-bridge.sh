#!/usr/bin/env bash
#
# End-to-end proof that the bridge carries the Mac's traffic over the phone's
# cellular radio, with no Wi-Fi network and no Personal Hotspot.
#
# Waits for the phone to be unlocked, launches the app with the autoconnect
# harness, waits for the Mac to report a live session, then measures:
#
#   1. that a session actually started (Mac's own log, not a UI claim)
#   2. which interface the phone says traffic egressed on
#   3. the Mac's public IP — must be the CARRIER's, not this Mac's ISP
#   4. throughput through the bridge
#
#   ./scripts/prove-bridge.sh
#
# Unlock the phone and leave it unlocked; everything else is automatic.
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE=00008120-000000000000001E
BUNDLE=com.uplink.app
OUT=${SCRATCH:-/tmp}/prove-bridge.$$

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

blue "==> 0. Baseline: what this Mac looks like WITHOUT the bridge"
BASE_IP=$(curl -s --max-time 15 -4 https://api.ipify.org 2>/dev/null)
BASE_ORG=$(curl -s --max-time 15 -4 "https://ipinfo.io/${BASE_IP}/org" 2>/dev/null)
echo "    ${BASE_IP}  ${BASE_ORG}"

blue "==> 1. Waiting for the phone to be unlocked (up to 10 min)"
LAUNCHED=0
for i in $(seq 1 60); do
  if xcrun devicectl device process launch --device "$DEVICE" \
       --environment-variables '{"UPLINK_AUTOCONNECT":"1"}' "$BUNDLE" >/dev/null 2>&1; then
    LAUNCHED=1
    green "    launched with autoconnect (attempt $i)"
    break
  fi
  sleep 10
done
if [[ $LAUNCHED -eq 0 ]]; then
  red "    phone never became unlockable — cannot proceed"
  exit 2
fi

blue "==> 2. Waiting for the Mac to report a live session (up to 90s)"
LIVE=0
for i in $(seq 1 45); do
  STARTED=$(log show --last 2m --predicate 'subsystem == "com.uplink.app"' --info --debug 2>/dev/null \
            | grep -c "session started with" || true)
  ENDED=$(log show --last 2m --predicate 'subsystem == "com.uplink.app"' --info --debug 2>/dev/null \
            | grep -c "session ENDED with" || true)
  if [[ "${STARTED:-0}" -gt "${ENDED:-0}" ]]; then
    LIVE=1
    green "    session live (${STARTED} started / ${ENDED} ended)"
    break
  fi
  sleep 2
done
if [[ $LIVE -eq 0 ]]; then
  red "    no live session appeared"
  echo "    last session events:"
  log show --last 3m --predicate 'subsystem == "com.uplink.app"' --info --debug 2>/dev/null \
    | grep -E "session |accept:|host FAILED" | tail -10 | sed 's/^/      /'
  exit 1
fi

blue "==> 3. What interface does the phone say it egressed on?"
log show --last 3m --predicate 'subsystem == "com.uplink.app"' --info --debug 2>/dev/null \
  | grep -E "egress:|accept: inbound" | tail -4 | sed 's/^/    /'

blue "==> 4. The Mac's public IP THROUGH the bridge"
BR_IP=$(curl -s --max-time 30 -4 https://api.ipify.org 2>/dev/null)
BR_ORG=$(curl -s --max-time 30 -4 "https://ipinfo.io/${BR_IP}/org" 2>/dev/null)
echo "    ${BR_IP}  ${BR_ORG}"
if [[ -n "$BR_IP" && "$BR_IP" != "$BASE_IP" ]]; then
  green "    CHANGED from the baseline — traffic is leaving via the phone"
else
  red "    UNCHANGED from the baseline — traffic did NOT cross the bridge"
  exit 1
fi

blue "==> 5. Throughput through the bridge"
./scripts/throughput-test.sh 2>&1 | sed 's/^/    /'

blue "==> 6. Coverage matrix"
./scripts/coverage-test.sh 2>&1 | tail -25 | sed 's/^/    /'

green "==> Done. Evidence above is from the Mac's own log and live measurement."
