# Cross-Platform Technology Decisions

**Status:** Decision record for design review, not implementation
**Milestone:** 4 — StudioCore Architecture & Extraction Design
**Baseline:** `main` / `7cfc8594f416c987386e0abe103cc75121de073a`
**Date:** 2026-11-11
**Companions:** [STUDIOCORE_ARCHITECTURE.md](STUDIOCORE_ARCHITECTURE.md), [STUDIOCORE_INTERFACE_DESIGN.md](STUDIOCORE_INTERFACE_DESIGN.md), [STUDIOCORE_EXTRACTION_ROADMAP.md](STUDIOCORE_EXTRACTION_ROADMAP.md)

---

## 1. Purpose

This document records the technology choices that follow from the architecture and interface design, the evidence behind each one, the alternatives considered, and what remains unproven. It deliberately separates:

- **VERIFIED** facts about the repository;
- **RECOMMENDATION** decisions proposed by this milestone;
- **HYPOTHESIS — NOT VERIFIED** expectations that require a prototype or measurement.

No choice here authorizes implementation. The audit already contains the top-level classifications; this document explains and applies them.

---

## 2. Constraints that drive the decisions

**VERIFIED.**

1. The macOS app is a single Swift compilation unit built with `swiftc`, not SwiftPM (`build.sh:58`, `build.sh:60-66`). It must keep building and shipping.
2. The image pipeline is Core Image plus Vision (`Sources/RetouchStudio/Core/ImageProcessor.swift`, `Sources/RetouchStudio/Core/FaceAnalyzer.swift`, `Sources/RetouchStudio/Core/SceneEngine.swift`).
3. The AI helper is an external Python process over a local socket; the protocol-v2 installer is disabled (`Sources/RetouchStudio/Core/AIWorker.swift:15`, `Sources/RetouchStudio/Core/AIRuntime.swift:40`).
4. The v3 project is a single JSON file with an absolute path and an Apple bookmark (`Sources/RetouchStudio/Models/Project.swift:8-28`).
5. Tests are a custom harness with no display, linking the app sources (`Tests/run.sh:35`, `Tests/run.sh:51-54`), plus an opt-in corpus harness (`Tests/run-corpus.sh:33`).
6. The corpus covers 78 render cases and 21 references, but not Vision detection, AI, RAW/HEIC, or UI (`Docs/GOLDEN_IMAGE_CORPUS.md:27-52`, `Docs/IMAGE_ENGINE_CHARACTERIZATION.md:265`).
7. The audit's classifications are the baseline (`Docs/PHASE0_CROSSPLATFORM_AUDIT.md:280-340`).

The hard product constraints are:

- Preserve macOS output quality and editing behavior.
- Preserve the reliability work already merged: export protection, recovery candidates, runtime transactions, metadata privacy, batch isolation.
- Keep existing projects openable.
- Do not force a rewrite of the macOS shell.
- Support Windows and Linux without a second, divergent document model.

---

## 3. Decision summary

| # | Decision | Status | Confidence | Reversible? | Must be validated |
|---|---|---|---|---|---|
| D1 | Rust for `StudioCore` | **RECOMMENDATION** (audit: confirmed) | High for pure logic | Medium | Build/toolchain on all targets; FFI ergonomics |
| D2 | C ABI with opaque handles plus versioned JSON for cold paths | **RECOMMENDATION** | High | High | ABI stability, ownership, panic containment |
| D3 | Core Image adapter first; Rust engine later | **RECOMMENDATION** (engine: prototype) | High for adapter, low for Rust parity | High | Corpus parity, performance, color |
| D4 | Python worker now; ONNX only after research | **RECOMMENDATION** (ONNX: needs research) | High for keeping Python | High | Model conversion, licensing, memory |
| D5 | v4 directory package, v3 read-only compatibility | **RECOMMENDATION** (audit: confirmed) | High | Medium | Migration fixtures, atomic save, Windows |
| D6 | macOS SwiftUI/AppKit; Qt 6/QML candidate for Windows/Linux | **RECOMMENDATION** (Qt: prototype) | High for macOS, medium for Qt | High | RTL, IME, color, tablet, accessibility, licensing |
| D7 | Platform adapters behind ports | **RECOMMENDATION** | High | High | Windows/Linux file, IPC, identity semantics |
| D8 | Snapshot history in core, gesture coalescing in shell | **RECOMMENDATION** | High | High | Memory, behavior parity |
| D9 | Corpus plus project/ABI conformance as release gates | **RECOMMENDATION** | High | High | Coverage gaps and cross-platform tolerances |
| D10 | Per-OS packaging; AI runtime optional | **RECOMMENDATION** | Medium | High | Signing, notarization, runtime size, models |

