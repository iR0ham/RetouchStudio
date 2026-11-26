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
# RETOUCH_DMG_DIR to write the image and its sidecar outside the source tree.
OUT_DIR="${RETOUCH_DMG_DIR:-.}"
mkdir -p "$OUT_DIR"
OUT_ABS=$(cd "$OUT_DIR" && pwd)
DMG="$OUT_ABS/$NAME.dmg"
SIDECAR="$DMG.sha256"

# Never destroy a previous image of the same version: once published or
# accepted, a release artifact is evidence, and a re-run must not silently
# replace it. RETOUCH_DMG_FORCE=1 is the explicit opt-in to overwrite.
if [ "${RETOUCH_DMG_FORCE:-0}" != "1" ]; then
  for existing in "$DMG" "$SIDECAR"; do
    if [ -e "$existing" ]; then
      echo "✗ از قبل وجود دارد: $existing — برای جلوگیری از حذف تصویر قبلی، متوقف شد. برای بازنویسی RETOUCH_DMG_FORCE=1 تنظیم کنید." >&2
      exit 1
    fi
  done
fi

STAGE=$(mktemp -d /tmp/retouch-dmg.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Retouch Studio.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Retouch Studio $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# The sidecar records the absolute image path so `shasum -a 256 -c <sidecar>`
# verifies from any working directory; a relative line would only be valid
# from the directory the script happened to run in.
shasum -a 256 "$DMG" > "$SIDECAR"

echo "✓ ساخته شد: $DMG  ($ARCHS)"
echo "  checksum: $SIDECAR"
