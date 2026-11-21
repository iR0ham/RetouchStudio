# Product Capability Matrix — post-first-release scope

Status date: 2026-11-21. Branch basis: `main` @ `9708860`.
Owner direction of record: [POST_RELEASE_ROADMAP.md](POST_RELEASE_ROADMAP.md) (groups A–I).
Companion document for *shipping* scope: [PRODUCT_ACCEPTANCE_MATRIX.md](PRODUCT_ACCEPTANCE_MATRIX.md).

This matrix is the single planning surface for capabilities that are **not** part of the
first release. It exists so that roadmap decisions are made against measured code state
instead of feature-list optimism. Nothing in this file authorises implementation work: the
first release keeps priority, and no row here may enter its critical path.

## How a row is judged

Each row carries the ten attributes the owner required. They are packed into seven
columns, mapped explicitly:

| Owner's attribute | Where it lives in a row |
| --- | --- |
| 1 current status | `Status` |
| 2 source files and architectural components | `Source / components` |
| 3 whether the UI exists | `UI · Works`, first part |
| 4 whether actual functionality works | `UI · Works`, second part |
| 5 automated test coverage | `Evidence`, `AT` / `CI` markers |
| 6 manual acceptance evidence | `Evidence`, `MA` marker (`—` when none exists) |
| 7 macOS support status | `Status` + `Known limitation` (macOS is the reference host; deviations are named) |
| 8 Windows support status | `Windows` |
| 9 dependencies and blockers | `Depends on / blockers` |
| 10 known limitations | `Known limitation` |

Statuses: `Implemented` · `In Progress` · `Planned` · `Not Started` · `Blocked` ·
`Needs Validation`.

Evidence markers: **AT** automated test in the repo · **CI** the test is asserted by a
green hosted run · **MA** manual acceptance observed in the running application ·
**DOC** a document asserts it and nothing reproducible backs it · **HW** hardware
measurement (harness/benchmark) · **—** no evidence.

Rules applied, per the owner's directive:

- A capability is **not** `Implemented` because a UI surface, an interface contract, a
  mock, a placeholder or a CI job exists. `Implemented` requires a real code path plus
  `AT` evidence of it working.
- AI capabilities additionally require **genuine inference evidence**. There is none in a
  checkout: `AIRuntime.package` is `nil` (`Sources/RetouchStudio/Core/AIRuntime.swift:40`),
  so no shipped-runtime inference has ever been recorded from the application UI. Every
  group D and group F AI row therefore sits at `Blocked` or `Not Started`, regardless of
  how complete its worker code looks.
- `MA` is only asserted where an acceptance run is recorded in
  `PRODUCT_ACCEPTANCE_MATRIX.md` or a task result. A row can be `Implemented` with no
  `MA`: that means *tested, not yet accepted by a human in the running app*, and it is
  flagged as such rather than promoted.

## Confidence and known gaps in this matrix

Read this section before quoting any number from it.

- **Windows column is CI-only.** `windows-2025` runners prove build, engine and UIA
  behaviour; no physical Windows machine has been used. `verified` here means "green on a
  hosted runner", which understates driver/GPU-specific risk.
- **`MA` coverage is thin by design.** First-release acceptance evidence concentrates on
  shipping scope; groups A–I items outside that scope mostly lack human acceptance.
- **Headline counts disagree with the row data.** The research inventory that produced
  this matrix summarised itself as "12 implemented, 21 partial, ~114 of 152 absent". The
  rows it delivered number **128** (20 A, 13 B, 17 C, 13 D, 13 E, 9 F, 14 G, 15 H, 14 I),
  and their statuses are **32 Implemented, 21 In Progress, 7 Blocked, 68 Not Started,
  0 Needs Validation**. The rows are authoritative; that headline is not. Do not reuse the
  "12 of 152" figure. (Recompute with the table itself if this file changes.)
- **`Needs Validation` is currently unused.** Every uncertain row either has an artefact
  that proves behaviour (`AT`/`CI`/`HW`) or has no code path, so it lands in
  `Not Started`/`Blocked`. Reserve that status for code that claims to work and has no
  reproducible evidence — the open documentation conflicts listed below are the candidates.
