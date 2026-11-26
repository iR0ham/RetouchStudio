# Post-Release Product Roadmap — RetouchStudio

Status: **registered owner direction, planning-only.** Recorded 2026-11-21 from the owner's
"PM DIRECTIVE — RetouchStudio Post-Release Product Roadmap & Strategic Ownership".
Capability state of record: [PRODUCT_CAPABILITY_MATRIX.md](PRODUCT_CAPABILITY_MATRIX.md).
First-release plan of record, unchanged: [MASTER_PLAN_REMAINING_WORK.md](MASTER_PLAN_REMAINING_WORK.md)
and [W5_ROADMAP.md](W5_ROADMAP.md).

## 1. What this document is, and what it is not

**It is** the long-term product direction for releases *after* the first public release:
the owner's capability groups, the priorities between them, the PM's recommendations on
top of them, and the dependencies and risks that decide the order of work.

**It is not** a scope document for the first release. Binding rules carried forward
verbatim from the directive:

- The first public release remains the immediate priority. Its scope and acceptance
  criteria are unchanged.
- No capability in this roadmap may be added to the first-release critical path.
- Release readiness is never delayed to implement a roadmap feature.
- This document does not authorise an implementation campaign.
- Existing milestones and engineering priorities stay intact.

> The first release must not become an endless development cycle because of the future
> roadmap.

Roadmap work starts only after the first release ships, or on an explicit owner go-ahead
for a named slice. Approval boundaries from §7 of the directive are unchanged and are
restated in §7 below.

## 2. Vision and permanent principles

RetouchStudio evolves into a professional, local-first photo editor combining professional
editing, advanced portrait retouching, AI image enhancement, AI object and background
editing, generative editing, professional workflow and management, and local AI
processing infrastructure.

These are constraints, not preferences, and they bind every phase below:

1. Local-first processing. 2. No cloud inference. 3. No hidden uploads or telemetry.
4. Non-destructive editing wherever practical. 5. Professional output quality.
6. macOS **and** Windows. 7. Transparent capability availability and error reporting.
8. Explicit user consent for new model and runtime downloads.

## 3. Capability groups

Priority is the owner's. "Rows" is the count of capabilities in that group inside the
matrix, which is where status, evidence, source locations, Windows state and limitations
are recorded per capability.

| Group | Priority | Rows | Shape of the work |
| --- | --- | --- | --- |
| A Professional core editor (layers, groups, layer masks, adjustment layers, blend modes, opacity/fill, non-destructive, smart objects, advanced undo/redo, history panel, crop, perspective, transform, warp, brush engine, clone stamp, dodge/burn, gradient, liquify, face reshape) | Critical | 20 | 4 Implemented, 4 In Progress, 12 Not Started. The six layer-system rows have no code path and require the document/render rework in §5 |
| B Selection and masking engine (object, quick, magic wand, subject, sky, hair, people, refine edge, select and mask, colour range, luminosity, AI semantic selection, advanced refinement) | Critical | 13 | 0 Implemented, 2 In Progress, 1 Blocked, 10 Not Started. Owner's rule: **one shared engine, not per-feature copies** — today there is no selection abstraction at all |
| C Professional colour management (curves, levels, exposure, contrast, WB, hue/sat, vibrance, colour balance, HSL, grading, selective colour, LUTs, RAW colour, soft proofing, histogram, RGB/CMYK, ICC) | High | 17 | 5 Implemented, 7 In Progress. The most mature group after portrait; the ceiling is a fixed pipeline order and forced sRGB output |
| D Advanced AI processing (upscale, enhance, denoise, deblur, face recovery, skin retouch, hair masking, relighting, colourization, restoration, shadow removal, reflection removal, recomposition) | Critical | 13 | 1 Blocked, 12 Not Started, **0 Implemented**. Owner's rule honoured: Upscaler and Enhancer remain separate capabilities with independent quality criteria and validation |
| E Advanced portrait retouching (smoothing, blemish, frequency separation, eyes, teeth, under-eye, wrinkles, flyaways, symmetry, body, makeup, skin-tone match, portrait lighting) | Critical | 13 | 8 Implemented — the strongest group and the product's differentiator, and it needs no AI runtime. 8 of those are macOS-only |
| F AI object, background and generative editing (object removal, background removal/replacement, AI object selection, generative fill, outpainting, semantic editing, context-aware reconstruction, localized AI editing) | High | 9 | 2 Implemented, 5 Blocked, 2 Not Started. The blocked five need runtime + per-artefact model approval |
| G Professional photo workflow (library, folder browser, thumbnails, metadata/EXIF, ratings, labels, flags, collections, batch rename, batch processing, comparison, duplicate detection) | Medium–High | 14 | 0 Implemented, 1 In Progress, 13 Not Started. The app is a single-document shell; this is the largest coherent greenfield build |
| H Professional export system (presets, JPEG, PNG, TIFF, WebP, AVIF, 8/16-bit, compression, resize, output sharpening, profile conversion, watermarks, batch export, queue, selective metadata) | High | 15 | 7 Implemented. Closest group to "done"; owner's rule that format and bit-depth claims match real platform capability is already honoured (WebP/AVIF documented as absent) |
| I Performance, reliability, extensibility (GPU, caching, proxies, background processing, multi-image, autosave, crash recovery, native format, interrupted-processing recovery, shortcuts, workspaces, plugins, performance monitoring, memory management) | Critical / continuous | 14 | 6 Implemented, 3 In Progress, 5 Not Started. Reliability rows are strong; extensibility rows (shortcuts, workspaces, plugins, monitoring) are unbuilt |

