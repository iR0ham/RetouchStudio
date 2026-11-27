#!/bin/bash
# Regression fixtures for Tools/make-dmg.sh: checksum-sidecar portability and
# output-path containment.
#
#   Tools/test-make-dmg.sh
#
# Builds a throwaway stub bundle (a minimal Mach-O plus Info.plist, no
# signing), runs the real make-dmg.sh against it inside a temporary tree via
# RETOUCH_DMG_DIR, and checks seven properties:
#
#   1. the .sha256 sidecar is a portable line of exactly
#      "<64hex><two spaces><basename>", and it verifies with both
#      `shasum -a 256 -c` and `sha256sum -c` after ONLY the image and the
#      sidecar are copied to a fresh directory at a different absolute path
#      and the original output directory is deleted — the exact condition of
#      the release.yml publish gate, which merges every downloaded artifact
#      into one directory on a runner that never built the image and then
#      runs `for manifest in *.sha256; do sha256sum -c "$manifest"; done`
#      (.github/workflows/release.yml:199-200);
#   2. the .abs companion file carries the absolute provenance line, verifies
#      in place, and is deliberately not named *.sha256 so the CI glob never
#      consumes it;
#   3. a dangling symlink at any of the three output paths is refused before
#      anything is written (an [ -e ] test is blind to it), with FORCE and
#      without FORCE;
#   4. RETOUCH_DMG_FORCE=1 never writes through a symlink: a sidecar link
#      aimed at existing user data is refused and the target keeps its bytes;
#   5. the OUTPUT DIRECTORY, not just the companion's own name, presents
#      exactly one *.sha256 manifest to the release gate — asserted against
#      the real upload pattern and the real `for manifest in *.sha256` loop,
#      with a planted second manifest as the negative control that proves the
#      assertion can fail, and verified to fail in every glob collation the host
#      can produce (the gate mirror counts failures instead of reading the loop's
#      last status, so bash's strcoll ordering of the glob cannot hide it);
#   6. every sidecar file a successful build produces is non-empty and
#      single-line (the success-path half of the residue property);
#   7. when the digest tool itself fails, make-dmg.sh writes NO manifest at all
#      and keeps the image it built — exercised by shadowing `shasum` with a
#      failing stub on PATH, with the pre-fix redirect form reproduced as the
#      negative control that proves a 0-byte manifest really is left behind
#      without the compute-then-write ordering.
#
# A check that could not run on this host is printed as SKIP, never as ✓, so
# the ✓ count always means "executed and passed".
#
# A negative control re-creates the old absolute-path manifest against a
# deleted directory and asserts the verifier FAILS on it, proving this gate
# actually catches the defect it guards. Registered in
# .github/workflows/ci.yml (macOS Integration); its verdict line is one of
# the grepped literals there.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
# The cleanup trap is deliberately simple. Measured on /bin/bash 3.2.57 (the
# shell a GitHub macOS runner step uses): when a script that sets `set -e` and
# installs an EXIT trap dies from a PARSE error, the step's exit status is 0,
# and the status cannot be recovered inside the trap (`trap 'rc=$?; ...; exit
# $rc'` still yields 0). So a broken revision of this file can exit green while
# printing no checks at all. That is why the CI gate is not this script's exit
# code alone: .github/workflows/ci.yml:200 requires the literal
# 'dmg sidecar fixtures: all cases behaved as expected', which only the final
# line below can print, and ci.yml:213 fails the step if it is absent. Removing
# that grep would silently turn this fixture into a no-op.
trap 'rm -rf "$WORK"' EXIT
failures=0
skips=0