- **`Docs/TECHNICAL_AUDIT.md` is stale in the optimistic-negative direction** ("autosave
  absent" §3.1, "crop not in history" §3.1, "no CI configuration" §9.5 — all contradicted
  by `EditorModel.swift:2805-2836`, `StudioCore/DocumentValue.swift:338` and
  `.github/workflows/ci.yml`). Newer documents and the code win.
- **Two documentation conflicts remain open** and are recorded here rather than in the
  first-release queue, because the first release keeps its priority:
  `W5_ROADMAP.md:164-169` asserts `upscale.4x` macOS support from a recorded run whose
  evidence ledger is not in the repository (so the claim is not reproducible by a reader),
  and `FINAL_PRODUCT_COMPLETION_AUDIT.md` Gate C says "no profile write" while JPEG/PNG do
  embed a generated sRGB profile and TIFF stays untagged. This matrix follows the code, not
  those two sentences. Both are candidates for the capability-evidence ledger proposed in
  `POST_RELEASE_ROADMAP.md` §8.2 (P1).
- **Inventory basis is HEAD `40b157f` plus documentation**, and the owner's working tree
  has uncommitted changes in `CompareCanvas.swift`, `ModelTests.swift` and a new
  `ToastPlacement.swift`; those were never written to, and rows touching compare/UI were
  read as committed code plus those local edits.

## A. Professional core editor — strategic priority: Critical

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Layer system | Not Started | none; flat `RetouchProject` (`Sources/StudioCore/ProjectDocument.swift:10-60`) | no · no | — | absent | schema v6 + render graph + asset store (roadmap §5) | one flat edit record over one image |
| Layer groups | Not Started | none | no · no | — | absent | layer system | — |
| Layer masks | Not Started | `MaskRecord` (`Sources/StudioCore/Mask.swift:73-94`) is a scoping record, not a layer property | no · no | — | records preserved (`DocumentModel.cs:236`) | layer system; mask ownership moves to layers | masks float independently of any stack |
| Adjustment layers | Not Started | fixed pipeline order (`Sources/RetouchStudio/Core/ImageProcessor.swift:885-1008`) | no · no | — | absent | render graph with per-stage nodes | order is compiled, not user-editable |
| Blend modes | Not Started | only `CGBlendMode.screen` for histogram painting (`Views/HistogramView.swift:85`) | no · no | — | absent | compositor | no compositing model at all |
| Layer opacity / fill | Not Started | mask-level `opacity` only (`Mask.swift:47`) | no · no | — | absent | layer system | — |
| Non-destructive editing | Implemented | `DocumentState` (`StudioCore/DocumentValue.swift:332`), re-render from source (`ImageProcessor.swift:129-193`), v5 project stores edits | yes · yes | AT CI MA | renders a subset | — | flat model: non-destructive but not reorderable |
| Smart objects | Not Started | nearest primitive `BackdropStore` / `AIEditStore` | no · no | — | absent | asset store + layer system | — |
| Advanced undo / redo | Implemented | `EditorModel.swift:387-420` (100 steps, 350 ms coalescing, redo branch), C ABI `HistoryABI.swift` | yes (menu) · yes | AT CI MA | verified (55 host checks) | needs tree semantics when layers land | no non-linear history |
| History panel | Not Started | none; undo is keyboard/menu only | no · no | DOC | absent | undo model (exists) | a cheap win independent of layers |
| Crop | Implemented | `Crop.swift`, `CropOverlay.swift`, `ImageProcessor.swift:149-165` | yes · yes | AT CI MA | verified (UIA drag) | — | aspect presets, not a full constraint matrix |
| Perspective correction | Not Started | prompt string only (`QuickEdit.swift:53`) | no · no | — | absent | transform + resampling infrastructure | — |
| Transform | In Progress | turn / mirror / straighten / crop | partial · partial | AT CI | verified for the subset | free-transform maths | no scale/skew/arbitrary rotate handle UI |
| Warp | In Progress | `FeatureReshaper.swift:8-10` local warp kernels | no tool · engine yes | AT | absent | mesh infrastructure (shared with Liquify) | slider-driven only, no freeform warp |
| Professional brush engine | In Progress | `HealOverlay.swift`, `AISelectOverlay.swift` | partial · yes (heal) | AT | absent | stroke/dynamics model + compositor | no paint engine, no brush dynamics/pressure |
| Clone stamp | Not Started | heal is content-aware synthesis with no sampled source (`ImageProcessor.swift:604-654`) | partial (heal) · no clone | — | absent | brush engine | nearest feature is Heal |
| Dodge and burn | Not Started | no implementation in `Sources` | no · no | — | absent | brush engine + mask scoping | — |
| Gradient tool | Not Started | vignette only | no · no | — | absent | brush/paint engine | — |
| Liquify | In Progress | `FeatureReshaper.swift:337-554` | yes (as sliders) · yes | AT | absent | mesh warp (same as Warp) | no push/pucker/freeze/edge tools |
| Face reshape | Implemented | `FeatureReshaper.swift:337-520`, `ImageProcessor.swift:858-870` | yes · yes | AT | absent | landmark quality | single largest face only |

