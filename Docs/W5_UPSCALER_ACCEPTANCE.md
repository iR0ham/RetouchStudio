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

**Addendum 2026-11-19 — the 7.5 GB figure above is an estimate, not a limit on
this path.** The paragraph names `RETOUCH_AI_MEMORY_BUDGET_GB` while sizing the
run; as shipped, that variable never refuses an upscale. It is read once
(`worker/retouch_ai_worker/engine.py:45`). The only comparative use that can
refuse a job is in `_generate` (`engine.py:735-739`: `peak = 4.0 + MP * 3.2`,
refused with `BUDGET_EXCEEDED` when it exceeds the budget); the other use only
caps the MLX wired limit (`engine.py:961`). `_job_upscale` never reads it, and
no host sets or passes it (`workerEnvironment`,
`Sources/RetouchStudio/Core/AIWorker.swift:535-556`; `git grep
RETOUCH_AI_MEMORY_BUDGET_GB` over `Sources`, `Windows` and `Tests` finds no
code). The bounds on an upscale are the **40 MP output ceiling**
(`engine.py:39`, enforced at `:761-765`) mirrored by `RenderUpscale.canHandle`
(`Sources/StudioCore/RenderPolicy.swift:10-17`), and the **1500 s host wait**
(`Sources/RetouchStudio/Core/ExportService.swift:224`). §11.3 originally read
the 7.5 GB figure as a second exclusion; that reading is withdrawn there.

**Addendum 2026-11-19 — a memory refusal would reach the user as a timeout.**
`-32013` is `BUDGET_EXCEEDED` in the worker
(`worker/retouch_ai_worker/protocol.py:27`), but both hosts name the same
number `E_TIMEOUT` (`Sources/RetouchStudio/Core/WorkerClient.swift:37`,
`Windows/RetouchStudio.AI/WorkerClient.cs:46`) and also emit it for their own
wait timeouts (`WorkerClient.swift:256`, `WorkerClient.cs:140-141`). A real
generative memory refusal therefore surfaces as a timeout, and any future
upscale memory gate would too, until the frozen mapping is corrected — an
owner-reserved contract change, reported here and not made.

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

### 9.6 Harness minors closed (2026-11-19): exit classification, record honesty, JSON safety

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

---

## 10. Phase 2 `lr` measurement (run 2026-11-18T21:37–21:53Z; recorded 2026-11-19): A1 bar met and the bicubic control beaten on every image

Status of this section: append-only. Nothing above is rewritten, reordered or
softened. §9.5 left the `lr` result NOT MEASURED and made it "the next
measurement's decision, not this section's"; this section records that run and
nothing else. No number below is an estimate.

### 10.1 What was run

The real `upscale.4x` capability, through the worker socket, against the
adopted production store **`swin2sr-x4` 1.0.0** (the same record reports
`capability: "upscale.4x supported"`). Eight fixtures from the owner's private
portrait set, referred to by label only — no path, file name or derived pixel
is in this repository. Seven are 2268×4032 and one is 3213×5712 cropped to
3212×5712 (crop to a multiple of 4); all are 8-bit, three-channel, no alpha,
EXIF orientation 1, Display P3. 129 tiles in total; every tile ran on `mps`;
every output was exactly the reference size; every sidecar named model
version 1.0.0; every succeeded job folder held only its published pair.

These eight are drawn from the same private portrait set as §7.5's eight, with
no new source material, but they are not the same eight pairs and the labels
do not denote the same pair across the two sections: §7.5 had six images at
2268×4032 and two at 3212×5712, this run has seven and one, so
R1/R2/C1–C3/H1/B1/L1 here and C1–C8 there do not line up. The labels are local
to each section, and the near-coincidence of "C1" at 33.31 dB in §7.5 and
33.32 dB here is between **different pairs**, not a change in the model's
standing. Neither record pairs a label with a source path or digest — the
record's `source` field carries dimensions, mode and ICC only — and §7.5's job
folders were deleted after measurement, so the two pairs cannot be matched
after the fact. The tile totals differ for the same reason the pairs do — 129
here against 138 in §7.5 — and a label must not be quoted across the two
sections.

Protocol, fixed before the run and not tuned after it:

- **Colour first:** Display P3 → sRGB (Pillow `ImageCms.profileToProfile`,
  `renderingIntent=1`, relative colorimetric), then crop to a multiple of 4.
- **Degradation `lr`, in this order:** Gaussian **blur radius 1.2 px at the
  reference resolution** → antialiased **bicubic downscale ÷4** → **JPEG
  quality 70, 4:2:0** → **Gaussian noise σ = 5 code values** of 255, the last
  two at the degraded resolution. One deterministic seed per image, base
  20261118 (20261118…20261125 below).
- **PSNR:** 8-bit gamma-encoded sRGB code values, RGB, RMS over all channels,
  between the 4× output and the true reference.
- **Seam band:** ±32 px around the engine's own `_axis_tiles` boundaries;
  diagnostic only, no threshold.
- **Control:** plain bicubic ×4 of the same degraded input, recorded per image
  and never an exit-code input; the 0.5 dB margin is reporting only.
- **Gate:** Decision A1's per-image minimum **24.0 dB**, applied to each image,
  never to the mean; the bar was not moved.
