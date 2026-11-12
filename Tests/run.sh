#!/bin/bash
# Runs the engine regression suite (Tests/EngineTests.swift).
#
# Why a separate harness instead of `swift test`: this project is built with
# swiftc against Command Line Tools only (no Xcode), so there is no test runner.
# The suite links the app's Core sources directly and asserts on real rendered
# pixels.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_ARCH="${RETOUCH_ARCH:-$(uname -m)}"
case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "RETOUCH_ARCH باید arm64 یا x86_64 باشد." >&2; exit 1 ;;
esac

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

# Swift only allows top-level code in a file named main.swift, so each suite is
# copied to a scratch directory under that name before compiling.
#
# The app's whole source tree is linked except `App.swift` (its @main would
# collide with main.swift and it launches the UI) and `SelfCheck.swift` (the
# separate --selftest harness). The engine and the models share types in both
# directions, so linking only a hand-picked subset drifts out of date.
SOURCES=$(find Sources/RetouchStudio -name '*.swift' ! -name 'App.swift' ! -name 'SelfCheck.swift')

CORE_DIR="build/studiocore/$TARGET_ARCH"
./Tests/build-studiocore.sh "$TARGET_ARCH" "$SDK" "$CORE_DIR"

run_suite() {
  local suite="$1" name="$2"
  local work out
  work="$(mktemp -d)"
  cp "$suite" "$work/main.swift"
  out="$work/$name"
  swiftc -O -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$SDK" -o "$out" \
    -I "$CORE_DIR" \
    "$work/main.swift" \
    $SOURCES "$CORE_DIR/libStudioCore.a" \
    -framework SwiftUI -framework AppKit -framework CoreImage \
    -framework Vision -framework UniformTypeIdentifiers 2>&1 | grep -E "error:" && exit 1
  # The suites are compiled from a scratch copy, so fixture lookups cannot use
  # #filePath. Hand the checkout root over instead.
  RETOUCH_TESTS_ROOT="$PWD" "$out"
}

run_suite Tests/EngineTests.swift enginetests
run_suite Tests/ModelTests.swift modeltests
run_suite Tests/RuntimeProcessTests.swift runtimeprocesstests
run_suite Tests/RuntimeV2Tests.swift runtimev2tests
