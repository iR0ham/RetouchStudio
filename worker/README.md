# retouch_ai_worker

A local, headless worker that runs the generative edit for Retouch Studio. It
listens on a Unix domain socket, accepts one heavy job at a time, and never
touches the network while a job is running.

Python 3.13. Models: FLUX.2 klein 4B (q4, Apache-2.0) for edits, SAM 2.1 tiny
(Apache-2.0) for masks.

## Install

The source lives in this repository. `Tools/setup-worker-venv.sh` creates
`worker/.venv` from the hashed lockfile; nothing is fetched from a mutable
branch.

```bash
./Tools/setup-worker-venv.sh          # protocol/server tests (numpy, Pillow)
./Tools/setup-worker-venv.sh --full   # builds CPython 3.13.15 from source, then models/MLX/torch
```

`requirements.lock` pins every macOS arm64 wheel by version and SHA-256. The
test lock is a strict subset so a fresh checkout can run the regressions
without downloading torch. `--full` builds the interpreter from
`Python-3.13.15.tgz` (SHA-256
`c28d9d213c09b5b5ab2c29812950e12f746999e099b82894231be954b26baed9`); the app
bundle carries that framework, never a Homebrew or user-installed Python.

The full lock is what ships, so it has its own checks. `tools/lock_closure.py`
parses the shipped package's imports and proves each unguarded one is pinned
(`sam2` is guarded, a deliberate refusal, not a dependency), then compares a
`pip --dry-run --report` of the full lock against it. `tools/import_smoke.py`
imports the heavy modules the engine loads lazily once a full environment
exists. CI runs the first on every pull request, and the second beside a build
of the runtime archive.

## Run

```bash
cd worker
PYTHONPATH=. .venv/bin/python -m retouch_ai_worker serve \
  --socket "$HOME/Library/Application Support/RetouchStudio/AI/worker.sock" \
  --jobs   "$HOME/Library/Application Support/RetouchStudio/AI/jobs" \
  --allow-root "$HOME/Pictures"
```

`--allow-root` is the only way the worker may read a file by path. Anything
outside those roots is refused with `PATH_DENIED`; the app normally passes
pixels through shared memory instead.

Useful side commands:

```bash
python -m retouch_ai_worker models list
python -m retouch_ai_worker models verify flux2-klein-4b-q4
python -m retouch_ai_worker models plan flux2-klein-4b-q4       # prints the manifest
python -m retouch_ai_worker models download flux2-klein-4b-q4   # needs --yes
python -m retouch_ai_worker selftest
python -m retouch_ai_worker call models.list                    # one JSON-RPC call
```

`models download` is the only command that opens a network connection, and it
refuses to fetch anything unless the user has approved the exact manifest hash
printed before the transfer. Files are written to `<models>/.staging/`, checked
by SHA256, then moved into place.

## Protocol

Protocol version 2, JSON-RPC 2.0, one object per line, 1 MiB per frame, and
`contractVersion: "1"` in every request and response. The host launches the
helper with `--protocol-version 2 --helper-generation <uuid> --launch-nonce
<uuid> --registry <path> [--usage-fd N]`; `hello` and `health` return the same
generation, nonce, pid and `protocol_version`, and the worker writes its
readiness record under the host's `flock`. `Docs/AI_PROTOCOL_V2.md` is the
cross-platform contract; `Tests/Contract/protocol2.json` is the shared fixture.

| Method | Purpose |
|---|---|
| `hello` | protocol/contract version, generation, nonce, pid, job snapshot, allowed roots |
| `health` | readiness plus catalog health |
| `provider.list` | execution providers this worker has actually initialised (`mps`/`cpu` once a model has loaded, `[]` plus a `reason` before any model has run) |
| `ping` | liveness |
| `models.list` / `models.verify` / `models.plan` | catalog, checksums, download manifest |
| `job.submit` | `{kind, capabilityId?, params, out_shm?}` → `{job_id}`; one at a time (`BUSY`) |
| `job.status` / `job.result` / `job.cancel` | lifecycle |
| `jobs.list` | current job and the last ten |
| `buffer.release` | detach a shared-memory output |
| `shutdown` | stop accepting, exit |

Notifications carry no `id`: `job.started`, `job.progress` (with `stage` and
`step`), `job.cancelling`, `job.finished`.

Job kinds: `ping`, `mask`, `patch_edit`, `upscale`.

An image parameter is one of:

- `{"shm": name, "width": W, "height": H, "channels": 3}` — preferred; the app
  owns the segment and must `shm_unlink` it;
- `{"data": "data:image/png;base64,..."}` — small images and tests;
- `{"path": "/abs/path"}` — only inside an allowed root.

Results are written as PNG inside the job directory; `out_shm` additionally
copies the result into an app-allocated segment. A successful `upscale` also
writes the `retouchstudio.ai.provenance/1` sidecar named
`<artifact>.provenance.json` beside its output and returns the path as
`provenance`; the record's values are measured from the bytes the job wrote,
which the publishing rename moves unchanged, and `provenance.verify` re-reads
both after the commit (`provenance.py`).

A `patch_edit` reply that stays local carries one rectangle for both output
files:

```
{"mode": "patch",
 "patch": ".../patch.png", "alpha": ".../alpha.png",
 "box": [x0, y0, x1, y1],            # pixels, top-left origin
 "image_size": [width, height],
 "dilate": 4, "feather": 2,
 "outside_pixels_identical": true, ...}
```

`patch.png` holds the edited pixels for `box` and `alpha.png` their mask. The
alpha is exactly zero outside the dilated mask, so an app can stretch both files
onto the same rectangle at any resolution and composite without touching a
pixel outside the box. The full-frame fallback returns `mode: "full-frame"` and
no patch files.

## Invariants the code enforces

1. **One heavy job.** A second submit while one runs returns `BUSY`; the machine
   has 16 GB and two models do not fit.
2. **No network in the job path.** `server.py`, `engine.py`, `transport.py`,
   `protocol.py`, `catalog.py` and `plan.py` contain no `urllib`, `http.client`,
   `requests` or `socket.socket`; a unit test fails if that changes. Only
   `downloads.py` has transfer code, and the server never imports it.
3. **Licence gate before disk.** Every entry carries a `permitted_use` record —
   code, weights and training data separately — and `Catalog.require()` raises
   `LICENSE_BLOCKED` before it looks at the files when the record does not admit
   the model (`unknown`, `approved-with-conditions` with an unmet condition, or
   any `excluded` artefact). The same record travels whole through `models.list`
   and `Catalog.public()`, so the app reads the worker's own position.
   Real-ESRGAN remains evaluation-only until Phase 4. LaMa was removed from the
   catalog entirely (weights have no license); MI-GAN is MIT and is the shipped
   small-hole inpaint model.
4. **Original pixels survive.** Jobs decode the input, write new files, and
   never write the input path.
5. **Strict compositing.** `composite()` dilates the mask, feathers only its
   inside, and leaves every pixel outside byte-identical; the result reports
   `outside_pixels_identical` so the app can refuse a bad result.
6. **Mask routing.** `patch_edit` takes `engine`: `inpaint` (MI-GAN, refused
   above 25 % of the frame), `patch` (FLUX) or `auto`. Without an explicit
   engine, `mask_policy()` sends masks up to 6 % of the frame to patch
   rendering, up to 45 % to a whole-frame render, and refuses anything larger.
7. **Cancel.** `job.cancel` is acknowledged immediately; the job stops at the
   next denoising step, which is the only point MLX can be interrupted from
   inside a single `generate_image` call. The `upscale` job is not MLX, so it
   defines its own safe points: before it loads the model, between tiles, and
   again after the encoder has written the staged PNG but before publication
   begins — a cancel at the write leaves neither artifact nor temp file and no
   provenance sidecar. Cancellation is deliberately **not** re-checked inside
   the publication itself: a request that arrives there lands on a commit that
   is already under way, and the pair finishes. Tearing it apart would trade a
   late cancel for an artifact without provenance.
8. **One engine thread.** MLX streams and torch device state are thread-local,
   and mflux's VAE attention builds an MLX array as its attention scale, so a
   model loaded on one thread cannot be used from another. Every job therefore
   runs on the engine's own thread, no matter which connection submitted it.
9. **Memory budget (generative renders).** A generative render is refused with
   `BUDGET_EXCEEDED` when its estimated peak exceeds
   `RETOUCH_AI_MEMORY_BUDGET_GB` (default 7.5). The upscale path never reads
   it: upscale is bounded by the 40 MP output ceiling and the host's own wait.
