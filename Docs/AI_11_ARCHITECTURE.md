# AI-01 — Local AI Editing Architecture (RetouchStudio 1.1)

**Status:** Research and decision record for review. It changes no product
behavior, enables no download and authorizes no implementation.
**Milestone:** AI-01 under the RetouchStudio Master Execution Plan V4.
**Base:** `main` at `a559a0e` (2026-11-16), including the merged Windows
runtime payload-size fix from PR #63; the AI-01 branch merged that commit
without changing this document's findings.
**Companions:** [AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md),
[AI_11_ROADMAP.md](AI_11_ROADMAP.md),
[ORIGINAL_MASTER_PLAN.md](ORIGINAL_MASTER_PLAN.md),
[PROJECT_SCHEMA_V5.md](PROJECT_SCHEMA_V5.md),
[AI_RUNTIME.md](AI_RUNTIME.md),
[STUDIOCORE_ARCHITECTURE.md](STUDIOCORE_ARCHITECTURE.md).

## 1. Purpose and limits

This document defines how a complete, local-only AI editing system should be
structured so that W5 (runtime and model management) and the capability
milestones that follow can be implemented without redesigning the product.
It does not implement any AI feature, change the project schema, alter the
release architecture or replace the existing worker.

- W5 remains an implementation milestone. Nothing here counts as inference,
  runtime management or model management that already works.
- Master V4 remains authoritative. Where this research suggests a different
  internal ordering, [AI_11_ROADMAP.md](AI_11_ROADMAP.md) states that
  explicitly instead of redefining V4.
- Every claim below is one of:

| Label | Meaning |
|---|---|
| **VERIFIED** | Checked against the source tree, a recorded run, or a read-back artifact. |
| **MEASURED** | A number produced by a run or a measurement whose context is cited. |
| **ESTIMATE** | A projection with its basis stated; never presented as a result. |
| **RECOMMENDATION** | A proposed decision for review. |
| **NOT VERIFIED** | Not proven here; includes anything that depends on the external worker checkout or on hardware that does not exist in CI. |

## 2. What exists today

### 2.1 macOS application (VERIFIED unless stated)

