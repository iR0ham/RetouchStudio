# W5-4 Upscaler — acceptance readiness and runtime approval request

Status: **harness ready, not executed.** No download, no installation, no
model adoption and no inference has been performed for this work. The
harness below is committed and validated against a protocol-level fake
engine; every number in this document is either measured on this machine
(dated) or is an explicit estimate labelled as such.

This document is a decision ledger. Facts are added with dates; nothing
already recorded is rewritten.

---

## 1. What exists already (measured, no action needed)

**Runtime** — `~/Library/Application Support/RetouchStudio/AI/runtime`
(1.3 GB, probed read-only on 2026-11-17):

| Component   | Pinned (worker/requirements.lock) | Installed (probed)  |
|-------------|-----------------------------------|---------------------|
| CPython     | 3.13                              | 3.13.15             |
| torch       | 2.15.0                            | 2.15.0              |
| transformers| 5.22.1                            | 5.22.1              |
| mlx / metal | 0.32.4 / 0.32.4                   | installed           |
| numpy       | 2.5.4                             | installed           |

MPS is available: `torch.backends.mps.is_available()` returned True on this
Mac (MacBook Air M3, 16 GB, macOS 27.2). Nothing about the runtime needs to
change for the acceptance run.

**Model** — `swin2sr-x4` ("Swin2SR x4 (real-world)"), 12.05 M parameters,
Apache-2.0 (commercial use permitted), macOS arm64 only in this catalog.
Source: `https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr`
(release: the three files below, no other network host is contacted).

| File                     | Bytes      | SHA-256                                                              |
|--------------------------|-----------:|----------------------------------------------------------------------|
| config.json              | 772        | `1e986fb6d0b6de32bae01a6ccd756e5d8ae1525dcb52f7ee5b2dc7f6132d6365`   |
| preprocessor_config.json | 152        | `cbc36266fcc93d5bc1e9ca69bcc648ae9d268918ad14cd3507216740f129cc4d`   |
| pytorch_model.bin        | 48,460,141 | `4a5f52a20932085557ed115f87c0ee8385e12f2719108c0dfd38c64aedea4710`   |

Total: 48,461,065 bytes (~48.5 MB).

**A legacy flat install of this model is already on this Mac** (~46 MB under
the AI model directory, verified by size and SHA-256 when the capability
adapter was written). It is not adopted: `capability.list` reports
`upscale.4x` as `blocked` for the legacy layout, and naming the capability
(W5-4 Slice 2) makes the 4× export refuse until the model is adopted. This
refusal is the designed behaviour, not a defect.

## 2. The acceptance harness (committed, `worker/tools/upscale_acceptance.py`, f288994)

Speaks only to the listening worker over its Unix socket, on the same path
the host uses. Judges the five gates the decision record freezes and records
everything else as measurement without inventing thresholds:

| Gate          | Frozen criterion (W5-0 §3.6/§4.3)                                        |
|---------------|--------------------------------------------------------------------------|
| dimensions    | the output is exactly 4× the input                                       |
| provenance    | the adopted artifact's sidecar names its own bytes, capability and model |
| cleanup       | a succeeded job's folder holds only the published pair                   |
| cancelCleanup | a cancelled job's folder holds no artifact and no temp at all            |
| provider      | the device the result names is the one `provider.list` reports           |

Recorded, never judged (no frozen threshold exists): bit depth, ICC profile,
alpha, EXIF orientation, wall and job seconds, tile count and mean per-tile
milliseconds, peak worker RSS (only if psutil is present; the pinned runtime
does not ship it), swap, cancel latency, output SHA-256, PSNR against an
owner-supplied `--reference`. Quality against the approved corpus is **not**
run by this tool: the corpus and its tolerance are an owner decision recorded
below before the run.

Validated on 2026-11-17 against a protocol-level fake server: all five gates
judged pass, the cancel path measured (latency 17 ms, error −32014), and the
refusal path exits 2 with `not-runnable` when the worker will not run the
capability — a blocked install can never be reported as a pass.

## 3. What the run needs from the owner (the approval request)

One decision and, depending on it, one network action.

**Decision A — how the model becomes adopted (pick one):**

- **A1. Adopt the existing legacy install** (recommended: no download, no
  network). Open Model Manager in the running app and adopt the offered
  `Swin2SR x4` install. This moves nothing and downloads nothing; it records
  the existing bytes into the versioned store identity. Local files affected:
  writes under `~/Library/Application Support/RetouchStudio/AI/models/`
  (adoption marker / versioned links); no other file is touched.
