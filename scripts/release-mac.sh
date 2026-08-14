#!/usr/bin/env bash
#
# Build → sign (Developer ID) → notarize → staple → install → launch.
#
# This is the ONLY way to run the Mac app, because it contains a system
# extension. macOS activates one only if it is Developer ID signed AND
# notarized, or if SIP is off. We keep SIP on, so every build gets notarized.
#
# Notarization is an automated malware scan, not App Store review: no queue, no
# human, typically 1–3 minutes. It is invisible to end users, who just see a
# normal app.
#
# One-time setup (see docs/device-test-log.md):
#   1. Create a "Developer ID Application" certificate in Xcode
#      (Settings → Accounts → Manage Certificates → + )
#   2. Create an app-specific password at appleid.apple.com
#   3. xcrun notarytool store-credentials uplink-notary \
#        --apple-id you@example.com --team-id 9NT85V7Q37 --password <app-specific>
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

KEYCHAIN_PROFILE="${UPLINK_NOTARY_PROFILE:-uplink-notary}"
TEAM_ID="${UPLINK_TEAM_ID:-9NT85V7Q37}"
BUNDLE_ID="com.uplink.app"
DEST="/Applications/UpLink.app"
BUILD_DIR="$ROOT/build/release"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

# ── Preflight: fail with instructions, not a cryptic tool error ────────────
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  red "No 'Developer ID Application' certificate found."
  echo
  echo "Create one in Xcode → Settings → Accounts → (your Apple ID) →"
  echo "Manage Certificates → + → Developer ID Application."
  echo
  echo "An 'Apple Development' certificate is NOT enough: development profiles"
  echo "never carry the -systemextension entitlement values, and unnotarized"
  echo "extensions are refused by macOS unless SIP is disabled."
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  red "Notary credentials '$KEYCHAIN_PROFILE' are not stored."
  echo
  echo "Create an app-specific password at appleid.apple.com, then run:"
  echo "  xcrun notarytool store-credentials $KEYCHAIN_PROFILE \\"
  echo "    --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>"
  exit 1
fi

# ── Developer ID PROVISIONING PROFILES ────────────────────────────────────
# Distinct from the certificate. A system extension needs the
# "-systemextension" networkextension entitlement values, which ONLY Developer
# ID profiles carry — development profiles never do. Xcode cannot mint these
# automatically here: creating one requires an archive, and the archive cannot
# build without one.
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

