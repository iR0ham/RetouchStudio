# Worker regression artifacts

The Python worker source now lives at `worker/` in this repository. Its complete
regression suite runs with `Tests/run-worker.sh` (137 tests) and the macOS CI job
creates the hashed environment with `Tools/setup-worker-venv.sh`.

This directory keeps the P0-06 download regression as a historical standalone
artifact for anyone comparing it with the external Phase 0 checkout. The
canonical copy is `worker/tests/test_downloads.py`; do not edit only this copy.

- `test_two_file_download_progress.py` — P0-06: a plan mixing an installed file
  with a missing file counts both files' bytes, never re-fetches the installed
  one, starts the progress offset after it, moves monotonically and ends at
  100%.
