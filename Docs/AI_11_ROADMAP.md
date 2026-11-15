# AI-01 — Roadmap for a complete local AI editing system (1.1)

**Status:** Research and sequencing proposal for review. It schedules no work,
opens no branch beyond the AI-01 documentation branch and authorizes no
implementation.
**Milestone:** AI-01 under the RetouchStudio Master Execution Plan V4.
**Base:** `main` at `46e2b14` (2026-11-16).
**Companions:** [AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md),
[AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md),
[ORIGINAL_MASTER_PLAN.md](ORIGINAL_MASTER_PLAN.md),
[MASTER_PRODUCT_COMPLETION_STATUS.md](MASTER_PRODUCT_COMPLETION_STATUS.md).

## 1. How this roadmap relates to Master V4

Master V4 §2 sets the delivery order: audit → W4 image engine and Windows
metadata → Windows parity (including face analysis, masks, processing, batch
export) → W3 face analysis and masking on both platforms → W5 AI runtime and
inference → reliability/performance → installer → acceptance → release
readiness. **This roadmap does not reorder V4.** It answers a narrower
question: once the AI work authorized under V4 begins, what must be built
first, what depends on what, and what evidence closes each step.

| V4 stage | AI-01 work package | What AI-01 adds |
|---|---|---|
| W4 Windows metadata/parity | None directly | Confirms the portable job contract and that AI never enters the C ABI |
| W3 face analysis and masking | F1, F2, S1, S2 | Model options, licence findings, mask/identity boundary rules |
| W5 runtime and inference | R1–R4 | Reproducibility gap, integrity gaps, memory rules, adapter design |
| No V4 stage today | H1, B1, G1, E1, P1, U1, N1 | Capability definitions and dependencies for work that follows W5 |

Two consequences follow and are stated plainly:

1. **Nothing in AI-01 can be scheduled before the W5 substrate exists** —
   except the W3 face-analysis model decision, which V4 already places before
   W5 and which is an owner decision about a Windows landmark model.
2. **Windows AI is last on purpose.** The Windows host has no inference
   runtime, no landmarks and no mask rendering; a Windows AI claim before those
   exist would be unsupported by the platform.

## 2. Evidence labels

Every gate below is one of **VERIFIED** (source or recorded run),
**MEASURED** (a number with cited context), **ESTIMATE** (basis stated) or
**NOT VERIFIED** (depends on the external worker, a GPU CI does not have, or a
licence not yet cleared). A milestone closes only on VERIFIED or MEASURED
evidence. An ESTIMATE can plan a step; it cannot close one.

## 3. Dependency order

```
R0  Reproducible worker source + licence inventory        (W5 prerequisite)
 └─ R1  Job contract v1 (kinds, artifacts, errors, cancel)
     ├─ R2  Adapter: Python worker host (exists, needs contract conformance)
     │   └─ R3  Benchmark harness + memory/thermal protocol
     │       ├─ U1  Upscaling (Swin2SR today) and 2× output
     │       ├─ H1  Healing/object removal tiers (MI-GAN → LaMa → generative)
     │       ├─ E1  Enhancement / restoration (separate job kinds)
     │       ├─ S2  Click-to-mask and fine matte (SAM 2.1 / BiRefNet class)
     │       │   ├─ S1  Semantic mask classes (skin/hair/clothing/subject)
     │       │   └─ G1  Generative edit / outpainting
     │       │       └─ B1  Background: matte + composite (+ generated bg)
     │       └─ P1  Portrait AI augmentation (only where classical fails)
     └─ R4  Accelerator gate (Core ML / MLX / ORT) per component, measured
F1  Face analysis model decision (macOS Vision today)     (W3, parallel)
 └─ F2  Face parsing / landmarks upgrade (only if F1 requires it)
N1  Windows AI adapter (depends on R1 and on Windows landmarks/masks existing)
```

The graph is a dependency graph, not a delivery promise. V4's stage order
still decides when a package may start.

## 4. Work packages

### R0 — Reproducible worker and licence inventory (W5 prerequisite)

**Why first:** the worker is a separate checkout. A fresh clone cannot
reproduce a single inference, and the catalog's integrity fields are
incomplete (SAM 2.1 tiny has neither size nor SHA256 — [AI_RUNTIME.md](AI_RUNTIME.md)
§6.3). No model decision can be verified against a source that is not in the
repository.

