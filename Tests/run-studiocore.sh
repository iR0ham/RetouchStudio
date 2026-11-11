#!/bin/bash
# Builds StudioCore on its own, proves it has no platform dependencies, then
# runs Tests/StudioCoreTests.swift linked only against Foundation and the
# module. This is the executable form of the module contract: StudioCore must
# compile and pass its tests without AppKit, SwiftUI, Core Image, Vision,
# ImageIO, CoreGraphics, UIKit or the app target.
#
#   ./Tests/run-studiocore.sh               # host arch
#   ./Tests/run-studiocore.sh x86_64        # explicit arch (Rosetta on Apple silicon)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_ARCH="${1:-${RETOUCH_ARCH:-$(uname -m)}}"
case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "معماری باید arm64 یا x86_64 باشد." >&2; exit 1 ;;
esac

FORBIDDEN_IMPORTS='AppKit|SwiftUI|CoreImage|Vision|ImageIO|CoreGraphics|UIKit|UniformTypeIdentifiers|CoreVideo|Metal|AVFoundation|Cocoa|RetouchStudio'
PLATFORM_TYPES='NSColor|NSImage|NSFont|NSBezierPath|CIImage|CIColor|CIFilter|CGImage|CGColor|CGContext|CGRect|CGSize|CGPoint|CGFloat|CGAffineTransform|VNDetect[A-Za-z]*|VNImageRequestHandler|VNRecognize[A-Za-z]*|UTType|\bColor\b|\bImage\b|\bView\b'

failed=0
fail() { echo "  ✗ $*" >&2; failed=1; }

echo "→ بررسی مرز پلتفرم در Sources/StudioCore"
while IFS= read -r file; do
  hits=$(perl -pe 's{//.*$}{}' "$file" | grep -nE "^[[:space:]]*(@[^ ]+[[:space:]]+)*import[[:space:]]+($FORBIDDEN_IMPORTS)" || true)
  [ -z "$hits" ] || fail "$file imports a platform/app module: $hits"
  hits=$(perl -pe 's{//.*$}{}' "$file" | grep -nE "($PLATFORM_TYPES)" || true)
  [ -z "$hits" ] || fail "$file mentions a platform type:"$'\n'"$hits"
done < <(find Sources/StudioCore -name '*.swift')

imports=$(grep -RhE "^[[:space:]]*import[[:space:]]" Sources/StudioCore | sort -u)
[ "$imports" = "import Foundation" ] || fail "StudioCore imports more than Foundation:"$'\n'"$imports"
[ "$failed" -eq 0 ] && echo "  ✓ فقط Foundation؛ هیچ نوع پلتفرمی در ماژول نیست"

# The same SDK probe as build.sh keeps every harness on one SDK.
SDK=""
for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr); do
  probe=$(mktemp -d)
  printf 'import SwiftUI\nstruct P: View { @State var v = 1; var body: some View { Text("\\(v)") } }\n' > "$probe/p.swift"
  if swiftc -typecheck -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$candidate" "$probe/p.swift" >/dev/null 2>&1; then
    SDK="$candidate"; rm -rf "$probe"; break
  fi
  rm -rf "$probe"
done
[ -n "$SDK" ] || { echo "no compatible SDK found" >&2; exit 1; }

echo "→ ساخت مستقل ماژول StudioCore ($TARGET_ARCH)"
CORE_DIR="build/studiocore/$TARGET_ARCH"
./Tests/build-studiocore.sh "$TARGET_ARCH" "$SDK" "$CORE_DIR"

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
cp Tests/StudioCoreTests.swift "$work/main.swift"
out="$work/studiocoretests"

echo "→ کامپایل تست‌ها فقط با Foundation و StudioCore"
# No -framework flags: anything the module secretly imported would fail here.
swiftc -O -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$SDK" \
  -I "$CORE_DIR" -o "$out" \
  "$work/main.swift" "$CORE_DIR/libStudioCore.a" >"$work/build.log" 2>&1 || {
  cat "$work/build.log" >&2
  exit 1
}

linked=$(otool -L "$out" | grep -E "AppKit|SwiftUI|CoreImage|Vision|ImageIO|CoreGraphics|UIKit|UniformTypeIdentifiers|CoreVideo|Metal|AVFoundation" || true)
if [ -n "$linked" ]; then
  fail "the test binary links platform frameworks:"$'\n'"$linked"
else
  echo "  ✓ باینری تست فقط Foundation/StudioCore را لینک می‌کند"
fi

echo "→ اجرای تست‌های StudioCore"
STUDIOCORE_ROOT="$PWD" "$out"
[ "$failed" -eq 0 ] || exit 1
