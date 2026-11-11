# Worker regression artifacts

The Python worker is a separate checkout (`~/RetouchStudio-Phase0/worker`) and
is not a Git repository. Tests kept only there would disappear from a fresh clone
of this repository, so copies of worker-only regressions live here.

Nothing in this directory runs automatically: `Tests/run.sh` does not include it
and `build.sh` does not read it. To run an artifact against the external worker,
follow the header of its file (it is runnable with `PYTHONPATH` pointing at the
worker), or copy the file into the worker's `tests/` directory and use its normal
unittest discovery. The original external test remains the source of truth and
must not be replaced by these copies.

- `test_two_file_download_progress.py` — P0-06: a plan mixing an installed file
  with a missing file counts both files' bytes, never re-fetches the installed
  one, starts the progress offset after it, moves monotonically and ends at
  100%.