**128 capabilities: 32 Implemented, 21 In Progress, 7 Blocked, 68 Not Started.** All 32
`Implemented` rows have automated test coverage, while manual acceptance in the running app
is recorded for 17 of them — the other 15 are tested but not yet human-accepted. No AI
capability in D or F is `Implemented`, and none can be until real inference is observed from
the application UI.

## 4. What must be true before the roadmap's value is reachable

Two gates sit in front of most of groups D and F, and in front of parts of B and E, and
they are delivery gates rather than feature work:

- **G1 — distributable local runtime.** `AIRuntime.package` is `nil`
  (`Sources/RetouchStudio/Core/AIRuntime.swift:40`): no AI entry point in the app can reach
  the worker, so no D/F capability can satisfy its own acceptance criteria. This is the
  first-release Runtime Delivery milestone, already in progress, and it must not be
  confused with roadmap scope. Its licensing gate **was** opened by an optional
  `opencv-python` wheel that dragged in a GPLv3-configured FFmpeg build; that wheel was
  removed in `1e4632c` (NumPy replacement in `worker/retouch_ai_worker/morphology.py`),
  which closed the gate. Removal, not argument, was and remains the standing answer. The
  lesson is a standing rule for this roadmap — **every new dependency gets a
  licence inventory and a proof-of-absence scan before adoption.**
- **G2 — per-artefact model approval.** SAM 2 (156,008,466 B) and MI-GAN (28,079,181 B) are
  listed but unverifiable, `sam2` is not in the worker lock, and written licences are still
  outstanding for the fine-matte (BiRefNet-class) and LaMa tiers, plus the Windows landmark
  model. Any D/F row whose blocker names a model is unschedulable until that model has a
  dossier (name+version, provenance, licence and redistribution effect, size, SHA-256,
  platforms, runtime, RAM/VRAM, expected quality, limitations, integration method).

Planning consequence, and it is the most important line in this document: **the entire AI
value proposition of the roadmap is currently hostage to one runtime artefact and a handful
of model licences.** Sequencing that ignores this produces features that cannot be
accepted.

## 5. Architectural dependencies

The decisive constraint is that the current model is a **flat edit record over one source
image**: `RetouchProject` holds `adjustments`, `crop`, `healSpots`, `stickers`, `aiEdits`
and `masks`, and `ImageProcessor.render` applies one compiled sequence (analysis → masks →
retouch → colour → crop → composite). Layers, adjustment layers, blend modes and layer
masks are not features that can be bolted onto that shape. Seven things have to change:

1. **Document model** — a layer stack (content reference, mask id, blend mode, opacity/
   fill, visibility, group parent) implies project schema **v6**, migration from v5, and an
   explicit unknown-record policy.
2. **Content/asset model** — raster layers, adjustment layers and smart objects need an
   asset store; today only `BackdropStore`, `MaskStore`, `AIEditStore` exist.
3. **Render graph** — a compositor that evaluates the stack bottom-up with per-layer
   caching, replacing one fixed order and a single `CIContext`. Adjustment layers become
   nodes; this is also what makes non-destructive editing extensible rather than fixed.