- **SSIM:** 8-bit sRGB luma (Rec.601), 11×11 Gaussian window σ = 1.5,
  K1 = 0.01, K2 = 0.03, mean over the valid area; computed after the run on
  the same output files and the same control pairs. The script was ephemeral
  at measurement time; it is committed as `worker/tools/upscale_ssim.py`
  (2026-11-19, same formulation, inputs as arguments). Rerunning it needs an
  interpreter with torch (the AI runtime venv; plain `Tests/run-worker.sh`
  does not provide it) and the eight private sources, which are not
  committed, so the numbers are reproducible only on a machine that holds
  both; on this one the rerun reproduces the rows of §10.2 row for row, to the
  recorded six decimals on the same interpreter versions (CPython 3.13.15,
  torch 2.15.0, numpy 2.5.4, Pillow 13.0.0), PSNR cross-check included. The
  six-decimal digits depend on that float32 `conv2d` accumulation, so an
  independent float64 recomputation of the same formula on this machine
  differs at about 1e-5 (C1 0.882322 against the recorded 0.882312).

### 10.2 Per-image results

Labels are local to this run; they are not the §7.5 identifiers (§10.1).

| image | reference px | tiles | job s | PSNR dB | seam band dB | bicubic control dB | Δ vs control | SSIM model | SSIM control |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| R1 | 2268×4032 | 15 | 100.87 | 31.51 | 31.50 | 30.19 | +1.32 | 0.859036 | 0.812626 |
| R2 | 2268×4032 | 15 | 100.22 | 31.82 | 30.95 | 30.57 | +1.25 | 0.844326 | 0.806012 |
| C1 | 2268×4032 | 15 | 103.12 | 33.32 | 33.12 | 31.40 | +1.92 | 0.882312 | 0.839645 |
| C2 | 2268×4032 | 15 | 104.56 | 31.49 | 30.33 | 29.66 | +1.83 | 0.933397 | 0.876221 |
| C3 | 2268×4032 | 15 | 107.16 | 32.70 | 31.61 | 30.49 | +2.21 | 0.949544 | 0.891057 |
| H1 | 2268×4032 | 15 | 110.12 | 30.65 | 31.13 | 29.57 | +1.08 | 0.842856 | 0.796489 |
| B1 | 2268×4032 | 15 | 110.38 | 31.48 | 29.24 | 30.11 | +1.37 | 0.880061 | 0.833055 |
| L1 | 3212×5712 | 24 | 180.35 | 31.79 | 30.71 | 29.34 | +2.45 | 0.887050 | 0.834942 |

### 10.3 Verdict

- **A1 bar:** `a1Bar: met`, exit code 0; per-image minimum **30.65 dB**,
  mean **31.84 dB**, median **31.65 dB**; `belowBar`, `notMeasured` and
  `dimensionFailures` are all empty.
- **Control:** bicubic ×4 scores minimum **29.34 dB**, mean **30.17 dB**,
  median **30.15 dB**; the model wins on all eight images
  (+1.08…+2.45 dB), with no tie and no loss.
- **SSIM:** the model is higher on every image — model 0.842856–0.949544,
  control 0.796489–0.891057; the arithmetic means over the table are
  0.884823 and 0.836256.

### 10.4 Determinism

One fixture was run twice at seed 20261118 (two consecutive same-seed records,
immediately before the corpus run): PSNR **33.32 / 33.32 dB**, seam band
**33.11 / 33.11 dB**, bicubic control **31.40 / 31.40 dB** — spread
**0.00 dB** on every metric. Job time was 64.0 s and 90.2 s (wall 67.53 s and
91.21 s): timing on this laptop is load-dependent and is not a benchmark,
while quality reproduced. The corpus image with the same dimensions and seed
(C1) records 33.32 dB PSNR, 31.40 dB control and 33.12 dB seam; the 0.01 dB
seam difference is a band diagnostic only, and no threshold depends on it.

### 10.5 Evidence tier

Real inference on this Mac's MPS (MacBook Air M3, 16 GB, macOS 27.2), through
the worker socket, against the adopted production store `swin2sr-x4` 1.0.0.
The harness logic is unit-tested on synthetic pixels
(`worker/tests/test_upscale_quality_corpus.py`, 21 tests on the merged tree at
2026-11-19; this section first cited 14, and §11 records the correction): the
engine's tile boundaries and an edge-only band, the seam mask, the median, the
bar-versus-control separation and the unrounded bar, the `lr` degradation
order and per-seed determinism, the descriptor, the 0/1/2/3 exit mapping with
a bad input and an unreachable worker at 2 and an unexpected failure at 3, a
provenance failure and an unreadable fixture recorded as unmeasured rows,
non-finite values written as `null`, and the control note built from the run's
own numbers. CI proves that logic.

It is **not** shipped-build evidence: the installed bundle carries no
`Contents/Resources/Worker` and `AIRuntime.package` is nil. No product-path
export with upscaling and no export-cancel ran this round. CI cannot reproduce
the numbers — no runner has this model store or MPS, and no fixture is
committed.

### 10.6 NOT VERIFIED

- The degradation is **synthetic** (blur → bicubic ÷4 → JPEG q70 → noise); it
  is not a camera capture. No true high-ISO sensor frame and no motion-blurred
  frame was measured.
- H1 and C1 are **proxies**, chosen on their noise / sharpness appearance, not
  on recorded ISO or exposure metadata.
- **No perceptual or human judgement** was made this round: no side-by-side
  viewing and no preference votes.
- **Windows** upscaling and **2×** upscaling are untouched.
- **No memory or VRAM profiling** this round; the memory profile of the
  upscale path is not measured here.
- Timing is **single-run and load-dependent** (64–180 s per image); it is not
  a benchmark.
- No product-path UI export, no export-cancel, no download, install or
  conversion; the store was already adopted.
- No fixture or derived pixel is in the repository; the evidence JSON lives
  outside it.

