#!/usr/bin/env bash
#
# One-shot answer to "why isn't it bridging?", in the order the failures
# actually happen.
#
# The three not-bridging states have completely different remedies — no cable,
# cable but nothing listening on the phone, cable and listener but no pairing —
# and before this they all looked the same from a terminal. Each check below
# prints what to do about it rather than just what it found.
set -uo pipefail

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }

blue "==> 1. Is usbmuxd reachable?"
if [[ -S /var/run/usbmuxd ]]; then
    green "    /var/run/usbmuxd is present"
else
    red   "    /var/run/usbmuxd is missing — usbmuxd is not running."
    red   "    This is not a normal state; a reboot is the usual fix."
    exit 1
fi

blue "==> 2. Is an iPhone attached BY CABLE?"
# `devicectl` lists devices paired over Wi-Fi too, and they are useless here:
# the entire premise is that the Mac is not depending on a network. The app
# filters these out by ConnectionType; this mirrors that.
DEVICES=$(xcrun devicectl list devices 2>/dev/null | grep -i iphone || true)
if [[ -z "$DEVICES" ]]; then
    red   "    No iPhone found."
    red   "    → Plug the cable in. If it is already in, try a different cable:"
    red   "      a charge-only cable presents no data interface at all."
    exit 1
fi
echo "$DEVICES" | sed 's/^/    /'
green "    an iPhone is attached"

blue "==> 3. Is UpLink running on the phone?"
# The Mac probes the extension's port first, then the app's. Which one answers
# is worth knowing: the app's port means the bridge dies when the phone is
# locked or the app is backgrounded.
FOUND=""
for PORT in 50505 50506; do
    if nc -z -G 1 127.0.0.1 "$PORT" 2>/dev/null; then FOUND="$PORT"; fi
done
LOG=$(/usr/bin/log show --last 2m --predicate 'subsystem == "com.uplink.app"' --style compact 2>/dev/null || true)
RELAY=$(echo "$LOG" | grep -E "usb: relaying|usb: attached|answered on neither" | tail -3)
if [[ -n "$RELAY" ]]; then
    echo "$RELAY" | sed 's/^/    /'
fi
if echo "$LOG" | grep -q "answered on neither"; then
    red   "    The phone did not answer on either port."
    red   "    → Open UpLink on the iPhone and turn the bridge on."
    exit 1
fi
if echo "$RELAY" | grep -q "foreground app"; then
    warn "    Answering on the APP's port, not the extension's."
    warn "    → The bridge will drop when the phone locks or the app is"
    warn "      backgrounded. Worth recording in docs/device-test-log.md:"
    warn "      it means usbmux cannot reach a Network Extension listener."
fi

blue "==> 4. Is a session live?"
SESSION=$(echo "$LOG" | grep -E "session started|session ENDED" | tail -1)
case "$SESSION" in
    *"session started"*) green "    a session is live: ${SESSION##*session }" ;;
    *"session ENDED"*)   red   "    the last event was a session ENDING: ${SESSION##*session }"; exit 1 ;;
    *)
        red "    No session."
        red "    → If the phone is answering, this Mac is probably not paired"
        red "      with it. Open UpLink's Devices window and pair."
        exit 1
        ;;
esac

blue "==> 5. Is the egress actually cellular?"
EGRESS=$(echo "$LOG" | grep -E "egress:" | tail -1)
case "$EGRESS" in
    *[Cc]ellular*) green "    ${EGRESS##*egress: }" ;;
    "")            warn "    nothing measured yet — the egress is only observed once real traffic goes out" ;;
    *)             red  "    NOT cellular: ${EGRESS##*egress: } — you are not bypassing anything"; exit 1 ;;
esac

green "OK — cable attached, phone answering, session live."
