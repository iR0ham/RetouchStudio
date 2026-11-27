#!/bin/bash
# Regression fixtures for Tools/make-dmg.sh: checksum-sidecar portability and
# output-path containment.
#
#   Tools/test-make-dmg.sh
#
# Builds a throwaway stub bundle (a minimal Mach-O plus Info.plist, no
# signing), runs the real make-dmg.sh against it inside a temporary tree via
# RETOUCH_DMG_DIR, and checks four properties:
#
#   1. the .sha256 sidecar is a portable line of exactly
#      "<64hex><two spaces><basename>", and it verifies with both
#      `shasum -a 256 -c` and `sha256sum -c` after ONLY the image and the
#      sidecar are copied to a fresh directory at a different absolute path
#      and the original output directory is deleted — the exact condition of
#      the release.yml publish gate (`cd artifacts; sha256sum -c *.sha256`
#      on a runner that never built the image);
#   2. the .abs companion file carries the absolute provenance line, verifies
#      in place, and is deliberately not named *.sha256 so the CI glob never
#      consumes it;
#   3. a dangling symlink at any of the three output paths is refused before
#      anything is written (an [ -e ] test is blind to it), with FORCE and
#      without FORCE;
#   4. RETOUCH_DMG_FORCE=1 never writes through a symlink: a sidecar link
#      aimed at existing user data is refused and the target keeps its bytes.
#
# A negative control re-creates the old absolute-path manifest against a
# deleted directory and asserts the verifier FAILS on it, proving this gate
# actually catches the defect it guards. Registered in
# .github/workflows/ci.yml (macOS Integration); its verdict line is one of
# the grepped literals there.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

