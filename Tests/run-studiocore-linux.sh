#!/bin/bash
# Compiles StudioCore and its tests with a non-Apple Swift toolchain and its
# Foundation, then runs the same checks. This is the executable form of the
# Linux claim: no SDK probe, no macOS frameworks, no Apple-only linker.
#
#   ./Tests/run-studiocore-linux.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FORBIDDEN_IMPORTS='AppKit|SwiftUI|CoreImage|Vision|ImageIO|CoreGraphics|UIKit|UniformTypeIdentifiers|CoreVideo|Metal|AVFoundation|Cocoa|RetouchStudio'
PLATFORM_TYPES='NSColor|NSImage|NSFont|NSBezierPath|CIImage|CIColor|CIFilter|CGImage|CGColor|CGContext|CGRect|CGSize|CGPoint|CGFloat|CGAffineTransform|VNDetect[A-Za-z]*|VNImageRequestHandler|VNRecognize[A-Za-z]*|UTType|\bColor\b|\bImage\b|\bView\b'

failed=0
fail() { echo "  ✗ $*" >&2; failed=1; }

echo "→ بررسی مرز پلتفرم در Sources/StudioCore (Linux)"
while IFS= read -r file; do
  hits=$(perl -pe 's{//.*$}{}' "$file" | grep -nE "^[[:space:]]*(@[^ ]+[[:space:]]+)*import[[:space:]]+($FORBIDDEN_IMPORTS)" || true)
  [ -z "$hits" ] || fail "$file imports a platform/app module: $hits"
  hits=$(perl -pe 's{//.*$}{}' "$file" | grep -nE "($PLATFORM_TYPES)" || true)
  [ -z "$hits" ] || fail "$file mentions a platform type:"$'\n'"$hits"
done < <(find Sources/StudioCore -name '*.swift')

imports=$(grep -RhE "^[[:space:]]*import[[:space:]]" Sources/StudioCore | sort -u)
[ "$imports" = "import Foundation" ] || fail "StudioCore imports more than Foundation:"$'\n'"$imports"
[ "$failed" -eq 0 ] || { echo "  ✗ the boundary failed; not compiling" >&2; exit 1; }
echo "  ✓ فقط Foundation؛ هیچ نوع پلتفرمی در ماژول نیست"

CORE_DIR="build/studiocore/linux"
mkdir -p "$CORE_DIR"
work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

echo "→ کامپایل StudioCore روی $(uname -s) $(uname -m)"
swiftc -O -module-name StudioCore \
  -emit-module -emit-module-path "$CORE_DIR/StudioCore.swiftmodule" \
  -emit-library -static -o "$CORE_DIR/libStudioCore.a" \
  -module-cache-path "$work/cache" \
  Sources/StudioCore/*.swift

cp Tests/StudioCoreTests.swift "$work/main.swift"

echo "→ کامپایل تست‌ها فقط با Foundation و StudioCore"
swiftc -O -module-cache-path "$work/cache" -I "$CORE_DIR" \
  -o "$work/studiocoretests" \
  "$work/main.swift" "$CORE_DIR/libStudioCore.a"

echo "→ اجرای تست‌های StudioCore"
STUDIOCORE_ROOT="$PWD" "$work/studiocoretests"