fail() { echo "  ✗ $*" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $*"; }
# A check that cannot run here is announced as SKIP and counted separately.
# Printing it as ✓ would inflate the executed-check count, which is the only
# number a reader can verify from the log.
skip() { echo "  · SKIP $*"; skips=$((skips + 1)); }

# make_stub <dir> <CFBundleShortVersionString>
# Build a throwaway tree holding a copy of the real script plus a minimal
# Mach-O and Info.plist, so "Retouch Studio.app" next to the script resolves
# without touching the repository working copy. No signing beyond an ad-hoc
# identity, which hdiutil does not care about.
#
# Every scenario that reaches hdiutil gets its OWN version, because -srcfolder
# briefly mounts the volume it writes and two images with the same volume name
# inside one process can collide. The first measured run of this harness hit a
# transient "hdiutil: create failed - Resource busy" in the whitespace scenario
# (scenario G) while every other build in the same run succeeded, and the race
# reproduced on a second host-side experiment. Unique volume names take that
# host-level timing dependence out of the harness; they change no assertion,
# because each scenario checks the filename and manifest bytes it actually
# produced, and make-dmg.sh derives the name from the version it reads.
make_stub() {
  local dir="$1" version="$2"
  mkdir -p "$dir/Tools" "$dir/Retouch Studio.app/Contents/MacOS"
  cp Tools/make-dmg.sh "$dir/Tools/make-dmg.sh"
  cc -x c -arch arm64 -mmacosx-version-min=14.0 -o "$dir/Retouch Studio.app/Contents/MacOS/RetouchStudio" - <<'C'
int main(void) { return 0; }
C
  /usr/bin/printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' \
    '<dict>' \
    '<key>CFBundleIdentifier</key><string>app.retouchstudio.mac.dmgtest</string>' \
    '<key>CFBundleName</key><string>Retouch Studio</string>' \
    '<key>CFBundleShortVersionString</key><string>'"$version"'</string>' \
    '<key>CFBundleVersion</key><string>1</string>' \
    '</dict>' \
    '</plist>' > "$dir/Retouch Studio.app/Contents/Info.plist"
  codesign --force --sign - "$dir/Retouch Studio.app" >/dev/null 2>&1
}

STUB="$WORK/stub"
make_stub "$STUB" 0.0.0-dmgtest

# run_make_dmg <out-dir> [extra env assignments...] ; rc is left in RC.
# Uses $STUB unless STUB_FOR_RUN names a different throwaway tree.
run_make_dmg() {
  local out="$1"; shift
  local stub="${STUB_FOR_RUN:-$STUB}"
  RC=0
  env "$@" RETOUCH_DMG_DIR="$out" "$stub/Tools/make-dmg.sh" >"$WORK/last.log" 2>&1 || RC=$?
}

# Resolved once, up front: scenario A2 and scenario B must agree on which
# verifier actually ran, otherwise a host-specific branch can silently change
# what the gate mirror proves.
SHA256SUM=""
if command -v sha256sum >/dev/null 2>&1; then SHA256SUM="sha256sum"
elif [ -x /sbin/sha256sum ]; then SHA256SUM="/sbin/sha256sum"; fi

# gate_loop <dir> [LC_ALL-value] — mirror of the release.yml publish gate: for
# every *.sha256 in one merged artifact directory, verify it. Exit status is
# non-zero iff at least one manifest failed.
#
# This helper exists because an earlier revision ended its subshell with the
# `for` loop itself, which reports only the LAST manifest's status. That is not
# the same thing: release.yml runs the loop under `bash -e` (GitHub's default
# shell for a run step), so ONE failing manifest aborts the step. It is also
# host-dependent, because bash orders a glob with strcoll and therefore with
# LC_COLLATE. Measured on this host with one good and one dead manifest:
#   LC_ALL=C          -> RetouchStudio-<v>.dmg.sha256 injected.sha256
#   LC_ALL=en_US.UTF-8 -> injected.sha256 RetouchStudio-<v>.dmg.sha256
# In the second order the dead line runs first, the loop's status comes from the
# good manifest, and a planted-manifest control silently loses its teeth. That
# is why CI on macos-15 (LANG=en_US.UTF-8) reported
# "✗ negative control passed: the publish loop would not notice an extra absolute
# manifest" at 2026-11-27T23:38:46Z on the same SHA that was green here.
# Counting failures removes the dependence on glob order entirely.
gate_loop() {
  local dir="$1"
  local loc="${2:-}"
  local manifest fails=0
  (
    if [ -n "$loc" ]; then export LC_ALL="$loc"; fi
    cd "$dir" || exit 9
    for manifest in *.sha256; do
      if [ -n "$SHA256SUM" ]; then
        $SHA256SUM -c "$manifest" >/dev/null 2>&1 || fails=$((fails + 1))
      else
        /usr/bin/shasum -a 256 -c "$manifest" >/dev/null 2>&1 || fails=$((fails + 1))
      fi
    done
    exit "$fails"
  )
}

# verify_one <dir> <manifest> [LC_ALL-value] — run the gate verifier on exactly
# one manifest, so a result can never be attributed to the wrong file.
verify_one() {
  local dir="$1" manifest="$2"
  local loc="${3:-}"
  (
    if [ -n "$loc" ]; then export LC_ALL="$loc"; fi
    cd "$dir" || exit 9
    if [ -n "$SHA256SUM" ]; then
      $SHA256SUM -c "$manifest" >/dev/null 2>&1
    else
      /usr/bin/shasum -a 256 -c "$manifest" >/dev/null 2>&1
    fi
  )
}

# glob_order <dir> <LC_ALL-value> — the space-separated order bash gives
# *.sha256 in that collation. Used only to prove the collation probe below is
# not vacuous (an unavailable locale collapses to C and is then reported SKIP).
glob_order() {
  LC_ALL="$2" /bin/bash -c 'cd "$1" && set -- *.sha256 && printf "%s" "$*"' _ "$1"
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
# ------------------------------------------------------- scenario A2 (globs)
# The assertion this block replaces tested the companion's own name inside a
# case statement built from that same name, so no repository state could ever
# have made it fail. Everything here tests the DIRECTORY the publish gate
# actually globs, and the block ends with a negative control proving the
# assertions can go red.
if [ -s "$SIDECAR" ]; then pass "portable sidecar exists and is non-empty"; else
  fail "portable sidecar is missing or 0 bytes — a failed checksum must not leave residue"
fi
if [ -s "$SIDECAR_ABS" ]; then
  ABS_LINES=$(wc -l < "$SIDECAR_ABS" | /usr/bin/tr -d ' ')
  if [ "$ABS_LINES" = "1" ]; then pass "absolute companion exists, is non-empty, one line"; else
    fail "absolute companion holds $ABS_LINES lines (expected 1)"
  fi
else
  fail "absolute companion is missing or 0 bytes"
fi

# (a) One manifest only. The publish job loops over every *.sha256 it got, so a
#     second file with that suffix changes what the gate verifies.
MANIFEST_COUNT=$(/bin/ls "$OUT1" | /usr/bin/grep -c '\.sha256$' || true)
if [ "$MANIFEST_COUNT" = "1" ]; then
  pass "output directory exposes exactly one *.sha256 manifest to the gate glob"
else
  fail "output directory exposes $MANIFEST_COUNT *.sha256 manifests (expected 1)"
fi

# (b) Mirror release.yml:61/91 — the upload pattern must pick up the portable
#     sidecar and must NOT pick up the companion.
UPLOAD_PATTERN="$IMG.sha256"
if [ -f "$OUT1/$UPLOAD_PATTERN" ]; then pass "upload pattern RetouchStudio-*-<arch>.dmg.sha256 matches the portable sidecar"; else
  fail "portable sidecar does not match the release upload pattern: $UPLOAD_PATTERN"
fi
if [ -f "${SIDECAR_ABS}" ]; then
  case "$(basename "$SIDECAR_ABS")" in
    *"$IMG.sha256") fail "companion name would be uploaded and globbed: $(basename "$SIDECAR_ABS")" ;;
    *)              pass "companion name falls outside the upload pattern and the gate glob" ;;
  esac