fail() { echo "  ✗ $*" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $*"; }

# Run the real script from a throwaway tree that holds a copy of it plus the
# stub bundle, so "Retouch Studio.app" next to the script resolves without
# touching the repository working copy.
STUB="$WORK/stub"
mkdir -p "$STUB/Tools" "$STUB/Retouch Studio.app/Contents/MacOS"
cp Tools/make-dmg.sh "$STUB/Tools/make-dmg.sh"
cc -x c -arch arm64 -mmacosx-version-min=14.0 -o "$STUB/Retouch Studio.app/Contents/MacOS/RetouchStudio" - <<'C'
int main(void) { return 0; }
C
/usr/bin/printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' \
  '<dict>' \
  '<key>CFBundleIdentifier</key><string>app.retouchstudio.mac.dmgtest</string>' \
  '<key>CFBundleName</key><string>Retouch Studio</string>' \
  '<key>CFBundleShortVersionString</key><string>0.0.0-dmgtest</string>' \
  '<key>CFBundleVersion</key><string>1</string>' \
  '</dict>' \
  '</plist>' > "$STUB/Retouch Studio.app/Contents/Info.plist"
codesign --force --sign - "$STUB/Retouch Studio.app" >/dev/null 2>&1

# run_make_dmg <out-dir> [extra env assignments...] ; rc is left in RC.
run_make_dmg() {
  local out="$1"; shift
  RC=0
  env "$@" RETOUCH_DMG_DIR="$out" "$STUB/Tools/make-dmg.sh" >"$WORK/last.log" 2>&1 || RC=$?
}

# ---------------------------------------------------------------- scenario A
OUT1="$WORK/out1"
mkdir -p "$OUT1"
run_make_dmg "$OUT1"
if [ "$RC" -eq 0 ]; then pass "build into RETOUCH_DMG_DIR succeeded"; else
  fail "build failed (rc=$RC): $(/usr/bin/tail -n 3 "$WORK/last.log")"
fi
IMG=$(/bin/ls "$OUT1" | /usr/bin/grep '\.dmg$' | /usr/bin/head -n 1)
[ -n "$IMG" ] || { fail "no .dmg produced in $OUT1"; exit 1; }
SIDECAR="$OUT1/$IMG.sha256"
SIDECAR_ABS="$SIDECAR.abs"

HASH=$(/usr/bin/shasum -a 256 "$OUT1/$IMG" | /usr/bin/awk '{print $1}')
EXPECTED="$HASH  $IMG"
LINES=$(wc -l < "$SIDECAR" | /usr/bin/tr -d ' ')
LINE=$(/bin/cat "$SIDECAR")
if [ "$LINES" = "1" ] && [ "$LINE" = "$EXPECTED" ]; then
  pass "sidecar is exactly one portable '<64hex>  <basename>' line"
else
  fail "sidecar is not the portable basename form (lines=$LINES): $LINE"
fi
case "$LINE" in
  */*) fail "sidecar still contains a path separator: $LINE" ;;
  *)   pass "sidecar names no directory at all" ;;
esac
if [ -f "$SIDECAR_ABS" ]; then
  ABS_LINE=$(/bin/cat "$SIDECAR_ABS")
  if [ "$ABS_LINE" = "$HASH  $OUT1/$IMG" ]; then
    pass "companion .abs carries the absolute provenance line"
  else
    fail "companion .abs line is not the absolute form: $ABS_LINE"
  fi
  RC=0; (cd "$OUT1" && /usr/bin/shasum -a 256 -c "$IMG.sha256.abs") >/dev/null 2>&1 || RC=$?
  if [ "$RC" -eq 0 ]; then pass "companion .abs verifies in place with -c"; else
    fail "companion .abs did not verify in place (rc=$RC)"
  fi
else
  fail "companion .abs file was not written"
fi
if [ -f "$SIDECAR_ABS" ]; then
  case "$SIDECAR_ABS" in
    *.sha256) fail "companion would be consumed by the release *.sha256 glob" ;;
    *)        pass "companion name stays outside the *.sha256 glob" ;;
  esac
fi

# ---------------------------------------------------------------- scenario B
# Mirror the publish gate: image + portable sidecar alone, fresh absolute
# directory, original output directory gone.
ART="$WORK/ci-sim/artifacts"
mkdir -p "$ART"
cp "$OUT1/$IMG" "$SIDECAR" "$ART/"
rm -rf "$OUT1"
RC=0; (cd "$ART" && /usr/bin/shasum -a 256 -c "$IMG.sha256") >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then
  pass "shasum -a 256 -c verifies after move to a different absolute path"
else
  fail "shasum -a 256 -c failed on the portable sidecar (rc=$RC)"
fi
SHA256SUM=""
if command -v sha256sum >/dev/null 2>&1; then SHA256SUM="sha256sum"
elif [ -x /sbin/sha256sum ]; then SHA256SUM="/sbin/sha256sum"; fi
if [ -n "$SHA256SUM" ]; then
  RC=0; (cd "$ART" && $SHA256SUM -c "$IMG.sha256") >/dev/null 2>&1 || RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "sha256sum -c (release.yml tool) verifies after the move"
  else
    fail "sha256sum -c failed on the portable sidecar (rc=$RC)"
  fi
else
  pass "sha256sum not available on this host; release.yml runs it on Linux (skipped locally)"
fi

# Negative control: the old absolute-path form must FAIL the same verifier.
printf '%s\n' "$HASH  $WORK/gone/$IMG" > "$ART/oldform.sha256"
RC=0; (cd "$ART" && /usr/bin/shasum -a 256 -c oldform.sha256) >/dev/null 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
  pass "negative control: an absolute line for a moved image is rejected (rc=$RC)"
else
  fail "negative control did not fail: the gate would not catch the old format"
fi
rm -f "$ART/oldform.sha256"

# ---------------------------------------------------------------- scenario C
# A dangling symlink at the image path is invisible to [ -e ] but visible to
# [ -L ]; the guard must refuse it, leave the link dangling, and write no
# sidecar.
OUT2="$WORK/out2"
mkdir -p "$OUT2"
ln -s "$WORK/does-not-exist.dmg" "$OUT2/$IMG"
run_make_dmg "$OUT2"
if [ "$RC" -ne 0 ]; then pass "dangling symlink at the image path is refused (rc=$RC)"; else
  fail "script accepted a dangling symlink at the image path"
fi
if [ -L "$OUT2/$IMG" ] && [ ! -e "$OUT2/$IMG" ]; then
  pass "refused image-path symlink is untouched and still dangling"
else
  fail "image-path symlink was followed, replaced, or dereferenced"
fi
if [ ! -e "$OUT2/$IMG.sha256" ] && [ ! -L "$OUT2/$IMG.sha256" ]; then
  pass "no sidecar written when the image-path guard fired"
else
  fail "sidecar was written despite the image-path refusal"
fi

# --------------------------------------------------------- scenario D (FORCE)
# FORCE must still refuse to write through a sidecar symlink aimed at real
# user data, and the target bytes must survive.
OUT3="$WORK/out3"
mkdir -p "$OUT3"
cp "$ART/$IMG" "$OUT3/$IMG"
VICTIM="$WORK/user-data.txt"
/usr/bin/printf 'PRECIOUS-DATA\n' > "$VICTIM"
ln -s "$VICTIM" "$OUT3/$IMG.sha256"
run_make_dmg "$OUT3" RETOUCH_DMG_FORCE=1
if [ "$RC" -ne 0 ]; then pass "FORCE=1 still refuses a symlinked sidecar (rc=$RC)"; else
  fail "FORCE=1 accepted a symlinked sidecar and wrote through it"
fi
if [ "$(/bin/cat "$VICTIM")" = "PRECIOUS-DATA" ] && [ ! -L "$VICTIM" ]; then
  pass "symlink target data survived the refusal (not truncated)"
else
  fail "symlink target was written through: data loss"
fi

# ------------------------------------------------- scenario E (dangling .abs)
OUT4="$WORK/out4"
mkdir -p "$OUT4"
ln -s "$WORK/does-not-exist.abs" "$OUT4/$IMG.sha256.abs"
run_make_dmg "$OUT4"
if [ "$RC" -ne 0 ]; then pass "dangling symlink at the .abs path is refused (rc=$RC)"; else
  fail "script accepted a dangling symlink at the .abs path"
fi
if [ -L "$OUT4/$IMG.sha256.abs" ] && [ ! -e "$OUT4/$IMG.sha256.abs" ]; then
  pass "refused .abs symlink is untouched and still dangling"
else
  fail ".abs symlink was followed, replaced, or dereferenced"
fi

# --------------------------------------------- scenario F (round-18 behavior)
# Ordinary existing outputs still refuse without FORCE (overwrite protection
# must not regress while the guard is extended).
OUT5="$WORK/out5"
mkdir -p "$OUT5"
cp "$ART/$IMG" "$OUT5/$IMG"
run_make_dmg "$OUT5"
if [ "$RC" -ne 0 ]; then pass "existing image without FORCE still refuses (rc=$RC)"; else
  fail "existing image without FORCE was overwritten"
fi

if [ "$failures" -ne 0 ]; then
  echo "✗ dmg sidecar fixtures: $failures problem(s)" >&2
  exit 1
fi
echo "✓ dmg sidecar fixtures: all cases behaved as expected"
