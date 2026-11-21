#!/bin/bash
# Regression fixtures for Tools/audit-bundle-notices.sh.
#
#   Tools/test-bundle-notices.sh
#
# Builds throwaway bundle-shaped directories (no compiler, no signature) and
# checks that the audit accepts a fully-accounted bundle and rejects each way a
# notice can drift from the files it is supposed to cover. Not registered in
# Tests/run.sh yet; see Docs/RELEASING.md for the build-time invocation.
set -euo pipefail
cd "$(dirname "$0")/.."

AUDIT="$PWD/Tools/audit-bundle-notices.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

fail() { echo "  ✗ $*" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $*"; }

# A minimal bundle that carries exactly what a real light bundle carries.
make_bundle() {
  local root="$1"
  mkdir -p "$root/Contents/MacOS" "$root/Contents/Resources/Fonts" \
           "$root/Contents/_CodeSignature"
  printf 'plist\n' > "$root/Contents/Info.plist"
  printf 'pkg\n' > "$root/Contents/PkgInfo"
  printf 'binary\n' > "$root/Contents/MacOS/RetouchStudio"
  printf 'sig\n' > "$root/Contents/_CodeSignature/CodeResources"
  printf 'icon\n' > "$root/Contents/Resources/AppIcon.icns"
  printf '{}\n' > "$root/Contents/Resources/model-catalog.json"
  cp LICENSE "$root/Contents/Resources/LICENSE"
  cp Resources/THIRD_PARTY_NOTICES.txt "$root/Contents/Resources/THIRD_PARTY_NOTICES.txt"
  cp Resources/Fonts/OFL.txt "$root/Contents/Resources/Fonts/OFL.txt"
  cp Resources/Fonts/Vazirmatn-Regular.ttf "$root/Contents/Resources/Fonts/"
  cp Resources/Fonts/Vazirmatn-Bold.ttf "$root/Contents/Resources/Fonts/"
}

expect_pass() {
  local name="$1" root="$2"
  if "$AUDIT" "$root" > "$WORK/out.log" 2>&1; then
    pass "$name"
  else
    fail "$name: expected PASS"
    sed 's/^/      /' "$WORK/out.log" >&2
  fi
}

expect_fail() {
  local name="$1" root="$2" needle="$3"
  if "$AUDIT" "$root" > "$WORK/out.log" 2>&1; then
    fail "$name: expected FAIL"
  elif grep -Fq "$needle" "$WORK/out.log"; then
    pass "$name"
  else
    fail "$name: failed without saying '$needle'"
    sed 's/^/      /' "$WORK/out.log" >&2
  fi
}

BASE="$WORK/base.app"
make_bundle "$BASE"
expect_pass "accounted bundle passes" "$BASE"

STRAY="$WORK/stray.app"
cp -R "$BASE" "$STRAY"
mkdir -p "$STRAY/Contents/Resources/vendor"
printf 'blob\n' > "$STRAY/Contents/Resources/vendor/blob.bin"
expect_fail "an unaccounted file fails" "$STRAY" "no notice accounts for Contents/Resources/vendor/blob.bin"

EXTRA="$WORK/extra.app"
cp -R "$BASE" "$EXTRA"
cp Resources/Fonts/Vazirmatn-Regular.ttf "$EXTRA/Contents/Resources/Fonts/Vazirmatn-Light.ttf"
expect_fail "a new font the notice misses fails" "$EXTRA" \
  "does not name Contents/Resources/Fonts/Vazirmatn-Light.ttf"

MISSING="$WORK/missing.app"
cp -R "$BASE" "$MISSING"
rm -rf "$MISSING/Contents/Resources/Fonts"
expect_fail "a notice naming absent fonts fails" "$MISSING" \
  "the notice names Vazirmatn, but the bundle carries no Vazirmatn font"

NO_OFL="$WORK/no-ofl.app"
cp -R "$BASE" "$NO_OFL"
rm "$NO_OFL/Contents/Resources/Fonts/OFL.txt"
expect_fail "fonts without their licence text fail" "$NO_OFL" \
  "the Vazirmatn fonts ship without Contents/Resources/Fonts/OFL.txt"

WORKER="$WORK/worker.app"
cp -R "$BASE" "$WORKER"
mkdir -p "$WORKER/Contents/Resources/Worker"
printf 'module\n' > "$WORKER/Contents/Resources/Worker/worker.py"
expect_fail "a bundled helper without notices fails" "$WORKER" \
  "the bundled AI helper carries no Contents/Resources/Worker/LICENSE"

WORKER_OK="$WORK/worker-ok.app"
cp -R "$WORKER" "$WORKER_OK"
cp worker/LICENSE "$WORKER_OK/Contents/Resources/Worker/LICENSE"
cp worker/THIRD_PARTY_NOTICES.md "$WORKER_OK/Contents/Resources/Worker/THIRD_PARTY_NOTICES.md"
expect_pass "a bundled helper with its own notices passes" "$WORKER_OK"

if [ "$failures" -ne 0 ]; then
  echo "✗ notice audit fixtures: $failures problem(s)" >&2
  exit 1
fi
echo "✓ notice audit fixtures: all cases behaved as expected"
