# Retouch Studio — Local AI Runtime

**Applies to:** the local AI helper, whether it is bundled inside `Retouch Studio.app` or installed from a future approved protocol-v2 runtime archive. The on-demand installer is disabled in the current stabilization build (`AIRuntime.package` is nil). Measurements below were taken with the 2.1 (build 3) development build, before the first public release (`app.retouchstudio.mac`, 1.0.0).
**Target:** macOS 14.0 or later. The app is universal (arm64 + x86_64); the helper is an Apple-silicon (arm64) runtime, so AI tools are unavailable on Intel. Measured on a MacBook Air M3 with 16 GB.
**Related:** [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md), [`PHASE5_ACCEPTANCE.md`](PHASE5_ACCEPTANCE.md)

The helper is self-contained. A full build carries it inside the app. Release builds do not, and the protocol-v2 download path exists in the code but is disabled in the current build: no official runtime package has been approved, so `AIRuntime.package` stays nil and Settings offers no runtime download. The `RetouchStudio-1.0.0-ai-runtime-arm64.zip` asset on the 1.0.0 release page is a legacy archive; it is not treated as a compatible protocol-v2 package, and compatibility has not been verified. When an official package is configured, the runtime archive and the model weights will be the only downloads. The runtime gets its own consent sheet showing the archive name, its size and a 16-character SHA256 prefix before anything is fetched. Each model gets a sheet showing its file count, total size and licence; that sheet does not list every file or its SHA256. Everything that runs — the retouching engine, the Python helper, PyTorch, Transformers, ONNX Runtime and MLX — is local.

---

## 1. What ships, and what does not

| Component | Location | Size |
|---|---|---|
| App, engine and UI | `Contents/MacOS/RetouchStudio` | 5.9 MB |
| Light release app (per architecture / universal) | `Retouch Studio.app` | ~3.5–4 MB / ~16 MB |
| Python 3.13.15 + wheels + helper (full build) | `Contents/Resources/Worker/` | ~1.29 GiB |
| Protocol-v2 runtime (future approved package, installed on demand) | `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2/` | archive size fixed by its package metadata |
| Legacy 1.0.0 runtime archive (not read by this build) | Release asset only; never installed under `AI/runtime` | 388,277,063 bytes zipped |
| Typeface (Vazirmatn, SIL OFL) | `Contents/Resources/Fonts/` | ~496 KB |
| **Whole full app bundle** | | **~1.31 GiB** |
| Model weights | Not shipped; downloaded by consent | 28 MB – 4.6 GB |

Download sizes from the catalog: FLUX.2 klein 4B q4 — 4.6 GB; SAM 2.1 tiny — 148.8 MB (156,008,466 bytes, measured 2026-11-18); Swin2SR x4 — 48.5 MB; MI-GAN — 28.1 MB. The app works with any subset; a missing model produces a clear “open Manage Models” message instead of a failed job.

The worker is the framework interpreter copied from Homebrew Python 3.13.15, with the Homebrew dylibs it needs (`libssl`, `libcrypto`, `liblzma`, `libmpdec`, `libsqlite3`) relocated into `Worker/lib` and every Mach-O reference rewritten to `@loader_path`. No Homebrew installation is required on the target Mac, and no Mach-O load command in the bundle refers to `/opt/homebrew`. A handful of unused framework scripts (`pip3`, `pydoc3`, `idle3`) and pkg-config files still carry Homebrew shebangs or build paths; the helper never runs them — it is started through the bundled `Python.framework` interpreter.

---

## 2. Install