4. **Mask ownership** — masks attach to layers instead of floating as selection records.
   `MaskRecord` is reusable as the raster/geometry payload, which is why B (the shared
   masking engine) is a foundation, not a sibling.
5. **History semantics** — snapshots must cover a tree; coalescing and the 100-step cap
   need per-layer meaning.
6. **Export planner and C ABI** — `RenderContract` must describe a stack, and Windows must
   either render layers or explicitly refuse them. Today Windows preserves records it cannot
   render and names the unrenderable edits; a layer system multiplies that exposure.
7. **UI** — the inspector becomes a layer panel; the current 11-group accordion has no
   place to put a stack.

Dependency chain that follows from this, and which drives §6:
`G1 runtime` and `P2 cross-platform render substrate` → `P3 shared selection/masking
engine` → `P4 document model v6 + compositor` → `A layers/adjustment layers/blend modes`,
and `P3` in parallel → `D/F AI scoping`, `E frequency separation`, `F removal/fill`.
Everything in the roadmap hangs off two substrate items.

## 6. Sequencing

### 6.1 The owner's proposed sequence (recorded, unmodified)

1. Core editor expansion — layers, masks, history, brush engine, selection engine,
   non-destructive editing.
2. Professional image editing — curves, levels, HSL, colour grading, colour management, RAW.
3. AI image enhancement — upscaler improvements, enhancer, denoise, deblur, restoration.
4. Portrait retouching — face analysis, parsing, skin retouching, hair masking, eyes.
5. AI object and generative editing — removal, background, generative fill, outpainting,
   semantic editing.
6. Professional workflow — library, collections, batch, export management, project
   management.

The owner explicitly invited a better sequence on evidence. PM revision below changes three
things and leaves the destination identical.

### 6.2 PM-revised sequence (bucket: **PM-proposed change to owner items**)

| Phase | Content | Entry gate | Exit criterion |
| --- | --- | --- | --- |
| **0** | Ship the first release. Runtime delivery milestone closes with a real download → verify → install → launch → ×4 inference from the UI | existing first-release gates | release approved by owner |
| **1 Substrate** | P2 cross-platform render/compositing substrate, P1 capability-evidence ledger, P4 design package (document model v6 + render graph spec, no user-visible features) | Phase 0 shipped | the renderer can composite an ordered stack with blend modes and per-layer opacity on **both** hosts behind a flag, corpus still green |
| **2 Masking as infrastructure** | P3 shared selection engine: subject/sky/hair/people, colour range, luminosity, refine edge, one Select-and-Mask workspace | Phase 1 | one mask API serves traditional tools and every AI tool; masks are layer-attachable |
| **3 Core editor** | layers, groups, layer masks, adjustment layers, blend modes, opacity/fill, history panel, brush engine, clone stamp, dodge/burn, gradient, mesh warp unifying warp/liquify/face reshape, perspective | Phase 2 | a professional flat-free workflow is possible end-to-end with non-destructive edits on both hosts |
| **4 Colour and capture** | curves spline, levels with gamma, WB tint + eyedropper, per-range colour balance, grading wheels, selective colour, LUT import, ICC/profile choice + soft proofing, P6 RAW workflow | Phase 1; P6 needs its own licence review | colour-managed edit→preview→export with no undocumented clipping; pro capture format opens non-destructively |
| **5 Portrait quality (continuous from Phase 1)** | frequency separation, flyaway removal, face symmetry, match-to-reference skin tone, portrait lighting, real-photo body/pose acceptance, Windows rendering parity for all 8 existing Implemented rows | none — runtime-independent | the differentiator is measurable on real photographs on both hosts, not only in unit tests |
| **6 AI enhancement** | upscaler as-is plus enhancer as its own capability, denoise, deblur, face recovery, restoration — each with its own model dossier and quality corpus | G1 + G2 per model | genuine in-app inference with quality validation and honest capability disclosure |
| **7 Generative and object editing** | object removal, fine matte background removal/replacement, generative fill, outpainting, semantic editing, context-aware reconstruction | Phases 2 + 6, model approvals, memory policy for 16 GB | memory-bounded, quality-validated, refusal-is-truthful |
| **8 Workflow and management** | P14 multi-document sessions, library, folder browser, thumbnails, metadata/EXIF, ratings/labels/flags, collections, P9 edit presets, batch rename/process, comparison, duplicate detection | Phase 3 (presets need the edit model) | a photographer can cull and process a shoot without leaving the app |
| **9 Extensibility** | P11 command registry + custom shortcuts, custom workspaces, P12 local-only performance monitoring, P13 accessibility/i18n bar, plugin architecture last | stable document and render contracts | third-party surface exists only against frozen, versioned contracts |