fi

# (c) Reproduce the publish loop over the WHOLE output directory, companion
#     included. PROBE P1 showed the old harness only ever copied two of the
#     three files, so a companion that broke the glob stayed invisible here.
GATE="$WORK/gate-sim"
mkdir -p "$GATE"
cp "$OUT1/"* "$GATE/"
GATE_RC=0
gate_loop "$GATE" || GATE_RC=$?
GATE_TOOL="shasum -a 256 (release.yml uses sha256sum on Linux)"
if [ -n "$SHA256SUM" ]; then GATE_TOOL="$SHA256SUM, the release.yml tool"; fi
if [ "$GATE_RC" -eq 0 ]; then
  pass "publish-loop mirror over the full output directory verifies (via $GATE_TOOL)"
else
  fail "publish-loop mirror failed with the files make-dmg.sh produces (rc=$GATE_RC)"
fi

# Negative control for (c): an extra manifest must break the same loop. Without
# this, (c) could pass for a script that simply never ran the verifier.
#
# The injected line reproduces the real publish-gate condition — a builder
# absolute path that the verification host cannot resolve (scenario B's proven
# technique, and exactly what release.yml sees when it downloads artifacts onto
# a runner that never built them). An earlier draft of this control pointed at
# "$OUT1/$IMG", which was still a live path at that moment, so the verifier
# succeeded and the control had no teeth; it correctly reported RED. That
# failure is the reason the injection now names a directory the script never
# creates.
#
# A SECOND way this control was inert is recorded in gate_loop's comment: the
# loop reported only its last manifest's status, so under an en_US.UTF-8
# collation the dead line ran first and the control went green->red on a runner
# while staying green at home. The three checks below separate the two failure
# modes: the planted line really is unverifiable, the whole-loop mirror notices
# it, and the whole-loop mirror notices it in every glob order the host can
# produce.
printf '%s  %s\n' "$HASH" "$WORK/gone-builder-dir/$IMG" > "$GATE/injected.sha256"
ONLY_RC=0
verify_one "$GATE" injected.sha256 || ONLY_RC=$?
if [ "$ONLY_RC" -ne 0 ]; then
  pass "negative control is live: the planted absolute line alone is unverifiable (rc=$ONLY_RC)"
