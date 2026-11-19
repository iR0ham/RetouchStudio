#!/bin/bash
# Runs the worker's protocol, server and registry regressions (163 tests).
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON="${RETOUCH_WORKER_PYTHON:-worker/.venv/bin/python3}"
[ -x "$PYTHON" ] || {
  echo "worker interpreter not found: $PYTHON" >&2
  echo "  run Tools/setup-worker-venv.sh, or set RETOUCH_WORKER_PYTHON" >&2
  exit 1
}
export PYTHONPATH="$PWD/worker${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
"$PYTHON" -m unittest discover -s worker/tests -v