## B. Advanced selection and masking engine — strategic priority: Critical (shared infrastructure)

The owner's instruction is explicit: selection/masking is **one shared engine**, not
per-feature copies. Today there is no selection abstraction at all, so B is the load-
bearing dependency for A (layer masks), D (hair/skin/relight) and F (removal/fill).

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Object selection | Not Started | none outside Quick Edit | no · no | — | absent | selection engine (B1) | — |
| Quick selection | Not Started | none | no · no | — | absent | B1 | — |
| Magic wand | Not Started | none | no · no | — | absent | B1 (region growing) | — |
| Select subject | Not Started | Vision person segmentation exists internally (`SceneEngine.swift:101-146`) but only feeds Body/Background | no · engine only | AT | absent | B1 exposure of an internal mask as a selection | the hard part already exists, unplumbed |
| Select sky | Not Started | none | no · no | — | absent | B1 | — |
| Select hair | Not Started | hair region masks for makeup (`MakeupEngine.swift`) | no · engine only | AT | absent | B1 + fine-detail matte | no hair selection surface |
| Select people | Not Started | none | no · no | — | absent | B1 + face/pose analysis | — |
| Refine edge | In Progress | SAM 2 refine for Quick Edit (`AIMaskSelection.refined`, `EditorModel.swift:1690`), feather/gates | partial · code only | — | absent | B1; the current refine is AI-backed and blocked | no non-AI edge-adjust UI |
| Select and Mask workspace | Not Started | none | no · no | — | absent | B1 + mask rendering | — |
| Colour range selection | Not Started | none | no · no | — | absent | B1 | — |
| Luminosity masks | Not Started | none | no · no | — | absent | B1 + adjustment layers (otherwise useless) | — |
| AI semantic selection | Blocked | `mask.click` → SAM 2.1 tiny (`worker/retouch_ai_worker/capabilities.py:54`, `engine.py:586-598`), point/brush/box UI (`AIMask.swift`) | yes (Quick Edit) · not observed | — | absent | approved runtime + `sam2` pinned in the worker lock | never demonstrated end-to-end |
| Advanced mask refinement | In Progress | `Mask.swift:73-127` strokes, box, invert, feather, raster hash, persisted in v5 | partial · yes (persistence) | AT CI | records preserved | B1 | no dedicated refinement surface |