Three changes versus the owner's order, each with its reason:

1. **Substrate before features (Phase 1 moved ahead of "core editor expansion").** The
   owner's step 1 bundles layers and the selection engine as if they were features. §5 shows
   they are architecture: layers require schema v6, an asset store, a compositor and history
   semantics. Starting with visible layer UI would produce a demo that cannot survive the
   corpus, the C ABI or Windows.
2. **Masking before layers (Phase 2 before Phase 3).** The owner's own instruction to treat
   selection/masking as reusable shared infrastructure argues for doing it first: it is the
   single highest-leverage node in the graph, feeding A (layer masks), D (hair, skin,
   relighting), E (frequency separation, flyaways) and F (removal, fill, outpaint). Layers
   without a real mask engine give users a stack they cannot scope.
3. **Portrait quality runs continuously from Phase 1 instead of sitting fourth.** E already
   has 8 working capabilities and needs no runtime, so its remaining value — texture-
   preserving frequency separation, symmetry, flyaways, Windows parity — is the cheapest
   professional credibility available anywhere in this roadmap, and it is the app's
   differentiation from a general-purpose editor.

No release numbers and no delivery dates are assigned, per the directive.

## 7. Governance and approval boundaries (unchanged by this roadmap)

PM may independently: review architecture, map dependencies, assess feasibility, write
technical specifications, recommend priorities and milestones, maintain this document and
the matrix, identify reusable infrastructure, plan future work, and challenge technical
decisions with evidence.

This roadmap authorises none of the following: cloud inference or hidden data
transmission; new model downloads, installations, adoption, conversion or distribution
without explicit owner approval **for the exact artefact**; paid services or spending;
breaking changes to frozen contracts, schemas or the C ABI; public releases, tags or
publication; destructive Git operations or discarding owner work; material product-direction
changes outside delegated authority.

## 8. PM additions, proposals and open questions

Each significant item states: what, why, problem or opportunity, dependencies and
complexity, impact, priority. Buckets are kept distinct as required.

### 8.1 Owner-defined strategic requirements (no PM change)

Groups A–I as listed in §3; Upscaler and Enhancer as separate capabilities; selection and
masking as shared infrastructure; local-first and consent rules; the four status principles
in §2.

### 8.2 PM-recommended additions — **not in the owner's list**