### 10.7 What may be said

Quality value-add over a classical resize is now **MEASURED AND MET within
this documented protocol** — these eight private portraits, the `lr`
degradation above, per-image PSNR and SSIM — and **must not be quoted outside
it**. It says nothing about other degradations, other content, Windows, 2× or
a shipped build, and it does not by itself make `upscale.4x` production-ready.

### 10.8 Dated addendum (2026-11-19): the SSIM rerun's cost and interpreter

The rerun 10.1 reports was priced on this machine: 58.17 s wall for the eight
images and their control pairs, CPU only — no model load, no MPS work, one
process. The wall time is the rerun's own console measurement, not a field of
its record: `ssim.log` holds the eight JSON lines, `done` and `exit=0`, and
no timing. It reproduced all eight rows, with the model higher on every
image; the means 10.3 computes from those rows are 0.884823 (model) and
0.836256 (control), and the rerun printed `exit=0`. The harness record behind
10.2 marks the dimensions exact for all eight rows. The PSNR cross-check
agrees with the recorded values to within 0.01 dB: the largest residual over
the 16 model-plus-control comparisons is 0.005 dB — the rounding half-width
of the recorded two-decimal values (for example L1 31.785 recomputed against
31.79 recorded) — and the harness stores PSNR already rounded to two
decimals, so no unrounded cross-check is possible.

Environment fact worth recording: the test venv pinned for the worker suite,
`/private/tmp/rs-worker-venv`, has CPython 3.13.15, numpy 2.5.4 and Pillow
13.0.0 but **no torch**, so it runs the 163-test suite and cannot run this
tool. The rerun used
`~/Library/Application Support/RetouchStudio/AI/runtime/bin/python3` — the
10.1/11.2 interpreter — and the eight private sources, which are not
committed.

---

## 11. Memory envelope measured on the pre-band whole-frame path (2026-11-19): what §§4–10 estimated and what a worker actually costs

Status: addendum. §§1–10 stay as written; the estimates this section
supersedes are cited by location and dated here rather than edited away. The
only edits made above are the three §10 corrections this section records in
11.1.

Scope of the measurements: the fits and times in 11.2 were taken on a worker
whose `engine.py` is the **whole-frame quantiser** — sha256
`7d591fc6a6696098ea9f5415302404d7ba0b38043e650cca9009dac4f44b38e8`
(commit `d7d833e`), i.e. before the banded `_quantise` this branch ships. They
are measurements of *that* path. What was measured of the shipped banded path
is the call-level `tracemalloc` peak in 11.1; its effect on process-level RSS
and footprint slope is **not measured** (11.5).

**Dated pointer (2026-11-19).** That gap is now filled: §12 measures the
banded path's process-level RSS and footprint on the shipped head. The fits
in 11.2 remain measurements of the pre-band path and are kept as its upper
bound, not re-read as the shipped cost.

### 11.1 Corrections recorded this round (2026-11-19)

- **§10.5's test count.** It said 14;
  `worker/tests/test_upscale_quality_corpus.py` has **21** `def test_` functions
  on the merged tree (the count in §10.5 is corrected, and the coverage list
  now names the follow-up's additions: provenance failure and unreadable
  fixture as unmeasured rows, the unrounded bar, non-finite values as `null`,
  the run's own control note). This is a test-file count, not a pin:
  `Tests/run-worker.sh` still runs 163.
- **§10.1/§10.2 fixture labels.** Added: the eight `lr` fixtures come from the
  same private portrait set as §7.5's eight but are a different selection
  (7 × 2268×4032 + 1 × 3212×5712 here against 6 + 2 there) and the labels do
  not denote the same pair across sections. The 33.31 dB of §7.5's C1 and the
  33.32 dB of this run's C1 are therefore different pairs; neither record
  carries a source path or digest, so no comparison between them can be made
  and none is claimed. Tile totals differ for the same reason (129 against
  138).
- **§10.1's SSIM provenance.** The script was ephemeral at measurement time.
  It is now `worker/tools/upscale_ssim.py` (a tool, not a test), with the
  recorded formulation in its docstring and its inputs as arguments. The rerun
  needs an interpreter with torch (the AI runtime venv) and the eight private
  sources, which are not committed, so it is reproducible only on a machine
  that holds both; on this one it reproduces all eight rows of §10.2 row for
  row, to the recorded six decimals on the same interpreter versions (CPython
  3.13.15, torch 2.15.0, numpy 2.5.4, Pillow 13.0.0), PSNR cross-check
  included. An independent float64 recomputation of the same formula differs
  at about 1e-5 (C1 0.882322 against 0.882312), so the six decimals are
  interpreter-dependent, not a portable tolerance.
- **The quantiser's arithmetic** (`worker/retouch_ai_worker/engine.py`,
  `_quantise`). Both figures that circulated were wrong, and the shipped code
  was changed so the claim is true. Measured with `tracemalloc` on the pinned
  interpreter (CPython 3.13.15, numpy 2.5.4), whole-call peak per output
  pixel, with the accumulator (12 B/px), the weight plane (4) and the uint8
  artifact (3) counted:
  - The old whole-frame expression peaks at **52.0 B/px** at every height.
    Its stage trace is 16 (inputs) → 28 (divide) → **40 (clip)** → 28 (the
    divide temporary is freed only after the clip returns) → 40 (`× 255`) →
    **52 (`round`)**; the cast adds 3 more while the clip result and the
    rounded array are alive, which stays below the round stage. The review's
    **40.0** is the clip stage read as the peak; the earlier **~55** (in this
    PR's body and in the arithmetic behind it) assumed the `× 255` array was
    still alive during the cast, which Python frees after `round`. The true
    peak is 52.0.
  - The banded version merged on 4bd90bb (two band temporaries) measures
    **25.1 / 31.0 / 43.0 B/px** at 4032 / 2048 / ≤1024 output rows — the
    review's model `19 + 24·min(1024, H)/H` reproduces these exactly, so its
    banded numbers were right even though its old-path number was not.
  - The shipped version removes the second band temporary: one reusable
    float32 band buffer takes the `× 255` and the rounding in place and the
    cast writes straight into the artifact slice. Measured **22.0 / 25.0 /
    31.0 B/px** at the same heights, i.e. `19 + 12·min(1024, H)/H`, **below
    the 52.0 of the expression it replaced at every height**. Byte identity
    holds: the pinned job artifact is still 327 bytes with SHA-256
    `8e35b0c06dc7f3cb678b80c3bd3f6656de7246997593c044bf0ae3384c1da1c4`, the
    committed equivalence test passes at its heights (0, 1, 6, 7, 8, 15 and
    one band plus a row), and an ad hoc run of the same comparison over 37
    rows and the full 4032×2268 frame found no differing byte.
- **§4's "dominated by the float32 accumulator pair (~0.6 GB) plus torch/MPS
  overhead"** is superseded as an estimate by the fits in 11.2 (measured on the
  pre-band path, per the section scope): the whole worker's resident set is
  0.673 GB + 0.0402 GB per output megapixel, and its peak footprint is
  2.728 GB + 0.0579 GB per output megapixel, so the accumulator is one term
  inside a much larger constant.