## C. Professional colour management — strategic priority: High

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Curves | In Progress | 3-anchor curve (`Adjustments.swift:142-149`) | yes · yes | AT | absent (black/white only) | editable spline + per-channel curves | not a pro curves tool |
| Levels | In Progress | auto-levels in `LookEngine.applyLevels`, driven by Auto Analyze + blacks/whites | partial · partial | AT | as blacks/whites | Levels panel with gamma | — |
| Exposure | Implemented | `Adjustments.exposure`, `ImageProcessor.swift:885-1008` | yes · yes | AT CI MA | verified (cross-host MAE 0.01) | — | 8-bit display precision |
| Contrast | Implemented | same | yes · yes | AT CI | verified | — | — |
| White balance | In Progress | `warmth` only | yes · yes | AT | verified (warmth) | tint axis + eyedropper | no neutral picker |
| Hue and saturation | In Progress | global saturation + per-band hue | yes · yes | AT | partial | global hue rotation | — |
| Vibrance | Implemented | `Adjustments.vibrance` | yes · yes | AT CI | verified | — | — |
| Colour balance | In Progress | split tone (`splitTone`) | yes · yes | AT | absent | per-shadow/mid/highlight CMY | — |
| HSL | Implemented | 8-band H/S/L (`Adjustments.swift:153-158`) | yes · yes | AT | absent | — | band count fixed at 8 |
| Colour grading | In Progress | 6 film looks + 40 presets (`Look.swift`, `Adjustments.swift:754-1007`) | yes · yes | AT | absent | colour wheels + midtone range | preset-based, not grade-based |
| Selective colour | Not Started | none | no · no | — | absent | C pipeline stage | — |
| LUT support | Not Started | internal 32³ cubes only (`LookEngine.swift:240-290`) | no · no | — | absent | `.cube` import + LUT bake-in path | no user LUTs |
| RAW colour processing | Not Started | no RAW/DNG decode path (`FINAL_PRODUCT_COMPLETION_AUDIT.md` §3) | no · no | — | absent | decoder dependency + licence review + camera profile handling | see roadmap item P6: RAW *decode* is the real gap, not RAW colour |
| Soft proofing | Not Started | none | no · no | — | absent | ICC output choice (C17) | — |
| Histogram | Implemented | `HistogramView.swift`; Windows `EditorViewModel.cs:191` | yes · yes | AT CI MA | verified | — | RGB/luma only, no readout numerics |
| RGB and CMYK workflow | Not Started | RGB only | no · no | — | absent | colour model conversion engine, ink limits | proposed for removal — see roadmap P9 |
| ICC handling across edit/preview/export | In Progress | working space `extendedLinearSRGB` (`ImageProcessor.swift:117`), source profile carried, sRGB output policy (`OUTPUT_COLOR_POLICY.md`), JPEG/PNG embed generated sRGB | yes (policy, no picker) · partial | AT CI MA | partial (decode→sRGB; TIFF untagged) | profile picker + render-policy change; currently `RenderPolicy.swift:146-149` forces `.sRGB` on every export | wide-gamut colours clip; docs/UI must not promise profile preservation (PM decision D1: truthfulness before pixels) |

## D. Advanced AI image processing — strategic priority: Critical

Owner constraint honoured: **Upscaler and Enhancer are separate capabilities with
separate validation.** At code level they are not the same mechanism — and only one of
them exists. `upscale.4x` is model-backed (`swin2sr-x4`, `capabilities.py:65`) with a
dedicated memory-banded export path (`RenderPolicy.swift`, `ExportService.swift:204`);
`enhance.photo` is a fixed `unsupported` record ("no AI enhancer model",
`capabilities.py:68`) and has no model candidate, so it cannot even be estimated.

