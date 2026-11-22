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
  # The notice names all four tracked fonts, and the audit now checks each
  # named font individually, so a passing bundle must carry all four.
  cp Resources/Fonts/Vazirmatn-Regular.ttf Resources/Fonts/Vazirmatn-Medium.ttf \
     Resources/Fonts/Vazirmatn-SemiBold.ttf Resources/Fonts/Vazirmatn-Bold.ttf \
     "$root/Contents/Resources/Fonts/"
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
  "the bundled AI helper carries no non-empty Contents/Resources/Worker/LICENSE"

WORKER_OK="$WORK/worker-ok.app"
cp -R "$WORKER" "$WORKER_OK"
cp worker/LICENSE "$WORKER_OK/Contents/Resources/Worker/LICENSE"
cp worker/THIRD_PARTY_NOTICES.md "$WORKER_OK/Contents/Resources/Worker/THIRD_PARTY_NOTICES.md"
cp worker/requirements.lock "$WORKER_OK/Contents/Resources/Worker/requirements.lock"
expect_pass "a bundled helper with its own notices passes" "$WORKER_OK"

# The Worker/* row blanket-accepts every helper file, so the audit must verify
# the helper notices themselves: non-empty content and a name for each pin.
PIN_UNNAMED="$WORK/pin-unnamed.app"
cp -R "$WORKER_OK" "$PIN_UNNAMED"
{
  printf '# Third-party notices\n\n'
  printf 'The worker itself is MIT licensed; see `LICENSE`.\n'
  printf 'Every pinned distribution is named except one:\n'
  sed -n 's/^\([A-Za-z0-9_.-]*\)==.*/\1/p' worker/requirements.lock | sort -u \
    | grep -vx 'Jinja2' | paste -sd ', ' -
} > "$PIN_UNNAMED/Contents/Resources/Worker/THIRD_PARTY_NOTICES.md"
expect_fail "a pinned distribution no helper notice names fails" "$PIN_UNNAMED" \
  "does not name the pinned distributions: Jinja2"

NOTICE_EMPTY="$WORK/worker-notice-empty.app"
cp -R "$WORKER_OK" "$NOTICE_EMPTY"
: > "$NOTICE_EMPTY/Contents/Resources/Worker/THIRD_PARTY_NOTICES.md"
expect_fail "an empty helper notice fails" "$NOTICE_EMPTY" \
  "the bundled AI helper carries no non-empty Contents/Resources/Worker/THIRD_PARTY_NOTICES.md"

LICENSE_EMPTY="$WORK/worker-license-empty.app"
cp -R "$WORKER_OK" "$LICENSE_EMPTY"
: > "$LICENSE_EMPTY/Contents/Resources/Worker/LICENSE"
expect_fail "an empty helper licence fails" "$LICENSE_EMPTY" \
  "the bundled AI helper carries no non-empty Contents/Resources/Worker/LICENSE"

NO_LOCK="$WORK/worker-no-lock.app"
cp -R "$WORKER_OK" "$NO_LOCK"
rm "$NO_LOCK/Contents/Resources/Worker/requirements.lock"
expect_fail "a helper tree without a lock fails" "$NO_LOCK" \
  "carries no Contents/Resources/Worker/requirements.lock"

# The opposite direction of the font check: a notice may not claim a font the
# bundle does not carry, even when other named fonts are present.
FONT_SHORT="$WORK/font-short.app"
cp -R "$BASE" "$FONT_SHORT"
rm "$FONT_SHORT/Contents/Resources/Fonts/Vazirmatn-Medium.ttf"
rm "$FONT_SHORT/Contents/Resources/Fonts/Vazirmatn-SemiBold.ttf"
expect_fail "a notice naming a missing font fails while others are present" "$FONT_SHORT" \
  "the notice names Contents/Resources/Fonts/Vazirmatn-Medium.ttf, but the bundle does not carry it"

if [ "$failures" -ne 0 ]; then
  echo "✗ notice audit fixtures: $failures problem(s)" >&2
  exit 1
fi
echo "✓ notice audit fixtures: all cases behaved as expected"