| Area | Current state | Where |
|---|---|---|
| Face detection and landmarks | Apple Vision `VNDetectFaceLandmarksRequest` on a reused BGRA buffer; confidence ≥ 0.35 and area ≥ 0.2 % of the frame; largest-first. Landmarks are Vision's contour, eyes, pupils, brows, lips, nose, crest and midline (~76 points plus derived rows), not a dense 3D mesh. | `Sources/RetouchStudio/Core/FaceAnalyzer.swift`, [MASTER_PRODUCT_COMPLETION_STATUS.md](MASTER_PRODUCT_COMPLETION_STATUS.md) §4 |
| Derived facial regions | Eye/lip shields, lids, lash line, iris, forehead, cheeks, blush, jaw, chin, under-eye, teeth/enamel are computed geometrically from landmarks. | `FaceAnalyzer.swift` |
| Masks | Geometrically built grayscale coverage with feather/softness and luminance, saturation and YCbCr gates; 1024 px preview and 4096 px export; subtract/union/intersect. | `Sources/RetouchStudio/Core/MaskBuilder.swift` |
| Persistent masks and face identity | Schema v5 stores mask records and face identities; a mask may carry `faceId`; face records carry a box, never masks. Identity is re-attached by box overlap; runtime geometry is never encoded. | [PROJECT_SCHEMA_V5.md](PROJECT_SCHEMA_V5.md) §1–3, `Sources/RetouchStudio/Core/FaceIdentity.swift` |
| Classical retouch | Frequency-separation skin smoothing, donor-texture healing, separate sclera/iris/lash and enamel masks, makeup, reshape, film looks. | `Sources/RetouchStudio/Core/SkinEngine.swift`, `MakeupEngine.swift`, `FeatureReshaper.swift`, `LookEngine.swift` |
| Heal stamps | Stored points in the document; rendered by the classical engine. | `Sources/RetouchStudio/Models/Heal.swift` |
| AI helper | External Python 3.13 process over a local Unix socket, JSON-RPC 2.0, one request per line; the worker source is a separate checkout and is **NOT VERIFIED** here. | `Sources/RetouchStudio/Core/WorkerClient.swift`, [AI_RUNTIME.md](AI_RUNTIME.md) |
| AI jobs exposed by the host | `upscale`, `patch_edit`, `mask`, plus `models.list/plan/verify/download`, `health`, `ping`, `shutdown`. | `Sources/RetouchStudio/Core/WorkerClient.swift`, `Sources/RetouchStudio/Models/QuickEdit.swift`, `Sources/RetouchStudio/Core/ExportService.swift`, `Sources/RetouchStudio/Models/ModelManager.swift:76-159` |
| Quick Edit | Three presets: remove object and reimagine route to the generative `patch` engine; heal area routes to the small-hole `inpaint` engine. A masked generative patch is 512 px with 4 steps; a whole-frame reimagine is a separate explicit request. Measured on the owner's M3: about 24 s for the fastest masked patch and about 47 s under load; the guard timeout is 300 s. | `QuickEdit.swift:36-45`, `:65`, `:93-95`, `:107-122`, `:137` |
| Non-destructive AI edits | A result is a patch plus an alpha file stored beside the edit id; the compositor uses `CIBlendWithMask` and crops the blend to the edit's rectangle, so pixels outside the authorized box stay the input pixels; preview and export rebuild the same layers at their own sizes. | `Sources/RetouchStudio/Core/AICompositor.swift:63-83` |
| 4× upscaling | Export-time only: render at source size, send the pixels to the `upscale` job (Swin2SR x4), show tile progress, then apply analysis callouts at the enlarged size. The job timeout is 1500 s. A real 4× upscale from the bundled runtime was recorded. | `ExportService.swift:137-165`, `:204-242`, [AI_RUNTIME.md](AI_RUNTIME.md) §3 |
| Model manager | The catalog, plan, verify and download operations live in the worker CLI; the host shows the list, a consent plan with a manifest hash, progress, verify and remove. A missing size makes progress indeterminate rather than fake. | `Sources/RetouchStudio/Models/ModelManager.swift:34-207` |
| Consent and integrity | Each model sheet shows file count, total size and licence; the download runs only after approval with the manifest hash; catalog SHA256 files are verified. SAM 2.1 tiny has neither a size nor a SHA256 in the inspected catalog, so it cannot be checksum-verified. | [AI_RUNTIME.md](AI_RUNTIME.md) §3, §6.3 |
| Runtime v2 host lifecycle | Transactional install with staging, backup, functional validation, rollback and recovery; registry, generation, nonce and CAS; process identity checks; a shared usage lease inherited by the child through fd 197. | `AIRuntime.swift`, `AIRuntimeTransaction.swift`, `AIRuntimeValidation.swift`, `HelperRegistry.swift`, `RuntimeUsageLease.swift` |
| Network behavior | Measured zero TCP/UDP endpoints while idle and during a real upscale; exactly two HTTPS connections during an approved download. | [PRIVACY_AUDIT.md](PRIVACY_AUDIT.md) §3 |
| Catalog today | FLUX.2 klein 4B (q4) 4.6 GB, SAM 2.1 tiny ~298 MB on disk, Swin2SR x4 48.5 MB, MI-GAN 28.1 MB; licences recorded as Apache-2.0, Apache-2.0, Apache-2.0 and MIT (weights) respectively. These are catalog/documented facts, not model tests run by AI-01. | [AI_RUNTIME.md](AI_RUNTIME.md) §1, §6.3 |

### 2.2 What is disabled, incomplete or unverified

| Item | State |
|---|---|
| On-demand runtime package | `AIRuntime.package` is `nil`; no official protocol-v2 package exists, so no runtime download is offered (`AIRuntime.swift:40`). |
| Worker-side protocol v2 behavior | The host side is implemented; the worker side handshake, readiness and shutdown against a real protocol-v2 helper are **NOT VERIFIED**. |
| Worker source | Outside this repository, not under version control here; its catalog, preprocessing and inference details are **NOT VERIFIED**. |
| SAM 2.1 tiny integrity | No size or SHA256 in the inspected catalog; verify cannot compare it. |
| Model removal guard | `ModelManager.remove` checks that the target stays under `AI/models` but takes no runtime lease and does not check `ModelActivity.isRunning(id)` before deleting; it only calls `forget` afterwards, so a removal racing a running job is not excluded (`ModelManager.swift:196-207`). |
| Working-copy cleanup | Only a >24 h sweep of export temp siblings runs. `clearWorkingCopies()` has no call site and the helper's job cleanup is **NOT VERIFIED**. |
| Windows AI | No face path, no masks, no AI edits and no runtime. The Windows host preserves AI/mask records and names them as edits it cannot render. |
| Windows face landmarks | `Windows.Media.FaceAnalysis` returns boxes without landmarks, so it cannot drive masks. A distributable landmark model is an owner decision. |
| Learned semantic segmentation | Person/background separation exists through Apple Vision's person-segmentation request (`SceneEngine.swift:146-174`, `.balanced`, 1600 px working copy); face-region masks (skin, eyes, lips, brows) are geometric with color gates. There is no learned face parsing (region classes), no clothing/hair class model and no general subject/object segmentation. |
| Dense face mesh | Does not exist; do not claim it. |
| Enhanced/restored images | No AI enhancement, denoise, deblur or restoration product path exists. |
| AI background removal | Background work is a composite over Apple Vision's person matte; it is a learned *segmentation*, not a fine matte: no hair-edge refinement, no trimap/alpha matting, no subject-type model other than "person". |
| Benchmarks | No systematic AI benchmark table (latency matrix, peak memory, thermal) exists. The measured numbers are single-machine observations: Quick Edit ~24 s fastest / ~47 s loaded, and a real 4× upscale 64×64 → 256×256 on `mps` at 0.55 s compute (0.46–2.37 s across runs, 5–7 s whole job), recorded in [PHASE5_ACCEPTANCE.md](PHASE5_ACCEPTANCE.md) §4. |