**Every row below is unverifiable from the application until the runtime delivery
milestone lands** (`AIRuntime.package == nil`). This is the single largest product risk in
the roadmap and the reason D/F cannot be sequenced as ordinary feature work.

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| AI Upscaler | Blocked | `_job_upscale` (`worker/retouch_ai_worker/engine.py:517`), export toggle (`Views/EditorView.swift:294-316`) | yes, disabled · not observed | AT (worker) HW (harness) | blocked | approved + signed runtime package; Windows ONNX/DirectML evidence | ×4 quality corpus measured at worker level only; in-app ×4 from the UI has never run |
| AI Image Enhancer | Not Started | none; classical Auto Retouch only | no · no | DOC | absent | model selection + per-artefact owner approval + its own quality criteria | deliberately never labelled upscale (`W5_ROADMAP.md:34,49`) |
| AI Denoise | Not Started | none ("denoise" in `EditorModel.swift:1867` is a diffusion loop stage) | no · no | — | absent | runtime + model approval | — |
| AI Deblur | Not Started | none | no · no | — | absent | runtime + model approval | — |
| AI Face Recovery | Not Started | none; `face.parsing` unsupported | no · no | — | absent | Windows landmark model + weights licence | — |
| AI Skin Retouch | Not Started | classical `SkinEngine` only; `portrait.ai` unsupported | classical yes · no AI | — | absent | face parsing model licence | — |
| AI Hair Masking | Not Started | classical hair regions only | no · no | — | absent | runtime + matte model | — |
| AI Relighting | Not Started | none | no · no | — | absent | runtime + depth/normals model | — |
| AI Colorization | Not Started | none | no · no | — | absent | runtime + model approval | — |
| AI Photo Restoration | Not Started | none; `restore.photo` unsupported | no · no | DOC | absent | runtime + model approval | — |
| AI Shadow Removal | Not Started | none | no · no | — | absent | runtime + model approval | — |
| AI Reflection Removal | Not Started | none | no · no | — | absent | runtime + model approval | — |
| AI Image Recomposition | Not Started | prompt "reimagine" edits pixels inside the frame; geometry is untouched | no · no | — | absent | B selection + crop + generative substrate | — |

## E. Advanced portrait retouching — strategic priority: Critical

This is the app's strongest and most differentiating area, and almost all of it is
classical (no runtime dependency). Note that 8 of 13 rows work on macOS only — E is where
the Windows parity debt is most concentrated.

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Natural skin smoothing | Implemented | `SkinEngine.swift`, `ImageProcessor.swift:681-753` with texture-preserve | yes · yes | AT | absent | Windows render parity | dark/fair extremes unmeasured |
| Blemish removal | Implemented | same | yes · yes | AT | absent | Windows parity | — |
| Frequency separation | Not Started | `texturePreserve` blends blur against texture; no HF/LF split | no · no | — | absent | needs A/B layer+mask substrate (P3) | the pro-grade version of smoothing is the missing piece |
| Eye enhancement | Implemented | eye brighten/sharpen/iris/lashes (`SkinEngine`, `MakeupEngine:150-210`) | yes · yes | AT | absent | Windows parity | — |
| Teeth whitening | Implemented | `MakeupEngine`, gated on landmark detection | yes · yes | AT (gate) | absent | Windows parity | — |
| Under-eye reduction | Implemented | `darkCircles` | yes · yes | AT | absent | Windows parity | Lab-space correction still deferred |
| Wrinkle reduction | Implemented | `wrinkle` | yes · yes | AT | absent | Windows parity | — |
| Hair flyaway removal | Not Started | none | no · no | — | absent | B hair selection | — |
| Face symmetry correction | Not Started | reshape sliders exist; no symmetry analysis | no · no | — | absent | landmark analysis | — |
| Body retouching | Implemented | `SceneEngine.swift:100-200`, `FeatureReshaper.swift:430-554` | yes · yes | AT (synthetic) | absent | Windows parity | no real-photo pose acceptance |
| Makeup enhancement | Implemented | `MakeupEngine.swift`, 40 shades | yes · yes | AT | absent | Windows parity | — |
| Skin tone matching | In Progress | `skinToneEvens` evens tone within one subject | yes · partial | AT | absent | reference-sampling model | no match-to-reference-image |
| Portrait lighting | Not Started | skin brighten/shine only | no · no | — | absent | D relighting or a local luminance model | — |

