#!/bin/bash
#
# Records what happens while the wireless bridge is being brought up.
#
# The Mac under test is the Mac driving the test, and raising the access point
# takes its Wi-Fi radio — so anything watching from here goes blind at exactly
# the moment there is something to see. This writes to disk instead, to be read
# afterwards.
#
# It lives in the repo rather than /tmp because a reboot clears /tmp, and a
# reboot is a normal part of this work: system extensions only uninstall then.
#
#   ./scripts/wireless-watch.sh &
#
# Then read /tmp/uplink-watch-samples.txt and /tmp/uplink-watch-log.txt.
set -uo pipefail
SAMPLES=${UPLINK_WATCH_SAMPLES:-/tmp/uplink-watch-samples.txt}
LOGFILE=${UPLINK_WATCH_LOG:-/tmp/uplink-watch-log.txt}
MINUTES=${UPLINK_WATCH_MINUTES:-40}
PHONE=${UPLINK_WATCH_PHONE:-}

: >"$SAMPLES"; : >"$LOGFILE"
echo "started $(date)" >>"$SAMPLES"

# The quoting here matters. A predicate passed through `nohup bash -c` loses its
# inner quotes and the stream silently matches nothing — which reads exactly
# like a subsystem that is not logging, and cost an hour of believing IPC was
# dead when it was carrying 25 messages every 22 seconds.
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "com.uplink.app" OR process == "InternetSharing"' \
  >>"$LOGFILE" 2>&1 &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null' EXIT

for i in $(seq 1 $((MINUTES * 12))); do
    # The phone's address is read from the lease each time rather than fixed.
    # A hardcoded 192.168.2.2 reported "no entry" for a phone that was present
    # and healthy on .3, which was read as the phone having left.
    if [ -z "$PHONE" ]; then
        LEASE=$(/usr/bin/awk -F= '/ip_address/{a=$2} END{print a}' /var/db/dhcpd_leases 2>/dev/null)
    else
        LEASE=$PHONE
    fi
    {
        echo "--- t=$((i * 5))s $(date +%H:%M:%S) ---"
        printf 'bridge100: '; /sbin/ifconfig bridge100 2>/dev/null | grep 'inet ' || echo absent
        printf 'en0: '; /sbin/ifconfig en0 2>/dev/null | grep -E 'status:' | tr -d '\t'
        printf 'InternetSharing: '; pgrep -x InternetSharing >/dev/null && echo running || echo stopped
        printf 'phone(%s): ' "${LEASE:-none}"
        if [ -n "$LEASE" ]; then
            /usr/sbin/arp -n "$LEASE" 2>&1 | head -1
            printf 'route: '; /sbin/route -n get "$LEASE" 2>/dev/null | grep interface | tr -d ' \t'
        else
            echo "no lease yet"
        fi
    } >>"$SAMPLES"
    sleep 5
done
echo "finished $(date)" >>"$SAMPLES"
