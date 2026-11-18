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