- **`RenderPolicy.secondsPerOutputMegapixel = 6.5`** is 26–95 % optimistic
  against the measured 8.21–12.69 s per output megapixel (11.2), so in-app
  ETAs under-report. It is a reserved owner number and no StudioCore or test
  edit is made here.
  **Superseded 2026-11-19:** the "reserved owner number" label above is not
  carried forward; the constant is now a fitted 12.0 s base plus 9.0 s per
  output mega-pixel and `Tests/ModelTests.swift:2022` was updated with it.
  See §12.9; the sentence above is kept as written.

### 11.2 Measured worker memory and time on this Mac, pre-band whole-frame path (2026-11-19)

Measured by the Test Engineer on this MacBook Air M3 (16 GB, macOS 27.2) with
the headless worker only — no app launch, the production store untouched and
read-only, no download, install or conversion — against `engine.py` sha256
`7d591fc6a669…` (the whole-frame `_quantise`, commit `d7d833e`), **not** the
banded path this branch ships. Method: `time -l` maximum resident set size per
first-job, and the process's peak physical footprint, over **four first jobs**
on square centre crops of one private fixture (the four table rows), **plus one
warm second job** at 20.070 MP — **five observations in all, and the warm
point is included in both fits** (dropping it leaves the cold-only
`0.659 GB / 40.0 B/px` subset) — plus determinism runs and throughput per
output megapixel.

| output MP | peak RSS GB | peak footprint GB | job s |
|---:|---:|---:|---:|
| 4.000 | 0.773 | 2.940 | 50.76 |
| 9.986 | 1.026 | 3.305 | 107.75 |
| 20.070 | 1.592 | 3.908 | 164.76 |
| 39.942 | 2.204 | 5.023 | 360.62 |

The 20.070 MP point's warm second job measured 1.546 GB RSS and 3.909 GB
footprint — no accumulation across two jobs.

- **RSS fit:** `0.673 GB + 0.0402 GB/MP` (b ≈ 40 B/px, slope SE 3.6, R² 0.977,
  RMSE 0.097 GB); the cold-only subset is unchanged at `0.659 / 40.0`.
- **Peak-footprint fit:** `2.728 GB + 0.0579 GB/MP` (b ≈ 58 B/px, R² 0.9994,
  RMSE 0.022 GB).
- **Throughput:** 8.21–9.03 s per output megapixel at ≥ 20 MP, 12.69 s/MP at
  4 MP — the small-input penalty, because the tile side grows 667 → 903 px and
  the overlap amortises worse. Planning envelope for a 16 GB machine:
  **b = 30–58 B/px, a = 2.7 GB, 8.2–12.7 s/output-MP**.
- **Determinism:** three separate 4480² jobs across two processes produced
  byte-identical output (`81c7212665c8`).
- **Caveats:** ambient load was 9.7–19.6 from a concurrent build, swap already
  stood at 14.29 GB, one fixture was used, crops were square centre crops, and
  nothing above 40 MP can be executed — the 40 MP ceiling is still in force,
  so the upper points are the largest the product permits and the fit is an
  extrapolation beyond them.

### 11.3 What that means for the ceiling

`RenderUpscale.maxOutputPixels = 40_000_000` (`Sources/StudioCore/RenderPolicy.swift:10`)
stays the executable bound, and the host waits **1500 s** for an upscale job
(`Sources/RetouchStudio/Core/ExportService.swift:224`).

