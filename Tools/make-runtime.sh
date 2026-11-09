#!/bin/bash
# Packages the relocatable AI helper as the optional runtime archive that a
# light build downloads on demand. The archive is the Worker folder itself:
# bin/python3, Python.framework, lib, site-packages and retouch_ai_worker at the
# zip root, so extraction lands exactly on the layout AIRuntime validates.
#
# Usage: make-runtime.sh <Worker folder> [version]
set -euo pipefail

ROOT="${1:?usage: make-runtime.sh <Worker folder> [version]}"
VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"

[ -x "$ROOT/bin/python3" ] || {
  echo "not a helper runtime: $ROOT" >&2
  echo "  Expected bin/python3. Build one with ./build.sh release before removing the Worker cache." >&2
  exit 1
}

OUT="RetouchStudio-$VERSION-ai-runtime-arm64.zip"
ditto -c -k "$ROOT" "$OUT"

BYTES="$(stat -f%z "$OUT")"
SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$OUT" > "$OUT.sha256"

echo "✓ ساخته شد: $OUT  ($BYTES بایت)"
echo "  checksum: $OUT.sha256"
echo "  AIRuntime.swift: RUNTIME_BYTES = $BYTES"
echo "                   RUNTIME_SHA256 = \"$SHA\""