| # | Recommend | Why / problem addressed | Dependencies · complexity | Priority |
| --- | --- | --- | --- | --- |
| P1 | **Extend and gate the capability evidence ledger that already ships** — `worker/retouch_ai_worker/capability-evidence.json` exists and holds one `upscale.4x` entry; add per-capability records (run id, host, artefact hash, quality metric) and a CI gate that refuses a status bump without one | The owner's §9 measures progress by verified evidence, and four documentation gaps or mismatches were found while building the matrix (a support claim whose ledger is textual — it exists, but names no run id, host or artefact hash, so a reader cannot re-run it, a stale "worker source outside the repository", stale negative audit claims, a doc-vs-doc ICC conflict). The matrix rots without an artefact backing it, and every future roadmap decision inherits the rot | low complexity, no runtime dependency; touches tests and CI only | **now, Phase 1** — cheapest item here, protects everything after |
| P2 | **Cross-platform GPU render and compositing substrate** (one render API; Metal on macOS, D3D12 or a portable backend on Windows) | Today Windows runs an image pipeline on CPU with WPF compositing while macOS uses CoreImage/GPU. Layers, blend modes, masks at resolution and 50 MP canvases are not achievable on the current Windows path, so half the roadmap would silently become macOS-only | high complexity, cross-cutting; must be spike-validated before commitment | **Phase 1** — gate for A, B, C at professional scale |
| P3 | **Selection/masking engine as a named infrastructure milestone** (not a feature list) | Directly implements the owner's §B instruction; without a single abstraction each new tool re-implements masking, which is how the current state is "masks exist but are not a layer property" | depends on P2; medium–high | **Phase 2** |
| P4 | **Document model v6 + render-graph design package** (specification and a throwaway spike, no user-visible features) before any layer UI | §5 shows layers are architecture, not a feature: a stack needs schema v6, an asset store, a compositor, tree-structured history and C ABI semantics. Building UI first is how a project ends up with a demo that cannot survive the golden corpus or Windows | after Phase 0; depends on P2 for the renderer; medium complexity for the spec, high for what it unlocks | **Phase 1, first item** |
| P5 | **Type/text layers, shape layers and a path/Pen tool** — absent from the owner's list | A professional editor without type cannot do watermarks, captions, social crops or branding beyond the current text-only tiled watermark; paths are also the *non-AI* route to precise masks, so they serve B and F as well | P2, P4 for layers; P3 for path→mask; medium | **Phase 3** |
| P6 | **RAW capture workflow** (decode + DNG + non-destructive camera settings), generalising the owner's "RAW Colour Processing" row | The audit shows there is no RAW/DNG decode path at all. A "professional photo workflow" that cannot open a camera's native files excludes the core audience, and it is the largest single adoption blocker after layers. Requires a decoder dependency whose licence must be reviewed — no assumption is made here | licence review + camera support data distribution; medium–high | **Phase 4**, gated on its own owner approval |
| P7 | **Print and output module** (paper ICC profiles, margins/sizing, soft-proof → print) | §C lists soft proofing but nothing prints; pro photo work ends on paper or in a client hand-off, and profile-correct printing is the reason soft proofing exists | P2, ICC profile choice in C; medium | **Phase 4** |
| P8 | **Interoperability: PSD import (incl. layer groups), layered TIFF round-trip, XMP sidecars** | Professionals receive PSDs and must hand work back; "local-first" is only useful inside a real toolchain. Import-first is much cheaper than write-full | P4; medium for read-only, high for write | **Phase 3–4**, read-only first |
| P9 | **Reusable edit presets / develop recipes with sync across a batch** | G lists batch processing and H lists export presets, but nothing carries the *edit* as a reusable object — which is what makes batching worth using. Current batch applies one crop to every file | Phase 3 edit model; low–medium | **Phase 8**, with G |
| P10 | **Local computational photography: HDR merge, focus stacking, panorama** | These are the workflows where local-first beats cloud products on privacy for studio and real-estate work, and they are natural users of the masking and alignment substrate. None is in the owner's list | P2, P3, alignment; high | **after Phase 7**, as a differentiator bet |
| P11 | **Command registry with configurable keyboard shortcuts (and keymap presets)** | §I lists it last, but pros adopt or abandon an editor on keyboard ergonomics; doing it before custom workspaces is cheap and improves every later tool | low–medium; independent | **pull forward into Phase 3** |
| P12 | **Local-only, opt-in performance and stability instrumentation** (timings, memory pressure, crash artefacts written to disk; no transmission) | §I asks for performance monitoring while §2 forbids telemetry — both are satisfiable only by a local-first diagnostic store. Today metrics exist solely inside test output, so a real-world regression is invisible | medium | **Phase 1**, small |
| P13 | **Accessibility and internationalisation as a standing quality bar** (VoiceOver, keyboard-only operation, RTL, localized numerals/units) | Not in the owner's list at all, yet the product already ships an English and a Persian UI, and current gaps are measured: bidi reflow scrambles `4.61 GB · Apache-2.0`, Latin digits leak into Persian strings, and keyboard focus stepping is untestable in CI because Full Keyboard Access is off. A pro tool must be operable without a mouse | ongoing; low per item | **continuous from Phase 0** |
| P14 | **Multi-document sessions and tabbed/multi-window editing** | §G's library, comparison and culling all presuppose more than one open document; the shell is single-document today | Phase 3–8 boundary; medium–high | **before Phase 8** |

### 8.3 PM-proposed changes to existing owner capabilities