- **146 MP** (a 9.14 MP source; 16× the area at 4× per axis) would need
  ≈ 11.2 GB of peak footprint on the 58 B/px slope (the review's summary said
  10.8 GB, which is the same fit read at ≈ 55 B/px — inside the 30–58
  envelope), and 1199–1318 s at the measured ≥ 20 MP **output** rate of
  8.21–9.03 s/output-MP, i.e. **under** the 1500 s host wait with 12–20 %
  margin. Neither the 7.5 GB budget (`RETOUCH_AI_MEMORY_BUDGET_GB` is never
  consulted by `_job_upscale`; the §4 addendum of 2026-11-19 records the code
  path) nor the host wait mechanically excludes 146 MP: **the 40 MP ceiling is
  the only gate that refuses it today.** The ≈ 11.2 GB fitted footprint on a
  16 GB machine that is already swapping is an engineering judgement about
  headroom, not an enforced check, and physical swap behaviour at that size
  was not measured. The 1853 s figure belongs to the 12.69 s/MP
  **small-output** regime (4 MP output, 667 px tiles) and must not be quoted
  as the reason 146 MP is refused: tile side grows with output, so that rate
  cannot be transferred upward.
  *Dated pointer (2026-11-19):* the ≈ 11.2 GB fitted footprint here belongs to
  the pre-band slope and is **superseded** for the shipped banded path by
  ≈ 6.56 GB (§12.7, fit in §12.1). The time figures and the 1853 s correction
  in this bullet stand as recorded.
- **293 MP** is infeasible **on time**: 2406–3718 s exceeds the 1500 s wait in
  every measured regime; its ≈ 19.7 GB fitted footprint (18.9 GB at 55 B/px)
  is the same kind of engineering judgement, not an enforced gate.

### 11.4 Decision (engineering lead, 2026-11-19)

1. **`maxOutputPixels = 40_000_000` is kept for 1.1.** No ceiling change is
   made in this PR, and none is proposed by these data.
2. **The banded quantiser is retained for headroom at the permitted sizes**,
   not as an enabler of a raise: it lowers the quantisation stage's peak from
   52.0 to 22–31 B/px at sizes the product allows.
3. **The largest raise these data would defend on a 16 GB machine is ≈ 100 MP**,
   and only with a proportional host timeout (≈ 820–1270 s at the measured
   rate, against 1500 s today) **and** measured evidence that the process-level
   per-pixel cost actually came down. That evidence does not exist: the
   quantiser's call-level reduction (11.1) is a ~21–30 B/px cut at that stage
   only, so the pre-band envelope is an upper bound for it and not a
   measurement of the shipped slope.
   **Superseded in basis 2026-11-19:** the banded process-level evidence this
   item says does not exist now exists (§12), so ≈ 100 MP is no longer a
   memory-derived ceiling; see §12.7. The ceiling itself stays owner-reserved
   and unchanged.
4. **The ceiling value itself is owner-reserved**, because it is shipped user
   copy (`Sources/RetouchStudio/Models/Localization.swift:502-504`,
   `Sources/RetouchStudio/Models/PersianL10n.swift:516`), a pinned test
   (`Tests/ModelTests.swift:3262-3285`) and recorded product behaviour
   (`Docs/W5_IMPLEMENTATION_DECISION_RECORD.md:387`). No such change is made
   or requested here.

### 11.5 NOT VERIFIED in this section

- The fits are from **one fixture** and four output sizes; content, chroma and
  compressibility vary per photo.
- **Nothing above 40 MP was executed**, so the 146 MP and 293 MP figures are
  the fit extrapolated, not measured.
- The runs were under **heavy ambient load** with swap already in use; the
  memory figures are peak measurements, the timing figures are not a
  benchmark.
- **No app-launched export** and no export-cancel was exercised; the headless
  worker is the measured path.
- **The banded quantiser's effect on process-level RSS and footprint slope is
  unmeasured.** 11.2 is the whole-frame path (`engine.py` sha256
  `7d591fc6a669…`); the shipped path has only the call-level `tracemalloc`
  peak of 11.1, so the fits must not be quoted as if they describe the banded
  code. Direction: the banded quantiser is 21–30 B/px lower at the
  quantisation stage (52.0 → 22–31 B/px, call-level), so these pre-band fits
  are an **upper bound for that stage only**; the torch/MPS component is
  unchanged and unmeasured.
  *Dated pointer (2026-11-19):* measured now — §12.1 (slope and intercept),
  §12.2 (per size) and §12.6 (shipped-head contract).
- The earlier reading that the 7.5 GB budget "excludes" 146 MP is withdrawn:
  the budget is never consulted by `_job_upscale` (see the §4 addendum,
  2026-11-19), so there is no budget-side check at any size to verify.

---

## 12. Banded path measured on the shipped head (2026-11-19): slope halved, intercept unchanged

Status: addendum. §11 is left as written; each statement this section
supersedes carries a dated pointer at its own location. §11 measured the
**pre-band whole-frame quantiser** (`engine.py` sha256 `7d591fc6a669…`,
commit `d7d833e`). This section measures what `main` actually ships: the
**banded `_quantise`** — 1024-row bands through one reused float32 buffer —
at `77951c3`.

Provenance: a headless worker from a separate worktree of `77951c3`, with
`engine.py` sha256
`d911594323d085b47c619f73f4ee754649384cd97aab2a7940d5b1882dd5df44`;
interpreter
`~/Library/Application Support/RetouchStudio/AI/runtime/bin/python3`
(CPython 3.13.15, torch 2.15.0 on MPS, numpy 2.5.4, Pillow 13.0.0) — the
11.2 interpreter; model `swin2sr-x4` 1.0.0, `pytorch_model.bin` sha256
`4a5f52a20932085557ed115f87c0ee8385e12f2719108c0dfd38c64aedea4710`; the
same private fixture and square centre crops, the same `time -l` pair (max
RSS and peak physical footprint), the same four first output sizes and one
warm second job at 20.070 MP. Machine: this MacBook Air M3, 16 GB,
macOS 27.2. No app launch, the production store read-only, no download,
install or conversion. The raw record is
`/tmp/rs-banded-out/evidence/sweep.json` with its `time -l` logs; like
11.2's, it lives outside the repository.

