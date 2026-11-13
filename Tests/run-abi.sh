#!/bin/bash
# Builds the StudioCore C ABI v0 static library and runs the C test that links
# it, so a host which does not share Swift's ABI is proven to work through
# studioscore_core.h alone.
#
#   ./Tests/run-abi.sh               # host arch
#   ./Tests/run-abi.sh x86_64        # explicit arch (Rosetta on Apple silicon)
#   ./Tests/run-abi.sh arm64 /path/to/sdk
#
# Tests/run.sh passes its own SDK so every harness shares one module build.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_ARCH="${1:-${RETOUCH_ARCH:-$(uname -m)}}"
case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "معماری باید arm64 یا x86_64 باشد." >&2; exit 1 ;;
esac

SDK="${2:-}"
if [ -z "$SDK" ]; then
  for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr); do
    probe=$(mktemp -d)
    printf 'import SwiftUI\nstruct P: View { @State var v = 1; var body: some View { Text("\\(v)") } }\n' > "$probe/p.swift"
    if swiftc -typecheck -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$candidate" "$probe/p.swift" >/dev/null 2>&1; then
      SDK="$candidate"; rm -rf "$probe"; break
    fi
    rm -rf "$probe"
  done
fi
[ -n "$SDK" ] || { echo "no compatible SDK found" >&2; exit 1; }

CORE_DIR="build/studiocore/$TARGET_ARCH"
./Tests/build-studiocore.sh "$TARGET_ARCH" "$SDK" "$CORE_DIR"

ABI_DIR="build/studioabi/$TARGET_ARCH"
mkdir -p "$ABI_DIR"
ABI_SOURCES=$(find Sources/StudioCoreABI -name '*.swift')
[ -n "$ABI_SOURCES" ] || { echo "Sources/StudioCoreABI is empty" >&2; exit 1; }

echo "→ ساخت کتابخانه C ABI ($TARGET_ARCH)"
# shellcheck disable=SC2046,SC2086
swiftc -O -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$SDK" \
  -module-name StudioCoreABI \
  -emit-module -emit-module-path "$ABI_DIR/StudioCoreABI.swiftmodule" \
  -emit-library -static -o "$ABI_DIR/libStudioCoreABI.a" \
  -I "$CORE_DIR" \
  $ABI_SOURCES

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
out="$work/abi_tests"

echo "→ کامپایل تست C11 با هدر عمومی"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic \
  -arch "$TARGET_ARCH" -isysroot "$SDK" -mmacosx-version-min=14.0 \
  -I Sources/StudioCoreABI/include \
  -c Tests/ABI/abi_tests.c -o "$work/abi_tests.o"

echo "→ لینک C با Swift"
swiftc -O -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$SDK" \
  -o "$out" \
  "$work/abi_tests.o" \
  "$ABI_DIR/libStudioCoreABI.a" "$CORE_DIR/libStudioCore.a"

echo "→ اجرای تست‌های C ABI"
STUDIOCORE_ROOT="$PWD" "$out"