| # | Item | Proposal | Reason |
| --- | --- | --- | --- |
| C1 | C "RGB and CMYK workflow" | **Remove CMYK**; keep RGB + printer-profile soft proofing (P7) | CMYK conversion needs a colour-model engine, ink limits and separation rules; photographers retouch RGB and let the RIP separate. High cost, near-zero benefit for this audience |
| C2 | H "AVIF" | **Defer AVIF behind WebP** | encoder dependency with unsettled licence/platform exposure (the same class of problem that is currently blocking the runtime), while WebP covers the web-delivery need |
| C3 | I "Plugin architecture" | **Last, after document and render contracts freeze**; interim extensibility via presets and batch actions | a plugin ABI created now freezes the very contracts Phases 1–3 must evolve, and would make every later change a breaking one |
| C4 | A "Warp", "Liquify", "Face reshape" | **One mesh-warp capability family**, three UI expressions | three rows currently imply three engines; the codebase already has warp kernels that a shared mesh would generalise |
| C5 | B "Refine edge", "Select and Mask", "Advanced Mask Refinement" | **One masking-workspace milestone** | they overlap today and one of them (Refine edge) is secretly an AI feature because it calls SAM 2 — a non-AI edge tool must exist independent of G1 |
| C6 | D/F sequencing | **Gate all D/F rows on G1/G2**, and keep classical portrait work (E) independent | otherwise acceptance criteria for five Blocked rows are unsatisfiable and their status will drift |
| C7 | E "Frequency Separation" | Promote from a feature to **the quality bar for skin work**, with a measured texture-preservation test | the owner's §E requirement "preserve natural skin texture" is currently met only by a blur/texture blend, not a real HF/LF split; without a measurement the requirement is unenforceable |
| C8 | G "Photo Library" | Build it **file-system-first with optional catalog** (no import ritual, sidecar metadata, non-destructive to the folder) | the pro audience splits between Lightroom-style catalogs and bridge-style folder browsing; catalog-only would exclude the second half and add a data-recovery surface |

### 8.4 Ideas requiring investigation before any commitment

- **I1** ONNX Runtime vs the Python/PyTorch worker for Windows and DirectML — decides
  whether the Windows AI rows need a second runtime at all.
- **I2** Long-term fate of the Python worker: keep and sign it, or move inference into a
  native local engine. Affects distribution size, signing, 16 GB memory behaviour and every
  D/F acceptance criterion.
- **I3** RAW decoder choice (LibRaw-class) — licence, camera support data, redistribution
  obligations, colour pipeline.
- **I4** Portable GPU backend for P2 (wgpu vs explicit Metal + D3D12 pair).
- **I5** Tiled/pyramid canvas rendering for very large layered documents.
- **I6** Perceptual hashing for duplicate detection and "find similar".
- **I7** PSD read/write: library licence versus a partial in-house parser.
- **I8** Whether Flux-class generative work is honest on a 16 GB machine at all, or should
  ship as an explicit opt-in tier with declared limits.
- **I9** Making `Model Manager` states and capability availability machine-assertable, so
  "Installed/Active" can never again be shown for something that cannot run.
