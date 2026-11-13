#!/bin/bash
# R1 StudioCore conformance gate.
#
# Validates the canonical fixtures, render-plan order, corpus lock, and a
# header-only C ABI smoke test. Does not build or launch RetouchStudio.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Windows images ship the interpreter as `python`, and Git Bash has no
# `python3` alias. PYTHON lets a caller pin the executable explicitly.
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  PYTHON=python
fi
"$PYTHON" Tests/Conformance/conformance.py

CC="${CC:-cc}"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
  -I Tests/Conformance/ABI \
  Tests/Conformance/ABI/abi_smoke.c \
  -o "$WORK/abi_smoke"

"$WORK/abi_smoke"

# The StudioCore C ABI v0 header is a separate contract from the image-engine
# draft, so it gets its own header-only translation unit.
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
  -I Sources/StudioCoreABI/include \
  Tests/Conformance/ABI/core_smoke.c \
  -o "$WORK/core_smoke"

"$WORK/core_smoke"