---

## 4. D1 — Core language: Rust

### 4.1 Evidence

**VERIFIED.**

- The core responsibility is pure data and logic: document state, operations, history, project codec, export/batch policy, recovery policy. These are testable without a display and without GPU access.
- The current code handles user originals and writes user files. Memory-safety defects in a photo editor can destroy originals; this is a domain where a safe language has concrete value.
- A stable C ABI can be consumed by Swift, C++, and Qt without a language runtime dependency.
- The audit already classifies Rust for `StudioCore` as a confirmed recommendation (`Docs/PHASE0_CROSSPLATFORM_AUDIT.md:286`).

### 4.2 Alternatives

| Option | Strengths | Weaknesses for this product | Verdict |
|---|---|---|---|
| **Rust** | Memory safety, strong type system, good JSON/serde ecosystem, C ABI, cross-platform toolchain, testability | Learning curve; FFI ownership discipline; smaller image-processing ecosystem than C++ | **Recommended** for core |
| **C++** | Mature imaging ecosystem (OpenCV, LibRaw, Qt), direct Qt integration | Manual memory safety in code that writes originals; ABI fragility across compilers; slower safe refactoring | Not recommended for core; acceptable inside a vetted engine library |
| **Swift everywhere** | One language, current team knowledge, excellent Apple integration | No production-grade cross-platform UI/imaging equivalent; Swift on Windows/Linux is immature for this product; still needs a second UI | Not recommended |
| **C# / .NET** | Good cross-platform runtime, Avalonia UI | Adds a third runtime; interop with Qt/C++ and Swift; no evidence of benefit over Rust | Not recommended |
| **Go** | Simple deployment | Weak for pixel/geometry work, FFI overhead, no strong win over Rust | Not recommended |

### 4.3 Rationale

**RECOMMENDATION.** Rust for StudioCore because:

1. The core is mostly parsing, validation, state transitions, and policy — Rust's strengths.
2. The safety argument is strongest exactly where the product is riskiest: user originals, project files, recovery.
3. The C ABI is a clean boundary for Swift and Qt.
4. It can be tested headlessly, which the current flat Swift module cannot prove.
5. It does not force a rewrite of the macOS renderer or UI.

### 4.4 Open questions

- **HYPOTHESIS — NOT VERIFIED.** Rust build times and binary size on the three targets are acceptable for this team.
- **HYPOTHESIS — NOT VERIFIED.** The team can maintain a Swift reference implementation and a Rust core during the transition without drift. The roadmap mitigates this with one source of truth and conformance fixtures.
- **HYPOTHESIS — NOT VERIFIED.** C ABI ownership can be kept small enough to audit. The interface design limits the ABI to lifecycle, document calls, and render buffers.

---

## 5. D2 — FFI: C ABI, not a C++ ABI or language bridge

### 5.1 Options

| Option | Assessment |
|---|---|
| **C ABI** | Stable across compilers and languages; explicitly owned memory; easiest to test from Swift, C++, and Qt. **Recommended.** |
| C++ ABI | Fragile across standard libraries and compilers; name mangling; exceptions across boundaries; harder from Swift/Qt. Rejected. |
| Swift↔Rust bridge generator | Adds a tool and a generated layer; useful later, not required for the first contract. Not chosen now. |
| JSON-only over a process | Simplest isolation but adds IPC latency and process management for every edit; useful for AI, not for a document session. Rejected as the primary core boundary. |
| WebAssembly | Portable, but forces a runtime in every shell and complicates native file/pixel access. Not justified. |

