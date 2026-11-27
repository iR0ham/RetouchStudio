#!/bin/bash
# Builds the drag-to-applications disk image from the packaged app.
# Run ./build.sh release first; the app must already be signed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Retouch Studio.app"
[ -d "$APP" ] || { echo "✗ \"$APP\" پیدا نشد؛ اول ./build.sh release را اجرا کنید." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/RetouchStudio")
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) SUFFIX=universal ;;
  *arm64*) SUFFIX=arm64 ;;
  *x86_64*) SUFFIX=x86_64 ;;
  *) echo "✗ معماری ناشناخته: $ARCHS" >&2; exit 1 ;;
esac
NAME="RetouchStudio-${VERSION}-${SUFFIX}"

# Where the image lands. The default is the repository root, which is the
# historical behaviour and keeps the documented filename
# RetouchStudio-<version>-<arch>.dmg. Release-evidence builds set
# RETOUCH_DMG_DIR to write the image and BOTH of its checksum records
# (the portable <name>.dmg.sha256 and the absolute <name>.dmg.sha256.abs
# companion) outside the source tree.
OUT_DIR="${RETOUCH_DMG_DIR:-.}"
mkdir -p "$OUT_DIR"
OUT_ABS=$(cd "$OUT_DIR" && pwd)
DMG="$OUT_ABS/$NAME.dmg"
SIDECAR="$DMG.sha256"
# The absolute-path line is kept as a separate companion so the portable
# .sha256 manifest stays verifiable anywhere. It deliberately does not end
# in .sha256, so the release workflow's `*.sha256` glob never consumes it.
SIDECAR_ABS="$SIDECAR.abs"

# Never destroy a previous image of the same version: once published or
# accepted, a release artifact is evidence, and a re-run must not silently
# replace it. RETOUCH_DMG_FORCE=1 is the explicit opt-in to overwrite.
# A symlink counts as existing even when its target does not ([ -e ] is
# blind to dangling links), and the script never writes through a symlink:
# a shell redirect or hdiutil -ov aimed at a link would land outside
# OUT_DIR, so even FORCE refuses to replace the three output paths when any
# of them is a link.
for existing in "$DMG" "$SIDECAR" "$SIDECAR_ABS"; do
  if [ "${RETOUCH_DMG_FORCE:-0}" != "1" ]; then
    if [ -e "$existing" ] || [ -L "$existing" ]; then
      echo "✗ از قبل وجود دارد: $existing — برای جلوگیری از حذف تصویر قبلی، متوقف شد. برای بازنویسی RETOUCH_DMG_FORCE=1 تنظیم کنید." >&2
      exit 1
    fi
  elif [ -L "$existing" ]; then
    echo "✗ $existing یک پیوند نمادین است — هرگز داخل پیوند نوشته نمی‌شود، حتی با RETOUCH_DMG_FORCE=1." >&2
    exit 1
  fi
done

STAGE=$(mktemp -d /tmp/retouch-dmg.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

# Staging copies a bundle this machine just built, so no com.apple.quarantine
# attribute is involved and `ditto` correctly needs no --noqtn here. Quarantine
# suppression belongs to the unpack side, where it is applied:
# AIRuntime.swift:146 and UpdateVerification.swift:129 both pass
# `ditto -x -k --noqtn`. Nothing in this script downloads an archive.
ditto "$APP" "$STAGE/Retouch Studio.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Retouch Studio $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# The published sidecar must be portable: the release workflow downloads
# every artifact into one merged directory on a different runner, then runs
# `for manifest in *.sha256; do sha256sum -c "$manifest"; done`
# (.github/workflows/release.yml), and the artifact actions keep only
# basenames. An absolute builder path can never resolve there. So the
# .sha256 line is generated inside the output directory and records only the
# image basename; verify it with `shasum -a 256 -c` (or `sha256sum -c`) run
# next to the image. The .abs companion still records the absolute line for
# local evidence and is excluded from the *.sha256 glob by its suffix.
#
# Both records are computed into shell variables first and only then written.
# A shell redirect creates its target before the producer runs, so the earlier
# `( … shasum … ) > "$SIDECAR"` form left a 0-byte manifest behind whenever
# shasum itself failed — and an empty manifest is worse than a missing one,
# because `sha256sum -c` reports a malformed checksum line instead of "no
# evidence here". Under `set -e` a failed substitution now aborts the script
# before either path exists. Tools/test-make-dmg.sh asserts both the residue
# behaviour and the glob shape.
PORTABLE_LINE=$( cd "$OUT_ABS" && shasum -a 256 "$NAME.dmg" )
ABSOLUTE_LINE=$( shasum -a 256 "$DMG" )
printf '%s\n' "$PORTABLE_LINE" > "$SIDECAR"
printf '%s\n' "$ABSOLUTE_LINE" > "$SIDECAR_ABS"

echo "✓ ساخته شد: $DMG  ($ARCHS)"
echo "  checksum (قابل‌حمل، برای بررسی کنار خود تصویر): $SIDECAR"
echo "    مثال: cd \"\$(dirname \"$SIDECAR\")\" && shasum -a 256 -c \"$NAME.dmg.sha256\""
echo "  checksum با مسیر مطلق (فقط شواهد بومی، در گلوب CI نیست): $SIDECAR_ABS"
