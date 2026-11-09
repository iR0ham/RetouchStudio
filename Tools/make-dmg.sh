#!/bin/bash
# Builds the drag-to-Applications disk image from the packaged app.
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

STAGE=$(mktemp -d /tmp/retouch-dmg.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Retouch Studio.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$NAME.dmg" "$NAME.dmg.sha256"
hdiutil create -volname "Retouch Studio $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$NAME.dmg" >/dev/null

shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256"

echo "✓ ساخته شد: $NAME.dmg  ($ARCHS)"
echo "  checksum: $NAME.dmg.sha256"