### 5.2 Recommendation

**RECOMMENDATION.**

- Opaque handles (`ScCore`, `ScSession`, `ScEngine`, `ScCancelToken`).
- Typed C structs for the render hot path, with `struct_size` and `abi_version`.
- Canonical JSON command/response envelopes for document and project operations, so adding a parameter does not change the ABI.
- Rust panics caught at the boundary and returned as `INTERNAL`.
- One isolated `unsafe` FFI module; the rest of the crate can deny unsafe code.
- Release functions for every owned buffer and error. No Rust allocator crosses the boundary implicitly.

**HYPOTHESIS — NOT VERIFIED.** JSON overhead on document commands is negligible because commands are user-scale (one per gesture or one per save), not per-pixel. This is easy to measure and not a blocker.

---

## 6. D3 — Image engine: keep the reference, prove the portable engine

### 6.1 Current state

**VERIFIED.**

- The 17-stage pipeline is implemented with Core Image (`Sources/RetouchStudio/Core/ImageProcessor.swift:731`).
- Vision supplies faces and pose (`Sources/RetouchStudio/Core/FaceAnalyzer.swift:12`, `Sources/RetouchStudio/Core/SceneEngine.swift:14`).
- The corpus validates downstream pixels, not Vision detection (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md:26`, `:265`).
- The audit classifies a Rust engine as needing a technical prototype (`Docs/PHASE0_CROSSPLATFORM_AUDIT.md:287`).

### 6.2 Options

| Option | Strengths | Risks | Verdict |
|---|---|---|---|
| **Core Image adapter now** | Exact current quality; no renderer rewrite; macOS can adopt StudioCore safely | macOS-only; locks portability behind an adapter | **Recommended immediate step** |
| **Rust engine (`wgpu` + CPU tier)** | Portable, memory-safe, shares language with core, can target Metal/D3D12/Vulkan | Large parity surface; color/GPU differences; unproven performance; no prototype | **Future, gated by prototype and corpus** |
| **C++ engine (OpenCV/LibRaw/Qt)** | Mature imaging ecosystem; Qt integration | Memory safety; compiler/ABI issues; still needs a GPU/color strategy | Not recommended as primary |
| **Swift engine + portable replacement later** | Keeps one language on macOS | No portable Swift engine path; the "later" replacement is the same Rust work; adds a second transition | Not recommended |
| **Third-party engine** | Could shorten work | Licensing, control, color management, exact parity unknown | Needs research only if a concrete candidate appears |

### 6.3 Recommendation

**RECOMMENDATION.** Two-phase engine strategy:

1. **Wrap first.** Put the current `ImageProcessor`/Core Image path behind the engine C ABI as `CoreImageEngineAdapter`. The macOS app must pass the existing corpus exactly. This proves the contract and isolates document logic from rendering without changing pixels.
2. **Prove, then replace.** Build a Rust engine vertical slice only after the contract and corpus gates exist. Start with deterministic, high-value stages (color/light, geometry, crop/orientation) and compare against the adapter. Do not switch a product path until the slice passes the same-host exact gate and the owner accepts the cross-platform tolerance.

The engine contract is the important deliverable. Choosing Rust before the contract would repeat the current coupling in a new language.

### 6.4 What must be validated

- A single-kernel parity spike (skin, heal, or warp) against the macOS reference.
- Color-space behavior on P3 and sRGB sources; output profiles.
- Mask rasterization and the 2% gate.
- Face/person mask construction, or a decision to keep it in the adapter.
- Performance on the M3/16 GB target and on representative Windows/Linux hardware.
- GPU fallback behavior when Metal/D3D12/Vulkan is unavailable.
- Determinism per stage and the tolerance for cross-platform comparisons.

All performance and parity claims in this document are **HYPOTHESIS — NOT VERIFIED** until these run.

---

## 7. D4 — AI: keep Python, define the contract, research ONNX

### 7.1 Current state

**VERIFIED.**

- The worker is a separate Python process over `AF_UNIX` JSON-RPC (`Sources/RetouchStudio/Core/AIWorker.swift:15`, `Sources/RetouchStudio/Core/WorkerClient.swift:17`).
- The runtime installer exists but is disabled because `AIRuntime.package` is `nil` (`Sources/RetouchStudio/Core/AIRuntime.swift:40`).
- Model weights are downloaded separately with consent and hash verification; they are not in the repository (`Sources/RetouchStudio/Models/ModelManager.swift`).
- The audit records that the worker source is outside the repository and that the v1.0.0 tag has no installer (`Docs/PHASE0_CROSSPLATFORM_AUDIT.md:219-227`).

### 7.2 Options

| Option | Assessment |
|---|---|
| **Keep Python worker** | Only working AI path; no parity risk; supports the current models. **Recommended near term.** |
| **ONNX Runtime** | Portable inference, multiple execution providers; model conversion, licensing, memory, and quality unmeasured. **Needs research.** |
| **Rust AI engine** | Would own manifests, sessions, tiling; needs the contract first and a prototype. **Needs a prototype.** |
| **Cloud inference** | Contradicts local-first/privacy; not justified by the repository. Rejected. |
| **Replace models** | Quality and licensing risk; no evidence. Not part of portability. |

### 7.3 Recommendation

**RECOMMENDATION.**

1. Keep Python for the near term.
2. Standardize the job schema and provenance now (interface design §7).
3. Make transport portable: Unix socket on macOS/Linux, named pipe or loopback on Windows, same framing.
4. Treat AI as an optional capability: `AI_UNAVAILABLE` must leave the editor fully usable.
5. Do not ship ONNX until one task (segmentation or upscaling) passes a frozen quality comparison and its licensing is cleared.
6. Never change a model silently; a model change is a versioned, approved change with a visible diff.

### 7.4 ONNX specifics to validate

- Model conversion for SAM2, Swin2SR, and MIGAN. Flux-class generative editing is the hardest case and may remain Python.
- Execution providers: Core ML, DirectML, CUDA/TensorRT, CPU. Capability differences and fallback.
- Memory on 16 GB machines, especially with a 4 B-parameter model.
- Model size and download UX.
- Licensing and redistribution of converted weights.
- Determinism and quality versus the current worker.
- Cancellation and progress semantics across execution providers.

**HYPOTHESIS — NOT VERIFIED.** ONNX Runtime can match the current segmentation/upscaling quality. No conversion or benchmark was run in this milestone.

---

## 8. D5 — Project format: v4 directory package

### 8.1 Current state

**VERIFIED.** v3 is a single JSON file with `version`, `imagePath`, `imageBookmark`, `adjustments`, export defaults, crop, orientation, heal spots, stickers, AI edits, analysis, and selected face (`Sources/RetouchStudio/Models/Project.swift:8-28`). The bookmark and absolute path are Apple-specific.

### 8.2 Options

| Option | Strengths | Weaknesses | Verdict |
|---|---|---|---|
| **v4 directory package** | Auditable files, content-addressed assets, platform state isolated, easier incremental writes, matches audit direction | Directory swap is not a single atomic operation on all OSes; packaging/backup UX | **Recommended** |
| Single-file ZIP | Easy to share, atomic replace of one file | Whole-file rewrite, harder crash recovery, opaque diff, asset duplication, extension/UTI churn | Alternative, not chosen |
| Single JSON with base64 assets | Simple, preserves UTI | Huge files, 33% bloat, whole-file rewrite, poor crash behavior | Rejected |
| External asset store only | Small project file | Fragile on move/backup; missing assets; not portable | Rejected as default |
| Database | Transactions | Opaque, heavy, hard to inspect/recover, overkill | Rejected |

### 8.3 Recommendation

**RECOMMENDATION.** A directory package with `manifest.json`, `source.json`, `operations.json`, `export.json`, `assets/`, `previews/`, and `platform/<os>.json`, as specified in the interface design. The audit already recommends this shape (`Docs/PHASE0_CROSSPLATFORM_AUDIT.md:346-361`).

Rules:

- The source is external by default; embedding is explicit and warned.
- All shared geometry declares a coordinate space.
- Assets are content-addressed with SHA-256.
- Unknown fields are preserved.
- Platform access data is isolated per OS.
- Atomic save uses a staged generation and a journal; durability is reported honestly.
- v3 remains readable; a v3 projection exists for compatibility when the state is representable.

### 8.4 What must be validated

- Directory swap behavior on APFS, NTFS, and common Linux filesystems.
- Crash injection at every step of the save protocol.
- Migration fixtures from real v3 projects, including missing AI assets and stale bookmarks.
- Large projects with many AI patches; asset deduplication and disk usage.
- Backup/sync tools that do not understand directory packages (Dropbox, OneDrive, Time Machine).
- UTI/Finder behavior for a directory package.

**HYPOTHESIS — NOT VERIFIED.** A directory package is acceptable to macOS users who are used to single files. The UI must present it as one document and avoid exposing internals.

---

## 9. D6 — UI: keep macOS, make Qt the candidate for Windows/Linux

### 9.1 Requirements

The UI must support:

- A large canvas with overlays, brush strokes, crop handles, and compare split.
- Color-managed display (at least sRGB and P3).
- Persian/Arabic shaping, bidi, IME, and RTL layout.
- Menus, keyboard shortcuts, accessibility, drag and drop, and native file dialogs.
- A packaging story for Windows and Linux.
- A path that does not abandon the existing macOS app.

### 9.2 Comparison

| Framework | macOS | Windows | Linux | Canvas/perf | Color | RTL/Persian | Accessibility | Packaging | Cost/risk | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| **SwiftUI + AppKit** | Native, current | No | No | Strong on macOS | Excellent | Current app handles it | Native | Existing | Zero new risk | **Keep for macOS** |
| **Qt 6 / QML** | Good | Native-quality | Native-quality | Strong with QRhi/QSG | `QColorSpace` and ICC support; needs prototype | `LayoutMirroring`, HarfBuzz shaping; needs prototype | QAccessible | windeployqt/linuxdeploy; LGPL/commercial | Large dependency; licensing; prototype needed | **Leading candidate for Windows/Linux, conditional** |
| Tauri + web UI | Good | Good | Good | WebView variance; canvas latency | WebView color management is weak | CSS/browser support | Browser a11y | Small | Pixel-accurate editing risk | Not recommended for editor |
| Avalonia (.NET) | Good | Good | Good | Decent | Needs research | Good | Good | .NET runtime | Third runtime; interop | Needs research only |
| Flutter | Good | Good | Good | Custom renderer | Plugin gaps | Good | Improving | Large | Desktop ecosystem/color gaps | Not recommended |
| Electron | Good | Good | Good | Heavy | Weak | Good | Good | Very large | Memory/color | Not recommended |
| Slint | Good | Good | Good | Good | Needs research | Needs research | Immature | Small | Ecosystem maturity | Not recommended now |

### 9.3 Recommendation

**RECOMMENDATION.**

- Keep SwiftUI + AppKit for macOS. Do not rewrite the shell.
- Make Qt 6/QML the leading candidate for Windows/Linux, subject to a prototype that proves the hard requirements.
- Do not choose a webview-based shell for the editing surface.
- Keep Simple/Pro as presentations of one document API; do not let them fork history or image behavior.

The Qt prototype must cover:

- Persian shaping and bidi in menus, labels, and canvas text.
- IME composition in a text field and in the prompt sheet.
- Tablet pressure and high-frequency pointer events.
- Color-managed canvas: P3/sRGB source, ICC display profile, and a GPU surface for engine output.
- Accessibility tree and keyboard navigation.
- Menu/shortcut integration and native file dialogs.
- Packaging with the runtime and optional AI component.
- Licensing review (LGPL obligations or a commercial license).

**HYPOTHESIS — NOT VERIFIED.** Qt can meet the color and input requirements without unacceptable latency. A rectangle-drawing prototype would not retire this risk; the prototype must edit a real image.

---

## 10. D7 — Platform adapters

### 10.1 Decision

**RECOMMENDATION.** Implement the ports in the interface design per OS:

| Port | macOS | Windows | Linux |
|---|---|---|---|
| Source access | Security-scoped bookmarks, POSIX paths | Paths, ACLs, file IDs, long paths | Paths, mount points, portals |
| File store | POSIX atomic write, `fsync` file and directory | `ReplaceFileW`/`MoveFileEx`, flush buffers, directory semantics | POSIX plus filesystem-specific behavior |
| Decode/encode | ImageIO | WIC or a portable decoder | libraw/ImageMagick or a portable decoder |
| Color | ColorSync/Core Image | WCS/ICC | LCMS/colord |
| GPU | Metal/Core Image | D3D12/Vulkan | Vulkan/OpenCL |
| IPC | Unix socket | Named pipe or loopback | Unix socket |
| Process identity/locks | pid + start time + `flock` | Job Objects, file IDs, named mutex | pidfd + `flock` |
| Notifications/background | AppKit/Foundation | WinRT/Toast, task scheduler | Desktop portal/systemd |

### 10.2 Rules

- Only adapters import OS frameworks.
- Core sees portable values and opaque handles.
- A missing platform hint degrades to "locate the source", never to data loss.
- The adapter owns durability and must report it accurately.
- No adapter contains editing rules.

### 10.3 Risks

- Windows file identity and replacement semantics differ from POSIX. **HYPOTHESIS — NOT VERIFIED** until crash tests run.
- Linux desktop environments vary (Flatpak, Snap, Wayland/X11). The supported matrix must be explicit.
- macOS sandbox/security scope must still work after the extraction; the current bookmark path must remain the reference.

---

## 11. D8 — History and state ownership

**RECOMMENDATION.**

- StudioCore owns document state, transactions, undo/redo, clean marker, and revision.
- The shell owns gesture timing, 350 ms coalescing policy, tool mode, zoom, pan, compare position, sheets, and window state.
- Snapshots are full document states with shared immutable assets, bounded at 100 entries.
- Assets are never mutated by undo; an undone AI edit remains available for redo.

Why not reversible command objects: the current model already works with snapshots (`Sources/RetouchStudio/Models/EditorModel.swift:313-366`), and command inversion for every retouch parameter is error-prone. Why not store history in the project: current projects do not, and doing so would bloat files and couple history to format migration. Both are rejected for now.

**HYPOTHESIS — NOT VERIFIED.** Full snapshots stay within memory budgets for large documents. The roadmap includes a measurement gate.

---

## 12. D9 — Validation and testing

**RECOMMENDATION.**

| Layer | Gate |
|---|---|
| Swift extraction (no Rust) | Existing 840 checks plus corpus pass unchanged; project JSON byte-identical for representable fixtures |
| Rust core | Unit/property/fuzz tests; cross-language conformance on document fixtures; non-Apple CI build |
| macOS engine adapter | Corpus exact same-host; export characterization unchanged |
| Rust engine | Corpus comparison in methodology order; per-stage parity; owner-approved tolerances |
| Project v4 | Round-trip, unknown fields, v3 migration, missing/relocated source, crash injection |
| Recovery | Candidate immutability, ordering, quarantine, epoch invalidation, durability |
| AI | Fake worker protocol tests; runtime failure paths; provenance; cancellation |
| Shells | Native interaction tests; RTL/Persian; accessibility; packaging |

The corpus is necessary but not sufficient: it does not exercise Vision, AI, RAW/HEIC, or UI (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md:265`). A release gate that only runs the current 78 cases would overstate confidence.

