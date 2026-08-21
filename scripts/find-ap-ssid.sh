#!/bin/bash
#
# Read-only. Finds where macOS actually stores the hosted access point's SSID.
#
# NAT:AirPort:NetworkName in com.apple.nat.plist is written, accepted, and
# ignored: the Mac broadcast "UpLink-Spike" while that field read
# "UpLink-c743de63". The live software-AP configuration is somewhere else, and
# every candidate needs root to read.
#
#     sudo ./scripts/find-ap-ssid.sh
#
set -uo pipefail
OUT=/tmp/uplink-ap-ssid.txt
: >"$OUT"

say() { printf '\n===== %s =====\n' "$1" >>"$OUT"; }

say "WHAT THE IGNORED FIELD SAYS"
/usr/bin/plutil -extract NAT.AirPort.NetworkName raw -o - \
    /Library/Preferences/SystemConfiguration/com.apple.nat.plist >>"$OUT" 2>&1

say "AIRPORT PREFERENCES (prime suspect)"
/usr/bin/plutil -p /Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist >>"$OUT" 2>&1

say "ANYTHING CONTAINING THE NAME ON THE AIR"
# The name is the search key: whatever file holds it is the file that matters.
/usr/bin/grep -rls "UpLink-Spike" \
    /Library/Preferences /var/db /Library/Application\ Support/com.apple.TCC \
    2>/dev/null >>"$OUT"
echo "(grep done)" >>"$OUT"

say "OTHER SOFTWARE-AP CANDIDATES"
for f in \
    /Library/Preferences/com.apple.wifi.plist \
    /Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist \
    /Library/Preferences/com.apple.airport.opproxy.plist
do
    [ -e "$f" ] && { echo "--- $f"; /usr/bin/plutil -p "$f" 2>&1 | head -25; } >>"$OUT"
done

say "SYSTEM KEYCHAIN ENTRY FOR THE HOSTED NETWORK"
/usr/bin/security find-generic-password -s AirPort -a "UpLink-Spike" \
    /Library/Keychains/System.keychain >>"$OUT" 2>&1
echo "(keychain done)" >>"$OUT"

printf 'Done. Read %s\n' "$OUT"