## F. AI object and background editing — strategic priority: High

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Advanced object removal | Blocked | Quick Edit `removeObject` → `patch_edit` (Flux, `engine.py:298`) | yes (sheet) · not observed | — | absent | runtime + approved model + B masks | never demonstrated end-to-end |
| Background removal | Implemented | `backgroundRemove` alpha via Vision person matte (`SceneEngine.swift:274-387`) | yes · yes | AT CI | absent | fine-matte tier blocked (BiRefNet licence) | manual edges, no hair-level matte |
| Background replacement | Implemented | fill colour, stored backdrop, blur/tone (`Adjustments.swift:177-189`, `InspectorView.swift:591-636`) | yes · yes | AT | absent | edge quality from B | falls back to geometric masks |
| AI object selection | Blocked | SAM 2 point/box (`mask.click`) | yes · not observed | — | absent | runtime + `sam2` pin | — |
| Generative fill | Blocked | Quick Edit `reimagine`/patch edit (mflux Flux2, `engine.py:611-631`) | yes · not observed | — | absent | model approval + runtime + memory policy | — |
| Outpainting | Blocked | deliberately refused (`capabilities.py:61-62`) | no · no | DOC | absent | licensed engine decision still open | product declines rather than fakes it |
| Semantic image editing | Not Started | prompt "reimagine" is the nearest path and it is blocked | no · no | — | absent | B + F generative substrate | — |
| Context-aware reconstruction | Not Started | none (LaMa tier licence unresolved, `simple-lama` in no lock) | no · no | — | absent | runtime + model licence | — |
| Localized AI editing | Blocked | `AIMask` + patch edit only (`QuickEditRunner`) | yes · not observed | — | absent | runtime | — |

## G. Professional photo workflow — strategic priority: Medium–High

The application is a single-document shell. All of G is absent except batch export.
Library/asset management is the largest coherent build in the roadmap and the one with the
weakest reuse of existing infrastructure.

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Photo library | Not Started | none; recent files only (`AppSettings.swift:109-176`) | no · no | — | absent | catalog store + thumbnail service | — |
| Folder browser | Not Started | none | no · no | — | absent | library | — |
| Thumbnail grid | Not Started | preset tiles only (`Components.swift:415`) | no · no | — | absent | thumbnail cache (I2) | — |
| Metadata viewer | Not Started | none in `InfoViews.swift`/`InspectorView.swift` | no · no | — | absent | metadata read model (H15 partly exists) | — |
| EXIF viewer | Not Started | none | no · no | — | absent | same | — |
| Star rating | Not Started | none | no · no | — | absent | library | — |
| Color labels | Not Started | none | no · no | — | absent | library | — |
| Flag / reject | Not Started | none | no · no | — | absent | library | — |
| Collections | Not Started | none | no · no | — | absent | library | — |
| Batch rename | Not Started | none | no · no | — | absent | batch planner (H13) | — |
| Batch processing | In Progress | one document applied to many sources (`BatchPlanner.swift`, `EditorModel.swift:2041+`) | yes ("Batch Export…") · yes | AT CI MA | verified | edit presets (H1) for real value | export-only; one crop for all files |
| Multi-image comparison | Not Started | `CompareCanvas` compares before/after of one photo | no · no | — | absent | library | — |
| Side-by-side comparison | Not Started | same | no · no | — | absent | library | — |
| Duplicate detection | Not Started | none in `Sources` | no · no | — | absent | library + perceptual hashing | — |

## H. Professional export system — strategic priority: High

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Export presets | Not Started | last-used settings persisted (`AppSettings.swift:56-67`) | no · no | — | absent | preset model (edit presets exist as a pattern) | "Looks" are edit presets, not export presets |
| JPEG | Implemented | `ExportService.writeResult`, `RenderContract.swift:7` | yes · yes | AT CI MA | verified | — | 8-bit only |
| PNG | Implemented | same | yes · yes | AT CI MA | verified | — | — |
| TIFF | Implemented | same | yes · yes | AT CI MA | verified | — | profile untagged |
| WebP | Not Started | no encoder (`ExportFormat` has 4 cases) | no · no | — | absent | encoder dependency + licence review | platform support varies |
| AVIF | Not Started | no encoder | no · no | — | absent | same, plus HEIF/AV1 licence and platform questions | proposed for deferral (P10) |
| 8-bit / 16-bit output | Implemented | PNG/TIFF 16-bit I/O (`ImageProcessor.swift:1047-1095`) | yes · yes | AT CI MA | verified | — | JPEG stays 8-bit |
| Compression controls | In Progress | JPEG quality only (`supportsQuality`) | yes · yes | AT CI | verified (quality) | per-codec options | no PNG/TIFF compression choice |
| Resize on export | Implemented | long edge 0/4096/2048/1080, never enlarges | yes · yes | AT CI | verified | — | fixed choices, not arbitrary dimensions |
| Output sharpening | Not Started | none (`eyeSharpen` is retouch) | no · no | — | absent | sharpen kernel + media-size rules | — |
| Color profile conversion | In Progress | sRGB policy; JPEG/PNG embed sRGB; P3 source converts on export | yes (policy) · partial | AT CI MA | partial (decode→sRGB) | profile picker; `RenderPolicy.swift:148` forces `.sRGB` | must not be described as profile preservation (PM decision: truthfulness before pixels) |
| Watermarks | Implemented | `Watermark.swift`, `WatermarkRenderer` | yes · yes | AT CI MA | records guarded, not rendered | Windows renderer | text-only, tiled |
| Batch export | Implemented | `BatchPlanner`, per-file isolation, cancel at boundaries | yes · yes | AT CI MA | verified | — | sequential, not parallel |
| Export queue | Not Started | no persistent queue; one batch at a time | no · no | — | absent | background processing (I4) | — |
| Selective metadata preservation | In Progress | allowlist + strip; IPTC/XMP carried on JPEG/PNG (`ExportService`, `MetadataCarry.cs`) | yes (strip toggle) · partial | AT CI MA | partial (no GPS) | composing XMP/IPTC is a deferred owner decision (W4-2) | carry-only: sources with no spliceable block lose those records; TIFF allowlist only |