### 12.1 Fits on the shipped path: the per-pixel slope halved, the fixed cost did not move

| fit | pre-band whole-frame (11.2) | banded, shipped head | slope change | R² banded |
|---|---|---|---:|---:|
| peak footprint | `2.728 GB + 0.0579 GB/MP` (57.9 B/px) | `2.708 GB + 0.02637 GB/MP` (26.4 B/px) | −54 % | 0.9994 |
| max RSS | `0.673 GB + 0.0402 GB/MP` (40.2 B/px) | `0.558 GB + 0.01842 GB/MP` (18.4 B/px) | −54 % | 0.918 |

Both fits use the same five observations as 11.2 — four cold first jobs
(4.000, 9.986, 20.070 and 39.942 MP output) plus the warm second job at
20.070 MP, the warm point included in both fits. The intercept barely moved
(2.728 → 2.708 GB footprint; 0.673 → 0.558 GB RSS). The roughly 2.7 GB a
loaded `swin2sr-x4` worker costs — weights, the MPS allocator, the host
process — is paid per job, not per pixel, and the refactor touched only the
per-pixel term.

### 12.2 Per-size measurements and pixel identity

| output MP | peak RSS GB | peak footprint GB | job s | 11.2 RSS GB | 11.2 footprint GB | Δ RSS | Δ footprint |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 4.000 | 0.629 | 2.803 | 46.94 | 0.773 | 2.940 | −18.6 % | −4.7 % |
| 9.986 | 0.727 | 2.984 | 100.22 | 1.026 | 3.305 | −29.1 % | −9.7 % |
| 20.070 | 1.046 | 3.232 | 176.48 | 1.592 | 3.908 | −34.3 % | −17.3 % |
| 39.942 | 1.284 | 3.760 | 354.84 | 2.204 | 5.023 | −41.7 % | −25.1 % |

One job per size — individual jobs, not medians; the 20.070 MP warm second
job measured 0.838 GB RSS and 3.241 GB footprint, so two jobs in one process
show no accumulation, the conclusion 11.2 reached for the whole-frame path.
The saving grows with size, which is what capping the quantiser's working
set and recycling it predicts: at 4 MP the whole-frame temporary was
affordable, at 40 MP it was the dominant term.

**Pixel identity.** For the one size where both files exist, the output is
not merely similar but byte-identical: the banded 4.000 MP job wrote
`cf9eb1dabb476b836928d19ad137fe5bd40f2a3a50e1dd9715392c74477acb79`
(1,824,655 bytes), the digest recorded for the whole-frame output of the
same input (12.6 records the comparison). The 20.070 MP output,
`81c7212665c8b014251fa9a7d2fe49ac4dd17b3678e0d86925c96c429db1acce`, was
identical across its three jobs and carries the `81c7212665c8` prefix 11.2
recorded for three separate pre-band 4480² jobs. The 9.986 and 39.942 MP
banded outputs (`1b13a42e89e46efa…`, `69f77ece848e2f34…`) have no pre-band
counterpart file kept, so their identity rests on the committed equivalence
test over synthetic heights and the pinned 327-byte artifact, not on a
side-by-side file.

**Sampler note.** A 100 ms `ps` poller ran during every job as a
cross-check; it under-reads peaks (0.561 GB against `time -l`'s 0.629 GB at
4 MP), so this section quotes the `time -l` values — the method 11.2 used —
and not the poller's.

### 12.3 Why the slope halves although the call-level peak did not predict it

The two models measure different things. The `tracemalloc` figures 11.1
records are call-level: one thread, Python-allocated numpy buffers, the
torch/MPS stage and every other thread excluded. The figures here are
process-level at sample time: model weights, the MPS allocator, every thread
and every live buffer. 11.1's committed numbers — 52.0 B/px pre-band,
22.0 / 25.0 / 31.0 B/px banded at 4032 / 2048 / ≤ 1024 output rows
(`19 + 12·min(1024, H)/H`) — are a 21–30 B/px cut at the quantiser, and that
is what appears as a halved process-level slope once the whole-frame
temporary no longer coexists with everything else. The constant cost of
launching and loading stays where such a cost belongs: in the intercept. A
call-level peak therefore cannot predict the process slope from either side,
which is why 11.5 refused to re-read 11.2's fits as the banded cost.

### 12.4 Where the peak call allocates, on the shipped blob

`UPSCALE_BAND_ROWS = 1024` (`worker/retouch_ai_worker/engine.py:44`);
`_quantise` is `engine.py:216-254`. It allocates the uint8 artifact once
(`:246`) and a single reusable float32 band of `min(1024, height)` rows
(`:247`), then per band: `np.multiply(acc[start:stop], 255, out=view)`
(`:251`), `np.rint(view, out=view)` (`:252`),
`np.copyto(pixels[start:stop], view, casting="unsafe")` (`:253`). No second
band temporary is ever live, which is the whole difference from the
two-temporary version 11.1 also records. Worker `engine.py` sha256
`d911594323d085…` — the blob the sweep and the contract run share.

11.1's committed call-level peaks stand as measured on this blob and are not
re-run here; 12.1's process-level figures are the measurement this section
adds.

### 12.5 Throughput: no attributable regression

