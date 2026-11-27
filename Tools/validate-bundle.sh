#!/bin/bash
# Checks the packaged application bundle itself, not a loose executable.
#
#   Tools/validate-bundle.sh "Retouch Studio.app" [arm64|x86_64|universal] \
#       [--require-worker|--forbid-worker]
#
# Exits non-zero on a missing identity key, a wrong executable, an invalid
# signature, a missing or unsealed helper, or a bundle that does not carry the
# MIT licence, the third-party notice, and honest copyright wording. Runtime
# path containment is proved by executing the packaged interpreter in the
# functional worker self-test; inert upstream text is not a runtime-path leak.
# It never modifies the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: Tools/validate-bundle.sh <bundle> [expected-archs] [--require-worker|--forbid-worker]}"
EXPECTED="${2:-}"
WORKER_MODE="${3:-}"
case "$WORKER_MODE" in
  ""|--require-worker|--forbid-worker) ;;
  *) echo "✗ unknown worker policy: $WORKER_MODE" >&2; exit 1 ;;
esac
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
  COPYRIGHT=$(/usr/libexec/PlistBuddy -c "Print :NSHumanReadableCopyright" "$PLIST" 2>/dev/null || true)
  if [ -z "$COPYRIGHT" ]; then
    fail "NSHumanReadableCopyright is empty"
  else
    echo "  · copyright: $COPYRIGHT"
    # The app is MIT-licensed, so the Finder-level copyright line must say so
    # and must not keep the all-rights-reserved claim it used to carry.
    case "$COPYRIGHT" in
      *"All rights reserved"*|*"all rights reserved"*)
        fail "NSHumanReadableCopyright still claims all rights reserved: $COPYRIGHT" ;;
    esac
    case "$COPYRIGHT" in
      *MIT*) ;;
      *) fail "NSHumanReadableCopyright does not name the MIT licence: $COPYRIGHT" ;;
    esac
  fi
fi

RESOURCES="$APP/Contents/Resources"
BUNDLE_LICENSE="$RESOURCES/LICENSE"
BUNDLE_NOTICES="$RESOURCES/THIRD_PARTY_NOTICES.txt"
# MIT requires its notice to accompany copies, and the bundled font's licence
# requires the same for the fonts. A release bundle without either is invalid.
[ -f "$BUNDLE_LICENSE" ] \
  || fail "Contents/Resources/LICENSE is missing"
if [ -f "$BUNDLE_LICENSE" ]; then
  grep -q "MIT License" "$BUNDLE_LICENSE" \
    || fail "Contents/Resources/LICENSE is not an MIT licence text"
  grep -q "Copyright (c).*iRoham" "$BUNDLE_LICENSE" \
    || fail "Contents/Resources/LICENSE does not name this project's copyright"
fi
[ -f "$BUNDLE_NOTICES" ] \
  || fail "Contents/Resources/THIRD_PARTY_NOTICES.txt is missing"
if [ -f "$BUNDLE_NOTICES" ]; then
  grep -qi "Vazirmatn" "$BUNDLE_NOTICES" \
    || fail "Contents/Resources/THIRD_PARTY_NOTICES.txt does not attribute Vazirmatn"
fi

# The packaged diagnostic may consume only the canonical independent reference.
# This rejects missing, altered, symlinked, alternate and ambiguous layouts while
# leaving the existing signature, Worker, catalogue and notice checks intact.
if ! /usr/bin/python3 "$PWD/Tools/validate-m3-fixture.py" verify-bundle "$APP"; then
  fail "M3 reference fixture validation failed"
fi

RESOURCES="$APP/Contents/Resources"
WORKER="$RESOURCES/Worker"
WORKER_READY=0
# Reject unsafe topology before signing diagnostics can obscure the actionable
# error. A dangling link is still a forbidden Worker even though `test -e`
# follows the link and reports it absent.
if [ -L "$WORKER" ]; then
  if [ "$WORKER_MODE" = "--forbid-worker" ]; then
    fail "helper runtime is forbidden in this build"
  else
    fail "worker runtime root must not be a symbolic link"
  fi