find_profile() {
  local want_app_id="$1"
  local f name appid
  for f in "$PROFILE_DIR"/*.provisionprofile; do
    [[ -e "$f" ]] || continue
    local plist
    plist=$(security cms -D -i "$f" 2>/dev/null) || continue
    appid=$(printf '%s' "$plist" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw - 2>/dev/null)
    [[ "$appid" == "$TEAM_ID.$want_app_id" ]] || continue
    # Developer ID profiles have no provisioned devices and carry the
    # -systemextension entitlement values.
    printf '%s' "$plist" | grep -q "systemextension" || continue
    echo "$f"
    return 0
  done
  return 1
}

MISSING=0
for APP_ID in "$BUNDLE_ID" "$BUNDLE_ID.proxy"; do
  if ! find_profile "$APP_ID" >/dev/null; then
    [[ "$MISSING" -eq 0 ]] && red "Missing Developer ID provisioning profile(s):"
    echo "    - $APP_ID"
    MISSING=1
  fi
done

if [[ "$MISSING" -eq 1 ]]; then
  echo
  echo "  These must be created in your Apple Developer account. Xcode cannot do"
  echo "  it for you here: minting one needs a successful archive, and the archive"
  echo "  needs the profile."
  echo
  bold_line() { printf '\033[1m%s\033[0m\n' "$1"; }
  bold_line "  At https://developer.apple.com/account/resources/profiles/list"
  echo "    1. Click + to create a profile"
  echo "    2. Under Distribution choose 'Developer ID', then Continue"
  echo "    3. App ID: select the one listed above"
  echo "    4. Certificate: your 'Developer ID Application' certificate"
  echo "    5. Name it (e.g. 'UpLink Developer ID'), Generate, then Download"
  echo "    6. Double-click the downloaded .provisionprofile to install it"
  echo
  echo "  Repeat for each App ID listed above, then run this script again."
  echo
  echo "  Check the App ID has the Network Extensions capability enabled; without"
  echo "  it the generated profile will not carry the -systemextension values and"
  echo "  this check will keep failing."
  exit 1
fi

profile_name() {
  local f
  f=$(find_profile "$1") || return 1
  security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null
}

green "Developer ID provisioning profiles found:"
for APP_ID in "$BUNDLE_ID" "$BUNDLE_ID.proxy"; do
  echo "    $APP_ID → $(profile_name "$APP_ID")"
done

# Signing is configured per target in project.yml (it must be: a project-wide
# specifier matches one bundle ID and fails on the other). Verify the names
# there still match what is actually installed, so a regenerated profile with a
# different name fails here with an explanation rather than deep in xcodebuild.
for PAIR in "$BUNDLE_ID:UpLinkMac" "$BUNDLE_ID.proxy:UpLinkProxyExtension"; do
  APP_ID="${PAIR%%:*}"
  INSTALLED=$(profile_name "$APP_ID")
  if ! grep -q "PROVISIONING_PROFILE_SPECIFIER: \"$INSTALLED\"" project.yml; then
    red "project.yml does not reference the installed profile for $APP_ID."
    echo "  installed profile name : $INSTALLED"
    echo "  Update PROVISIONING_PROFILE_SPECIFIER in project.yml to match."
    exit 1
  fi
done

blue "==> Regenerating project"
xcodegen generate --quiet

# Archive + export, rather than a plain build.
#
# A plain build with CODE_SIGN_STYLE=Manual needs provisioning profiles that
# already exist, and Developer ID profiles carrying Network Extension
# entitlements have to be created first. `-allowProvisioningUpdates` on an
# archive lets Xcode mint them, and exportArchive with method `developer-id`
# then signs and packages exactly as distribution requires.
# macOS keeps the STAGED copy of a system extension unless the version
# changes. Rebuilding with the same version leaves the old binary running — you
# debug against code that no longer exists, which is exactly as confusing as it
# sounds. A monotonic build number forces a restage every time.
BUILD_NUMBER=$(date +%s)
blue "==> Archiving Release (build $BUILD_NUMBER)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ARCHIVE="$BUILD_DIR/UpLink.xcarchive"

xcodebuild archive \
  -project UpLink.xcodeproj \
  -scheme UpLinkMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

[[ -d "$ARCHIVE" ]] || { red "Archive failed"; exit 1; }

blue "==> Exporting with Developer ID"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<!-- Hardened runtime is required for notarization. -->
	<key>destination</key>
	<string>export</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>PROFILE_APP_KEY</key>
		<string>PROFILE_APP_NAME</string>
		<key>PROFILE_EXT_KEY</key>
		<string>PROFILE_EXT_NAME</string>
	</dict>
</dict>
</plist>
PLIST

# Substituted after the heredoc so the profile names are resolved at runtime.
/usr/bin/sed -i '' \
  -e "s|PROFILE_APP_KEY|$BUNDLE_ID|" \
  -e "s|PROFILE_APP_NAME|$(profile_name "$BUNDLE_ID")|" \
  -e "s|PROFILE_EXT_KEY|$BUNDLE_ID.proxy|" \
  -e "s|PROFILE_EXT_NAME|$(profile_name "$BUNDLE_ID.proxy")|" \
  "$BUILD_DIR/ExportOptions.plist"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -quiet

APP="$BUILD_DIR/export/UpLink.app"
[[ -d "$APP" ]] || { red "Export produced no app at $APP"; exit 1; }

# The extension must be inside the bundle or activation fails at runtime with
# a misleading "extension not found".
if [[ ! -d "$APP/Contents/Library/SystemExtensions" ]]; then
  red "No system extension embedded. Check the copy.destination in project.yml."
  exit 1
fi

blue "==> Notarizing (typically 1–3 minutes)"
ZIP="$BUILD_DIR/UpLink.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
  red "Notarization failed. For the reason:"
  echo "  xcrun notarytool history --keychain-profile $KEYCHAIN_PROFILE"
  echo "  xcrun notarytool log <submission-id> --keychain-profile $KEYCHAIN_PROFILE"
  exit 1
fi

blue "==> Stapling the ticket"
# ONLY the outer .app. The notarization ticket already covers nested code, and
# stapling the embedded extension first modifies that bundle — which breaks the
# app's seal, since the app's signature covers its own contents. The symptom is
# "a sealed resource is missing or invalid" from spctl, after a notarization
# that succeeded.
xcrun stapler staple "$APP"

blue "==> Verifying Gatekeeper accepts it"
if ! spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tee /tmp/uplink-spctl.txt | tail -2; then
  red "Gatekeeper rejected the app. Notarization may have succeeded but the"
  red "bundle was modified afterwards, invalidating its signature."
  cat /tmp/uplink-spctl.txt
  exit 1
fi
codesign --verify --deep --strict "$APP" || { red "Signature verification failed"; exit 1; }

# ── Install ───────────────────────────────────────────────────────────────
if [[ -d "$DEST" ]]; then
  EXISTING_ID=$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    red "$DEST exists but is not UpLink (bundle ID '$EXISTING_ID'). Not touching it."
    exit 1
  fi
  osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
  sleep 1
  rm -rf "$DEST"
fi

# Every build leaves another UpLink.app registered with LaunchServices — in
# DerivedData, archive intermediates, the export dir. sysextd resolves the
# bundle ID through LaunchServices and can pick one of those instead of
# /Applications, then refuses with "cannot allow apps outside /Applications".
# Purging them here stops that recurring on every single build.
blue "==> Purging stale LaunchServices registrations"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -dump 2>/dev/null \
  | grep -E '^\s*path:.*UpLink\.app' \
  | sed 's/^[[:space:]]*path:[[:space:]]*//' | sed 's/ (0x[0-9a-f]*)$//' | sort -u \
  | while read -r stale; do
      [[ "$stale" == "$DEST" ]] && continue
      "$LSREG" -u "$stale" 2>/dev/null && echo "    unregistered $stale"
    done

blue "==> Installing to $DEST and launching"
cp -R "$APP" "$DEST"
open "$DEST"

echo
green "Notarized, installed, and running."
echo
echo "First launch only: approve UpLink in"
echo "  System Settings → General → Login Items & Extensions → Network Extensions"
echo
echo "Then check coverage:"
echo "  ./scripts/coverage-test.sh"
