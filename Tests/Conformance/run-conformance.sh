#!/bin/bash
# R1 StudioCore conformance gate.
#
# Validates the canonical fixtures, render-plan order, corpus lock, and a
# header-only C ABI smoke test. Does not build or launch RetouchStudio.
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 Tests/Conformance/conformance.py

CC="${CC:-cc}"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
  -I Tests/Conformance/ABI \
  Tests/Conformance/ABI/abi_smoke.c \
  -o "$WORK/abi_smoke"

"$WORK/abi_smoke"