**Deliverables:** worker source in the repository or a pinned, fetchable
dependency; `requirements.lock` reproducible; every catalog entry carries
size, SHA256 and a separate weights licence; the regression tests that live in
`Docs/worker-regressions/` run from a fresh clone.

**Exit:** a clean machine reproduces the recorded Swin2SR 4× job and the
recorded generative patch job from source, with the same hashes for inputs and
outputs where deterministic. Helper-side protocol-v2 CAS/readiness stops being
**NOT VERIFIED** because the package is published and tested.

**Does not:** enable `AIRuntime.package`, change the bundled runtime or alter
the 1.0 release architecture.

### R1 — Job contract v1

**Scope:** the engine-independent contract in
[AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §6 — kinds `analysis`,
`segmentation`, `mask`, `inpaint`, `generative_edit`, `upscale`, `enhance`,
`restore`, `matte`; artifact files; declared coordinate space; typed errors;
cancellation latency reporting; provenance beside artifacts.

**Depends on:** R0 for verified worker behavior.
**Exit:** the existing `upscale`, `patch_edit` and `mask` jobs are expressible
in the contract with no behavior change; contract tests use test doubles for
the adapter; a masked generative request routed to `full_frame` is refused
with the existing typed error (`QuickEdit.swift` refusal path).

**Does not:** add project keys, move pixels into the C ABI or rename existing
IPC methods. A compatibility shim is allowed; a second parser is not.

### R2 — Python adapter conformance

**Scope:** make the existing worker conform to the contract without rewriting
it; report capability, model identity and version; map worker errors.

**Depends on:** R1.
**Exit:** every capability the host offers today is discovered from the
adapter, not hard-coded in the UI; a stopped helper produces a typed error, not
a timeout; 4× upscale and one generative patch pass the contract suite on the
owner's M3.

### R3 — Benchmark harness and resource protocol (16 GB target)

**Scope:** fixed inputs, fixed seeds, measured wall time, compute time,
peak RSS/GPU memory where obtainable, thermal note; one heavy job at a time;
residency and unload policy; memory-pressure refusal.

**Depends on:** R2.
**Exit:** a repeatable table for each adopted model on the M3 16 GB target;
the harness records throttling instead of hiding it; all M3 feasibility classes
in [AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md) either get measured
values or stay labeled ESTIMATE.

**Does not:** turn single-machine observations into benchmark claims. The
recorded 64×64 → 256×256 upscale (0.46–2.37 s compute, 5–7 s job) remains one
observation, not a benchmark.

### R4 — Accelerator gate

**Scope:** per component, compare the Python path with Core ML (small models
first), MLX (Apple-silicon diffusion) and ONNX Runtime on Windows. Core ML
conversion is per-model work with op and shape limits; MLX does not use the
Neural Engine; ORT uses the CPU by default on CI.

**Depends on:** R3 (a measurement to beat).
**Gate:** identical inputs, equal or better quality, lower peak memory or
latency, and no duplicated maintenance path. A component that fails the gate
stays on the worker.
**Exit:** a decision record per component, not a migration plan.

### F1 — Face analysis model decision (W3, both platforms)

**Scope:** keep Apple Vision (~76 landmark points, confidence ≥ 0.35, area
≥ 0.2 %) on macOS; decide the Windows landmark backend. `Windows.Media.FaceAnalysis`
gives boxes only, so it cannot drive masks. Candidates in
[AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md) §3.

**Depends on:** nothing technical; it is an owner decision because it fixes a
first-party dependency on a model's weights licence.
**Exit:** a named backend per platform, its weights licence cleared, and a
golden-face corpus proving landmark stability across a reopen. Until then the
Windows face/mask stage stays BLOCKED, exactly as
[MASTER_PRODUCT_COMPLETION_STATUS.md](MASTER_PRODUCT_COMPLETION_STATUS.md) §4
records.

### F2 — Face parsing / mesh upgrade

**Scope:** learned face-region classes (skin, eyes, brows, lips, teeth, hair)
where geometric masks plus colour gates demonstrably fail. A 478-point mesh is
a different topology from Vision's and would need its own index map; it is not
a drop-in.

**Depends on:** F1, R3.
**Exit:** a quality corpus shows a measurable improvement over the geometric
mask on the same photos, with no identity drift and no invented teeth/sclera
pixels.

### S1 — Semantic mask classes · S2 — Click-to-mask and fine matte

**Scope:** S2 adds point/box-prompt masks (SAM 2.1 tiny is already bundled,
box-only today) and a fine matte for hair edges (BiRefNet-class, licence
pending). S1 adds classes beyond "person" (clothing, hair, subject objects).

**Depends on:** R1, R3; S2 before G1 for mask-guided generative edits.
**Exit:** a mask produced by a model is stored as ordinary v5 geometry (never
as a model object), the digest rule for the derived raster still holds, and a
deleted cache costs recomputation, not the mask.

### U1 — Upscaling

**Scope:** keep the export-time model: render at source size → upscale →
callouts. Add 2× as an output choice and an optional face-aware stage only if
measured quality justifies it.

**Depends on:** R3.
**Exit:** 2× and 4× outputs in [AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md)
§9 meet the stated quality bar on a fixed corpus; the 1500 s timeout and tile
progress remain; a size beyond the limit refuses before load.

**Does not:** make upscaling a canvas mutation (ADR-3) or merge it with
enhancement.

### E1 — Enhancement and restoration

**Scope:** same-size operations, separate from upscaling: denoise, deblur,
detail recovery, low-light, and old-photo restoration including optional face
restoration. Separate job kinds `enhance` and `restore`, separate quality
criteria. The AI Enhancer is a front-end preset over these stages (general,
portrait, face, low-light, old photo) with one strength control and a
before/after, not a fourth engine.

**Depends on:** R3.
**Exit:** each operation has a defined input/output contract, a measured
default that does not darken skin or invent pores, and a documented failure
mode (halos, plastic skin, identity drift).

### H1 — Healing and object removal tiers

**Scope:** small spot (MI-GAN, shipped), medium brush (LaMa-class, weights
licence to clear), large object/complex background (FLUX.2 klein, shipped).
Keep the patch+alpha+box layer contract and the "outside pixels identical"
promise.

**Depends on:** R3.
**Exit:** a per-scale quality corpus; a mask exceeding the 512 px patch is
refused or explicitly escalated to a whole-frame request, never silently
downscaled.

### B1 — Background

**Scope:** replace the backdrop composite's manual edges with a subject matte
(Vision person segmentation today, fine matte candidate) and blend controls;
generated backgrounds are a separate generative job.

**Depends on:** S2, G1 (for generated backgrounds).
**Exit:** edge quality is judged on a hair/clothing corpus; the matte is
stored as mask geometry, not as a model object; a missing matte model produces
a refusal, not a fake cutout.

### P1 — Portrait retouch augmentation

**Scope:** only where the classical engine fails. The shipped deterministic
pipeline preserves texture and imposes nothing on clean input; a face restorer
that plasticizes clean skin is a regression, not an upgrade.

**Depends on:** R3, F2.
**Exit:** an A/B corpus with skin-texture and identity metrics; the classical
path remains the default; any AI path is opt-in and reversible.

### G1 — Generative edit and outpainting

**Scope:** local prompt edit (FLUX.2 klein, shipped, 512 px patch), whole-frame
reimagine (explicit request), outpainting (no shipped engine; requires a model
with verified weights licence).

**Depends on:** R3, S2.
**Exit:** memory stays inside the measured envelope on 16 GB; cancellation
deletes the working copy; a missing model refuses; outpainting stays a refusal
until an engine passes the licence and memory gates.

### N1 — Windows AI

**Scope:** a Windows ML (ORT-based) adapter in a separate worker process for
the model set that passes F1 and R4, CPU EP first; no Python sidecar is
promised.

**Depends on:** R1, a Windows landmark decision (F1), Windows masks existing.
**Exit:** a real Windows run (not CI-only estimation) of face analysis and at
least one AI edit; DirectML is opportunistic and never required; the CPU-only
CI can validate correctness, not speed.

## 5. Milestones

| ID | Milestone | Closes when | Cannot claim |
|---|---|---|---|
| M0 | Worker reproducible | R0 exit evidence | That inference is reproducible in general |
| M1 | Contract frozen | R1 exit + adapter conformance | Any new capability |
| M2 | Measurement baseline | R3 table on M3 | Benchmark parity with any other machine |
| M3 | Face decision | F1 owner-signed choice | Windows face features working |
| M4 | Upscale + enhance | U1/E1 exit corpora | That enhancement is upscaling or vice versa |
| M5 | Healing tiers | H1 corpus per scale | Deterministic removal |
| M6 | Segmentation + background | S1/S2/B1 corpora | A fine matte without a matte model |
| M7 | Generative/outpaint | G1 memory + licence gates | Outpainting before an engine passes |
| M8 | Windows AI | N1 real run | macOS/Windows parity |
| M9 | Optimization | R4 decisions + stress/recovery | A model migration without a gate |

M0–M2 are infrastructure; M3 is a decision; M4–M7 are capability work; M8 is a
second platform; M9 is optimization. V4 still decides which stage is active.

## 6. MVP versus advanced

| Capability | MVP (defensible for 1.1) | Advanced (after measurement) |
|---|---|---|
| Face analysis | Vision on macOS; Windows blocked until F1 | Learned parsing, stable selection ids, mesh |
| Masking | Box/point mask via SAM 2.1; fine matte candidate | Semantic classes, hair matte, multi-subject |
| Healing | MI-GAN spots + FLUX.2 klein large removals | LaMa medium tier, selection-aware fill |
| Background | Person matte + composite + manual edge tools | Fine matte, generated backgrounds, relighting |
| Portrait | Classical engine unchanged | Opt-in AI skin/eye/teeth only with A/B evidence |
| Upscale | Swin2SR 4× at export; 2× output | Face-aware upscale, batch queue |
| Enhance | Classical same-size tools; AI enhancement refused until measured | Denoise/deblur/low-light/restore models |
| Generative | 512 px masked patch; whole-frame reimagine | Outpainting, multi-reference edits |
| Windows | Preserve and declare AI edits | ONNX adapter after F1 |

## 7. Testing and acceptance

1. **Golden corpus.** Existing tracked exports keep their hashes; AI artifacts
   are never regenerated in place. A new AI corpus is additive and versioned by
   hash, and a baseline is never rewritten to make a run pass.
2. **Determinism.** Same seed, same model version, same inputs → same bytes
   where the engine promises determinism; otherwise the variance is recorded.
3. **Layer contract.** For every edit, pixels outside the authorized rectangle
   must be identical; this is testable without a quality judgement.
4. **Cancellation and recovery.** Cancel at every stage (queued, loading,
   running, writing) leaves no half-edit and no working copy; a helper crash
   leaves the document unchanged. The host cleanup gap recorded in
   [AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §2.2 must be closed before
   this check can pass.
5. **Memory.** Peak memory is measured per adopted model; a refusal before load
   is preferred to a crash. The 16 GB target is the design constraint.
6. **Privacy.** Zero endpoints during any job; audit repeated whenever an
   adapter or model is added.
7. **Licence.** A model without a written commercial-use grant for its weights
   does not ship, whatever its code licence says.

## 8. Risks and owner decisions

| Risk / decision | Needed by | Owner input |
|---|---|---|
| Worker source outside the repository | M0 | Decide: move source in, or pin a fetchable dependency |
| Windows landmark model and its weights licence | M3 | Choose a distributable model or accept no Windows face/mask |
| Fine-matte weights licence (BiRefNet-class) | M6 | Authorize contacting the maintainer or pick a MIT/Apache alternative |
| LaMa weights licence | M5 | Same: written grant or exclude |
| Generative model memory on 16 GB | M7 | Accept opt-in heavy jobs and their latency, or restrict |
| Outpainting engine | M7 | Accept "not in 1.1" or fund a licensed model |
| GPU Windows hardware for DirectML | M8 | Decide whether any GPU claim is needed at all |

Each entry is a product-direction decision with a concrete impact; the rest of
the engineering choices belong to the implementing agent.

## 9. Out of scope for AI-01

No implementation, no UI change, no schema change, no dependency upgrade, no
model download, no runtime packaging change, no `AIRuntime.package`
enablement, no worker rewrite, no new language, no release or tag, no change to
PR #63 or the Windows payload-size workstream, and no modification of `main`.
