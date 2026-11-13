#!/bin/bash
# Measures the real engine stages on synthetic 12/24/48 MP frames.
#
#   ./Tests/run-benchmarks.sh                     # arm64 (host)
#   RETOUCH_ARCH=x86_64 ./Tests/run-benchmarks.sh # Rosetta
#   RETOUCH_BENCH_REAL_DIR="$HOME/Pictures" ./Tests/run-benchmarks.sh
#
# Optional RETOUCH_BENCH_REAL_DIR adds up to three JPEGs from that directory.
# Real photos are what exercise face analysis and mask building; the synthetic
# frames have no face, so those two stages are reported only for real input.
#
# Results are written to build/benchmarks/latest.json and printed as a table.
# This is not a pass/fail gate: timings depend on the host and machine load.
# Set RETOUCH_BENCH_MEMORY_PROBE (1, clear, load, render, decode, vision,
# vision-buffer) to isolate a memory-retention question instead. Methodology
# and the current observations live in Docs/PERFORMANCE_BENCHMARKS.md.
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

SOURCES=$(find Sources/RetouchStudio -name '*.swift' ! -name 'App.swift' ! -name 'SelfCheck.swift')
CORE_DIR="build/studiocore/$TARGET_ARCH"
./Tests/build-studiocore.sh "$TARGET_ARCH" "$SDK" "$CORE_DIR"

work="$(mktemp -d)"
cp Tests/Benchmarks.swift "$work/main.swift"
out="$work/benchmarks"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

if ! swiftc -O -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$SDK" -o "$out" \
  -I "$CORE_DIR" \
  "$work/main.swift" \
  $SOURCES "$CORE_DIR/libStudioCore.a" \
  -framework SwiftUI -framework AppKit -framework CoreImage \
  -framework Vision -framework UniformTypeIdentifiers \
  >"$work/build.log" 2>&1; then
  cat "$work/build.log" >&2
  exit 1
fi

RETOUCH_TESTS_ROOT="$PWD" \
RETOUCH_BENCH_COMMIT="$(git rev-parse HEAD)" \
"$out"