elif [ "$WORKER_MODE" = "--forbid-worker" ] && [ -e "$WORKER" ]; then
  fail "helper runtime is forbidden in this build"
elif [ -e "$WORKER" ] && [ ! -d "$WORKER" ]; then
  fail "worker runtime root is not a directory"
elif [ -d "$WORKER" ]; then
  APP_REAL=$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$APP")
  WORKER_REAL=$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$WORKER")
  case "$WORKER_REAL" in
    "$APP_REAL"/*) WORKER_READY=1 ;;
    *) fail "worker runtime root must resolve inside the app bundle" ;;
  esac
fi
if [ "$WORKER_MODE" = "--require-worker" ] && [ ! -e "$WORKER" ] && [ ! -L "$WORKER" ]; then
  fail "helper runtime is required but Contents/Resources/Worker is missing"
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

CATALOG="$RESOURCES/model-catalog.json"
if [ -f "$CATALOG" ]; then
  grep -q '"schema": "retouchstudio.model-catalog/1"' "$CATALOG" \
    || fail "model catalog has an unknown schema"
  if grep -q '{base}' "$CATALOG"; then
    fail "model catalog still contains the test {base} placeholder"
  fi
else
  fail "Contents/Resources/model-catalog.json is missing"
fi
if [ "$WORKER_MODE" != "--forbid-worker" ] && [ "$WORKER_READY" -eq 1 ]; then
  [ -x "$WORKER/bin/python3" ] || fail "worker interpreter bin/python3 is missing"
  LINK_TARGET=$(readlink "$WORKER/bin/python3" 2>/dev/null || true)
  [ "$LINK_TARGET" = "../Python.framework/Versions/3.13/bin/python3.13" ] \
    || fail "worker interpreter bin/python3 is not the expected relative symlink"
  PYTHON="$WORKER/Python.framework/Versions/3.13/bin/python3.13"
  if [ -x "$PYTHON" ]; then
    PYTHON_ARCHS=$(lipo -archs "$PYTHON" 2>/dev/null || true)
    echo "  · helper interpreter: Python 3.13 ($PYTHON_ARCHS)"
    [ "$PYTHON_ARCHS" = "arm64" ] \
      || fail "the Apple-silicon helper interpreter must be arm64, found: $PYTHON_ARCHS"
  else
    fail "worker framework interpreter Python.framework/Versions/3.13/bin/python3.13 is missing"
  fi
  [ -d "$WORKER/retouch_ai_worker" ] || fail "worker package retouch_ai_worker is missing"
  [ -f "$WORKER/.stamp" ] && grep -Eq '^[0-9a-f]{64}$' "$WORKER/.stamp" \
    || fail "worker source/runtime stamp is missing or malformed"
  if ! /usr/bin/python3 "$PWD/Tools/worker-integrity.py" verify "$WORKER"; then
    fail "worker integrity verification failed"
  fi
  BROKEN_LINKS=$(find "$WORKER" -type l ! -exec test -e {} \; -print)
  if [ -n "$BROKEN_LINKS" ]; then
    fail "the worker runtime contains broken symlinks:"
    printf '%s\n' "$BROKEN_LINKS" >&2
  fi
  # Do not grep the payload for /opt/homebrew or /usr/local/Cellar: upstream
  # comments, optional shell-completion destinations and CPython's generated
  # Makefile legitimately contain those strings. The functional self-test
  # executes this interpreter and rejects external sys.path/sysconfig entries.
elif [ "$WORKER_MODE" != "--forbid-worker" ]; then
  echo "  · helper runtime not bundled (AI tools unavailable)"
fi

# Ownership audit: every app file in the bundle must have a name on it, and a
# notice may not claim a font the bundle does not carry. Existence alone is not
# enough. The helper tree under Contents/Resources/Worker is covered by its own
# notices — the audit requires those files to exist, be non-empty and name every
# pinned distribution; see Tools/audit-bundle-notices.sh for the full scope.
echo "  · notice ownership:"
if ! ./Tools/audit-bundle-notices.sh "$APP"; then
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "✗ bundle validation found $failures problem(s)" >&2
  exit 1
fi
echo "  ✓ bundle validated"