- **A2. Fresh versioned download** (~48.5 MB from `huggingface.co`, exactly
  the three files in the table above, digest-checked before adoption; disk
  cost ~49 MB in `AI/models/swin2sr-x4/1.0.0/`). Run through Model Manager's
  download flow or `AI/models` CLI — the same digest gate applies either way.

**The run itself (after A):** start the app so the worker is listening, then

```
~/Library/Application\ Support/RetouchStudio/AI/runtime/.../python3 \
    worker/tools/upscale_acceptance.py \
    --socket "$HOME/Library/Application Support/RetouchStudio/AI/worker.sock" \
    --image <one 24-bit input PNG, ideally also a 16-bit one> \
    --jobs-root "$HOME/Library/Application Support/RetouchStudio/AI/jobs" \
    --cancel-after 2.0 \
    --out out/w54-acceptance.json
```

**What this authorizes:** exactly the two upscale jobs the harness submits
(one full run, one cancelled) — i.e. real inference on the real model. It
authorizes nothing else: no further jobs, no batch corpus run, no Windows
work.

**Resources the run uses (estimates, NOT VERIFIED until measured):** disk:
one job folder with the 16×-pixel output PNG plus its sidecar (a 640×960
input yields a 2560×3840 output, ~10–20 MB); memory: the worker's default
budget is 7.5 GB (`RETOUCH_AI_MEMORY_BUDGET_GB`); the upscale path's own
working set for the largest permitted input (2.5 MP → 40 MP output) is
dominated by the float32 accumulator pair (~0.6 GB) plus torch/MPS overhead —
this is an estimate from the engine constants, not a measurement. Runtime:
the catalog notes 6.2 s per 256² tile on MPS (measured earlier on this Mac);
tile counts are recorded by the harness. Network: none during the run (A1)
or only the download in step A2.

**Local files affected by the run:** `AI/jobs/<job-id>/` grows (two folders;
the store prunes the oldest beyond its retention); `AI/worker.log` grows;
`out/w54-acceptance.json` is written in the repository checkout. Recovery,
edits, and the model bytes themselves are untouched.

## 4. Decisions the record requires that are still open (proposals, not made)

- **Quality corpus and tolerance.** §4.3 fixes the method (owner-approved
  corpus, tolerance recorded before the run) but the corpus and tolerance do
  not exist yet. Proposal: the owner picks 3–5 representative photos from the
  private fixture set and a PSNR floor; the harness already accepts
  `--reference` per run and records PSNR without judging it, so the floor can
  be applied outside the tool once chosen. Nothing runs against a corpus
  until this is decided.
- **Where a stored edit's provenance sidecar persists** (the decision record
  explicitly leaves this open in §11). Adoption currently verifies the
  sidecar inside the job workdir; whether it is copied next to a stored edit
  is a product decision with a privacy side and is not made here.

## 5. What this document does not claim

- No Windows statement: the upscaler stays blocked on Windows (decision 6 of
  the W5 record); nothing in the harness touches it.
- No inference result: nothing in §1–§4 was produced by running the model.
- The runtime's MPS probe is a probe, not a benchmark; per-job seconds on
  this hardware come from the harness run once it is approved.

---

## 6. Windows finding (2026-11-17, read-only research; Windows stays BLOCKED)

Sources were reviewed for whether an existing ONNX path could serve a
Windows upscaler. Findings, with nothing adopted and no catalog change:

- Auto-converted community ONNX versions of the same upstream model exist:
  [onnx-community/swin2SR-realworld-sr-x4-64-bsrgan-psnr-ONNX](https://huggingface.co/onnx-community/swin2SR-realworld-sr-x4-64-bsrgan-psnr-ONNX)
  and its predecessor
  [Xenova/swin2SR-realworld-sr-x4-64-bsrgan-psnr](https://huggingface.co/Xenova/swin2SR-realworld-sr-x4-64-bsrgan-psnr),
  produced by automatic conversion for Transformers.js and published in
  multiple quantizations (including `model_q4f16.onnx`).
- Why none of them is adopted here: the frozen catalog carries the exact
  source bytes and digests of the *original* three files; a converted
  artifact is different bytes with provenance this repository cannot verify
  (the conversion script, its date and its quality are community claims, NOT
  VERIFIED), and decision 6 of the W5 record keeps Windows AI work out of
  scope until it is explicitly reopened. Converting a model locally is the
  same refusal for the same reason.
- Performance on Windows CPUs is unmeasured: the general ONNX Runtime
  documentation discusses tiled high-resolution inference and CPU tuning
  ([performance troubleshooting](https://onnxruntime.ai/docs/performance/tune-performance/troubleshooting.html),
  [device tensors](https://onnxruntime.ai/docs/performance/device-tensor.html))
  but no published benchmark of *this* model on *this* use exists, so no
  Windows CPU perf claim is made or repeatable.
- Consequence: `upscale.4x` remains `blocked` on Windows in the capability
  adapter; Windows keeps no upscaler path; nothing in this repository
  downloads, converts or approves an ONNX artifact.

---

## 7. Decision A1 executed (2026-11-18): sandbox adoption, real inference, corpus PSNR

Decision A1 (owner-approved: adopt the installed `swin2sr-x4` and measure the
corpus against a 24.0 dB per-image minimum) was executed on this Mac. Every
number below was measured today on the MacBook Air M3 (16 GB, macOS 27.2);
nothing here is an estimate. The measured outcome fails one of the two
conditions A1 fixed, and that is recorded as measured, not softened.

### 7.1 Runtime (probed, not changed)

`AI/runtime/bin/python3` — CPython 3.13.15; `torch` 2.15.0, `transformers`
5.22.1, `numpy` 2.5.4, `Pillow` 13.0.0; `torch.backends.mps.is_available()`
True. The `sam2` package is importable in this interpreter. Nothing was
upgraded, installed or downloaded.

### 7.2 Sandbox adoption through the real UI

The three flat files (772 / 152 / 48,460,141 bytes, the SHA-256 values in §1)
were copied to a scratch model root and the app was launched against it with
`RETOUCH_AI_MODELS=<scratch>/models`. Model Manager → **Adopt…** → confirm
performed the adoption; the confirmation dialog states it hashes the bytes,
moves them, and uses no network.

Result (verified on disk):

```
<scratch>/models/swin2sr-x4/1.0.0/{config.json, preprocessor_config.json,
                                   pytorch_model.bin, manifest.json}
<scratch>/models/swin2sr-x4/active.json      version 1.0.0, manifest e0da6778…
<scratch>/models/.locks/{install, swin2sr-x4@legacy, swin2sr-x4-1.0.0}   (empty)
```

The adopted `pytorch_model.bin` still hashes to
`4a5f52a20932085557ed115f87c0ee8385e12f2719108c0dfd38c64aedea4710`. While
the confirm button was pressed the app held no IPv4/IPv6 socket (sampled every
0.5 s), so adoption made no network call. The production model directory was
not touched: right after the run its three files still hashed to the values in
§1.

The app sweeps job folders at launch (older than 24 h and unlocked);
launching it for this test removed the stale render folders that had been
sitting in the production jobs root since 2026-11-08. Those folders are render
residue the host never reads (`AIWorker.cleanStaleJobFolders`); no edit,
project or original was involved.

### 7.3 `capability.list`, before and after, same worker code

| capability | before adoption | after adoption |
|---|---|---|
| `upscale.4x` | `blocked` — “swin2sr-x4 is installed without a version; adopt it in the model manager before a capability can bind it” | `supported`, `modelVersion` `1.0.0`, evidence `Docs/PHASE5_ACCEPTANCE.md §4 …`, no reason |
| every other id | unchanged | unchanged |

`mask.click` stayed `requires_model` in the scratch root, because that root
holds no `sam2.1-hiera-tiny`; the package itself imports (7.1). The whole list
was compared id by id, not spot-checked.

### 7.4 Real inference (worker CLI, `worker/tools/upscale_acceptance.py`)

One genuine job and one cancellation against a generated 640×480 probe image
(not an owner photo):

- output 2560×1920, exactly 4×; 6 tiles of 256 with 16 overlap; `mps`;
  26.1 s job, 36.05 s wall
- provenance sidecar: `upscale.4x`, `swin2sr-x4` **1.0.0**, artifact SHA-256
  matches its own bytes
- gates: dimensions, provenance, cleanup, provider, cancelCleanup — all
  `pass`
- cancellation requested 2.0 s in: status `cancelled` after 2899 ms, error
  `-32014`, job folder left with only its `.lock`

Evidence tier for the capability at this point: **real inference on this
hardware** (not “production ready”; see 7.7).

### 7.5 The corpus and its numbers

`worker/tools/upscale_corpus.py` (new, a tool — not under `worker/tests`, so
the discovered worker test count stays 140). Protocol, as A1 fixed it: convert
to sRGB from the embedded ICC profile first, crop to a multiple of 4, plain
antialiased bicubic downscale ×4 → `D`, run the real 4× capability on `D`, then
PSNR on 8-bit gamma-encoded sRGB code values, RGB, RMS over all channels; the
bicubic control is `D` upscaled ×4 with the same resampler. Seam bands are
±32 px around every multiple of 960 output px (tile step 256 − 16 = 240) and
are diagnostic only. Derived pixels stayed in a temporary directory and were
deleted; no fixture or derived image is in the repository.

Corpus: 8 fixtures from the owner’s private portrait set — 6 at 2268×4032 and
2 at 3213×5712 cropped to 3212×5712; all 8-bit JPEG with a Display P3 profile,
orientation 1; C4 is the low-saturation frame. 138 tiles in total.

| image | reference px | tiles | job s | PSNR dB | seam band dB | bicubic control dB | vs control |
|---|---:|---:|---:|---:|---:|---:|---:|
| C1 | 2268×4032  | 15 | 146.03 | 33.31 | 31.81 | 34.58 | −1.27 |
| C2 | 2268×4032  | 15 | 133.12 | 34.59 | 33.62 | 35.18 | −0.59 |
| C3 | 2268×4032  | 15 | 139.62 | 34.92 | 34.82 | 34.90 | +0.02 |
| C4 | 2268×4032  | 15 | 144.01 | 34.10 | 32.25 | 34.25 | −0.15 |
| C5 | 2268×4032  | 15 | 143.76 | 32.42 | 32.76 | 32.80 | −0.38 |
| C6 | 2268×4032  | 15 | 155.96 | 35.52 | 35.09 | 35.90 | −0.38 |
| C7 | 3212×5712  | 24 | 266.85 | 34.74 | 33.06 | 33.36 | +1.38 |
| C8 | 3212×5712  | 24 | 247.06 | 33.44 | 33.52 | 32.23 | +1.21 |

Aggregate: minimum **32.42 dB**, mean 34.13 dB, median 34.59 dB; every output
was exactly the reference size; every sidecar named model version 1.0.0; every
tile ran on `mps`, at roughly 4–11 s per tile.

### 7.6 Verdict against A1, and what it means

A1 fixed two conditions. Both are reported, separately, because they did not
agree:

- **Per-image minimum ≥ 24.0 dB — PASS.** The lowest image is 32.42 dB, and no
  image is near the bar.
- **The model must beat a bicubic-×4 control on the same pairs — FAIL.** It
  does not on C1, C2, C4, C5 and C6 (by 0.15–1.27 dB); it does on C3, C7 and
  C8 (by 0.02–1.38 dB). The combined verdict of the harness is therefore
  `fail`, and the 24.0 dB bar was not lowered to change that.

What the numbers show: the degradation A1 fixed is *bicubic* downscaling, and
the control is bicubic upscaling — the control is close to the inverse of the
degradation, so it recovers these pairs very well. The model is being asked to
beat a matched inverse, not a camera or JPEG degradation. That is a property
of the measurement design, not a defect in the model or the harness: the same
runs put the model at 32–35 dB absolute, with no seam degradation (seam bands
sit in the same range as the whole frame, sometimes higher). Whether a
realistic capture degradation should be the comparison, or whether the control
condition should be dropped, is an owner decision and is **not** made here. No
threshold in this document, in the harness or in the capability adapter was
changed.

### 7.7 What this run did not do

- **Production adoption: not performed.** The follow-on step ran only if every
  earlier step was green; the control condition in 7.6 is not green, so the
  production store was left exactly as it was (flat legacy install, capability
  `blocked`). Any later adoption still needs the owner’s word.
- **Product-path GUI export with upscaling: not exercised** (same precondition).
  The installed bundle used for the adoption test carries no worker runtime,
  so whether `adoptRunningHelper`/`waitForHelper` accept a hand-started helper
  through `RETOUCH_AI_SOCKET` is still unverified. The evidence tier for the
  feature stays at “real inference on this hardware”; it is not “production
  ready”.
- **CI cannot reproduce these numbers.** No GitHub runner has this model store
  or MPS; CI proves the harness’s logic only. No fixture is committed, so CI
  never sees owner pixels.
- 2× upscaling and any Windows ONNX artifact remain out of A1 scope and are
  untouched; nothing was downloaded, installed or converted.

---

## 8. Phase 2 (2026-11-18): replacement adversarial gate measured — FAIL; production adoption withheld

Status of this section: every number below was measured on this Mac on
2026-11-18. The replacement gate was fixed by the project manager; this
section records that decision, the measurement and the consequences. Nothing
here rewrites §7; §7.5 stands as measured, and its 24.0 dB bar stands as
accepted.

### 8.1 The project manager's decisions (recorded, dated 2026-11-18)

- **24.0 dB per-image minimum: ACCEPTED as PASS** for the §7.5 corpus
  (minimum 32.42 dB, mean 34.13 dB, all 8 images clear the bar by at least
  8.4 dB).
- **Bicubic-control condition: WITHDRAWN as a gate, kept as a non-gating
  diagnostic.** On a corpus degraded by a bicubic downscale,
  `bicubic x4(bicubic /4(R))` is close to the inverse of the degradation, so
  the control is near-optimal by construction and does not discriminate a
  model. The project manager states the condition was their addition, not the
  owner's bar.
- **Replacement adversarial gate (fixed by the project manager,
  2026-11-18):** three fixtures — two at 2268×4032 and one at 3213×5712
  cropped to 3212×5712 — with the same sRGB-first, crop-to-multiple-of-4
  discipline; degrade at the reference resolution with JPEG quality 70
  (4:2:0), Gaussian noise sigma = 5 code values out of 255 and a Gaussian
  blur of radius 1.2, then downscale by 4 with bicubic; measure
  `PSNR(model output, true reference R)` on 8-bit gamma-encoded sRGB code
  values. Gate: **every image >= 24.0 dB AND the model beats the bicubic-x4
  control by at least +0.5 dB on that same image.** Deterministic seeds; the
  bar is not to be moved if it fails.

### 8.2 Harness change

`worker/tools/upscale_corpus.py` now accepts `--degradation realistic` (the
§8.1 protocol: JPEG, then noise, then blur at the reference resolution, then
the bicubic ×4 downscale), a base `--seed` (default 20261118; one
deterministic seed is derived per sample position) and `--control-margin`
(default 0.5 for `realistic`; the original strict "must beat" for
`bicubic`). R1, R2 and R3 are the same fixtures as C1, C2 and C7 in §7.5.
The tool stays outside `worker/tests`, so the discovered worker suite is
still 140 tests (`Ran 140 tests ... OK` after the change, before the commit).
It still records metadata and numbers only; the degraded input is written to
a temporary directory and deleted after each sample.

### 8.3 Measured replacement corpus (2026-11-18T19:47:41Z–19:53:23Z)

| image | reference px | tiles | job s* | PSNR dB | seam band dB | bicubic control dB | delta vs control | margin gate |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| R1 | 2268×4032 | 15 | 64.43 | 33.44 | 32.06 | 33.31 | +0.13 | **fail** |
| R2 | 2268×4032 | 15 | 96.73 | 34.67 | 33.77 | 34.00 | +0.67 | pass |
| R3 | 3212×5712 | 24 | 169.63 | 34.85 | 33.19 | 32.38 | +2.47 | pass |

`*` Job seconds are machine-load dependent: the run overlapped a parallel
Swift build (load average 5.6–7.9). PSNR is not timing-sensitive. Job ids:
R1 `96846e6a5a00`, R2 `7a49b11b00e7`, R3 `be7bdcf403d2`.

Aggregate: minimum **33.44 dB**, mean 34.32 dB, median 34.67 dB. Every output
was exactly the reference size; every sidecar named model version 1.0.0;
every tile ran on `mps` (15 tiles for the 2268×4032 frames, 24 for the
3212×5712 frame); every succeeded job folder held only its published pair
plus the claim file.

### 8.4 Verdict against the replacement gate

- **Per-image >= 24.0 dB — PASS.** The lowest image is 33.44 dB; all three
  are more than 9 dB above the bar.
- **Beat the bicubic-x4 control by >= +0.5 dB — FAIL on R1** (+0.13 dB).
  R2 clears it (+0.67 dB) and R3 clears it (+2.47 dB). The gate is applied
  per image, so one miss fails it: the harness verdict is `fail` (exit 1).
- **Reproducibility:** a confirmation rerun of R1 with the same seed, as a
  separate job (`f99b3beb577e`, 63.39 s), produced identical numbers —
  33.44 dB for the model, 33.31 dB for the control.
- **Consequence, as the project manager fixed it:** on this gate the quality
  claim is unproven. **Production adoption (step 7) was therefore not
  performed**: no adoption through Model Manager, no capability flip, no
  product-path export, no UI export-cancel and no adoption network check
  were attempted. The production store is exactly as it was — flat
  `swin2sr-x4/{config.json, preprocessor_config.json, pytorch_model.bin}`
  (772 / 152 / 48,460,141 bytes) hashing to `1e986fb6…`, `cbc3626…` and
  `4a5f52a2…`, with no `1.0.0` directory, no `active.json` and no `.locks`;
  `upscale.4x` remains `blocked` for it.

### 8.5 Why the margin is small on one frame (diagnostic, not a gate)

Measured on the same three frames and seeds, without inference:

| image | RMS(D_realistic − D_bicubic), code values | control PSNR, bicubic → realistic |
|---|---:|---|
| R1 | 1.973 | 34.58 → 33.31 (−1.27 dB) |
| R2 | 1.829 | 35.18 → 34.00 (−1.19 dB) |
| R3 | 1.951 | 33.36 → 32.38 (−0.98 dB) |

The injected noise and blur are applied at the reference resolution and are
then averaged by the ×4 downscale: the degraded input differs from the plain
bicubic one by RMS 1.83–1.97 code values (about 0.7 % of full scale). The
control loses about 1 dB but stays close to the inverse of the degradation,
so it remains a strong competitor; R3, where the control is weakest
(32.38 dB), is the frame where the model gains most (+2.47 dB). The plain
bicubic controls in this table reproduce §7.5 exactly (34.58 / 35.18 /
33.36), which is a cross-check that the sRGB, crop and control path did not
change. This is recorded as a property of the fixed protocol, not as a
proposal to change the bar: whether the degradation belongs after the
downscale, whether the control condition should be dropped, or whether a
different corpus should decide is an owner/project-manager decision and is
**not** made here.

### 8.6 Evidence tier and what this round did not do

- Evidence tier: **real inference on this hardware through the worker socket**
  on the approved `swin2sr-x4 1.0.0`. It is not production-path evidence and
  not production ready.
- **NOT VERIFIED:** production adoption through Model Manager; the
  post-adoption `capability.list` for the production store; the
  product-path `ExportService` export (including whether
  `adoptRunningHelper`/`waitForHelper` accept a hand-started helper through
  `RETOUCH_AI_SOCKET`); a 4× export through the export sheet at exactly 4×
  with provenance 1.0.0; a UI export-cancel; shipped-build evidence — the
  bundle used for these runs carries no `Contents/Resources/Worker` and
  `AIRuntime.package == nil`, so any export evidence would have been
  developer-machine evidence.
- **Not run by design:** any download, install, new model, conversion, 2×
  upscaling, Windows ONNX path, or production adoption. No fixture or derived
  pixel is in the repository; derived job folders under `/tmp/rs-a1/jobs`
  were deleted after measurement, and the export source prepared for the
  unexecuted product-path step was a temporary `/tmp` file, deleted with it.
- **Production side effects this round: none.** No app was launched against
  the production store, no production job was submitted, and the production
  `AI/jobs` root stayed empty. The restore point
  `/tmp/rs-a1-restore/swin2sr-x4-flat` is intact and still hashes to
  `1e986fb6…`, `cbc3626…`, `4a5f52a2…`; because the store never changed, no
  rollback was needed.
- `upscale.4x` is **not usable by a real user of the installed app today**:
  the production store is still the un-versioned legacy layout. Nothing in
  this round adopted it.

---

## 9. Harness review follow-up (2026-11-19): the bar alone decides, and corrections to §7.5–§7.6 and §8

Status of this section: append-only. Nothing above is rewritten. Where §7.5,
§7.6 or §8 state something the review of 2026-11-18 proved wrong or stale,
the correction is recorded here, dated; those sections stay as written for the
record. No inference was run for this section, and no number below is a new
measurement: every figure is either arithmetic over the §7.5/§8 tables or a
restatement of the review's finding.

### 9.1 What the harness now does differently

`worker/tools/upscale_corpus.py`:

- **The exit code keys on the A1 bar only.** `a1Bar` is `met`, `missed` or
  `not-measured`; exit 0, 1 or 2 respectively (3 is reserved for a harness
  bug). The bicubic-x4 control is always measured and is now recorded per
  image as `control: win|tie|lose` with `controlDeltaDb`, and in aggregate
  under `aggregate.controlOutcomes`; it is never an input to the exit code.
  Before this change one lost pair forced exit 1 even when every image met
  the bar, so a rerun of the §7.5 corpus could not report what the owner
  decided.
- **Exit codes are distinguished.** 0 measured and bar met; 1 bar missed;
  2 nothing measurable (capability not `supported`, model not verified,
  worker unreachable, unreadable fixture, an artifact whose provenance does
  not verify, or a job that produced no exact-size output from the approved
  model version); 3 the harness itself raised. Previously every exception and
  every incomplete measurement collapsed into the same "bar missed" exit.
- **`--degradation lr`** applies the §8.1 parameters in the order that keeps
  them: Gaussian blur radius 1.2 at the reference resolution, bicubic ×4
  downscale, then JPEG q=70 (4:2:0) and Gaussian noise σ = 5/255 at the
  degraded resolution. The parameters and a per-sample seed (base 20261118,
  position offset) are in the record; a rerun is deterministic. `bicubic`
  and `realistic` are unchanged, so §7.5 and §8 stay reproducible.
- **Seam bands follow the engine's tile rule.** `engine._axis_tiles`
  (`worker/retouch_ai_worker/engine.py:153-166`) uses starts
  `range(0, length - 256 + 1, 240)` and clamps the last start to
  `length - 256`; the boundaries are those starts after the first, ×4. A
  567×1008 input therefore has x boundaries **960, 1244** and y boundaries
  **960, 1920, 2880, 3008**; an 803×1428 input has x **960, 1920, 2188** and
  y **960, 1920, 2880, 3840, 4688**. (The earlier tool used multiples of 960
  only. The review's note listed the 567×1008 x boundaries as
  "960, 1920, 1244"; 1920 belongs to the 1008-pixel axis — the arithmetic
  above is the engine's.) The per-image record now carries `seamBoundaries`.
- **The median is `statistics.median`.** The earlier expression took the
  upper of the two middle values.
- **ICC conversion is `renderingIntent=1`** (relative colorimetric) and the
  record states it; the review observed it byte-identical to intent 0 on
  these Display P3 matrix profiles. `describe()` now also records bit depth,
  channel count, alpha and EXIF orientation, like the acceptance harness.

Because the pure logic (crop, PSNR, seam mask, degradation order, verdict and
exit mapping) had no test, `worker/tests/test_upscale_quality_corpus.py` now
covers it on synthetic pixels: 14 tests, no worker, no model, no fixture. The
discovered worker suite is **154 tests** (`Ran 154 tests ... OK`), and the five
pinned places are updated together (`Tests/run-worker.sh`,
`.github/workflows/ci.yml`, `worker/README.md`, `Docs/W5_ADAPTERS.md`,
`Docs/worker-regressions/README.md`).

### 9.2 Corrections to §7.5 and §7.6 (recorded values, no rerun)

- **The control also clears the bar.** On the eight §7.5 pairs the bicubic
  control scores minimum **32.23 dB**, mean **34.15 dB** (model: minimum
  32.42 dB, mean 34.13 dB). The 24.0 dB bar therefore does not discriminate
  a learned upscaler from a classical resize on a bicubic-degraded corpus.
  Clearing it is not evidence of quality value-add, and **quality value-add
  over the control is NOT PROVEN** by this corpus. Nothing in this section
  claims otherwise.
- **Attribution.** The 24.0 dB per-image minimum is the owner's Decision A1
  bar. The "must beat the bicubic ×4 control" condition was added by the
  harness/lead, not by the owner; the project manager withdrew it as a gate
  on 2026-11-18 and it has been a diagnostic since. §7.6's "A1 fixed two
  conditions" is corrected here.
- **"No seam degradation" is false as written.** The §7.5 seam column sits
  0.10–1.85 dB *below* the whole-frame PSNR on six of the eight images (C1,
  C2, C3, C4, C6, C7) and above it on two (C5 +0.34 dB, C8 +0.08 dB). Those
  bands were also computed with the 960-only boundary set, which misses the
  clamped last start, so the column is superseded for seam purposes. It was
  not recomputed here (no inference this round); the next measured run will
  produce the corrected bands.
- **The §7.5 "median" is the upper middle value.** The arithmetic median of
  the eight recorded values is 34.345 dB (34.34 dB at two decimals), not
  34.59 dB. §8's three-value median (34.67 dB) is unaffected.

### 9.3 Corrections and annotations to §8

- §8.3 and §8.4 stand as measured: R1 +0.13 dB against the +0.5 dB
  condition, harness exit 1 at that time. The condition is now recorded as a
  diagnostic; the §8 measurement and its consequence (no production
  adoption) are unchanged.
- **The §8 degradation order has a defect, now recorded.** §8.1 applies
  JPEG, noise and blur at the reference resolution and then downscales ×4;
  the downscale averages the injected noise, which §8.5 itself measured as
  an RMS difference of 1.83–1.97 code values against the plain bicubic
  input (about 0.7 % of full scale). Most of the intended adversarial
  content therefore never reaches the model. `--degradation lr` exists to
  apply it at the degraded resolution; it has not been run on the corpus.
- §8.5's closing question (where the degradation belongs) is answered for
  the tool by the `lr` mode; whether the corpus result changes is the next
  measurement's decision, not this section's.

### 9.4 The launch-time jobs sweep, stated plainly (owner-facing)

The review's socket inspection — no IPv4 socket observed during a sampled
run — is a sampling observation of one run, not a verified invariant; this
section does not upgrade it to one. What is verified in the code is the other
half: the app sweeps **both** AI jobs roots on every launch,
unconditionally, whether or not a helper is started
(`Sources/RetouchStudio/App.swift:29` → `AIWorker.cleanupJobsAtStartup`,
`Sources/RetouchStudio/Core/AIWorker.swift:1361-1366`). Folders that are
unlocked and older than the grace period are removed by that sweep. Nothing
in this PR changes it; it is recorded here so the owner can decide whether an
unconditional launch sweep is the intended behaviour for a local-first
editor.

### 9.5 Evidence tier for this section

Documentation and tool logic only: no inference, no corpus run, no model
store access, no adoption. The harness's new mode and boundary rule carry
synthetic-logic evidence (the 14 tests above); whether the model clears
24.0 dB on `lr` is **NOT MEASURED** and is the next round's question. The
production store and `upscale.4x` remain exactly as §8.4 left them.

---

## 10. Harness minors closed (2026-11-19): exit classification, record honesty, JSON safety

Status of this section: append-only; nothing above is rewritten except the
exit-2 parenthetical in §9.1, which this section dates. No inference was run
and no number below is a new measurement; the single arithmetic correction is
derived from §7.5's own table.

- **A provenance failure is "nothing measurable", not a harness bug.**
  `worker/tools/upscale_corpus.py` let `provenance.ProvenanceError` (a
  `RuntimeError`, raised in
  `worker/retouch_ai_worker/provenance.py:174/177/191/210`) escape the
  per-sample loop, where `main`'s blanket handler reported it as exit 3. It is
  now caught beside `BadInput`: the image is recorded as unmeasured, the
  remaining samples still run, and the run exits 2. §9.1's exit-2 list now
  names it.
- **An unreadable fixture no longer crashes the summary.** The per-image
  progress line read `row['controlBicubicPsnr']` unconditionally, so the first
  `BadInput` row — a file Pillow cannot open, a corrupt ICC profile — raised
  `KeyError` inside the loop and turned a clean "bad input" run into exit 3
  with no record. Every field on that line is now read defensively; a worker
  `OSError` still aborts the run as before.
- **The control note describes its own run.** `CONTROL_NOTE` asserted the
  2026-11-18 eight-pair statistics in every record, so a `bicubic` run on any
  other pair set wrote numbers beside a note that contradicted them. It is now
  `control_note(mode, control_stats, outcomes)`: the 2026-11-18 sentence is
  labelled "On the 2026-11-18 corpus" and the note appends this run's own
  control minimum/mean/median and win/tie/lose counts, or states that no image
  was measured.
- **The bar compares the unrounded measurement.** Each image's PSNR is stored
  and compared at full precision; rounding is display-only (`aggregate`,
  `controlDeltaDb`, the printed line). A 23.996 dB image is `missed` instead
  of being displayed as 24.0 and counted as met.
- **Records are standard JSON.** `psnr`/`seamPsnr` can be `inf` on an exact
  match, which `json.dumps` writes as bare `Infinity` — rejected by Swift's
  `JSONDecoder` and by `jq`. Non-finite numbers are written as `null` and the
  writer uses `allow_nan=False`, so a future non-finite field fails loudly
  instead of producing an unreadable record.
- **§7.5's "at roughly 4–11 s per tile" (`:284`) is arithmetic its own table
  does not support.** §7.5's `job s` divided by `tiles` gives 8.9–11.1 s per
  tile (C2: 133.12 / 15 = 8.9; C7: 266.85 / 24 = 11.1); no fixture is near
  4 s. The line is left as written under the append-only rule and superseded
  by this paragraph. It is a timing observation, not a quality number; no PSNR
  value depends on it.
- **Tests and pins.** `worker/tests/test_upscale_quality_corpus.py` gained 7
  tests (provenance failure → exit 2, unreadable fixture → exit 2, the
  unrounded bar at 23.996/24.004, `inf` meets the bar, `inf`/`NaN` written as
  `null`, and the note built from this run). The corpus module now has 21. The
  five pinned places moved to the new total together (`Tests/run-worker.sh`,
  `.github/workflows/ci.yml`, `worker/README.md`, `Docs/W5_ADAPTERS.md`,
  `Docs/worker-regressions/README.md`).
- **Evidence tier:** synthetic logic only — no worker, no model, no fixture,
  no inference. Nothing in this section measures upscaler quality.