---

## 13. D10 — Packaging and distribution

**RECOMMENDATION.**

- macOS: keep the current `.app`/DMG flow, ad-hoc signing today, notarization when the owner chooses a distribution identity. Keep per-architecture artifacts and the universal build.
- Windows: signed installer (MSIX or a signed EXE installer), per-user install, optional AI runtime, model download with consent.
- Linux: AppImage or Flatpak; document the sandbox/portal implications for file access and IPC.
- AI runtime: separate optional component per OS and architecture; no model weights in the base installer; hash-verified downloads; explicit unavailable state.
- The core is a static library where possible to reduce loader complexity; a dynamic library only if shells need independent updates.

**HYPOTHESIS — NOT VERIFIED.** A static Rust core linked into the macOS app and the Qt shell keeps the build simple enough. This needs a build spike.

---

## 14. Rejected options and why

| Option | Why rejected now |
|---|---|
| Swift everywhere | No credible cross-platform UI/imaging path; still needs a second shell; does not solve Windows/Linux. |
| C++ core and shell | Memory-safety risk in code that writes originals; ABI fragility; no evidence of a team advantage. |
| Webview-based editor (Tauri/Electron) | Color management and canvas latency are core product risks; a photo editor cannot treat them as acceptable. |
| Flutter for the editor | Plugin/color/IME/accessibility gaps for a color-managed desktop editor. |
| Single-file JSON v4 with base64 | File size, rewrite cost, crash behavior, and diffability are worse than a package. |
| Cloud document store | No product requirement; conflicts with local-first/privacy. |
| Replacing Core Image immediately | No parity evidence; would sacrifice the only quality reference. |
| Replacing the Python worker immediately | No ONNX parity evidence; the working path would be lost. |
| Extracting `EditorModel` wholesale | It is the UI controller; moving it would move AppKit/SwiftUI into the core. |
| A general operation DAG | The reference pipeline is fixed and quality-critical; a graph invites unreproducible states. |
| Storing history in the project | Current projects do not; it would bloat files and complicate migration. |

