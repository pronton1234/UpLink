#!/usr/bin/env bash
#
# Walks you through the one-time signing setup and verifies each step.
#
#   ./scripts/setup-signing.sh
#
# Everything here needs YOUR Apple ID credentials, so this script never asks for
# them and never stores them. It checks what exists, tells you exactly what to
# do next, and confirms when it worked. Run it as many times as you like.
#
set -uo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${UPLINK_TEAM_ID:-9NT85V7Q37}"
PROFILE="${UPLINK_NOTARY_PROFILE:-uplink-notary}"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$1"; }
bold()  { printf '\033[1m%s\033[0m\n' "$1"; }

DONE=0
TOTAL=3

echo
bold "UpLink signing setup"
echo "The Mac app contains a system extension. macOS activates one only if it is"
echo "Developer ID signed AND notarized, so both are required — there is no way"
echo "around it short of disabling SIP."
echo

# ── 1. Developer ID Application certificate ───────────────────────────────
bold "[1/$TOTAL] Developer ID Application certificate"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  green "  ✓ Found:"
  security find-identity -v -p codesigning | grep "Developer ID Application" | sed 's/^/      /'
  DONE=$((DONE + 1))
else
  red "  ✗ Not found."
  echo
  echo "  In Xcode:"
  echo "    Settings → Accounts → (your Apple ID) → Manage Certificates…"
  echo "    → the + button, bottom left → Developer ID Application"
  echo
  amber "  Your existing 'Apple Development' certificate is not enough:"
  echo "  development profiles never carry the -systemextension entitlement"
  echo "  values the extension needs."
  echo
  echo "  Open that pane now with:  open -a Xcode"
fi
echo

# ── 2. App-specific password ──────────────────────────────────────────────
bold "[2/$TOTAL] App-specific password"
echo "  Cannot be checked from here — it lives in your Apple ID account."
echo
echo "  Create one at appleid.apple.com:"
echo "    Sign-In and Security → App-Specific Passwords → +"
echo "    Name it e.g. 'uplink notarization', then copy it (shown once)."
echo
amber "  This is NOT your Apple ID password. It is scoped to notarization and"
echo "  can be revoked on its own without touching your account."
echo

# ── 3. Stored notary credentials ──────────────────────────────────────────
bold "[3/$TOTAL] Notary credentials in your keychain"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  green "  ✓ Profile '$PROFILE' is stored and working."
  DONE=$((DONE + 1))
else
  red "  ✗ Profile '$PROFILE' is not stored (or not valid)."
  echo
  echo "  Once you have the app-specific password from step 2, run:"
  echo
  echo "    xcrun notarytool store-credentials $PROFILE \\"
  echo "      --apple-id <your-apple-id-email> \\"
  echo "      --team-id $TEAM_ID \\"
  echo "      --password <the-app-specific-password>"
  echo
  echo "  It is stored in your keychain. Nothing is written into this repo."
fi
echo

# Step 2 has no direct check; it is proven by step 3 succeeding.
[[ "$DONE" -eq 2 ]] && DONE=$TOTAL

# ── Result ────────────────────────────────────────────────────────────────
if [[ "$DONE" -eq "$TOTAL" ]]; then
  green "Setup complete. Build and run the Mac app with:"
  echo
  echo "    ./scripts/release-mac.sh"
  echo
  echo "Then approve UpLink once in System Settings → General →"
  echo "Login Items & Extensions → Network Extensions, and measure coverage:"
  echo
  echo "    ./scripts/coverage-test.sh"
  exit 0
fi

amber "Not ready yet — finish the steps marked ✗ above, then run this again."
echo
echo "Nothing else in the project is blocked by this. The off-device suite runs"
echo "now and covers the protocol, multiplexer, pairing, and UDP framing:"
echo
echo "    ./scripts/test.sh"
exit 1
