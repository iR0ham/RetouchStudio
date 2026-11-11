#!/bin/bash
# Runs the golden-corpus harness (Tests/CorpusTests.swift).
#
# This is opt-in: unlike Tests/run.sh it writes artifacts under Tests/Corpus
# and can take a couple of minutes, so it is not part of the default gate. It
# uses the same Command Line Tools SDK probe and source list as Tests/run.sh.
#
#   ./Tests/run-corpus.sh                     # arm64 (host)
#   RETOUCH_ARCH=x86_64 ./Tests/run-corpus.sh # Rosetta
#   RETOUCH_CORPUS_DIR=/tmp/corpus ./Tests/run-corpus.sh
#
# The exit status is non-zero when a check fails.
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
cp Tests/CorpusTests.swift "$work/main.swift"
cp Tests/CorpusSupport.swift "$work/CorpusSupport.swift"
out="$work/corpustests"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

if ! swiftc -O -target "${TARGET_ARCH}-apple-macosx14.0" -sdk "$SDK" -o "$out" \
  -I "$CORE_DIR" \
  "$work/main.swift" "$work/CorpusSupport.swift" \
  $SOURCES "$CORE_DIR/libStudioCore.a" \
  -framework SwiftUI -framework AppKit -framework CoreImage \
  -framework Vision -framework UniformTypeIdentifiers -framework Metal \
  >"$work/build.log" 2>&1; then
  cat "$work/build.log" >&2
  exit 1
fi

"$out"