else
  fail "the planted absolute line verifies on its own — the control tests nothing"
fi
INJECT_RC=0
gate_loop "$GATE" || INJECT_RC=$?
GATE_ORDER=$(glob_order "$GATE" C)
GATE_ORDER_U=$(glob_order "$GATE" en_US.UTF-8)
if [ "$INJECT_RC" -ne 0 ]; then
  pass "negative control: a second absolute-path manifest breaks the same loop (rc=$INJECT_RC)"
else
  fail "negative control passed: the publish loop would not notice an extra absolute manifest (LC_ALL=C glob order: $GATE_ORDER)"
fi
# Collation independence. If the host gives one order in both locales — because
# en_US.UTF-8 is unavailable and collapsed to C — the probe cannot distinguish a
# real fix from luck, so it is announced as SKIP rather than ✓.
if [ "$GATE_ORDER" = "$GATE_ORDER_U" ]; then
  skip "glob collation probe needs two distinct orders (host LC_ALL=C order: $GATE_ORDER)"
else
  RC_C=0; gate_loop "$GATE" C || RC_C=$?
  RC_U=0; gate_loop "$GATE" en_US.UTF-8 || RC_U=$?
  if [ "$RC_C" -ne 0 ] && [ "$RC_U" -ne 0 ]; then
    pass "gate mirror rejects the planted manifest in both collations (C rc=$RC_C, en_US.UTF-8 rc=$RC_U)"
  else
    fail "gate mirror outcome depends on glob order (C rc=$RC_C, en_US.UTF-8 rc=$RC_U)"
  fi
fi
rm -f "$GATE/injected.sha256"

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
if [ -n "$SHA256SUM" ]; then
  RC=0; (cd "$ART" && $SHA256SUM -c "$IMG.sha256") >/dev/null 2>&1 || RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "sha256sum -c (release.yml tool) verifies after the move"
  else
    fail "sha256sum -c failed on the portable sidecar (rc=$RC)"
  fi
else
  skip "sha256sum is not installed here, so the release.yml verifier binary itself is unexercised on this host (release.yml runs it on Linux; the gate mirror above used /usr/bin/shasum -a 256)"
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

# ------------------------------------------- scenario G (whitespace in paths)
# Every output path is quoted inside make-dmg.sh, but that was never exercised:
# a directory containing a space is the cheapest way to prove the sidecar is
# still written, still basename-only, and still verifiable by the gate loop.
# Its own stub version keeps the volume name unique (see make_stub).
SPACE_DIR="$WORK/out with spaces"
STUB_SPACE="$WORK/stub-space"
make_stub "$STUB_SPACE" 0.0.0-spacet
mkdir -p "$SPACE_DIR"
STUB_FOR_RUN="$STUB_SPACE" run_make_dmg "$SPACE_DIR"
unset STUB_FOR_RUN
if [ "$RC" -eq 0 ]; then pass "build into a RETOUCH_DMG_DIR containing spaces succeeded"; else
  fail "build into a spaced output directory failed (rc=$RC): $(/usr/bin/tail -n 3 "$WORK/last.log")"
fi
G_IMG=$(/bin/ls "$SPACE_DIR" | /usr/bin/grep '\.dmg$' | /usr/bin/head -n 1)
if [ "$G_IMG" = "RetouchStudio-0.0.0-spacet-arm64.dmg" ]; then
  pass "spaced directory produced the expected versioned image name"
else
  fail "spaced directory image name is unexpected: '$G_IMG'"
