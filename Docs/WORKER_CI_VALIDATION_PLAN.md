# Worker CI validation plan

The adversarial baseline of 2026-11-21 (seeds B1–B4, A1, AC-*, D1–D5, E3,
resolver exact/extra; measured on `80b23eea7`) was built from synthetic
fixtures. Synthetic fixtures prove the gates can fail; they do not prove the
payload builds, installs, imports or ships. This file records, for each real
path, what is verified today, the exact command and evidence that would
verify it, where it runs, and what is still unverified after PR #110.

Nothing here changes branch protection. `Worker Lock Closure` and
`Worker Payload Bundle` remain `continue-on-error: true` and are not required
contexts; promotion waits on the criteria recorded in `Docs/CI_GATES.md`
(F1–F3 closed, the seedings running in a required job, a seeded defect shown
failing its job, and a green streak on `main`).

## Status summary

| # | Path | Status | Vehicle |
|---|---|---|---|
| 1 | Real hash-verified install of `worker/requirements.lock` | **Unverified locally**; exercised by the advisory job, not a gate | `Worker Payload Bundle` → step *Install the full runtime lock* |
| 2 | Full runtime packaging (`bundle-worker.sh` + `make-runtime.sh`) | **Unverified locally**; exercised by the advisory job, not a gate | same job → step *Bundle the helper and package the runtime archive* |
| 3 | Real `ditto -x -k` extraction and first import from the extracted tree | **Unverified locally**; exercised by the advisory job, not a gate | same job → step *Import from the extracted runtime* |
| 4 | Positive import smoke in a real full-lock environment | **Unverified locally**; exercised by the advisory job, not a gate | same job → both smoke steps |
| 5 | Worker payload on Windows | **Out of scope** (see Windows below) | none |

"Synthetic fixtures are not real-runtime validation" applies to all five
rows: `test_payload_verification.py` builds zips in a temporary directory,
`test_pip_check_gate.py` feeds the judge captured streams, and
`test_import_smoke.py` injects an importer. They are the failure
demonstration, not the installation proof.

## 1. Real resolver installation

**Command (already wired):** the job runs

```bash
RETOUCH_PYTHON="$PYTHON_RUNTIME" ./Tools/setup-worker-venv.sh --full
```

which ends in (see `Tools/setup-worker-venv.sh`):

```bash
python -m pip install --require-hashes --no-deps -r worker/requirements.lock
```

The separate `Worker Lock Closure` job resolves the same lock without
installing it (`pip install --no-cache-dir --ignore-installed
--require-hashes --no-deps --dry-run --report ...`), which proves a wheel
exists for every pin on the runner's platform but downloads nothing into an
environment.

**Prerequisites:** `macos-15` runner, arm64; Homebrew `openssl@3`, `xz`,
`sqlite`; the source runtime built by `Tools/build-python-runtime.sh` (the job
does all of this).

**Expected evidence:** exit 0 from the install step; `du -sh` shows the
environment size; the `pip check` gate prints
`PIP CHECK GATE: PASS (only the documented mflux -> opencv-python gap)`;
`Inspect the runtime archive` proves the installed set matches the lock.