Banded job walls, same fixture and crop method as 11.2: 46.94 s at 4.000 MP
(11.74 s per output megapixel), 100.22 s at 9.986 (10.04), 176.48 s at
20.070 (8.79), 354.84 s at 39.942 (8.88); the two warm jobs at 20.070 MP
measured 173.26 and 189.68 s (8.63 and 9.45). Pre-band 11.2 measured
12.69 / 10.79 / 8.21 / 9.03 s/MP. The banded values sit −7 % to +15 % around
those, and the spread tracks ambient load rather than the band size: this
sweep ran at load averages 5.0–29.7 (the 20.070 MP cold job started at
29.7), against 9.7–19.6 for 11.2, and the warm pair alone differs from its
cold neighbour by 9 %. At the largest size, where the band loop does the
most work, the job is marginally faster (8.88 against 9.03 s/MP). No
regression is attributable, and none is claimed as a speed-up.

### 12.6 Contract end-to-end on the shipped head (2026-11-19)

A headless worker at `77951c3` (the `engine.py` blob of 12.4), driven over
its socket by a script, on a 500×500 crop (input file sha256
`bff790015b8c304b4343075de4387739f84b5699d0a90038e0b67cfa64072688`),
through the real `upscale.4x` path:

- **Claim and status.** The working folder was claimed before the job ran
  (`lock_held_while_running: true`) and `job.status` was observed `running`
  (`status_running_observed: true`); a second claim was refused while it
  ran.
- **Progress.** 9 `job.progress` events, all stage `upscale`, tiles 1–9:
  first `1/9`, middle `5/9`, last `9/9`.
- **Result.** A 2000×2000 RGB PNG, 1,824,655 bytes,
  `cf9eb1dabb476b836928d19ad137fe5bd40f2a3a50e1dd9715392c74477acb79`,
  byte-identical to the pre-band output for the same input
  (`pixel_identity_vs_pre_band: true`), engine `40.13 s`, `device: mps`.
- **Provenance.** A sidecar (`retouchstudio.ai.provenance/1`) recording
  capability `upscale.4x`, model `swin2sr-x4` 1.0.0 / `pytorch` / `mps`,
  `tile` 256, `overlap` 16, `scale` 4, `state: succeeded`, the same output
  digest, `elapsedSeconds` 40.13.
- **Release.** `lock_free_after_done: true` (the claim was released when the
  job ended) and `lock_exists_after_done: true` (the lock file stays);
  worker exit 0. The record's `result_status` is `null` because the script
  did not call `job.result`; the terminal state above comes from the
  sidecar.

This closes the assumption 11.5 listed as unverified — that the shipped
banded blob still honours `job.status`, `job.progress`, the workdir claim
and provenance end to end. It does **not** exercise `job.cancel`, and it is
a headless worker, not an app-launched export.

### 12.7 What it changes for the ceiling question (an owner decision, unchanged here)

The ceiling is unchanged and still owner-reserved; what changes is the
evidence behind it.

- **Memory stops being the binding constraint on a 16 GB Mac.** At the
  measured banded slope the 40 MP ceiling is a 3.76 GB footprint — 23.5 % of
  16 GB. `RETOUCH_AI_MEMORY_BUDGET_GB` (`engine.py:45`) is still never read
  by `_job_upscale` (`engine.py:752`); its only uses are the Flux pre-flight
  estimate (`engine.py:736-739`) and the MLX wired cap (`engine.py:961`).
- **§11.3's ≈ 11.2 GB at 146 MP is superseded** by ≈ 6.56 GB — 41.0 % of
  16 GB, ≈ 9.4 GB free before swap — on the measured banded slope, for a
  9.14 MP source at 4× per axis (the executable bound stays
  `UPSCALE_MAX_OUTPUT = 40_000_000`, `engine.py:39`, mirrored at
  `Sources/StudioCore/RenderPolicy.swift:10`).
- **Time is now the binding limit.** 146 MP extrapolates to 1260–1380 s at
  the measured ≥ 20 MP rate (8.63–9.45 s/output-MP) — 8–16 % under the
  1500 s host wait (`Sources/RetouchStudio/Core/ExportService.swift:225`),
  thin against a wait that is itself unmeasured at that size.

---

## 13. Dated addendum (2026-11-21): the worker suite count is derived, not copied

Status: addendum. §§9 and 12 stay as written; the two "five pinned places"
sentences in §9.1 (`:545`) and §9.2 (`:661`) describe the arrangement that
existed when they were recorded, and are left unedited as the record of it.

