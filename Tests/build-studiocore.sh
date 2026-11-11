#!/bin/bash
# Builds StudioCore as an independent Swift module plus a static library.
#
# StudioCore is Foundation-only by contract; it must not import AppKit, SwiftUI,
# CoreImage, Vision, ImageIO, CoreGraphics or UIKit. The app and the test
# harnesses link it with -I <outdir> and <outdir>/libStudioCore.a.
#
#   ./Tests/build-studiocore.sh                       # host arch, auto SDK
#   ./Tests/build-studiocore.sh arm64                 # explicit arch
#   ./Tests/build-studiocore.sh x86_64 /path/to/sdk build/out
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "arch باید arm64 یا x86_64 باشد." >&2; exit 1 ;;
esac

SDK="${2:-}"
if [ -z "$SDK" ]; then
  for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr); do
    probe=$(mktemp -d)
    printf 'import Foundation\n' > "$probe/p.swift"
    if swiftc -typecheck -target "${ARCH}-apple-macosx14.0" -sdk "$candidate" "$probe/p.swift" >/dev/null 2>&1; then
      SDK="$candidate"; rm -rf "$probe"; break
    fi
    rm -rf "$probe"
  done
fi
[ -n "$SDK" ] || { echo "no compatible SDK found" >&2; exit 1; }

OUT="${3:-build/studiocore/$ARCH}"
mkdir -p "$OUT"
SOURCES=$(find Sources/StudioCore -name '*.swift')
[ -n "$SOURCES" ] || { echo "Sources/StudioCore is empty" >&2; exit 1; }

# shellcheck disable=SC2046,SC2086
swiftc -O -target "${ARCH}-apple-macosx14.0" -sdk "$SDK" \
  -module-name StudioCore \
  -emit-module -emit-module-path "$OUT/StudioCore.swiftmodule" \
  -emit-library -static -o "$OUT/libStudioCore.a" \
  $SOURCES

echo "✓ StudioCore ($ARCH): $OUT/libStudioCore.a"