1. Copy `Retouch Studio.app` to `/Applications` (or anywhere writable).
2. Launch it. On a Mac other than the build machine, macOS may quarantine the ad-hoc signature; if the first launch is refused, right-click the app → **Open**, or clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Retouch Studio.app"
   ```

3. Open **Settings (⌘,) → Manage Models…**. In the current build there is no runtime download card: the protocol-v2 installer is disabled until an official package is configured. A build that carries the helper inside the app can download models, each after its own sheet shows the file count, total size and license. Once an approved runtime package exists, its sheet will show the archive name, its size and a 16-character SHA256 prefix before anything is fetched; the full hash is verified after download.
4. When the downloads finish, the app is fully usable offline.

There are no launch agents, no background daemons and no login items. The helper starts with the app and stops when the app quits normally; a bundled helper lives inside the app bundle, while an enabled protocol-v2 runtime would run from its installed tree. After a crash it is left running (or replaced) by the next launch, as described in [`PHASE5_ACCEPTANCE.md`](PHASE5_ACCEPTANCE.md) §3.

### Signature status

The app is signed **ad-hoc** (`codesign --verify --deep --strict` passes; `spctl -a` rejects it, because Gatekeeper only accepts Developer ID signatures). It is not notarized: notarization requires an Apple Developer ID certificate that this project does not have. Consequences:

- The app runs normally on the Mac that built it and on Macs where the owner approves the first launch.
- It cannot be distributed publicly as a “download and double-click” build until it is signed with a Developer ID and notarized.
- The bundle seal is real and is verified after launch, after an edit job and after a download — the helper never writes into the sealed bundle (`PYTHONDONTWRITEBYTECODE=1`).

---

## 3. Offline behaviour

After the models are installed:

- opening a photo, all twelve retouch tools, Auto Retouch, masking, AI edits, 4× upscaling and export are local;
- the helper communicates with the app over a Unix socket: `~/Library/Application Support/RetouchStudio/AI/worker.sock` for a bundled or source-checkout helper, and `.../AI/runtimes/worker.sock` once a protocol-v2 runtime is adopted;
- the app's network API is the runtime downloader (`AIRuntimeInstaller`), which is disabled in the current build and will fetch one approved archive after consent and check its SHA256 when enabled; the helper's only networking is the model downloader (`Downloads` is a separate command that requires consent).

This was measured, not assumed: see [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md) §3 — zero TCP/UDP endpoints while idle and during a real upscale job, and exactly two HTTPS connections during an approved download.

If a model file with a catalog SHA256 is damaged, `Manage Models… → Verify` reports the mismatched file and the model can be downloaded again. SAM 2.1 tiny's checkpoint gained its recorded size and SHA256 on 2026-11-18, so Verify now compares that file too; what its entry still refuses is the download, because the `sam2` runtime package is not part of the bundled worker. Launch never re-downloads anything on its own.

---

## 4. Where data lives

Paths depend on which helper is running.

**Bundled or source-checkout helper:**

| Path | Contents |
|---|---|
| `~/Library/Application Support/RetouchStudio/AI/models/` | Installed model weights |
| `~/Library/Application Support/RetouchStudio/AI/jobs/` | Helper working copies and job outputs (cleaned up over time) |
| `~/Library/Application Support/RetouchStudio/AI/worker.log` | Helper stdout/stderr |
| `~/Library/Application Support/RetouchStudio/AI/worker.sock` | Local JSON-RPC socket |
| `~/Library/Application Support/RetouchStudio/AI/helper-owner.json` | Which app instance owns the running helper |
| `~/Library/Application Support/RetouchStudio/AI/download-consent.json` | The approved manifest and its timestamp |

Both rows above say "Helper working copies and job outputs (cleaned up over
time)". Measured against the code on 2026-11-18, that describes two different
places as if they were one, and overstates the cleanup:

- **Job outputs** do live here — one folder per job id, written by the helper.
- **Working copies** — the resized `photo.png`/`source.png` the host hands the
  helper — live in `$TMPDIR/RetouchStudioAI/<job-uuid>/` instead
  (`AIWorker.workingDirectory`), which is passed to the helper only as an
  allowed read root. The host deletes a job's folder when the job returns, and
  `AIWorker.ensureRunning()` sweeps copies older than 24 h from that root after
  either launch path starts a helper (`AI_11_ARCHITECTURE.md` §16).
- "cleaned up over time" is true of the *current session only* for these two
  `jobs/` folders. The helper prunes them with an in-process ledger that keeps
  the last `keep_jobs` (20) entries and forgets the rest at exit
  (`worker/retouch_ai_worker/server.py:88, 256-262`), so folders from earlier
  sessions stay until the owner sets a disk retention rule — recorded as an open
  decision, not implemented, because a completed result the user never adopted
  is user-visible work. What startup does clear is provenance debris: it walks
  every job folder and removes a `*.provenance.json` whose artifact never
  arrived plus any half-written sidecar temp, skipping anything written at or
  after the sweep's own timestamp so a worker sharing the jobs root cannot take
  a live publication's evidence (`server.py:84-86`, `provenance.py:226-268`).
  Those are the only names it can match. The upscale path wrote the first of
  them; since 2026-11-18 every job the host names a capability for writes a pair
  too (`Docs/AI_EDIT_PROVENANCE_DECISION.md` §8), so the sweep now guards edit
  folders as well. The staged artifact of a publication — `<name>.png.tmp` — is
  not one of the names it matches: the publishing call removes it on every exit
  path it controls, so the residue a `SIGKILL` mid-write leaves is the same
  per-job clutter the retention decision above already covers, not new evidence
  with nothing to clear it.

**Addendum, 2026-11-18: the jobs-root retention rule is implemented.** The
paragraph above is kept as the measurement it was written from; what follows is
what runs now, and it is the answer to the decision that paragraph left open.

- **The job says what it owns.** `JobManager._run` takes an exclusive `flock` on
  `<workdir>/.lock` before it builds the job's context and closes it after
  `job.finished` has been emitted (`server.py`, `JOB_LOCK_NAME`,
  `acquire_folder_lock`). The kernel drops it if the helper dies, so a crash
  cannot leave a guard outliving the render it protected. The claim is what lets
  a job run longer than the age bound below without being cleaned under itself —
  the case an age-only sweep gets wrong.
- **The host clears what an earlier helper left.** `AppDelegate.attach` calls
  `AIWorker.cleanupJobsAtStartup()`, which sweeps *both* jobs roots —
  `AI/jobs/` and `AI/runtimes/protocol-v2/jobs/` — on a utility queue at launch,
  whether or not a helper ever starts (`AIWorker.cleanStaleJobFolders`). A folder
  is removed only when all three hold: its name is the helper's job-id spelling
  (twelve lowercase hex characters), its date is at least 24 h old, and this
  process can take its `.lock`. Anything else is kept and logged with the reason:
  an unreadable date, a name that is not a job id, a folder a live job holds, a
  removal that failed. The jobs root itself is never a candidate.
- **Why an unreadable date keeps a folder here.** The working-copy sweep in
  `AIWorker.ensureRunning()` treats a copy it cannot date as ancient, which is
  safe because those copies are duplicated in the project. These folders are not
  duplicated anywhere, so this sweep takes the other branch: no date, no
  deletion.
- **Nothing persisted points into these folders, so nothing breaks when they
  go.** An adopted Quick Edit or removal is a copy under `AI/edits` with its own
  sidecar, taken synchronously during adoption (`QuickEdit.swift`), and the
  export-time upscale artifact is verified and decoded inside the export that
  produced it. `EditorModel.aiJobID` is cancel-only and is never serialized; the
  recovery records store no path into `AI/jobs/`. That is the fact that makes a
  launch sweep safe, and it is why the "user-visible work" worry in the
  paragraph above does not apply to a folder that is already 24 h old at launch:
  the document that referenced it is closed, and a reopened document loads from
  `AI/edits` or the exported file.
- **What is still not claimed.** `_trim`'s in-session window (`keep_jobs` = 20)
  is unchanged, so the current session still trims by ledger rather than by
  age; the sweep runs at launch only, not on a timer, so a session that stays
  open for days accumulates as before; and the export-time provenance record
  dies with its folder 24 h after it was written, which is fine for a host that
  verified it during the export and has no reason to read it again — a future
  feature that wants long-lived upscale provenance must publish it somewhere
  durable first.

**Protocol-v2 runtime (when a package is configured):**

| Path | Contents |
|---|---|
| `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2/` | The installed protocol-v2 runtime |
| `~/Library/Application Support/RetouchStudio/AI/runtimes/protocol-v2-backup/` | Previous runtime kept during installation or recovery |
| `~/Library/Application Support/RetouchStudio/AI/runtimes/` | Runtime registry, transaction record, lock files (`runtime.lock`, `runtime-usage.lock`) |
| `~/Library/Application Support/RetouchStudio/AI/runtimes/jobs/` | v2 helper working copies and job outputs (cleaned up over time) |
| `~/Library/Application Support/RetouchStudio/AI/runtimes/worker.log` | v2 helper stdout/stderr |
| `~/Library/Application Support/RetouchStudio/AI/runtimes/worker.sock` | v2 local JSON-RPC socket |
| `~/Library/Application Support/RetouchStudio/AI/models/` | Installed model weights (never inside the runtime tree) |
| `~/Library/Application Support/RetouchStudio/AI/helper-owner.json` | Which app instance owns the running helper |
| `~/Library/Application Support/RetouchStudio/AI/download-consent.json` | The approved manifest and its timestamp |

The legacy `AI/runtime/` (singular) tree is never read, moved or deleted by the current build; a 1.0.0 runtime archive is not installed there. `AI/jobs/` is not legacy: it is the working directory of a bundled or source-checkout helper and is used whenever that helper runs.

Projects and originals are never modified in place; exports are written where the owner chooses. Private test photos are never read by the helper unless the owner sends that photo to it as part of an edit.

---

## 5. Uninstall

1. Quit the app (the helper stops with it).
2. Delete the app bundle.
3. Delete the data folder:

   ```bash
   rm -rf "$HOME/Library/Application Support/RetouchStudio"
   ```

   This removes the downloaded runtime, models, job working copies, the consent record, the owner record and logs. Nothing else is installed — no preference panes, no launch agents, no system extensions.

To keep the models but remove everything else, delete everything in that folder except `AI/models`.

---

## 6. Dependencies and licenses

### 6.1 Interpreter and system libraries

| Component | Version | License |
|---|---|---|
| Python | 3.13.15 (Homebrew framework) | PSF-2.0 |
| OpenSSL (`libssl.3`, `libcrypto.3`) | 3.5.x | Apache-2.0 |
| liblzma (`liblzma.5`) | 5.8.x (xz) | 0BSD (the xz CLI is GPL-2.0-or-later and is not shipped) |
| libmpdec (`libmpdec.4`) | 4.0.1 | BSD-2-Clause |
| SQLite (`libsqlite3`) | 3.54.x | Public domain |
| Vazirmatn typeface | bundled | SIL Open Font License 1.1 (`Resources/Fonts/OFL.txt`) |

The corresponding license texts ship inside each wheel's `.dist-info` directory where the package includes one.

### 6.2 Python wheels

67 packages are pinned by `worker/requirements.lock`, and every one of them is
bundled. The count is the number of distinct names in that file, counted
2026-11-21, after the `opencv-python` pin left the lock; the table gives the
principal ones:

| Package | Version | License |
|---|---|---|
| torch, torchvision | 2.15.0 / 0.29.2 | Apache-2.0 (plus BSD components) |
| transformers | 5.22.1 | Apache-2.0 |
| onnxruntime | 1.31.1 | MIT |
| numpy | 2.5.4 | BSD-3-Clause (bundle of permissive licenses) |
| pillow | 13.0.0 | MIT-CMU |
| mlx, mlx-metal | 0.32.4 | MIT |
| mflux | 0.24.0 | MIT |
| huggingface-hub | 1.33.0 | Apache-2.0 |
| tokenizers | 0.23.3 | Apache-2.0 |
| safetensors | 0.8.0 | Apache-2.0 |
| matplotlib, fsspec, protobuf | 3.11.2 / 2026.9.0 / 7.36.2 | PSF-style / BSD-3-Clause / BSD-3-Clause |

The complete pinned list is `worker/requirements.lock`.

**Two rows this table used to carry are not in that lock.** `SAM-2`
(`facebookresearch/sam2` @ `2b90b9f`, a git checkout) and
`simple-lama-inpainting` 0.1.0 were both listed here as bundled. Neither name
appears in `worker/requirements.lock`, so neither is fetched by
`Tools/setup-worker-venv.sh`, and neither exists in the venvs this machine builds
with. `build/Worker.cache` still holds the 2026-11-08 bundle, where they sit
beside the then-68 locked packages (`pip` and `psutil` on top of them — 72
`.dist-info` directories). The lock has 67 names today; the 68 is the count as
measured on that 2026-11-08 bundle and is not a contradiction of §6.2. LaMa is not wanted back: its weights carry no licence and the model
was removed from the catalog entirely (`worker/README.md` invariant 3), so the
row described a package nothing loads. SAM-2's own metadata says Apache 2.0, so
the obstacle there is a reproducible pin rather than the licence. What follows
from SAM-2's absence is stated where it is enforced: `mask.click` is `blocked`
because a lock-reproducible worker has no package that can read the SAM 2.1
checkpoint (`W5_ADAPTERS.md` §States).

### 6.3 Models

| Model | Role | License | Commercial use |
|---|---|---|---|
| FLUX.2 klein 4B (q4) | Generative edits | Apache-2.0 | Yes |
| SAM 2.1 tiny | Segmentation | Apache-2.0 | Yes |
| Swin2SR x4 | Upscaling | Apache-2.0 | Yes |
| MI-GAN (512, Places2) | Small-hole inpainting | MIT (weights) | Yes |

Weights are downloaded, never redistributed inside the app. Each download is verified against the SHA256 in the catalog when the manifest provides one. Inspected on 2026-11-10, the worker catalog (`retouch_ai_worker/catalog.py` in the separate checkout) gives SAM 2.1 tiny neither a size nor a SHA256: that download cannot be checksum-verified and its progress is indeterminate. That checkout is not under version control here, so this describes it as inspected, not a property of the app bundle.

Corrected 2026-11-18: both halves of that sentence are now out of date, and the paragraph is kept as the inspection it was. The worker source lives in this repository under `worker/`, and SAM 2.1 tiny's checkpoint carries a measured size (156,008,466 bytes) and SHA256 (`7402e0d8…be69`, from the installed file, matching the pinned URL's stream and HuggingFace's LFS object id). Downloading that entry is still refused, now for the reason that actually applies: `sam2` is in neither `worker/requirements.lock` nor the `models` extra of `worker/pyproject.toml`, so a machine that fetched the weights would have nothing that could load them. See [`W5_MODEL_MANAGER.md`](W5_MODEL_MANAGER.md) §2 for the manifest-digest rule that also gives the entry its own digest.

---

## 7. Building from source

Prerequisites: macOS 14 or later with Xcode Command Line Tools. The local AI helper is optional; its source is tracked at `worker/` in this repository, and its Python 3.13 environment is created by `Tools/setup-worker-venv.sh` at `worker/.venv`.

```bash
./build.sh release            # compiles, bundles the helper when it is reachable, runs the engine self-test, signs ad-hoc
RETOUCH_SKIP_WORKER=1 ./build.sh release   # app only; the AI tools report the helper as missing
RETOUCH_REBUNDLE=1 ./build.sh release      # force a fresh copy of the Python runtime
./Tests/run.sh                # Engine, Model, RuntimeProcess and RuntimeV2 suites
./Tests/run-worker.sh         # the worker suite (its count is pinned, see the note below)
```

`Tests/run.sh` compiles every Swift file under `Sources/RetouchStudio` except `App.swift` and `SelfCheck.swift`, then runs four suites: Engine, Model, RuntimeProcess and RuntimeV2. `RETOUCH_ARCH=x86_64 ./Tests/run.sh` runs the same suites against an x86_64 build (Rosetta on Apple silicon).

`Tests/run-worker.sh` discovers `worker/tests` with `unittest`, using
`worker/.venv/bin/python3` unless `RETOUCH_WORKER_PYTHON` names another
interpreter that can import the pinned wheels. Its test count is pinned in
four places — `.github/workflows/ci.yml`, the header comment of
`Tests/run-worker.sh`, `worker/README.md` and `Docs/W5_ADAPTERS.md` (plus the
`Docs/worker-regressions/README.md` copy) — so a new test moves them together.

Corrected 2026-11-18: this section used to say the helper "lives in a separate
worker checkout" and to print `cd "$RETOUCH_WORKER_ROOT" && ../.venv/bin/python
-m unittest discover -s tests` for 60 tests. Neither described a clone of this
repository: `worker/` is tracked, the runner is `Tests/run-worker.sh`, and the
discover path it used is what that script does internally. The superseded note
at the end of this section records the same correction for the build side.
`Docs/worker-regressions/` is still kept, but as the historical P0-06 artifact
its README describes, not as the place a test has to be copied to survive a
clone.

Overrides used by the bundler:

- `RETOUCH_WORKER_ROOT` — worker source directory; defaults to `./worker` when present
- `RETOUCH_WORKER_VENV` — Python environment with the wheels; defaults to `./.venv` when present
- `RETOUCH_SKIP_WORKER=1` — build the app without the helper runtime
- `RETOUCH_REBUNDLE=1` — ignore the runtime stamp and copy the interpreter again

`Tools/bundle-worker.sh` keeps a stamp of the Python version, the worker source hash and the wheel list in `Worker/.stamp`; an unchanged runtime is reused across builds. It refuses to finish if any Mach-O still refers to `/opt/homebrew`, if a symlink in the runtime is broken, or if a required signature step fails.

> **The worker source is a separate checkout.** It is not part of this repository. Point `RETOUCH_WORKER_ROOT` and `RETOUCH_WORKER_VENV` at it to bundle the helper. Without them the app still builds and runs; the AI tools simply report that the helper is not installed. Moving `worker/` and `requirements.lock` into this repository would make the build self-contained; it is listed as a follow-up.

> **Superseded 2026-11-18.** `worker/` *is* in this repository: 31 tracked paths
> including the hashed `worker/requirements.lock`, and
> `Tools/bundle-worker.sh:16` already defaults `WORKER_ROOT` to `$REPO_ROOT/worker`
> — `RETOUCH_WORKER_ROOT` and `RETOUCH_WORKER_VENV` are now overrides for a custom
> interpreter, not requirements. A plain clone bundles with no environment set, and
> CI does exactly that. See `AI_11_ARCHITECTURE.md` §17.
