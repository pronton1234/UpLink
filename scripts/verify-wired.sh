#!/usr/bin/env bash
#
# The whole wired-transport verification, unattended, in one command.
#
# Waits for the cable, then runs every check the change needs in the order the
# failures actually happen, and prints one verdict at the end. Nothing here
# reports a pass it did not observe — the existing scripts already refuse to
# measure a dead session, and this refuses to summarise one.
#
#     ./scripts/verify-wired.sh              # wait up to 10 min for the cable
#     ./scripts/verify-wired.sh --no-wait    # fail immediately if unplugged
#
# Prerequisites, because getting these wrong produces a confident wrong answer
# rather than an error (see docs/device-test-log.md):
#
#   * BOTH sides rebuilt and reinstalled. Installing the iOS app does not
#     restart a running NE extension.
#   * The never-bridge list set by PATH, with remotepairingd on it.
#   * No commercial VPN up.
#   * The Mac's Wi-Fi radio OFF, not merely disconnected.
set -uo pipefail
cd "$(dirname "$0")/.."

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }

WAIT=1
[[ "${1:-}" == "--no-wait" ]] && WAIT=0

FAILED=0
note_fail() { red "  FAIL: $*"; FAILED=1; }

blue "=== 0. The codec, against Apple's own daemon ==="
# Needs no device, and it is the check that found `badVersion` was 5 when the
# daemon says 6 — a mistake the unit tests could not catch, because the fake
# they run against was built on the same assumption.
if swift run --package-path spike/usb-probe usb-probe --selftest 2>&1 | grep -q "Codec verified"; then
    green "  codec agrees with the real usbmuxd"
else
    note_fail "the codec does not match the real usbmuxd — stop here"
    exit 1
fi

blue "=== 1. Waiting for the cable ==="
DEADLINE=$(( $(date +%s) + 600 ))
while true; do
    if swift run --package-path spike/usb-probe usb-probe 2>/dev/null | grep -q "^Device:"; then
        green "  a cabled iPhone is attached"
        break
    fi
    if [[ $WAIT -eq 0 ]]; then
        red "  No cabled iPhone. Plug one in, or drop --no-wait."
        exit 1
    fi
    if [[ $(date +%s) -ge $DEADLINE ]]; then
        red "  No iPhone within 10 minutes. Nothing was verified."
        exit 1
    fi
    printf '\r  waiting… (plug the iPhone in, and unlock it)'
    sleep 3
done

blue "=== 2. Which side of the phone answers ==="
# THE open question this whole design hedged against: whether usbmux can reach
# a listener inside a Network Extension. The answer changes what is true about
# locking the phone, so it is recorded rather than merely passed over.
PROBE=$(swift run --package-path spike/usb-probe usb-probe 2>&1)
echo "$PROBE" | grep -E "^  port|^RESULT" | sed 's/^/  /'
if echo "$PROBE" | grep -q "usbmux CAN reach a listener inside a Network Extension"; then
    green "  the extension answered — the preferred path works"
    warn  "  → record this in docs/device-test-log.md and delete spike/usb-probe"
elif echo "$PROBE" | grep -q "only the FOREGROUND APP answered"; then
    warn "  only the app answered: the bridge will drop when the phone locks."
    warn "  → this is the finding that would justify moving the listener."
else
    note_fail "nothing answered — is UpLink running on the phone?"
    exit 1
fi

blue "=== 3. Cable, pairing, session, egress ==="
./scripts/usb-status.sh || note_fail "usb-status reported a problem"

blue "=== 4. The proof that cannot be faked ==="
# Toggles the Wi-Fi radio itself and restores it on exit, so a failure here
# cannot strand the operator with no network.
./scripts/verify-cellular.sh --full || note_fail "cellular verification did not pass"

blue "=== 5. Throughput ==="
# The question the user actually asked: does it browse at native data speeds?
# Compared against the radio's own bandwidth estimate, so "slow" means slow
# relative to what the phone itself thinks it has.
./scripts/throughput-test.sh || note_fail "throughput did not meet the radio's own estimate"

echo
if [[ $FAILED -eq 0 ]]; then
    green "PASS — the wired bridge carried real traffic over cellular."
    green "Record the date and the port that answered in docs/device-test-log.md."
else
    red "NOT PROVEN. Do not report this as working."
    red "Re-read the prerequisites at the top of this script: most failures here"
    red "are a stale build on the phone, a missing never-bridge entry, or a"
    red "Wi-Fi radio that is disconnected rather than off."
    exit 1
fi
