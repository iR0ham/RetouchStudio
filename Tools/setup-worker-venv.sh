#!/bin/bash
# Creates the in-repository worker environment from the hashed lockfiles.
#
# --full builds/uses the pinned source-built CPython and installs
# requirements.lock (models, MLX, torch). The default installs
# requirements-test.lock, which is enough for the protocol and server suites.
# Every wheel is verified against the SHA-256 recorded in the lock.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-test}" in
  test) LOCK=worker/requirements-test.lock; FULL=0 ;;
  --full|full) LOCK=worker/requirements.lock; FULL=1 ;;
  *) echo "usage: $0 [test|--full]" >&2; exit 1 ;;
esac

PYTHON="${RETOUCH_PYTHON:-}"
if [ "$FULL" = "1" ] && [ -z "$PYTHON" ]; then
  PYTHON="$(Tools/build-python-runtime.sh)"
fi
if [ -z "$PYTHON" ]; then
  for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON="$candidate"; break; fi
  done
fi
[ -n "$PYTHON" ] || { echo "no Python 3.13 interpreter found" >&2; exit 1; }
"$PYTHON" - <<'PY' || exit 1
import sys
if sys.version_info[:2] != (3, 13):
    sys.exit("the hashed macOS wheels require Python 3.13")
PY

if [ "$FULL" = "1" ] && [ "$(uname -m)" != "arm64" ]; then
  echo "the AI runtime is arm64-only; build it on Apple silicon" >&2
  exit 1
fi

VENV="${RETOUCH_WORKER_VENV:-worker/.venv}"
if [ ! -x "$VENV/bin/python3" ]; then
  "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python3" -m pip install --disable-pip-version-check \
  --require-hashes -r "$LOCK"
echo "worker environment ready: $VENV ($([ "$FULL" = 1 ] && echo full || echo test))"