## 3. Design principles

1. **Local only.** No image, mask, prompt or intermediate leaves the machine.
   The only network path is an explicit, consented runtime or model download.
2. **Engine-independent contracts.** The project schema, UI and AI job
   contracts name capabilities, artifacts and provenance — never a Python
   module, a Core ML model or an ONNX graph.
3. **Non-destructive by construction.** AI output is a layer (patch plus
   alpha, or a whole-frame layer) stored outside the project body and
   referenced from the document; undo and export use the same layer path.
4. **Preview and export agree.** A layer is rebuilt at the size being
   rendered; upscaling happens before callouts are drawn.
5. **Identity and geometry stay independent.** A face identity is an
   association record with a box; a mask is user geometry that may name a
   face. Neither depends on the model that produced pixels.
6. **Capability discovery before offers.** The host offers a feature only when
   an installed model reports the capability; a missing model produces a clear
   message, not a failed job.
7. **Honest degradation.** If the helper, runtime or model is missing, the
   classical path or a refusal is used and stated; no placeholder inference is
   presented as production.
8. **The 16 GB target decides.** One heavy job at a time, small models kept
   resident, large models loaded on demand and unloaded explicitly, tiled
   inference for large images, and no design that assumes workstation memory.
9. **Explicit consent and verifiable artifacts.** Downloads are approved per
   item, hashed and visible; weights are never redistributed in the app.
10. **One schema.** Schema v5 is not extended by AI-01. New provenance lives
    in files beside the project, not in new project keys.

