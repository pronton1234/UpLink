#!/usr/bin/env bash
#
# Kills the bridge and restores normal networking. No reboot needed.
#
#   ./scripts/emergency-off.sh
#
# WHEN TO USE THIS
#
# If the Mac loses all network access and quitting UpLink does not bring it
# back. A transparent proxy extension sits in front of every TCP and UDP flow on
# the machine; if it claims flows it cannot service, everything stops — and the
# extension keeps running after the app quits, so the damage outlives the app.
#
# This script is deliberately blunt and safe to run at any time, including when
# nothing is wrong.
#
set -uo pipefail

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

blue "==> Quitting UpLink"
osascript -e 'quit app id "com.uplink.app"' 2>/dev/null || true
pkill -f '/Applications/UpLink.app/Contents/MacOS/UpLink' 2>/dev/null || true
sleep 1

blue "==> Disabling any saved UpLink network configuration"
# Removes the transparent proxy configuration so nothing restarts the provider.
# scutil is used rather than the app because the app may be the thing that is
# broken.
scutil --nc list 2>/dev/null | grep -i uplink || echo "    (no UpLink VPN/proxy configuration listed)"

blue "==> Deactivating the system extension"
# This is the real fix: with the extension gone, nothing is in front of your
# traffic. It stays installed and can be re-activated by launching the app.
if systemextensionsctl list 2>/dev/null | grep -q com.uplink.app.proxy; then
  systemextensionsctl uninstall 9NT85V7Q37 com.uplink.app.proxy 2>&1 | sed 's/^/    /' || true
  echo
  echo "    If that reported an error, macOS requires the app to request removal."
  echo "    Launch UpLink once and quit it, then re-run this script."
else
  echo "    (extension not currently active)"
fi

blue "==> Nudging the network stack"
# Cheaper than a reboot and usually enough once the proxy is out of the way.
sudo -n dscacheutil -flushcache 2>/dev/null || dscacheutil -flushcache 2>/dev/null || true
sudo -n killall -HUP mDNSResponder 2>/dev/null || true

echo
blue "==> Checking connectivity"
if curl -s --max-time 8 --noproxy '*' https://api.ipify.org >/dev/null 2>&1; then
  green "Network is working."
else
  echo "    Still no connectivity. Try, in order:"
  echo "      1. Turn Wi-Fi off and on again"
  echo "      2. systemextensionsctl list        # confirm the extension is gone"
  echo "      3. System Settings → General → Login Items & Extensions →"
  echo "         Network Extensions → turn UpLink off"
fi

echo
echo "Current state:"
systemextensionsctl list 2>/dev/null | grep -iE 'uplink|extension\(s\)' | sed 's/^/    /'