fi
if [ -n "$G_IMG" ] && [ -s "$SPACE_DIR/$G_IMG.sha256" ]; then
  G_LINE=$(/bin/cat "$SPACE_DIR/$G_IMG.sha256")
  G_HASH=$(/usr/bin/shasum -a 256 "$SPACE_DIR/$G_IMG" | /usr/bin/awk '{print $1}')
  if [ "$G_LINE" = "$G_HASH  $G_IMG" ]; then
    pass "spaced-directory sidecar is still the portable basename form"
  else
    fail "spaced-directory sidecar is wrong: $G_LINE"
  fi
else
  fail "spaced directory produced no image or no sidecar (IMG=$G_IMG)"
fi
G_COUNT=$(/bin/ls "$SPACE_DIR" | /usr/bin/grep -c '\.sha256$' || true)
if [ "$G_COUNT" = "1" ]; then
  pass "spaced directory still exposes exactly one *.sha256 manifest"
else
  fail "spaced directory exposes $G_COUNT manifests (expected 1)"
fi
GATE2="$WORK/gate sim/nested path"
mkdir -p "$GATE2"
cp "$SPACE_DIR/"* "$GATE2/"
GATE2_RC=0
gate_loop "$GATE2" || GATE2_RC=$?
if [ "$GATE2_RC" -eq 0 ]; then pass "publish-loop mirror verifies from a nested path containing spaces"; else
  fail "publish-loop mirror failed from a spaced path (rc=$GATE2_RC)"
fi

# ------------------------------------------------ scenario H (failed digest)
# Property 7. The digest tool is the only producer of the two manifests, so
# make-dmg.sh must not create either path before a digest exists. Shadowing
# `shasum` with a failing stub on PATH exercises the real script up to that
# point: the image gets built, then both assignments fail under `set -e`.
# The old `( … shasum … ) > "$SIDECAR"` form could not behave any other way —
# a redirect creates its target before the producer runs — which is exactly the
# 0-byte manifest that `sha256sum -c` reports as a malformed checksum line
# instead of as missing evidence.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
/usr/bin/printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/shasum"
chmod +x "$FAKEBIN/shasum"
OUT6="$WORK/out6"
STUB_DIGESTFAIL="$WORK/stub-digestfail"
make_stub "$STUB_DIGESTFAIL" 0.0.0-digestfail
mkdir -p "$OUT6"
STUB_FOR_RUN="$STUB_DIGESTFAIL" run_make_dmg "$OUT6" PATH="$FAKEBIN:$PATH"
unset STUB_FOR_RUN
H_IMG="RetouchStudio-0.0.0-digestfail-arm64.dmg"
if [ "$RC" -ne 0 ]; then pass "a failing digest tool aborts the build (rc=$RC)"; else
  fail "make-dmg.sh reported success even though shasum was forced to fail"
fi
if [ -s "$OUT6/$H_IMG" ]; then pass "the image itself survives a failed digest"; else
  fail "image missing or empty after the digest failure"
fi
for leftover in "$H_IMG.sha256" "$H_IMG.sha256.abs"; do
  if [ -e "$OUT6/$leftover" ] || [ -L "$OUT6/$leftover" ]; then
    fail "failed digest left manifest residue at $leftover"
  else
    pass "failed digest wrote no manifest at $leftover"
  fi
done

# Negative control for property 7: recreate the pre-fix redirect form with the
# same failing tool and prove it DOES leave a 0-byte manifest. If this ever
# stops failing, the scenario above is asserting nothing.
OLD_RC=0
( cd "$WORK" && PATH="$FAKEBIN:$PATH" shasum no-such-file ) > "$WORK/oldform.sha256" 2>/dev/null || OLD_RC=$?
if [ "$OLD_RC" -ne 0 ] && [ -f "$WORK/oldform.sha256" ] && [ ! -s "$WORK/oldform.sha256" ]; then
  pass "negative control: the redirect-first form really leaves a 0-byte manifest (rc=$OLD_RC)"
else
  fail "negative control did not reproduce the 0-byte residue (rc=$OLD_RC)"
fi
rm -f "$WORK/oldform.sha256"

# The verdict literal below is grepped by .github/workflows/ci.yml and must not
# change wording. Skips are reported on their own line so a reader can tell
# "all executed checks passed" apart from "all properties were exercised".
if [ "$failures" -ne 0 ]; then
  echo "✗ dmg sidecar fixtures: $failures problem(s)" >&2
  exit 1
fi
if [ "$skips" -ne 0 ]; then
  echo "  · dmg sidecar fixtures: $skips check(s) skipped on this host"
fi
echo "✓ dmg sidecar fixtures: all cases behaved as expected"

