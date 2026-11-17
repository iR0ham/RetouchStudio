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