**Measured cost** (run `44898102728`, PR #110, 2026-11-21): source runtime
build 157 s, full-lock install 56 s on that runner. The resolver-only cost
recorded in `ci.yml` is 304.6 MB in 169.8 s with `--no-cache-dir`; the
install figure above reflects the runner's cache state and is not a
cold-cache promise.

**Limitation:** installing proves the wheels unpack and their metadata is
satisfied. It does not prove any module imports, and it does not exercise the
app's own launch environment.

## 2. Full runtime packaging

**Commands (already wired):**

```bash
app="$RUNNER_TEMP/payload/Retouch Studio.app"
./Tools/bundle-worker.sh "$app"
cd "$RUNNER_TEMP/payload/out"
"$GITHUB_WORKSPACE/Tools/make-runtime.sh" \
  "$app/Contents/Resources/Worker" 0.0.0-ci
```

**Expected evidence:** `make-runtime.sh` exits 0 and writes
`RetouchStudio-0.0.0-ci-ai-runtime-arm64.zip`; `verify_payload.py` prints
`WORKER PAYLOAD: PASS (...)` with 68 dist-info for 67 pins (pip is the one
allowance at the environment's reported version), at least one licence file
and the root documents; `stat -f` and `shasum -a 256` print the archive size
and digest.

**Measured cost:** bundle + package 107 s, inspect 3 s (same run).

**Limitation:** the archive is built from the lock in this repository; it is
not the signed release artifact and carries no Developer ID signature. The
job runs on `macos-15` arm64 only.

## 3. Real extraction and first import

**Commands (already wired):**

```bash
mkdir -p "$RUNNER_TEMP/runtime"
ditto -x -k "$RUNTIME_ZIP" "$RUNNER_TEMP/runtime"
root="$RUNNER_TEMP/runtime"
home=$(ls -d "$root"/Python.framework/Versions/3.13)
PYTHONHOME="$home" \
PYTHONPATH="$root:$root/site-packages" \
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
  "$root/bin/python3" worker/tools/import_smoke.py
```

**Expected evidence:** `ditto` exits 0; the bundled interpreter starts with
the payload as `PYTHONHOME` (no Homebrew or user Python on the path); the
smoke prints `WORKER IMPORT SMOKE: PASS (...)` from the extracted tree.

**Measured cost:** 23 s for extraction plus the smoke (same run).

**Limitation:** this imports modules; it runs no model and no inference. It
also reuses the repository checkout for the smoke script and the package
scan (`--package worker/retouch_ai_worker`), so it proves the environment can
import what the checkout names, not that the extracted worker serves a job.

## 4. Positive real-environment import smoke

The smoke is dependency-aware: the fixed eight targets are a critical-path
floor, and every third-party top-level module the shipped package imports is
derived with the same AST walk `lock_closure.imported_modules()` uses, mapped
through `ALIASES` and required to be pinned. It runs twice in the payload job
— once in the venv, once from the extracted runtime.

**Expected evidence:** both steps exit 0 and print one verdict line naming
the fixed and derived targets and the stdlib / project-local / unpinned
counts. A newly introduced import with no pin is *not* imported by the smoke;
it is printed as `! module: ... the lock closure check must fail it`, and the
required `macOS Integration` job fails it through
`worker/tests/test_import_closure.py`. A guarded unpinned import (the shipped
`sam2`) is printed as a supported refusal and stays optional.

**Limitation:** a passing smoke proves importability under this interpreter,
not that a model loads or that a job runs.

## macOS

- Runner: `macos-15`, arm64, as used by `worker-lock-closure` (30 min timeout,
  required-eligible but advisory) and `worker-payload-bundle` (60 min timeout,
  `continue-on-error: true`).
- The four paths above all live in `worker-payload-bundle`; the resolver check
  lives in `worker-lock-closure`.
- Observed job duration: 363 s for the payload job on PR #110.
- CI needs the `w5-*` branch name (or a PR into `main`/`develop`), because the
  workflow triggers on `pull_request` targets and on `w5-**` pushes.

## Windows

Worker-payload validation on Windows is **out of scope** until the owner
approves a Windows worker artifact:

- the WPF host does not call the Python worker, and
  `Windows/RetouchStudio.AI/Capabilities.cs` marks all capability ids
  blocked or unsupported;
- the Python lock is not Windows-installable: it pins `mlx-metal 0.32.4`,
  which is a macOS-only (Apple Metal) distribution and publishes no Windows
  artifact. There is no Windows wheel set to install, package or smoke.
- No Windows job, script or fixture in this repository validates the worker
  payload, and this PR adds none. Inventing one would be a claim, not
  coverage.

## What remains unverified after PR #110

- Paths 1–4 are exercised only by an **advisory** job on the PR's runner; a
  green run is evidence, not a gate. They are unverified as a required check.
- No real model download, model load or inference is exercised by any part of
  this plan.
- The archive is unsigned and private-key signing is untested.
- Windows payload: out of scope, as above.
- The gates' failure demonstration on the real runner requires the synthetic
  seedings (the runner cannot be made to fail the resolver or corrupt its own
  archive without weakening a check); those seedings are pinned in the test
  suite and were measured locally.
- Promotion to required also waits on a green streak on `main`, per
  `Docs/CI_GATES.md`.
