#!/usr/bin/env bash
#
# Installs the built Mac app into /Applications and launches it.
#
# REQUIRED to exercise the bridge. The Mac app DOES ship a system extension
# (com.uplink.app.proxy), and macOS will not activate one from a build running
# out of Xcode's derived data — it has to be installed in /Applications, and for
# a real run it has to be Developer ID signed and notarized. Pressing Run in
# Xcode gets you the UI and nothing behind it.
#
# For a notarized build, use ./scripts/release-mac.sh instead. This script is
# for the app-shaped parts: menu bar, pairing UI, device list.
#
#   ./scripts/run-mac.sh            # copy the newest Debug build and launch
#   ./scripts/run-mac.sh --build    # build first, then copy and launch
#   ./scripts/run-mac.sh /path/to/UpLink.app
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.uplink.app"
DEST="/Applications/UpLink.app"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

APP=""
if [[ "${1:-}" == "--build" ]]; then
  blue "==> Building UpLinkMac (Debug, signed)"
  # Signed for real: an unsigned build cannot activate a system extension.
  xcodebuild build \
    -project UpLink.xcodeproj \
    -scheme UpLinkMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -quiet
elif [[ -n "${1:-}" ]]; then
  APP="$1"
fi

if [[ -z "$APP" ]]; then
  blue "==> Locating the newest macOS Debug build"
  APP=$(find ~/Library/Developer/Xcode/DerivedData \
          -maxdepth 5 -type d -name 'UpLink.app' -path '*/Build/Products/Debug/*' \
          2>/dev/null | head -1)
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
  red "Could not find a built UpLink.app."
  echo "Build it in Xcode first, or run: ./scripts/run-mac.sh --build"
  exit 1
fi

# Sanity check: this is our app, not something that merely shares the name.
FOUND_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null || echo "")
if [[ "$FOUND_ID" != "$BUNDLE_ID" ]]; then
  red "Refusing to install: $APP has bundle ID '$FOUND_ID', expected '$BUNDLE_ID'."
  exit 1
fi

blue "==> Source: $APP"

# Replace any previous copy. Guarded above so this can only ever remove a
# bundle that identifies itself as ours.
if [[ -d "$DEST" ]]; then
  EXISTING_ID=$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    red "$DEST exists but is not UpLink (bundle ID '$EXISTING_ID'). Not touching it."
    exit 1
  fi
  blue "==> Quitting any running instance"
  osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
  pkill -f "$DEST/Contents/MacOS/UpLink" 2>/dev/null || true
  sleep 1
  blue "==> Removing previous $DEST"
  rm -rf "$DEST"
fi

blue "==> Installing to $DEST"
cp -R "$APP" "$DEST"

blue "==> Launching"
open "$DEST"

echo
green "Installed and launched from /Applications."
echo
echo "Check the Mac side is up:"
echo "  systemextensionsctl list             # the proxy extension, if activated"
echo "  dns-sd -B _uplink._tcp               # advertising to the phone"