10. **Digests are checked where a model is loaded.** `Catalog.require_verified`
    runs `require` and then hashes every file the catalog gives a SHA-256 for,
    before the loader receives a path; a mismatch releases the lease so the
    install stays repairable and fails with `-32019`. Only `upscale` uses it:
    hashing that checkpoint costs 0.036 s for its 48,460,141-byte
    `pytorch_model.bin` (measured on this M3/16 GB Mac on 2026-11-17), once per
    process, while hashing 4.6 GB of FLUX weights before every render is not a
    startup cost the 16 GB budget can pay. Those entries keep the size gate in
    `require` and the on-demand `models verify`.
11. **A provider is named only after it initialised.** `Engine.execution_providers`
    reports the device a loader actually used (`mps` or `cpu`), and nothing plus
    a reason before the first model. Probing torch during the handshake would
    spend seconds and hundreds of megabytes to answer with a claim.
12. **An artifact is never alone.** `provenance.publish` lands the sidecar
    first and the artifact rename is the commit point, then re-reads the pair
    and withdraws both if the digests disagree, and refuses outright to
    publish over an artifact some other job already wrote. No filesystem makes
    two renames atomic, so the guarantee comes from the order: the state a
    crash can leave is a sidecar with no artifact — inert, cleared by
    `provenance.reconcile` — never an artifact whose provenance failed to
    arrive. The sweep is bounded by time as well: it takes a timestamp and
    clears only sidecars and half-written sidecar temps older than it, so a
    second worker sharing the jobs root cannot delete the evidence out from
    under a commit that is about to verify it. A sidecar written in the
    instant before that bound can still be cleared, and the commit that was
    about to verify it then withdraws its artifact — a lost job, never an
    unprovenanced one.
13. **A running job owns its workdir.** Before a job's context exists it takes an
    exclusive `flock` on `<workdir>/.lock` and closes it only after
    `job.finished` has been emitted, because the host reads the artifacts the
    moment it sees that event. The claim is what lets the app clear a jobs root
    it did not fill: `AIWorker.cleanStaleJobFolders` removes a folder only when
    it is 24 h old *and* nobody can be writing into it, so a render that overruns
    the age bound cannot be swept under itself. The kernel drops the lock when
    the holder dies, which is why no cleanup has to reason about a crashed
    worker, and why a crash cannot leave a guard outliving the job it protected.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `RETOUCH_AI_MODELS` | `~/Library/Application Support/RetouchStudio/AI/models` | model root |
| `RETOUCH_AI_EVAL_MODELS` | unset | `1` allows evaluation-only models (never ship with it) |
| `RETOUCH_AI_MEMORY_BUDGET_GB` | `7.5` | refuse generative renders above this estimate (upscale is bounded by the 40 MP output ceiling) |
| `RETOUCH_AI_MLX_CACHE_GB` | `4.0` | MLX buffer-cache cap; `0` uncaps |
| `RETOUCH_AI_MLX_WIRED_GB` | `6.0` | wire weights so the system cannot page them mid-job |

## Tests

```bash
./Tests/run-worker.sh
```

166 tests, no GPU and no model download: framing, contract versioning, request
validation, generation and nonce pairing, the readiness registry, catalog
licensing, download resume and checksums against a local HTTP server, job
lifecycle, BUSY, cancel, notifications, path denial, mask policy, compositing
byte-identity, alpha bounds, the frozen capability vocabulary, its evidence
rules and the runtime-package condition that is asked before either. The upscale
tests run a fake torch and a fake model against a real
numpy array, so they cover the provenance sidecar, the load-time digest, the
load/write cancel points and the reported provider without any inference
runtime. `test_provenance.py` patches the three syscalls the writer uses and
fails each one in turn — serialise, create, write, rename the sidecar, rename
the artifact, verify — to prove that every failure leaves either a complete,
self-consistent pair or nothing at all, and that startup recovery clears an
orphan sidecar without touching a completed pair or any other file. The workdir
claim is covered from both sides: `test_server.py` submits a slow job and shows
its `<workdir>/.lock` refused to a second descriptor and to a real child process
until `job.finished`, then granted once the job lets go, and `test_provenance.py`
shows the same startup sweep leaving that lock file alone.

## Acceptance

`tools/acceptance.py` drives a running worker over the socket only: license
refusal, checksum verification, a SAM mask job, N consecutive patch jobs with
per-job RSS and swap, BUSY refusal, cancel latency, recovery, and the integrity
flag on every result.

```bash
.venv/bin/python worker/tools/acceptance.py --socket /tmp/rs-worker.sock --jobs 10
```

The JSON record is written to `out/phase1-acceptance.json` and is what the
reports cite.
