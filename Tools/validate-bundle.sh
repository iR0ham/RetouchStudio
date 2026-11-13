#!/bin/bash
# Checks the packaged application bundle itself, not a loose executable.
#
#   Tools/validate-bundle.sh "Retouch Studio.app" [arm64|x86_64|universal]
#
# Exits non-zero on a missing identity key, a wrong executable, an invalid
# signature, or a Homebrew path leaking into the bundled helper. It never
# modifies the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: Tools/validate-bundle.sh <bundle> [expected-archs]}"
EXPECTED="${2:-}"
failures=0
fail() { echo "  ✗ $*" >&2; failures=$((failures + 1)); }

[ -d "$APP" ] || { echo "✗ bundle not found: $APP" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "Contents/Info.plist is missing"
if [ -f "$PLIST" ]; then
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST" 2>/dev/null || true)
  EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || true)
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || true)
  [ -n "$BUNDLE_ID" ] || fail "CFBundleIdentifier is empty"
  [ -n "$VERSION" ] || fail "CFBundleShortVersionString is empty"
  [ -n "$BUILD" ] || fail "CFBundleVersion is empty"
  [ -n "$EXECUTABLE" ] || fail "CFBundleExecutable is empty"
fi

BINARY="$APP/Contents/MacOS/$EXECUTABLE"
if [ -x "$BINARY" ]; then
  ARCHS=$(lipo -archs "$BINARY" 2>/dev/null || true)
  echo "  · executable: $EXECUTABLE ($ARCHS)"
  case "$EXPECTED" in
    arm64)    [[ "$ARCHS" == "arm64" ]] || fail "expected arm64, found: $ARCHS" ;;
    x86_64)   [[ "$ARCHS" == "x86_64" ]] || fail "expected x86_64, found: $ARCHS" ;;
    universal) [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] \
                 || fail "expected arm64+x86_64, found: $ARCHS" ;;
    "") ;;
    *) fail "unknown expected architecture: $EXPECTED" ;;
  esac
else
  fail "Contents/MacOS/$EXECUTABLE is missing or not executable"
fi

SIGNATURE_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1 || true)
if printf '%s' "$SIGNATURE_INFO" | grep -q "Signature=adhoc"; then
  echo "  ! signature: ad-hoc (runs locally; not a public distribution signature)"
elif printf '%s' "$SIGNATURE_INFO" | grep -q "Authority=Developer ID Application"; then
  AUTHORITY=$(printf '%s' "$SIGNATURE_INFO" | sed -n 's/^Authority=//p' | head -1)
  echo "  · signature: $AUTHORITY"
else
  fail "no recognizable code signature"
fi
if ! codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  fail "codesign --verify --deep --strict failed"
fi

WORKER="$APP/Contents/Resources/Worker"
if [ -d "$WORKER" ]; then
  [ -x "$WORKER/bin/python3" ] || fail "worker interpreter bin/python3 is missing"
  [ -d "$WORKER/retouch_ai_worker" ] || fail "worker package retouch_ai_worker is missing"
  HOMEBREW_HITS=$(grep -RIl -e "/opt/homebrew" -e "/usr/local/Cellar" "$WORKER" 2>/dev/null | head -5 || true)
  if [ -n "$HOMEBREW_HITS" ]; then
    fail "Homebrew paths leaked into the bundle:"
    printf '%s\n' "$HOMEBREW_HITS" >&2
  fi
else
  echo "  · helper runtime not bundled (AI tools unavailable)"
fi

if [ "$failures" -ne 0 ]; then
  echo "✗ bundle validation found $failures problem(s)" >&2
  exit 1
fi
echo "  ✓ bundle validated"