On the fail-closed worker-gate branch (`w5-worker-gates-failclosed`, PR #110)
the expected worker-suite size lives in exactly one place,
`Tests/expected-worker-tests.txt`. Three readers compare against that file
and none carries a second copy of the number:

- `Tests/run-worker.sh` reads the file, runs the suite, extracts the
  runner's own `Ran N tests` line and exits non-zero when the two disagree,
  naming both numbers in the message;
- `worker/tests/test_suite_count.py` re-discovers the suite in-process and
  compares the discovered count with the same file, so a stale value fails
  the suite itself;
- the `macOS Integration` job's "Assert every suite reported a verdict" step
  builds its `Ran ${expected_worker_tests} tests` pattern from the file.

The divergence was observed while adding tests for this addendum: with the
file still holding `188`, discovery found `190` and
`test_suite_count` failed with
`AssertionError: 190 != 188 : the discovered suite and
Tests/expected-worker-tests.txt disagree`; after the file was set to `190`,
the runner reported `Ran 190 tests ... OK` and exited 0. Adding, removing or
renaming a worker test now means editing one value, not five.
- **≈ 100 MP** keeps both margins comfortably: ≈ 5.35 GB (33.4 % of 16 GB)
  and 863–945 s (37–42 % under the wait). It is the size these data defend
  on both axes at once.
- **293 MP** extrapolates to ≈ 10.43 GB (65.2 % of 16 GB) and 2529–2769 s:
  outside the host wait by 69–85 %, so no ceiling near it can ship without a
  larger wait.
- **The pre-band fits were conservative, not unsafe.** 11.2's fit
  over-predicts the banded footprint at every measured size (2.96 against
  2.80 GB at 4 MP; 5.04 against 3.76 GB at 40 MP), as an upper bound should;
  no §11 conclusion understated the shipped cost.
- **What would change the answer:** measurements above 40 MP (which would
  test the ratio, the intercept, and the weaker RSS fit, R² 0.918), a second
  fixture, and a host wait chosen for the size rather than left at 1500 s.

### 12.8 NOT VERIFIED in this section

- **Nothing above 40 MP was executed.** The 100 / 146 / 293 MP figures are
  the fit extrapolated 2.5–7.3× past the measured range.
- **One fixture**, four output sizes; content, chroma and compressibility
  vary per photo.
- **The small-output regime's rate at other loads is uncharacterised.**
- **The fits are process-level but not per-component.** `tracemalloc` is
  call-level and excludes the torch/MPS stage; it was not re-run here.
- **Machine-specific.** M3, 16 GB, macOS 27.2, this torch 2.15.0 build; the
  sweeps ran under ambient load up to 29.7 with swap already in use, so the
  memory figures are peaks and the times are not a benchmark.
- **Developer-machine artefacts only.** The shipped DMG carries no Python
  runtime and the app never launches the worker — `release.yml` sets
  `RETOUCH_SKIP_WORKER` at lines 25, 55 and 113 — so no app-launched export,
  batch export or export-cancel was exercised, and nothing here is
  DMG-level evidence.
- **`job.cancel` on the shipped head** was not exercised (12.6).
- **No setting moved.** The 40 MP ceiling, the 1500 s wait, the 1024-row
  band, the 7.5 GB budget and the 163-test pin are unchanged by this
  section.

### 12.9 The upscale ETA constant, corrected (2026-11-19)

`RenderPolicy.secondsPerOutputMegapixel = 6.5` (11.1) is superseded by a
two-term estimate fitted to the banded-path timings in 12.5. The old constant
was not wrong about the fit's arithmetic — it was a number with no measurement
behind it, and the sheet it fed under-predicted every job that was run.

**The constants now shipped** (`Sources/StudioCore/RenderPolicy.swift`):

- `baseSeconds = 12.0` — fixed per-job cost.
- `secondsPerOutputMegapixel = 9.0` — rate per output mega-pixel.
- `estimatedSeconds(for:) = round(base + rate × outputMP)`.

**The fit.** A least-squares fit over the four cold jobs of 12.5 gives
11.9 s + 8.53 s/MP. The base is rounded up to 12 s. The warm repeat at
20.070 MP took 189.68 s, which requires the carried rate to be at least
(189.68 − 12) / 20.070 = 8.85 s/MP, so the rate is rounded up to 9.0. Neither
rounding direction can under-predict a measured job.

**Measured against projected** (cold jobs unless noted; s):

| output MP | measured | 12.0 + 9.0 × MP |
|---:|---:|---:|
| 4.000 | 46.94 | 48 |
| 9.986 | 100.22 | 102 |
| 20.070 | 176.48 | 193 |
| 39.942 | 354.84 | 371 |
| 20.070 (warm) | 189.68 | 193 |

**The ceiling still fits the wait.** At the 40 MP ceiling the estimate is
12.0 + 360 = 372 s, against the host's 1500 s timeout
(`Sources/RetouchStudio/Core/ExportService.swift:225`). As before, the
sheet's number is a planning estimate; the helper's own tile report is the
measured truth while a job runs.

**Tier limit.** Every timing above is developer-machine evidence — a 16 GB M3
under MPS at `77951c3` — not shipped-runtime behaviour.
`AIRuntime.package` is nil on this head
(`Sources/RetouchStudio/Core/AIRuntime.swift:40`), so the shipped DMG carries
no Python runtime, and `.github/workflows/release.yml` sets
`RETOUCH_SKIP_WORKER` at lines 25, 55 and 113. The estimate constant itself is
plain arithmetic and does not depend on that runtime.

**Provenance of the change.** 11.1 called this constant "a reserved owner
number" and stated that no StudioCore or test edit was made here. That label
was wrong for a value that only feeds a displayed estimate, and the sentence
stands unedited as the record of the earlier position. The change here is a
truthfulness fix made under the standing engineering directive: the constant
moved from an unmeasured 6.5 to the fitted 12.0 s base and 9.0 s/MP, and
`Tests/ModelTests.swift:2022`'s pinned example (a 4× export of a 800×600
photo, 7.68 output MP, 12.0 + 69.12 = 81.1 s) moved with it from 50 to 81.

**The test that keeps it honest.** `Tests/UpscaleEtaTests.swift` is compiled
and run by `Tests/run-studiocore.sh` (both blocks link only Foundation and
`StudioCore` and pass the same platform-framework `otool` guard as the module
tests). It asserts that the estimate meets or exceeds each of the four cold
jobs and the warm repeat in the table above, that the estimate is monotonic
in output size, that the 40 MP ceiling is still accepted, and that its
estimate falls inside the 1500 s wait.

**NOT VERIFIED.** The sheet's rendered text in a running app was not
exercised; only the value the model produces is tested. Nothing here
re-measures a job — 12.5 is the source of every timing.