- **I10** `M3-RUNTIME-INTEGRITY-PREFLIGHT` — an in-process `/usr/bin/codesign
  --verify --strict` check placed before the packaged upscale self-test is allowed
  to admit its model, so a tampered bundle stops failing open. Registered here on
  2026-11-26 by the documentation-truth pass; §9 makes this file PM-maintained, so
  the PM may renumber or relocate the entry. The defect it closes is recorded in
  `Docs/RELEASE_2.0.0_UPSCALER_GATE.md` §6.1: four tampered copies of the same
  bundle each printed `UPSCALE SELFTEST: PASS` with exit 0. Note that CLI
  verification is *not* absent today — `build.sh:221` runs
  `codesign --verify --deep --strict` on the built bundle and the acceptance
  workflow on the unmerged M3 head runs it before and after inference
  (`m3-packaged-acceptance.yml:124-125` and `:182-183`, both inside
  `set -euo pipefail` steps). What is absent is any check inside the launched
  application, which is the only place that can see a bundle modified after it left
  the build machine.
  **Deferred by decision, not oversight — 2.1, not 2.0.0.** Under ad-hoc signing
  this is a tamper-*consistency* check, not a security boundary: the same
  single-user writer who can modify a bundle can delete the check, and one
  re-signature defeats it — measured for the ad-hoc case only: `codesign --force
  --sign -` on the tampered copy produced a new CDHash `cd300858d44e23900cd8b2e49f860ea6300c6b4b`
  while the tampered payload stayed on disk at `85b7cc84c46b7d51a13d6983c52dacdfc7edbad162a2a156c76bc7ab4ce6a295`,
  and the copy then passed its own seal. Re-signing with a real Apple identity was
  NOT MEASURED and is out of reach under this project's ad-hoc-only policy, so that
  stronger claim is not made here. Adopting it also invalidates the
  current packaged acceptance identity and forces a full artefact re-run, which is
  why it cannot ride into 2.0.0. Scope as recorded: ~30–45 lines before
  `PackagedUpscaleSelfTest.swift:436`. `--deep` is unnecessary and the probe says
  so directly: a never-sealed file injected at
  `Contents/Resources/Worker/retouch_ai_worker/_evil_extra.py` — i.e. deep inside
  the Worker payload — was caught by the plain non-deep check at exit 1 with
  "a sealed resource is missing or invalid", so the outer resource seal already
  covers the Worker tree.
  **Seal anatomy that makes a plain verify cheap and correct (measured 2026-11-26,
  read-only, from the retained head-built clone's `Contents/_CodeSignature/CodeResources`).**
  The resource rules include a required `^Resources/` rule; the `files2` table seals
  29,174 entries — 29,158 whole-file `hash2` SHA-256 records plus 16 `symlink`
  records — and there are zero `cdhash` entries. `Resources/Worker/**`, including the
  32,133-entry Python payload, is therefore sealed as ordinary resources of the outer
  signature, not as nested code, so a single non-deep `codesign --verify --strict`
  pass already covers the whole tree and Apple's deprecated `--deep` adds nothing.
  **Coverage this adds over the offline gates:** on the two copies whose tree the
  Worker manifest cannot see — a file added outside the `Resources` seal rule and a
  4-byte non-Mach-O stub added to `Contents/MacOS/` — the recorded
  `Tools/worker-integrity.py` run reported `worker integrity verified: 32133
  entries` at exit 0 while `codesign --verify --strict` on the same copies returned
  exit 1. The two gates are therefore complementary, not redundant.
  **What the 2026-11-26 signature-probe records report — read from those records,
  not re-run by this documentation pass, therefore NOT VERIFIED here:** a pristine
  bundle verifies at exit 0 with empty stderr; a one-byte change to
  `Contents/Resources/Worker/retouch_ai_worker/engine.py` or
  `Contents/Resources/Worker/.integrity.json`, an added file outside the
  `Resources` seal rule, an added non-Mach-O stub in `Contents/MacOS/`, a deleted
  worker file and a repointed internal symlink each verify at exit 1 (the first five
  with "a sealed resource is missing or invalid", the symlink case with
  "No such file or directory"); a byte flip in a bundled `.so` under
  `Contents/Resources/Worker/Python.framework/…` behaves the same way, while a byte
  flip in the main `Contents/MacOS/RetouchStudio` binary returns exit 1 earlier
  (~0.08 s) with "invalid signature (code or signature have been modified)";
  causality is controlled on the same copy (injected
  item present → 1, removed → 0, re-added → 1); the tool succeeds with isolated
  `HOME`/`TMPDIR` (both directory digests unchanged before and after, and no
  signature-shaped file newer than the marker in the real `HOME`), with a
  non-existent `HOME`, with `HOME` made read-only (`chmod 500`), under `env -i` with
  an absolute binary path, from a read-only DMG mount (the detached DMG hash
  unchanged, no stale mount left), and after relocation. An early `env -i` attempt
  recorded exit 127, which was the probe script's own missing-binary bug and was
  superseded by the fixed run. On the trust path the records are more nuanced than
  "no contact": no `trustd`/`securityd` line named the bundle in any window (0
  naming lines in the 30–31 seen during the check and the 128–129 seen during the
  control), yet the ambient traffic was 54–55 lines in an idle window against 30–31
  during `codesign --verify --strict` and 128–129 during the `spctl --assess`
  positive control, which also emitted 42 OCSP lines and answered exit 3
  "rejected". So the claim the records support is "the check produces no
  attributable trust evaluation for this bundle", not "the system performs none";
  the first `log show` variant, which recorded 0 events in both windows including
  the positive control, was inconclusive and was replaced by the `log stream` run.
  Cost was ~1.1–2.2 s warm (median ~1.27 s), ~5.0 s cold from a freshly attached
  mount, ~2.7 s warm from the mount, maxRSS ~47 MB, on one 16 GB Apple-silicon
  machine; the same records confirm the shipped bundle is `Signature=adhoc` /
  `TeamIdentifier=not set` and carries no entitlements plist, so it is unsandboxed
  and spawning the tool is unrestricted — including from a child process whose
  bundle path contains a space (argv-list spawn, returncode 0, ~1.27–1.28 s) — and
  that the source bundle's tree digest
  (`df2649a904aaf3cc29e4222a061840c7f4bd7ae6c00a5f925ba3c9916c647b30`) was unchanged
  by the whole probe series.
  **What still has to be investigated before this can be scheduled:** every timing
  above comes from an external process spawning the CLI, never from the application
  process, so in-app spawn cost is unmeasured. The seam itself is narrower than it
  looks: at `d4ada2ac` the only production caller of `PackagedUpscaleSelfTest.run`
  is the `--upscale-selftest` dispatch in `Sources/RetouchStudio/Core/SelfCheck.swift:32-35`
  (`ExportService.swift:690` reuses `inferenceProvider(from:)`, not `run`), so this
  preflight would guard the diagnostic path only — whether to extend it to real
  export paths, and what a ~1.3 s per-export tax would then mean, is an open design
  question rather than part of this item. And the check must run before anything can
  create in-bundle residue: the acceptance workflow already treats `__pycache__` or
  `*.pyc` under `Contents/Resources/Worker/` as a failure
  (`m3-packaged-acceptance.yml:184-192`, with `PYTHONDONTWRITEBYTECODE=1` at `:132`),
  which is exactly the file churn a seal check placed after a worker start would
  report as tampering on a legitimate first run.

### 8.5 Risks that shape the plan

| # | Risk | Why it matters | Mitigation |
| --- | --- | --- | --- |
| R1 | **Runtime and model licensing is a single point of failure** for all of D and F | `AIRuntime.package == nil` means no AI capability can be accepted, and the distribution gate is open on licence grounds | finish the first-release runtime milestone before committing AI roadmap scope; P1 ledger; per-artefact dossiers |
| R2 | **Document model v6 is a breaking schema step** | migration from v5, frozen C ABI, corpus baselines, and Windows "preserve-but-cannot-render" semantics all move at once | the P4 design package lands before any layer UI; spike behind a flag; additive versioned fixtures; no silent fallback claims |
| R3 | **macOS/Windows divergence widens** | 8 of E's working capabilities and all of A/B/C's pro features would land macOS-only on the current CPU Windows path | P2 substrate; every Phase exit criterion is "both hosts or documented refusal" |
| R4 | **16 GB memory ceiling vs layers + AI simultaneously** | banding exists only for upscale today; a layered document plus a matte plus a diffusion pass is unbounded | memory model as part of the render graph, not an afterthought; explicit capability tiers |
| R5 | **Corpus regression during a renderer rewrite** | the golden corpus is the only cross-host truth and is protected | reuse the corpus as the Phase 1 exit gate; renew fixtures only by decision |
| R6 | **Evidence decay and documentation drift** | four mismatches found in one pass, including two docs contradicting each other on ICC | P1, plus the matrix's rule that status requires an artefact |
| R7 | **Scope gravity** — 128 capabilities, ~68 unbuilt | multi-year by construction; the failure mode is a half-built layer system in every release | one substrate phase at a time, exit criteria above, no phase starts while the first release is open |
| R8 | **New dependency licence exposure** | precedent: one optional wheel carried a GPLv3-configured FFmpeg build and blocked distribution | licence inventory + proof-of-absence for every added dependency, enforced in CI |
| R9 | **Truthfulness of capability disclosure** | measured defects: the export sheet advertises `AI upscale 4×` and refuses only after Save; only 1 of 5 runtime failure states is expressible; un-downloadable models show as "not installed" | first-release §6 work (#69/#75) is the precondition for any AI roadmap claim |
| R10 | **Any future feature that needs the cloud** would break the founding promise | generative/editing vendors increasingly server-side | hard constraint in §2; investigate local alternatives (I1, I2, I8) instead |

## 9. Change control

This file and the matrix are maintained by the PM. Owner-defined scope in §3 may not be
silently dropped or demoted: changes go in §8.3 with a stated reason, so the owner's
position and the PM's position stay separately visible. New capabilities enter §8.2 until
the owner adopts them. Every status change in the matrix requires an artefact (test, run id,
harness measurement or recorded acceptance), and no status in either document may be quoted
as release readiness for the first release.
