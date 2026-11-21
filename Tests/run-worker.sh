#!/bin/bash
# Runs the worker's protocol, server and registry regressions. The expected
# suite size lives only in Tests/expected-worker-tests.txt; this script fails
# when discovery finds a different number.
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

expected=$(tr -d '[:space:]' < Tests/expected-worker-tests.txt)
log=$(mktemp)
trap 'rm -f "$log"' EXIT
"$PYTHON" -m unittest discover -s worker/tests -v 2>&1 | tee "$log"
actual=$(sed -nE 's/^Ran ([0-9]+) tests? in .*/\1/p' "$log" | tail -1)
if [ "${actual:-}" != "$expected" ]; then
  echo "worker suite: discovered ${actual:-no count}, " \
       "Tests/expected-worker-tests.txt says $expected" >&2
  exit 1
fi
