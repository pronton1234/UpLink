#!/bin/bash
#
# Phase 0, question 1: does writing com.apple.nat.plist and kickstarting
# com.apple.NetworkSharing actually raise the access point on macOS 26?
#
# THIS TAKES THE WI-FI RADIO AWAY FOR ABOUT TWENTY SECONDS. That is not a side
# effect, it is the measurement: Internet Sharing hosts the access point on the
# same radio this Mac uses to reach the internet. Anything driving this machine
# remotely goes blind exactly when there is something to see, which is why the
# script captures to a file, restores, and leaves you to read the file
# afterwards rather than printing as it goes.
#
# It always restores the original configuration, including on Ctrl-C.
#
#     sudo ./scripts/ap-probe.sh
#     cat /tmp/uplink-ap-probe.txt
#
set -uo pipefail

PLIST=/Library/Preferences/SystemConfiguration/com.apple.nat.plist
OUT=/tmp/uplink-ap-probe.txt
BACKUP=/tmp/uplink-nat-backup.plist
SSID="UpLink"
PASSPHRASE="uplink-probe-passphrase"

if [[ $EUID -ne 0 ]]; then
    echo "needs root: sudo $0" >&2
    exit 1
fi

say() { printf '\n===== %s =====\n' "$1" >>"$OUT"; }
run() { printf '\n$ %s\n' "$*" >>"$OUT"; "$@" >>"$OUT" 2>&1; }

restore() {
    say "RESTORING"
    if [[ -f "$BACKUP" ]]; then
        cp "$BACKUP" "$PLIST"
        printf 'restored original %s\n' "$PLIST" >>"$OUT"
    else
        printf 'NO BACKUP TO RESTORE — check %s by hand\n' "$PLIST" >>"$OUT"
    fi
    launchctl kickstart -k system/com.apple.NetworkSharing >>"$OUT" 2>&1
    sleep 3
    run /sbin/ifconfig -l
    printf '\nDone. Read %s\n' "$OUT"
}
trap restore EXIT INT TERM

: >"$OUT"
say "WHEN"
run /bin/date

say "BEFORE — the configuration as it stands"
run /usr/bin/plutil -p "$PLIST"
run /sbin/ifconfig -l
run /usr/sbin/networksetup -listallhardwareports

# The source must be the product's own dead-end tunnel, so the access point
# comes up with nothing behind it. Read it rather than hardcode it: this Mac
# already records PrimaryUserReadable => "UpLink Route" from the August run.
SERVICE=$(/usr/bin/plutil -extract NAT.PrimaryService raw -o - "$PLIST" 2>/dev/null)
SOURCE_NAME=$(/usr/bin/plutil -extract NAT.PrimaryInterface.PrimaryUserReadable raw -o - "$PLIST" 2>/dev/null)
WIFI_DEV=$(/usr/sbin/networksetup -listallhardwareports \
    | awk '/Hardware Port: Wi-Fi/{getline; print $2}')

say "WHAT WILL BE WRITTEN"
{
    echo "PrimaryService  : ${SERVICE:-<none>}"
    echo "source name     : ${SOURCE_NAME:-<none>}"
    echo "Wi-Fi device    : ${WIFI_DEV:-<none>}"
    echo "SSID            : $SSID"
} >>"$OUT"

if [[ -z "${SERVICE:-}" || -z "${WIFI_DEV:-}" ]]; then
    say "ABORTED"
    echo "missing PrimaryService or Wi-Fi device; not writing anything" >>"$OUT"
    exit 1
fi

cp "$PLIST" "$BACKUP"

say "WRITING"
# defaults, not plutil: the file is a system preference and defaults is what
# actually round-trips the nested dictionaries here.
defaults write "${PLIST%.plist}" NAT -dict-add Enabled -int 1 >>"$OUT" 2>&1
defaults write "${PLIST%.plist}" NAT -dict-add SharingDevices -array "$WIFI_DEV" >>"$OUT" 2>&1
/usr/libexec/PlistBuddy -c "Set :NAT:AirPort:Enabled 1" "$PLIST" >>"$OUT" 2>&1
/usr/libexec/PlistBuddy -c "Set :NAT:AirPort:NetworkName $SSID" "$PLIST" >>"$OUT" 2>&1
run /usr/bin/plutil -p "$PLIST"

say "KICKSTART"
run launchctl kickstart -k system/com.apple.NetworkSharing
sleep 12

say "AFTER — did anything actually come up?"
# bridge100 carrying the gateway and a dedicated ap1 in the bridge is what an
# access point that is genuinely up looks like on this hardware. en0 reading
# 'inactive' while hosting is expected and is NOT evidence of failure.
run /sbin/ifconfig -l
run /sbin/ifconfig bridge100
run /sbin/ifconfig ap1
run /sbin/ifconfig en0

say "AFTER — what the config reads back as"
# Expected to disagree with what was written. The plist is input, not output:
# configd consumes it into live state and does not write back. This block exists
# to record that disagreement, not to judge success by it.
run /usr/bin/plutil -p "$PLIST"

say "AFTER — SharingDevices with the AP up (the value Task 4 needs)"
run /usr/bin/plutil -extract NAT.SharingDevices json -o - "$PLIST"

say "AFTER — what the daemon said"
run /usr/bin/log show --last 2m --predicate 'process == "InternetSharing"' --style compact

# THE BEST EVIDENCE IN THIS FILE.
#
# com.apple.SystemConfiguration.ISPreference is a configd plugin, Enabled=true,
# and its strings reference com.apple.nat.plist, com.apple.NetworkSharing and
# SharingDevices. It is what reads the preference and starts the daemon from it
# — which is both why writing the file is the supported input path and why the
# setting survives a reboot at all. It logs its own decision ("preference: NAT
# disabled"), so this says what configd concluded rather than leaving us to
# infer it from interfaces that may lag or lie.
say "AFTER — what configd's Internet Sharing plugin concluded"
run /usr/bin/log show --last 2m --predicate 'process == "configd"' --style compact
run /usr/bin/log show --last 2m --predicate 'subsystem == "com.apple.SystemConfiguration"' --style compact

say "REBOOT PERSISTENCE — what to check after restarting"
{
    echo "The plugin above is what restores this at boot, so if the AP came up"
    echo "here it should also come up after a restart. To confirm, leave NAT"
    echo "enabled, reboot, and run:"
    echo
    echo "    ifconfig bridge100 && pgrep -x InternetSharing"
    echo
    echo "This probe deliberately restores the original config, so it does NOT"
    echo "leave anything enabled to reboot into. That is a separate deliberate"
    echo "step, not something to do by accident."
} >>"$OUT"

say "VERDICT INPUTS"
{
    echo "bridge100 present : $(/sbin/ifconfig bridge100 >/dev/null 2>&1 && echo YES || echo NO)"
    echo "ap1 running       : $(/sbin/ifconfig ap1 2>/dev/null | grep -q RUNNING && echo YES || echo NO)"
    echo "InternetSharing   : $(pgrep -x InternetSharing >/dev/null && echo RUNNING || echo NOT RUNNING)"
} >>"$OUT"

exit 0
