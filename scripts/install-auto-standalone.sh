#!/usr/bin/env bash
#
# Installs the network watcher as a root LaunchDaemon, so the Mac reconfigures
# itself around the bridge and nothing has to be done by hand.
#
# After this, the whole flow is: connect from the phone, disconnect Wi-Fi, use
# the Mac. Browsers, apps and the terminal all just work, because the route and
# the resolver appear on their own.
#
#   sudo ./scripts/install-auto-standalone.sh
#   sudo ./scripts/install-auto-standalone.sh --uninstall
#   ./scripts/install-auto-standalone.sh --status
#
# Deliberately a LaunchDaemon rather than part of the app: the change needs root
# and neither half of the product has it. The system extension runs as root but
# is sandboxed, so it cannot call `networksetup`; the containing app is not
# sandboxed but is not root. See uplink-netwatch.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

LABEL="com.uplink.netwatch"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALLED_SCRIPT="/usr/local/libexec/uplink-netwatch.sh"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

case "${1:-install}" in

  --status)
    blue "==> Watcher"
    if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
      green "    loaded"
      launchctl print "system/${LABEL}" 2>/dev/null | grep -E "state =|pid =" | sed 's/^/    /'
    else
      echo "    not loaded"
    fi
    echo
    blue "==> Recent decisions"
    /usr/bin/log show --last 30m --predicate 'process == "logger" OR eventMessage CONTAINS "uplink-netwatch"' \
      --style compact 2>/dev/null | grep -i netwatch | tail -10 | sed 's/^/    /' \
      || echo "    (none logged yet)"
    exit 0
    ;;

  --uninstall)
    [[ $EUID -ne 0 ]] && { red "Needs root: sudo $0 --uninstall"; exit 1; }
    blue "==> Removing the watcher"
    launchctl bootout "system/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST" "$INSTALLED_SCRIPT"
    green "    removed"
    # Leave the Mac on DHCP rather than however the watcher last set it.
    networksetup -setdhcp "${UPLINK_WIFI_SERVICE:-Wi-Fi}" 2>/dev/null || true
    green "    Wi-Fi returned to DHCP"
    exit 0
    ;;

  install|"")
    [[ $EUID -ne 0 ]] && { red "Needs root: sudo $0"; exit 1; }
    ;;

  *) red "usage: $0 [--uninstall|--status]"; exit 1 ;;
esac

blue "==> Installing the watcher"
# Copied out of the repo on purpose: a LaunchDaemon that runs a script from a
# user-writable working tree is a privilege-escalation path, since anything that
# can edit the repo would then be running as root.
install -d -m 755 /usr/local/libexec
install -m 755 -o root -g wheel "$REPO/scripts/uplink-netwatch.sh" "$INSTALLED_SCRIPT"
green "    $INSTALLED_SCRIPT"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALLED_SCRIPT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/uplink-netwatch.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/uplink-netwatch.log</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
green "    $PLIST"

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
sleep 2

if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  green "==> Running."
  echo
  echo "  From now on, with the bridge connected you can simply disconnect"
  echo "  Wi-Fi and keep working — the route and resolver appear on their own,"
  echo "  and go away again when the bridge does."
  echo
  echo "  Watch it decide:  tail -f /var/log/uplink-netwatch.log"
  echo "  Remove it:        sudo $0 --uninstall"
else
  red "==> Did not start. Check /var/log/uplink-netwatch.log"
  exit 1
fi
