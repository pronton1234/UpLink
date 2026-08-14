#!/usr/bin/env bash
#
# The single entry point for everything testable without hardware.
# Wired to .githooks/pre-push so a regression cannot be pushed.
#
#   ./scripts/test.sh            # kit tests (fast — the loop you live in)
#   ./scripts/test.sh --all      # kit tests + both app builds (slow)
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

blue "==> UpLinkKit tests (unit + regression + loopback integration)"
cd "$ROOT/UpLinkKit"
swift test
green "    kit tests passed"

if [[ "${1:-}" != "--all" ]]; then
  echo
  green "OK — kit tests passed. Run with --all to also build the app targets."
  exit 0
fi

cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  red "xcodegen not found — install with: brew install xcodegen"
  exit 1
fi

blue "==> Regenerating Xcode project"
xcodegen generate --quiet

# Built into a SEPARATE derived data path on purpose. These are unsigned
# compile-only checks; writing them into Xcode's DerivedData would overwrite the
# signed app you actually run, and an unsigned build cannot reach the keychain —
# so the app would fail to start with no obvious connection to having run tests.
CI_DERIVED="$ROOT/build/ci-derived"

blue "==> Building UpLinkMac"
xcodebuild build \
  -project UpLink.xcodeproj \
  -scheme UpLinkMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$CI_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

blue "==> Building UpLinkiOS"
xcodebuild build \
  -project UpLink.xcodeproj \
  -scheme UpLinkiOS \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$CI_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

echo
green "OK — kit tests passed and both app targets build."
echo
echo "Note: background survival and real cellular egress cannot be verified here."
echo "Run the on-device checklist and record the result in docs/device-test-log.md."