## 4. Layered architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ Hosts: SwiftUI macOS editor            WPF .NET Windows host     │
├──────────────────────────────────────────────────────────────────┤
│ Portable product core (StudioCore behind C ABI v1)               │
│  project v5 codec · history · render/recovery policy · planner   │
├──────────────────────────────────────────────────────────────────┤
│ AI orchestration (each host, thin)                               │
│  capability discovery · job submission · cancel · progress ·     │
│  model/resource policy · consent UI                              │
├──────────────────────────────────────────────────────────────────┤
│ AI contract (engine-independent)                                 │
│  job kinds · artifact files · provenance · errors · versioning   │
├──────────────────────────────────────────────────────────────────┤
│ Platform inference adapters                                      │
│  macOS: bundled Python worker (PyTorch/MPS, MLX, ONNX Runtime)   │
│         future native Core ML / MLX behind the same contract     │
│  Windows: Windows ML (ORT) CPU baseline; DirectML opportunistic  │
├──────────────────────────────────────────────────────────────────┤
│ Model store (shared): weights downloaded on consent, hashed,     │
│  versioned; never inside the app bundle or the runtime tree      │
└──────────────────────────────────────────────────────────────────┘
```

**Boundaries.**

- `StudioCore` stays Foundation-only. No AI type, model name, tensor, image
  framework or platform inference API enters it. The existing boundary gate
  already enforces this ([CI_GATES.md](CI_GATES.md)).
- The AI orchestration layer belongs to each host. It is allowed to know the
  platform adapter, but the document and the renderer are not.
- The contract is data, not objects: paths, identifiers, rectangles,
  normalized coordinates, seeds, strengths, prompts, model identity and
  version, progress and error codes. It is serializable and testable with test
  doubles.
- An adapter may be replaced (Python today, Core ML/MLX tomorrow, ONNX on
  Windows) without touching the schema, the layer model or the UI.
- The model store is shared across adapters and platforms; the runtime tree is
  not. Weights stay under `AI/models`, runtimes under `AI/runtimes`.

## 5. Component catalogue

These are architectural candidates, not mandatory implementation names.
"Exists" means real code with tests today; "Extend" means the component exists
but needs contract or platform work; "New" means nothing ships yet.

| Component | State | Responsibilities | Inputs → outputs | Failure / cancel | Memory and platform |
|---|---|---|---|---|---|
| Face Analysis Engine | Extend | Detect faces, landmarks, confidence, regions; produce analysis results; never modify pixels. | oriented image → face records + regions + confidence | no face is a valid result; a detector failure is reported, not retried silently; cancel between images | Small; Vision on macOS; Windows backend undecided |
| Segmentation Engine | Extend | Person/background alpha exists (Vision, balanced); add subject/object and clothing/hair classes, click-to-mask refinement and a fine matte. | image + point/box → alpha mask at working resolution | low-confidence mask is rejected, not applied; cancel drops the job | Small–medium; Vision today; ONNX/MLX/Core ML candidates for classes and matting |
| Mask Management | Exists | Store, version, transform, feather, boolean operations, stale invalidation, derived raster cache. | strokes/box/parameters + frame → v5 mask record + optional raster | a different frame refuses the mask; a bad digest recomputes | CPU; shared by both hosts |
| Portrait Retouch Engine | Extend | Skin/texture, eye, teeth, lip, brow, tone and detail operations with intensity; identity preservation. | image + face regions + parameters → rendered pixels | bounded strength; missing landmarks skip that region with a message | Classical today; AI augmentation optional |
| Healing Engine | Extend | Spot and brush repair, content-aware fill, object removal, selection-based repair. | image + mask/points → patch + alpha | no half-edit; cancel deletes job output | MI-GAN/LaMa class small; generative fallback heavy |
| Background Engine | Extend | Background replacement over the existing person matte; needs matting/edge refinement, background detection and blend controls. | image (+ replacement) → subject alpha + composite | refusal when no matting model; cancel removes temp | Small–medium; Vision person matte today, learned matte candidate |
| Generative Editing Engine | Extend | Prompt-based local edit, fill, replacement, scene change, outpainting. | image + mask/box + prompt + seed → patch + alpha or whole-frame layer | 512 px patch contract; a masked request routed to full-frame is refused; timeout and cancel | Heavy; 4.6 GB FLUX class today, optional |
| Upscaling Engine | Exists | 2×/4× reconstruction, tiled inference, face-aware option, batch. | image pixels → enlarged image | size limit refuses up front; cancel stops the job and deletes output | Medium–high; Swin2SR today; tiling required |
| Enhancement Engine | New | Denoise, deblur, detail recovery, low-light, color/contrast/exposure correction at unchanged dimensions. | image + strength → same-size image | strength floor; refusal if model missing; cancel | Small–medium; must stay distinct from upscaling |
| AI Enhancer (product layer) | New | One user-facing, same-size operation with a strength control: an ordered pipeline of the stages below, chosen per subject type, previewed before commit. Not an upscaler and not a synonym for any single slider. | image + subject hint + strength → same-size enhanced image | each stage has its own default and failure mode; a failed stage never reports a blank "success" | Composes Enhancement and Restoration; one heavy job at a time |
| Restoration Engine | New | Old/degraded photo repair, scratch/noise/blur recovery, face restoration. | image (+ regions) → repaired image at same size | conservative defaults; no invented identity; cancel | Medium; may share stages with enhancement |
| AI Runtime Manager | Exists (macOS) | Install, validate, activate, recover, remove, lease and fence the inference runtime. | archive + package metadata → active runtime | rollback keeps the previous runtime; recovery is explicit | Disk; macOS only today |
| Model Manager | Exists | Catalog, plan, consent, download, verify, remove, capability reporting. | model id → installed state + capabilities | failed hash leaves no installed model; cancel is acknowledged on exit | Disk; shared store |
| Resource and Memory Manager | New | Budgets, sequential heavy jobs, residency, unload, memory-pressure response. | job demand + available memory → admit/queue/unload | OOM becomes a clear refusal, never a crash | Host-side; target 16 GB |
| Inference Job Scheduler | Partial | One job at a time today; needs queueing, priorities and cancellation latency guarantees. | job requests → ordered execution | cancel in flight; no silent requeue | Host-side |
| Platform Acceleration Adapters | Partial | Translate contract jobs to a concrete runtime; report capabilities. | contract job → artifact files | adapter failure maps to a contract error | macOS worker; Windows ORT candidate |

**Do not create** a separate abstraction layer for every engine before two
implementations exist. The classical engines stay where they are; the contract
is added where a model boundary already exists.

**Dependencies and tests.** Every engine depends on the model store and one
adapter, never on another engine's internals; the Enhancer composes engines
through the contract. Each component's test surface is its contract: artifact
identity, the outside-the-box pixel rule, mask/geometry invariance across crop
and turn, cancellation at each stage, typed errors, and a corpus check for
quality claims. A component without a measured corpus can ship correctness
tests but not a quality claim.

## 6. Shared AI contracts

The contract is the only thing both hosts and all future adapters share. It is
deliberately smaller than any SDK.

### 6.1 Job request

A request names a capability, not a model:

| Field | Meaning |
|---|---|
| `kind` | `analysis`, `segmentation`, `mask`, `inpaint`, `generative_edit`, `upscale`, `enhance`, `restore`, `matte` |
| inputs | image path (working copy), optional mask path, optional points/box in a declared space |
| parameters | strength, steps, patch size, seed, feather/dilate (with units), prompt |
| constraints | output size, tile limit, deadline |
| provenance | requested capability; the adapter chooses the model and returns its identity |

### 6.2 Result

Every result is files plus metadata:

- artifact paths (patch/alpha, whole image, mask, upscaled image);
- the rectangle the artifact may affect, in source-normalized top-left space;
- `outside_pixels_identical` where the engine can promise it;
- model identity, version and weight digest when available;
- seed, parameters and elapsed time;
- confidence or a per-region quality report where the capability produces one.

### 6.3 Rules

- **Coordinates.** All persisted geometry is source-normalized, top-left,
  upright and uncropped ([PROJECT_SCHEMA_V5.md](PROJECT_SCHEMA_V5.md) §4).
  Adapters may use their own space internally and must translate at the edge.
- **Mask units.** Feather and dilation are stored only once their unit is
  verified; today the worker's pixel units are passed but not written into the
  document ([PROJECT_SCHEMA_V5.md](PROJECT_SCHEMA_V5.md) §10).
- **Provenance is not schema.** Model identity and parameters live beside the
  artifact, not in a new project key. This keeps v5 stable and lets a later
  schema version adopt provenance deliberately.
- **Unknown capabilities are refused, not guessed.** The existing
  `requiredFeatures` guard is the model to follow.
- **Cancellation is end-to-end.** The host stops waiting, asks the adapter to
  drop the job, and deletes the working copy; an adapter that cannot cancel
  quickly must report that latency instead of claiming instant stop.
- **Errors are typed.** Missing helper, missing model, licence refusal,
  invalid input, out of memory, timeout, cancelled and internal failure are
  distinct, so the UI never turns a licence refusal into "try again".

## 7. Language and runtime decisions

Languages and inference runtimes are evaluated separately.

### 7.1 Languages

| Language | Role | Evidence and boundary | Verdict |
|---|---|---|---|
| Swift | macOS host, `StudioCore`, C ABI, future native inference | The whole macOS app and the shared core are Swift; the boundary gate keeps `StudioCore` Foundation-only. | **Keep.** No alternative needed. |
| Python | Inference worker on macOS | Already packaged as a self-contained 1.29 GiB runtime with pinned wheels, licence inventory and 60 worker tests (outside this repo). It is the only working inference path today. | **Keep for 1.1** behind the contract; do not expand its surface without a measured reason. |
| C# | Windows host | WPF host, 370 headless checks and the MSI path exist; it consumes shared logic through the C ABI. | **Keep.** |
| C / C++ | Runtime dependency only | ONNX Runtime and native model libraries are C/C++. No first-party C++ component is justified now. | **No new first-party code.** |
| Rust | — | No measured benefit over the existing Swift/Python split for this milestone. | **Not introduced.** |
| Other | — | No component has a boundary that would justify it. | **Not introduced.** |

Any future language must state the component, the measurable benefit, the
maintenance owner and the integration cost before it is added.

### 7.2 Runtimes

| Platform | Runtime | State | Role |
|---|---|---|---|
| macOS | PyTorch (MPS) inside the worker | VERIFIED as the current inference stack; current PyTorch MPS documentation states macOS 15.0+, while the app targets macOS 14 — whether the pinned wheel falls back to CPU on 14.x is **NOT VERIFIED** | Existing generative, inpaint, upscale and mask jobs |
| macOS | MLX / mflux | VERIFIED as bundled wheels; model-specific use **NOT VERIFIED** | Candidate Apple-silicon fast path for diffusion-class work; no Neural Engine |
| macOS | ONNX Runtime | VERIFIED as a bundled wheel; job use **NOT VERIFIED** | Candidate portable small-model path; CPU EP is the honest baseline |
| macOS | Core ML | Native OS framework; per-model conversion **NOT VERIFIED**; conversion and per-op ANE placement are per-model work | Candidate for small face/segmentation/enhancement models and the Neural Engine; requires a measured comparison before adoption |
| macOS | Metal / MPSGraph | Underlies PyTorch MPS, MLX and Core ML | No first-party Metal kernels are planned; hand-built graphs would re-implement layers |
| Windows | ONNX Runtime (CPU) | Available as a library; no AI integration exists | Mandatory baseline that works on CPU-only CI |
| Windows | ONNX Runtime DirectML | Documented as "sustained engineering" with new work moved to Windows ML; opset limits; **NOT VERIFIED** on any hardware | Fallback only, never a requirement |
| Windows | Windows ML (ORT-based) | The current Microsoft direction; CPU and legacy DirectML anywhere, vendor/NPU EPs need Windows 11 24H2; **NOT VERIFIED** inside a per-machine MSI | Recommended Windows runtime, contingent on the dependency-policy decision |

### 7.3 Recommendation

**RECOMMENDATION — keep the existing Python worker as the macOS inference
layer for 1.1, behind a capability contract, and treat native Core ML/MLX and a
Windows ONNX adapter as separately gated alternatives.** Evidence: the worker
is the only path with measured inference (4× upscale, generative patch), a
recorded runtime and model licence inventory, a packaged runtime and a
privacy-audited network surface. Rewriting it now would spend the milestone on
an unmeasured alternative and would not add a single capability.

The gate for changing any single component is a measured comparison on the
target M3: identical inputs, equal or better quality, lower peak memory or
latency, and a maintenance path that does not duplicate the worker. Core ML is
the most likely first native win for small models (face landmarks, face
parsing, matting, enhancement) because the Neural Engine suits them; a
diffusion-class model is unlikely to move first. A sensible first port is
Swin2SR, gated on matching the measured MPS result and an image-diff parity
check — not SAM 2 or FLUX.

Windows is not forced to share the Python bundle. **RECOMMENDATION — a C#
adapter on Windows ML (ORT-based) with the CPU EP as the only mandatory
provider, and DirectML as opportunistic acceleration.** The contract allows
the same ONNX weights; the host's separate worker process is the right shape
so an ORT fault cannot kill the WPF process. Two real costs: the Windows host
currently has no package dependency by design, and Windows ML adds a
Windows-specific package, native runtime payload and size to the per-machine
MSI. Whether Windows
ships a Python sidecar, an ONNX adapter or both remains an owner decision in
W5; no parity claim may be made before a Windows run proves the workflow.

## 8. Data flow

**Analysis (no pixel change).** Open → decode and orient → Vision/engine
analysis → face records and regions → overlay and inspector → the document
stores only what the owner saves (selected face, masks, analysis settings).

**Mask.** Owner draws or boxes → optional click-to-mask (`mask` job) → mask
record with strokes/box/parameters → derived raster cached by mask id → v5 save
→ export consumes the geometry.

**Local AI edit.** Selection/mask → working copy and mask PNG → `patch_edit` →
patch and alpha adopted into the edit store atomically → document gains an
`AIEdit` value → compositor draws it in preview and export.

**Whole-frame edit.** Prompt → `patch_edit` with `full_frame` → whole image →
opaque alpha → a layer covering the original → the same undo/export path.

**Upscale.** Export plan asks for a larger long edge → render at source size
(no callouts) → `upscale` with tile progress → enlarged pixels → callouts and
watermark applied at the new size → atomic write.

**Proposed enhancement/restoration.** Same-size render → `enhance`/`restore`
with strength → same-size result → layer or replacement stage → export. The
product must not call this "upscale". The **AI Enhancer** is the user-facing
operation over these jobs: general, portrait, face, low-light and old-photo
presets choose which stages run (tone/exposure, noise, deblur, detail, colour)
and their defaults; the owner adjusts one strength, sees a before/after and
commits. Each stage remains a separate contract with its own failure mode, so
a preset cannot hide which model touched the photo.

**Proposed background.** Image → `matte` → subject alpha → composite over a
solid, an image or a generated background → layer with edge blending. A
generated background is a separate generative job, not part of matte.

**Temporary data.** Job working copies live in the helper's job folder and are
deleted by the host after adoption; the helper trims its own folders. A failed
or cancelled job leaves no document change.

## 9. Resource management for the M3 16 GB target

These are recommendations to be measured in W5; none is a shipped guarantee.

1. **Serialize heavy jobs.** One generative, inpaint, upscale or restoration job
   at a time; the UI queues and shows position. Small vision jobs may share the
   helper only if measured memory and latency stay within budget.
2. **Residency tiers.** Small models (landmarks, parsing, matting, ~tens to
   low-hundreds of MB) may stay resident; heavy models (4.6 GB class) load on
   demand and are unloaded after an idle window. The idle window is a parameter
   to measure, not a constant to guess.
3. **Tiled upscaling.** The upscale job already reports tile progress and
   enforces a size limit; tile size and overlap must be chosen by measurement,
   not by convenience.
4. **Bounded patches.** Generative edits stay at a bounded patch (512 px today)
   with context; a request too large for the patch is refused or explicitly
   routed to a whole-frame job the owner asked for.
5. **Memory-pressure behavior.** Before a heavy load, compare the estimate to
   available memory; refuse with a clear message or unload another model. An
   allocation failure must surface as an error, never as a crash.
6. **Responsiveness.** Inference never runs on the UI thread; progress polls
   are bounded; the cancel control is always reachable; the app remains usable
   for browsing and classical edits while a job runs.
7. **Thermal behavior.** Long generative work on a fanless Air is expected to
   throttle. The benchmark plan must record wall time and note throttling
   rather than claim desktop-class throughput.
8. **Recovery.** A helper crash or app crash leaves no half-edit: adoption is
   atomic, the document changes only after both files exist, and a missing file
   is reported instead of drawn.

## 10. Privacy and security

- **No network in the job path.** The privacy audit measured zero endpoints
  while idle and during a real upscale, and only consented model downloads use
  HTTPS. Any future adapter must keep this property and be audited again.
- **Consent before bytes.** A runtime or model download shows name, size,
  licence and a hash prefix; the full hash is verified after download. No
  silent download, no background fetch.
- **Weights are never redistributed** inside the app; the catalog names an
  official source and a licence, and the licence is shown before download.
- **Integrity.** Catalog SHA256 is the authority where present. Entries without
  a size/hash (SAM 2.1 tiny today) must be treated as unverifiable until the
  catalog is completed.
- **Provenance.** The worker source must become reproducible (W5 requirement).
  Until then, every worker-internal claim stays **NOT VERIFIED**.
- **Temporary files.** The host removes the upscale working copy and its
  folder on every path, and sweeps stale export temp siblings older than 24 h
  (`ExportService.swift:204-242`, `:320-342`). Beyond that, cleanup is not
  proven: `clearWorkingCopies()` has no call site and the helper's own job
  cleanup is **NOT VERIFIED**. AI-01 records this gap instead of promising a
  clean working directory; closing it belongs to W5.
- **Logs.** The helper log can contain local paths; it stays inside the app's
  support folder and is never uploaded.
- **Signing.** macOS builds are ad-hoc signed and not notarized; AI runtime
  archives must be verified by hash because Gatekeeper cannot vouch for them.

## 11. Failure, cancellation and recovery

| Failure | Required behavior |
|---|---|
| Helper missing | AI actions say the helper is not installed and offer the existing setup path; classical tools keep working. |
| Model missing | The action names the model and opens Manage Models; no failed job. |
| Licence refusal | The worker's typed error is shown as a licence problem, not a crash or a retry loop. |
| Unsupported capability | The action is hidden or disabled with a reason; never a fake success. |
| Out of memory | Job refused before load when predictable; otherwise an explicit error and cleanup. |
| Timeout | Job cancelled, working copy deleted, document unchanged. |
| User cancel | Host stops waiting and asks the adapter to drop the job; latency is reported if the adapter cannot stop instantly. |
| Helper crash mid-job | Job fails; the next call restarts the helper through the existing probe; no half-edit exists. |
| Corrupt or missing artifact | The edit is reported missing, not drawn as blank or stale pixels. |
| Damaged model | Verify names the file; download and replace is the repair. |
| Interrupted runtime install | Transaction recovery completes or rolls back explicitly; a failure is never reported as recovered. |
| Stale mask | A mask whose frame differs from the open photo is not applied; the host says so. |
| Missing derived raster | Geometry is authoritative; recompute or redraw. |

## 12. Compatibility

- **Schema v5 is unchanged.** AI-01 adds no project keys. AI artifacts remain
  files beside the project; provenance is recorded beside the artifact.
- **Face identity vs mask geometry.** A mask may name a `faceId`; a face record
  never contains a mask. Neither is tied to a detector model. Reopening runs
  detection again and re-attaches identities by box overlap
  ([PROJECT_SCHEMA_V5.md](PROJECT_SCHEMA_V5.md) §1, §10).
- **Windows.** The C ABI carries JSON only: 13 exports, none returns pixels or
  masks; mask and face-id JSON is opaque cargo inside project read/write. The
  Windows host preserves masks and AI edits and names 19 categories of edit it
  cannot render (`DocumentModel.UnsupportedEdits`): heal spots, stickers, AI
  patches, masked selections, analysis callouts, skin retouching, skin finish,
  teeth whitening, eye enhancement, face reshaping, makeup, a look, film
  grain, curves, HSL colour, body adjustments, background adjustments, hair
  adjustments and lens tint — rather than exporting them silently.
  It must not claim to create, resolve or render them until a real Windows
  path exists.
- **Intel Macs.** The helper is arm64-only; AI tools remain unavailable there.
  This document does not change that.
- **Same-size image replacement** is not detectable from the mask frame and is
  a documented limitation, not a promise.
- **Old projects** keep their version; a document that gains masks or face
  identities saves as v5 through the existing deliberate upgrade.

## 13. Risks and open decisions

| Risk / decision | Impact | Current position |
|---|---|---|
| Worker source not in the repository | Every worker-internal claim is unverifiable; a fresh clone cannot reproduce inference. | W5 must bring the source into the repository or a reproducible dependency; **NOT VERIFIED** today. |
| No approved protocol-v2 runtime package | No on-demand runtime; AI exists only in builds that bundle the helper. | Installer stays disabled; do not invent metadata. |
| Windows AI backend | No face landmarks, no masks, no ORT integration. | Owner decision required for a distributable landmark model and weights; DirectML not verifiable on CPU-only CI. |
| 4.6 GB-class generative model on 16 GB | Load time, peak memory and thermal behavior are not measured for a full capability set. | Treat as opt-in, one job at a time; measure before promising latency. |
| Weight licences | Code licences do not cover weights; several candidates have non-commercial weights. | Every recommended weight needs its own verified licence entry; unverified terms are excluded from shipping candidates. |
| Enhancement vs upscaling vs restoration | Users can be misled if operations share a model without distinct contracts. | Separate job kinds, separate inputs/outputs and separate quality criteria; shared internal stages are allowed. |
| No measured benchmark suite for AI | Feasibility classes would be guesses. | [AI_11_ROADMAP.md](AI_11_ROADMAP.md) defines the measurement plan; until it runs, M3 classifications are **ESTIMATES**. |
| AI on Intel / low-memory machines | Feature availability differs by hardware. | AI remains Apple-silicon-only for now; other platforms are gated by measurement. |

## 14. Architecture decision records

**ADR-1 — Engine-independent AI contract with per-platform adapters.**
*Context:* two hosts, one worker today, a possible native path tomorrow.
*Decision:* contracts name capabilities and artifacts; adapters own models and
runtimes. *Consequences:* the schema and UI survive a runtime change; each
adapter must implement provenance and cancellation. *Status:* accepted for
design review.

**ADR-2 — AI output is a non-destructive layer.**
*Context:* undo, preview/export parity and recovery already rely on layers.
*Decision:* patch plus alpha for local edits, a whole-frame layer for
reimagine; store artifacts outside the project. *Consequences:* no pixel
mutation, clean undo, but the edit store must be cleaned and reported when
missing. *Status:* accepted (already implemented).

**ADR-3 — Upscaling is an export operation, not a canvas mutation.**
*Context:* the current pipeline renders at source size and upscales before
callouts. *Decision:* keep it; 2× and 4× are output choices. *Consequences:*
preview remains accurate; a user cannot "zoom in and keep editing" at 4×
without a separate decision. *Status:* accepted.

**ADR-4 — No new language and no wholesale runtime migration in AI-01.**
*Context:* Python worker works and is measured; native alternatives are
unmeasured. *Decision:* keep the worker behind the contract for 1.1; adopt
Core ML/MLX or an ONNX adapter only per component, with a measured gate.
*Consequences:* no rewrite cost now; two adapter paths to test later.
*Status:* recommendation.

**ADR-5 — Schema v5 stays the single project format.**
*Context:* masks, face identities and AI edits already have homes. *Decision:*
add no AI-specific project keys; provenance lives beside artifacts.
*Consequences:* no migration; a future schema change is a deliberate version.
*Status:* accepted.

## 15. Definition of done for this document

This architecture covers every capability in AI-01 §3 (A–H), states what
exists and what is proposed, separates languages from runtimes, keeps W5 as an
implementation milestone, preserves schema v5 and the existing worker, and
names the unverified items that must be closed before implementation.