## I. Performance, reliability and extensibility — strategic priority: Critical / continuous

| Capability | Status | Source / components | UI · Works | Evidence | Windows | Depends on / blockers | Known limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GPU acceleration | Implemented | CoreImage with `.useSoftwareRenderer: false` (`ImageProcessor.swift:115-120`) | no toggle · yes | AT CI MA | partial (WPF compositing; CPU image pipeline) | a cross-platform GPU path for Windows (P2) | **host-scoped `Implemented`**: GPU on macOS only; Windows composites in WPF and processes on CPU. No user toggle |
| Smart caching | In Progress | `cacheIntermediates`, 24-entry LUT cache, debounced preview | no · partial | DOC AT | absent | persistent preview cache | — |
| Proxy and preview rendering | Implemented | 1800 px preview, 1024 px masks, 4096 px export masks | implicit · yes | AT CI MA | verified (preview) | — | fixed sizes, no tiling for very large canvases |
| Background processing | In Progress | helper process + async jobs (`WorkerClient`, `QuickEditRunner`) | partial · yes | AT | absent | a job scheduler for non-AI work | one AI job at a time |
| Multi-image workflow | Not Started | single document (`App.swift`) | no · no | — | absent | document/session rework | blocks most of G |
| Autosave | Implemented | debounced autosave to recovery slots (`EditorModel.swift:2805-2836`) | toggle · yes | AT CI MA | verified (recovery parity) | — | not autosave-to-project-file |
| Crash recovery | Implemented | `Recovery.swift`, `DocumentRestoration`, launch prompt | yes · yes | AT CI MA | verified | — | single window |
| Native project format | Implemented | v5 codec + v3/v4 compatibility (`ProjectCodec.swift`, `PROJECT_SCHEMA_V5.md`) | yes · yes | AT CI MA | verified | v6 will be a breaking schema step | nested unknown records dropped by design |
| Recovery after interrupted processing | Implemented | transactional install/recovery, candidate store | yes · yes | AT CI MA | verified (its own rules) | an open rollback-truthfulness defect | a discarded `.lost` rollback outcome can mislabel the recovered state |
| Configurable keyboard shortcuts | Not Started | fixed keys (`ToolMode.swift`, menu shortcuts) | no · no | — | absent | command registry | — |
| Custom workspaces | Not Started | none | no · no | — | absent | layout system | — |
| Plugin architecture | Not Started | none in `Sources` or `Windows` | no · no | — | absent | stable document + render contracts first | proposed for deferral (P8) |
| Performance monitoring | Not Started | metrics printed by tests only | no · no | — | absent | instrumentation layer | no way to detect a regression in the field |
| Advanced memory management | In Progress | banded upscaler, 40 MP ceiling, `RuntimeUsageLease` | no · partial | HW AT | absent | global memory-pressure response | banding exists only for upscale |