---

## 15. Confidence and validation plan

### 15.1 High confidence

- Rust for pure core logic (audit-confirmed; matches the problem).
- C ABI as the boundary (standard, testable).
- Core Image adapter first (preserves the reference).
- v4 directory package (audit-confirmed; solves the v3 platform-data problem).
- SwiftUI/AppKit for macOS (current product).
- Python worker near term (only working path).

### 15.2 Medium confidence

- Qt 6/QML for Windows/Linux (promising, but the hard requirements are unproven).
- Snapshot history memory behavior.
- Windows durability sequence.
- Static linking of the core.

### 15.3 Low confidence / must not be presented as fact

- Rust engine parity and performance.
- ONNX Runtime quality, licensing, and memory.
- Cross-platform color tolerance.
- Qt color/input/accessibility parity.
- Directory-package acceptance by users and backup tools.
- Vision portability.

### 15.4 Validation order

1. Design review and owner approval (this package).
2. ABI/interface conformance and project fixtures.
3. Swift extraction with no behavior change.
4. macOS engine adapter behind the contract; corpus exact.
5. Rust core dual-run conformance; switch behind a flag.
6. Rust engine vertical slice; corpus gates.
7. v4 migration fixtures and crash tests.
8. Qt/RTL/color/tablet prototype.
9. Windows/Linux shell integration.
10. Optional AI/ONNX experiments, one task at a time.

No step in this order requires abandoning the macOS app or changing its output.

---

## 16. Decision record template for future changes

When a decision changes, record:

- Decision ID and date.
- The new evidence (prototype, measurement, corpus result).
- The old and new status.
- The affected interfaces and projects.
- The migration or rollback plan.
- The owner approval.

A decision that changes pixels, project bytes, AI models, or platform support is a product change, not a refactor. It needs explicit approval and a validation artifact.
