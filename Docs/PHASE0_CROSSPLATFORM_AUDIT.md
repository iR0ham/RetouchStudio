# Phase Zero — Cross-Platform Architecture Audit

**Project:** Retouch Studio
**Repository:** `iR0ham/RetouchStudio`
**Branch / commit:** `stabilization` at `5d8642f` (working tree clean at time of audit)
**Date:** 2026-11-09
**Mode:** read-only. No source file was modified, no dependency was installed, no file was deleted, no architecture or feature work was started.
**Evidence rule:** every statement below is labelled **VERIFIED** (read in the current tree or reproduced by a command), **PARTIAL**, **NOT REPRODUCED**, or **ASSUMPTION**. Line numbers refer to this commit, not to older audit documents.

---

## 0. Verdict in one page

1. **Retouch Studio is a mature, single-target macOS application**, not a prototype: 69 Swift files, 31,788 lines in `Sources/`, a working non-destructive editor, a tested image engine, a bundle, two DMGs, and a shipped 1.0.0 release.
2. **The quality engine is deeply Apple-bound.** Core Image appears in 19 files, Vision in 2, and the UI uses SwiftUI in 24 files and AppKit in 14. There is no direct Metal code; Core Image supplies the GPU path internally.
3. **The AI subsystem is a separate Python process**, not part of the Swift binary. Its runtime is a 388,277,063-byte arm64 archive, and the built `.app` measured 1.3 GB on disk (`du -sh`). The Python worker source is **not in this repository**; `build.sh` falls back to `$HOME/RetouchStudio-Phase0/worker`.
4. **A cross-platform product is feasible, but not by compiling this code for Windows or Linux.** It requires extracting a portable core, characterizing today's output, and building separate platform shells. The macOS app should remain the quality reference during that work.
5. **Four of the eight reported P0/P1 items are verified, three are partial, and one is not reproducible** (P0-06). The defects are real but localized; none requires an architecture rewrite.
6. **The first approved change should be a data-integrity milestone, not a migration.** Fix recovery deletion, original-file overwrite, runtime install rollback, and failed-load document identity, each with a regression test.
7. **Estimated full cross-platform parity:** 132–202 person-weeks (±40%), i.e. roughly 10–16 months with three engineers, or 31–47 months with one senior engineer. This excludes model licensing and certification delays.

**Nothing in this document authorizes implementation. Phase Zero ends with an approval request.**

---

## 1. Current architecture

### 1.1 Process and layer diagram

```text
┌──────────────────────────── Retouch Studio.app ────────────────────────────┐
│                                                                            │
│  App.swift (300 LOC)                                                       │
│   @main RetouchStudioApp · AppDelegate · EditorWindowDelegate · WindowBridge│
│   menus · Finder open · quit/close prompts · recovery prompt · --selftest  │
│                              │                                             │
│                              ▼                                             │
│  Views (18 files, 7,455 LOC)                                               │
│   EditorView · TopBar · ToolPanel · InspectorView · CompareCanvas           │
│   Analysis/Crop/Heal/Art/AI overlays · SettingsView · ModelManagerView      │
│   SmartAnalyzeSheet · Theme · Components · Histogram · Tutorial             │
│                              │  @EnvironmentObject / @Published             │
│                              ▼                                             │
│  EditorModel (3,135 LOC, 92 @Published properties)                         │
│   document state · undo/redo · operation tokens · panels · batch · export   │
│   recovery · presets · project open/save · AI orchestration                 │
│                              │                                             │
│        ┌─────────────────────┼──────────────────────┬───────────────────┐   │
│        ▼                     ▼                      ▼                   ▼   │
│  ImageProcessor        AnalysisRenderer        ExportService         AIWorker│
│  Core Image graph      CoreText overlay        render + ImageIO      Process │
│  Vision requests       face geometry           atomic write          launcher│
│  Skin/Look/Scene/      leader lines            16-bit PNG/TIFF       socket  │
│  Makeup/Mask/Heal/     labels                  JPEG/HEIC             client  │
│  Reshape/Backdrop                                                     │       │
│        │                                                            │       │
│        ▼                                                            ▼       │
│  CIContext ──► Core Image (GPU via Metal, CPU fallback)      AF_UNIX socket │
│  ImageIO · CoreGraphics · CoreText · Vision · CryptoKit                     │
└─────────────────────────────────────────────┬──────────────────────────────┘
                                              │ JSON-RPC
                                              ▼
┌──────────────────── Python helper process (optional) ──────────────────────┐
│ retouch_ai_worker serve                                                    │
│ PyTorch · Transformers · ONNX Runtime · MLX                                │
│ models under Application Support, downloaded by explicit consent           │
│ separate CLI process for model download / verify                          │
└────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Runtime topology

| Concern | Current mechanism | Evidence |
|---|---|---|
| UI process | One SwiftUI/AppKit process | `Sources/RetouchStudio/App.swift` |
| Editor state | `@MainActor` `EditorModel` `ObservableObject` | `Sources/RetouchStudio/Models/EditorModel.swift:9` |
| Image work | `Task.detached`, Core Image lazy graph | `EditorModel.load` 916–920; `ImageProcessor.process` 731 |
| AI transport | Unix-domain socket, JSON-RPC | `Core/WorkerClient.swift`, `Core/AIWorker.swift` |
| AI runtime | Bundled or downloaded Python venv + worker package | `Core/AIRuntime.swift:21–37`, `Core/AIRuntimeInstaller.swift` |
| Model files | Application Support, SHA-256 verified | `ModelManager`, bundled `downloads.py` |
| Persistence | JSON project sidecar v3; JSON recovery; `presets.json`; AI edits in Application Support | `Models/Project.swift`, `Models/Recovery.swift`, `Models/UserPreset.swift`, `Models/AIEdit.swift` |
| Build | Direct `swiftc`, universal, ad-hoc signing, self-test gate | `build.sh:52–66`, `159–188` |

### 1.3 Build and distribution facts

- `build.sh` is the authoritative build system; `Package.swift` is a 13-line manifest that is not used to build the shipped app.
- The build probes Command Line Tools SDKs for SwiftUI macro support, then compiles with `swiftc -O -whole-module-optimization`.
- Universal build is `arm64` + `x86_64`, combined with `lipo`; the Intel slice is executed through Rosetta and must pass `--selftest` (`build.sh:173–188`).
- Signing is ad-hoc (`codesign --force --sign -`). There are no entitlements, no App Sandbox, no hardened runtime and no notarization (`build.sh:159–160`).
- `Resources/Info.plist` declares bundle id `app.retouchstudio.mac`, version 1.0.0 (1), macOS 14 minimum, image viewer and `app.retouchstudio.project` editor roles, and the `.retouch` UTI.
- The worker runtime is either bundled or downloaded. The app bundle measured **1.3 GB** on disk with the helper present (`du -sh`); the downloadable archive is declared as **388,277,063 bytes** with SHA-256 `cb1485be…` and is arm64-only (`AIRuntime.swift:21–37`).
- `build.sh` comments describe the helper runtime as ~1.6 GB. That is a build-time comment, not a measurement performed in this audit.

### 1.4 Operation model

`EditorModel` gates work with `OperationKind` and tokens (`begin` / `end` / `refuseIfBlocking`, lines 234–297): `preview`, `load`, `export`, `batch`, `save`, `open`, `smart`, `ai`. Loads and previews use a generation counter; batch uses a separate `batchGeneration`. Exports and batch jobs run in detached tasks. This is a good foundation, but cancellation is not uniformly propagated (see P1-08).

---

## 2. Dependency map

### 2.1 Framework dependencies (VERIFIED by `grep '^import '`)

| Framework | Files importing it | Role | Portable? |
|---|---:|---|---|
| Foundation | 47 | model, files, JSON, processes, sockets | Yes, with OS-specific pieces isolated |
| CoreGraphics | 27 | geometry, color, bitmap types | Conceptually yes; types must be replaced |
| SwiftUI | 24 | entire UI | macOS only in practice |
| CoreImage | 19 | filter graph, masks, rendering | No; needs Rust/wgpu or CPU engine |
| AppKit | 14 | panels, alerts, windows, pasteboard, fonts | No; needs platform adapter |
| UniformTypeIdentifiers | 6 | image/project type filters | Replace with MIME/extension registry |
| ImageIO | 6 | decode, EXIF, encode | Replace with WIC / libraw / libvips |
| Vision | 2 | face landmarks, person segmentation, body pose | Replace with ONNX models |
| Combine | 2 | observable plumbing | Swift-only |
| CryptoKit | 1 | SHA-256 | Replace with RustCrypto/OpenSSL |
| CoreVideo | 1 | pixel buffer plumbing | Replace with engine buffer type |
| CoreText | 1 | analysis labels | Replace with DirectWrite/HarfBuzz |

### 2.2 Internal coupling (VERIFIED)

| Dependency direction | Nature | Risk |
|---|---|---|
| `Views` → `EditorModel` | one god object, 92 published fields | Any model change touches UI; hard to share view models |
| `EditorModel` → `Core/*` | direct calls to concrete engines | No protocol boundary; engine cannot be swapped |
| `Core/*` → `Models/*` | engines read `Adjustments`, `AnalysisSettings`, `HealSpot`, `Sticker`, `AIEdit` | “Core” is not independent of document types |
| `EditorModel` → AppKit | 22 AppKit-panel/alert references in the model alone | Business logic cannot run off macOS |
| `Core/ImageProcessor` → Vision | face/segmentation requests inside the image layer | Engine and ML runtime cannot be separated |
| `AIWorker` / `WorkerClient` → POSIX socket | `AF_UNIX` | Windows needs named pipes or authenticated loopback |
| `RetouchProject` → Apple bookmark | `Data` blob from `URL.bookmarkData` | Not portable, not readable by another platform |
| Tests → whole source tree | `Tests/run.sh` links all sources except `App.swift`/`SelfCheck.swift` | Any new platform-specific import breaks the test harness |

### 2.3 Build-time and runtime dependencies

- macOS Command Line Tools with a SwiftUI-capable SDK.
- `swiftc`, `lipo`, `codesign`, `ditto`, `/usr/bin/arch` (Rosetta for Intel self-test).
- Python runtime and wheels from an external checkout (`$HOME/RetouchStudio-Phase0/worker`, `$HOME/RetouchStudio-Phase0/.venv`); not vendored in this repository.
- Network only for the optional AI runtime and model downloads; the editor itself is offline.
- No package manager dependencies, no third-party Swift packages, no CI configuration in the repository.

---

## 3. Platform dependency inventory

### 3.1 Portability classes

**Class A — portable value/logic (can move almost unchanged to Rust or shared Swift):**

`Adjustments`, `UserPreset`, `Recovery` model, `AppSettings` values, `StatusToken`, `ToolMode`, `SliderHints`, `TutorialCopy`, `DeveloperProfile`, `Digits`, localization string tables, export format/quality rules, operation-token policy, preset math.

**Class B — portable geometry/model, but expressed in Apple types:**

`Crop` (`CGRect`), `HealSpot`, `Sticker`, `AnalysisSettings` (`CGPoint` endpoints/anchors), `DocumentOrientation`, `Look`, `Makeup`, `Backdrop`, `Watermark`, `AIEdit`, `AIMask`, `RetouchProject`, `AIModelRow/Plan` (Foundation-only aside from file APIs).

These are portable in principle, but `CGRect`, `CGPoint`, `CGSize`, `CGAffineTransform` and `Data`-bookmarks must be replaced by owned types or a math crate before sharing.

**Class C — platform-bound today:**

| Area | Files | Binding |
|---|---|---|
| Application shell | `App.swift` | SwiftUI `App`, `NSApplication`, menus, window delegate |
| UI | all 18 `Views/*.swift` | SwiftUI + AppKit panels/colors/fonts |
| Editor orchestration | `EditorModel.swift` | AppKit panels/alerts, SwiftUI `@Published` |
| Image engine | `ImageProcessor`, `SkinEngine`, `LookEngine`, `SceneEngine`, `MakeupEngine`, `MaskBuilder`, `FeatureReshaper`, `HealRenderer`, `ArtRenderer`, `BackdropEngine`, `AICompositor`, `ExportUpscale` | Core Image, CoreGraphics, Vision, ImageIO |
| Analysis overlay | `AnalysisRenderer` | CoreText, CoreGraphics |
| AI runtime | `AIWorker`, `WorkerClient`, `AIRuntime`, `AIRuntimeInstaller` | `Process`, `AF_UNIX`, URLSession, CryptoKit |
| Diagnostics | `SelfCheck.swift` | whole engine |

### 3.2 Feature-level inventory

| Feature | Depends on | Portable with work? |
|---|---|---|
| Decode JPEG/PNG/TIFF/HEIC | ImageIO | Yes: WIC + libheif/libvips; HEIC licensing must be checked |
| RAW | ImageIO / Core Image RAW | Yes: LibRaw + camera profile pipeline; highest quality risk |
| Color management | Core Image + `CGColorSpace` | Yes: lcms2 + ICC; must match rendering intents |
| Face landmarks | Vision | Yes: ONNX face mesh + landmark model; parity must be benchmarked |
| Person/background segmentation | Vision | Yes: ONNX segmentation/matting; different edges are a quality risk |
| Body pose | Vision | Yes: ONNX pose model |
| Healing | custom Core Image kernels | Yes: port kernels to WGSL/CPU; deterministic golden tests required |
| Skin/look/scene/makeup | Core Image filters and kernels | Yes: port graph; color math must be frozen |
| Reshape/warp | Core Image warp kernels | Yes: WGSL/CPU warp; interpolation must match |
| Upscale | Core Image + AI helper tiles | Yes: ONNX upscaler + tiled compositor |
| Text labels | CoreText | Yes: DirectWrite/HarfBuzz + font subset |
| Menus/shortcuts/IME/RTL | AppKit/SwiftUI | Platform adapter; RTL already a product requirement |
| File panels/alerts | AppKit | Platform adapter |
| Project location | Apple bookmark | Replace with relative path + content hash + platform locator |
| AI IPC | `AF_UNIX` | Named pipe or authenticated loopback on Windows |
| Model download | URLSession + `Process` | Platform HTTP client + child process |
| Updates/notarization | none today | New design required per platform |

---

## 4. Technical debt

Ranked by cost to the cross-platform goal and to near-term stability.

| # | Debt | Evidence | Consequence |
|---|---|---|---|
| D1 | `EditorModel` is a 3,135-line god object with 92 `@Published` fields | `Models/EditorModel.swift` | Every platform shell and every feature touches one file; high merge/regression risk |
| D2 | No enforced module boundaries | Core imports Models; Models import Core; single target | Cannot compile the engine without AppKit/SwiftUI; blocks reuse |
| D3 | AppKit inside the model | 22 panel/alert references in `EditorModel` | Business logic is untestable headlessly and non-portable |
| D4 | UI is 7,455 lines of SwiftUI | `Views/` | Cannot be reused by Windows/Linux; must be rebuilt as a second UI |
| D5 | Image engine is 13,458 lines tied to Core Image/Vision | `Core/` | The core product value is the least portable part |
| D6 | Python AI runtime is external and huge | no `worker/` in repo; 1.3 GB app; 388 MB archive | Reproducibility, auditability, Windows/Linux story, memory footprint |
| D7 | Project format uses an absolute source path + Apple bookmark | `Models/Project.swift:20–24` | Projects break when moved across machines/platforms |
| D8 | Metadata privacy is a blacklist | `ImageProcessor.strippedPrivacyMetadata` 1201–1219 | New/unknown identifying fields can leak |
| D9 | No CI | no workflow/config in repo | 1.0.0 quality depends on manual local runs |
| D10 | Localization parity is unenforced | `Localization.swift` 471 computed strings, `PersianL10n.swift` 471 overrides, no parity test | A forgotten Persian key falls back silently |
| D11 | Accessibility is sparse | 16 `accessibility*` modifiers across 7,455 UI lines | Both platform shells need an accessibility baseline |
| D12 | Distribution is ad-hoc and unsandboxed | `build.sh:159–160`, no entitlements | Gatekeeper/security expectations and future store distribution are unmet |
| D13 | Test harness compiles the whole app | `Tests/run.sh:35` | Platform-specific imports will make the suite untestable off macOS |
| D14 | Old audit docs contain stale line numbers | `Docs/TECHNICAL_AUDIT.md` | Risk of following outdated evidence |

---

## 5. Verified defect register

The directive's line numbers were treated as hypotheses and re-checked against `5d8642f`.

| ID | Title | Status | Primary evidence | Test coverage today |
|---|---|---|---|---|
| P0-01 | Recovery data deleted on cancel | **VERIFIED** | `EditorModel.swift:2529–2575` | None |
| P0-02 | Export can overwrite the original | **VERIFIED** | `EditorModel.swift:2685–2693`, `2718–2768`; `ExportService.swift:328–358` | None |
| P0-03 | Runtime install deletes the old copy before the new one is in place | **VERIFIED** | `AIRuntime.swift:84–107` | None for rollback |
| P0-04 | Privacy strip is incomplete | **PARTIAL** | `ImageProcessor.swift:1201–1219` | Only the current blacklist (`Tests/EngineTests.swift:1005`) |
| P0-05 | Batch analysis/stamps can leak across photos | **PARTIAL** | `EditorModel.swift:3051–3070` | None |
| P0-06 | Model download total is per-file | **NOT REPRODUCED** | `ModelManager.swift:206–216`; bundled `downloads.py:111–112,145–147` | None |
| P1-07 | Failed load changes title/export name | **VERIFIED** | `EditorModel.swift:908–927`, `963–964`, `2641–2644`, `2661–2677` | None |
| P1-08 | Batch cancel does not stop the running file | **PARTIAL** | `EditorModel.swift:2969–2971`, `3010–3020` | None |

### P0-01 — Recovery data loss on cancel (VERIFIED)

`offerRecoveryIfNeeded()` first checks `offeredRecovery` and sets it to `true`, so the prompt is once per session. If the source photo cannot be found, an alert offers **Locate** and **Discard**. The guard is:

```swift
guard alert.runModal() == .alertFirstButtonReturn,
      let picked = locatePhoto(for: project) else {
    RecoveryStore.clear()
    return
}
```

(Lines 2547–2551.) There is no Cancel button. Closing the alert or pressing Escape returns `.abort`, and cancelling the Locate panel returns `nil`; both paths delete the recovery file. The second alert (Restore / Discard, 2562–2574) also clears recovery in its `else`. **Cancel must mean postpone; only the explicit destructive button may delete.**

Required tests: Escape/close on both alerts keeps the file; cancelled Locate keeps it; explicit Discard deletes it; the prompt does not reappear in the same session; recovery still restores after relaunch.

### P0-02 — Export over the original (VERIFIED)

`saveExport()` only sets a suggested name in `NSSavePanel`; `export(to:)` passes the chosen URL directly to the renderer. `ExportService.write` replaces whatever exists:

```swift
if FileManager.default.fileExists(atPath: url.path) {
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
} else {
    try FileManager.default.moveItem(at: temporary, to: url)
}
```

(`ExportService.swift:348–352`.) There is no canonical-path comparison and no symlink resolution against `imageURL`. A user can overwrite the source photo, destroying the original. The temporary-file write prevents a *partial* file, not a *replaced original*.

Required tests: export to the exact source path is refused; export through a symlink/hardlink alias is refused; a different target succeeds; an explicit override (if the owner wants one) is confirmation-gated and never silent; batch output naming cannot collide with a source.

### P0-03 — Runtime installation safety (VERIFIED)

`AIRuntime.install` validates the staging layout, then:

```swift
if manager.fileExists(atPath: installDirectory.path) {
    try manager.removeItem(at: installDirectory)
}
try manager.moveItem(at: staging, to: installDirectory)
```

(`AIRuntime.swift:103–106`.) The old runtime is deleted before the new one is moved. A failed move (permissions, disk full, crash, external interference) leaves no runtime; re-downloading 388 MB is the only recovery. There is no backup directory and no rollback.

Required tests: injected `moveItem` failure restores the previous runtime; crash between delete and move is recoverable on next launch; staging is cleaned on every path; a corrupt archive never touches the installed copy; successful install replaces atomically.

### P0-04 — Metadata privacy (PARTIAL)

`strippedPrivacyMetadata` removes GPS, EXIF `UserComment`, `CameraOwnerName`, `BodySerialNumber`, `LensSerialNumber`, `ImageUniqueID`, and TIFF `Artist` (lines 1201–1219). It does **not** remove:

- `kCGImagePropertyExifMakerNote` (can contain camera serial, focus data, proprietary identifiers);
- `kCGImagePropertyIPTCDictionary` (can contain creator, contact, location, rights);
- TIFF `Make` / `Model` (camera identity);
- any future dictionary not on the blacklist.

XMP is **not** represented by the properties dictionary the app copies, so its survival depends on ImageIO and is **unverified**; it needs a fixture test rather than an assumption. The current approach is a blacklist, which is structurally fragile. The directive's preferred whitelist is the right long-term design: copy only the fields required for rendering and explicitly requested provenance.

Required tests: a fixture containing GPS, MakerNote, IPTC, XMP, serials, owner, artist, camera make/model, orientation, DPI and ICC. Assert every identifying field is absent when privacy is on, non-identifying EXIF/orientation/DPI/profile survive, and fields survive when privacy is explicitly off.

### P0-05 — Batch isolation (PARTIAL)

`exportOne` constructs a per-file snapshot and correctly clears AI edits and orientation for other files:

```swift
var fileSnapshot = snapshot
fileSnapshot.crop = useCrop ? snapshot.crop : nil
if url.resolvingSymlinksInPath() != documentURL {
    fileSnapshot.aiEdits = []
    fileSnapshot.orientation = .identity
}
```

(Lines 3062–3070.) However, it leaves `analysis` and `selectedFaceIndex` untouched, and leaves `healSpots`/`stickers` untouched when `includeStamps` is enabled. `AnalysisRenderer` consumes `settings.endpoint(for:)` and `settings.anchor(for:)` in source coordinates (`AnalysisRenderer.swift:189`, `568`), so document-specific leader lines and crop adjustments can land on a different person's face. Batch defaults keep overlays and stamps off (`EditorModel.swift:77–78`), so the default path is safe; the opt-in path is not.

Required tests: two photos with different face positions and counts; analysis on, stamps on; assert each output's overlay/stamp coordinates match its own image; `selectedFaceIndex` does not index into another photo's face list; shared settings (colors, labels, style) still apply.

### P0-06 — Model download progress (NOT REPRODUCED)

`ModelManager.consume` computes `received = offset + received` and assigns `total` from the progress line (lines 206–216). In the bundled worker, `total` is `plan["total_bytes"]` and `offset` is the cumulative bytes of already-completed files (`downloads.py:111–112,145–147`). Therefore the Swift UI already receives a plan-wide denominator; the reported bug does not reproduce against the inspected code.

Caveat: the **published runtime archive was not downloaded or inspected**, only the worker bundled inside the local `.app`. If the published archive differs, this conclusion must be re-tested. Action: add a regression test with a two-file plan, one pre-installed file and one downloaded file; assert `totalBytes` stays plan-wide and progress never moves backwards.

### P1-07 — Document state after a failed load (VERIFIED)

`load` sets `statusToken = .readingImage` and then `imageName = url.lastPathComponent` **before** decoding (lines 908–909). On failure it only sets `.couldNotRead` (923–926); it never restores the previous name. `install` sets `imageName`/`imageURL` only on success (963–964). `windowTitle` and `suggestedFileName()` both derive from `imageName` (2641–2644, 2661–2677), so a failed open changes the title and the default export name of the document still on screen.

Required tests: open A successfully, then attempt unreadable B; title and suggested export name must still describe A; with no prior document, a failed load must leave the app title, not B's name; status still reports the failure.

### P1-08 — Batch cancellation (PARTIAL)

`cancelBatchExport()` cancels only `batchTask` (2969–2971). The loop checks cancellation between files (3011), but each file runs in a new detached task (3014–3020) that does **not** inherit cancellation. `ExportService.run` checks `Task.isCancelled` (123, 133), but that detached task is never cancelled. A multi-minute AI upscale can therefore continue after Cancel and still write its output.

Single-export cancellation is correct: `cancelExport()` cancels `exportJob` (2772–2773), and `ExportService.run` observes it. Output writes are temp-file + replace, so no partial file is left behind.

Required tests: cancel during a slow batch file stops the work promptly, writes no file for the cancelled item, already-completed files remain valid, status is `.batchCancelled`, and a following batch can start cleanly.

---

## 6. Recommended shared architecture

This is a **proposal**, not a description of the current code. It is designed to preserve the existing macOS app as the reference implementation while enabling Windows and Linux.

### 6.1 Principles

1. **Quality reference first.** The macOS Core Image pipeline remains the oracle until a portable engine passes a frozen golden-image corpus.
2. **One document model, two shells.** UI is a shell; document operations are shared.
3. **No algorithm changes during extraction.** Ports are behavior-preserving; improvements are separate, approved changes.
4. **Platform code at the edges.** File dialogs, menus, fonts, color profiles, IPC, signing and updates are adapters.
5. **Local-first AI.** No cloud dependency for any offline workflow; model downloads are explicit, licensed and hash-verified.

### 6.2 Target layers

```text
┌────────────────────────────────────────────────────────────────────┐
│ UI shells                                                          │
│  macOS: SwiftUI/AppKit (kept)                                      │
│  Windows/Linux: Qt 6/QML (recommended)                             │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ command/query API, no UI types
┌──────────────────────────────▼─────────────────────────────────────┐
│ StudioCore                                                         │
│  document model · operation graph (non-destructive) · undo/history │
│  presets · export policy · project format · validation             │
│  localization catalog · status/telemetry (local only)              │
└───────────────┬──────────────────────────────┬─────────────────────┘
                │                              │
┌───────────────▼──────────────┐  ┌────────────▼─────────────────────┐
│ ImageEngine                  │  │ AIEngine                         │
│  decode/encode · color       │  │  face mesh/landmarks             │
│  filter graph · masks        │  │  person/background segmentation  │
│  heal/warp · analysis lines  │  │  body pose · upscale             │
│  tiling · deterministic CPU  │  │  ONNX Runtime + EP selection     │
│  GPU backend (wgpu)          │  │  model manifest/consent/license  │
└───────────────┬──────────────┘  └────────────┬─────────────────────┘
                │                              │
┌───────────────▼──────────────────────────────▼─────────────────────┐
│ Runtime + Platform adapters                                        │
│  files · dialogs · windows/menus · fonts · color profiles · IPC    │
│  process launch · HTTP · crypto · updates · signing · crash reports│
└────────────────────────────────────────────────────────────────────┘
```

### 6.3 Proposed module boundaries

| Module | Owns | Must not import |
|---|---|---|
| `studio-core` | document model, operation graph, project format, export rules, presets, recovery policy | UI, OS dialogs, GPU |
| `image-engine` | buffers, color, filter DAG, masks, heal, warp, overlays | UI, dialogs, AI process |
| `ai-engine` | model lifecycle, inference sessions, tiling, provenance | UI, document persistence |
| `runtime` | filesystem, HTTP, processes, IPC, crypto, clock | UI, document logic |
| `platform-macos` | SwiftUI/AppKit shell, Core Image reference backend, bookmarks | nothing above its adapter API |
| `platform-windows` | Qt shell, DirectWrite/WIC/DirectML adapters | document internals |
| `platform-linux` | Qt shell, fontconfig/lcms2/CUDA-or-CPU adapters | document internals |

### 6.4 What should not be shared

- SwiftUI views. They are macOS-specific.
- Core Image kernels as the cross-platform implementation. They may remain the macOS fast path, but the portable engine must not depend on them.
- Apple bookmarks in the shared project manifest.
- Python as a mandatory runtime.

---

## 7. Rust vs C++ vs Swift

| Criterion | Rust | C++ | Swift |
|---|---|---|---|
| Memory safety | Strong, compile-time | Manual | Strong (ARC), but leaks/cycles possible |
| Cross-platform UI | No first-class UI; bindings (Qt/Slint) | Mature Qt 6 | No viable Windows/Linux UI story |
| Image ecosystem | Growing (`image`, `imgref`, `rawloader`, `lcms2`, ONNX bindings) | Deepest: OpenCV, LibRaw, lcms2, Qt, ONNX | Apple-only for production imaging |
| GPU | `wgpu` (Metal/Vulkan/DX12), compute shaders | Native Metal/Vulkan/D3D; most mature | Metal only |
| Build/reproducibility | Cargo, lockfiles, good CI story | CMake/vcpkg/conan complexity | SwiftPM + Xcode/CLT; Windows toolchain immature |
| Talent/ramp-up | Steep initial curve | Large talent pool, older codebases | macOS talent only |
| Interop with current app | C ABI / FFI, or rewrite behind a façade | C ABI, easiest with existing C APIs | Direct, but only on Apple platforms |
| Risk for a 5-year product | Low long-term, medium short-term | Low performance risk, high safety risk | High platform risk |

**Recommendation:** Rust for the shared core and portable image engine; Swift for the macOS shell and as the temporary reference backend; C++ only if the team already has deep Qt/OpenCV/LibRaw expertise and wants one language for engine + shell.

**Why not Swift everywhere:** Swift on Windows/Linux exists, but there is no mature, production-grade SwiftUI/AppKit equivalent, the imaging ecosystem is Apple-centric, and the build/test/debug toolchain off macOS is not at the level this product needs. Choosing Swift as the sole language would still require a second UI framework and would add platform risk without removing the port.

**Why not C++ everywhere:** C++ is viable and has the best imaging ecosystem, but memory-safety defects in a photo editor that handles user originals are a poor trade. Rust gives comparable performance with a safer core, and `wgpu` covers Metal/Vulkan/DX12.

---

## 8. UI framework comparison

| Framework | macOS | Windows | Linux | Pro-editor fit | Risks |
|---|---|---|---|---|---|
| SwiftUI + AppKit | Native, current | No | No | Excellent on macOS | Cannot cross-compile |
| Qt 6 (Widgets/QML) | Good | Native-quality | Native-quality | Strong: docks, menus, IME, RTL, tablet events, accessibility | Licensing (LGPL/commercial), QML performance discipline |
| Flutter | Good | Good | Good | Medium: custom rendering, color-management/plugin gaps | Desktop plugin maturity, text/IME/RTL edge cases, memory |
| Tauri + web UI | Good | Good | Good | Weak for pixel-accurate pro editing | WebView color/perf/memory, native integration |
| Avalonia (.NET) | Good | Good | Good | Medium | Adds C# stack; imaging/GPU interop |
| Slint | Good | Good | Good | Immature for complex pro UI | Ecosystem, accessibility, widgets |
| Electron | Good | Good | Good | Weak | Memory, color management, bundle size |

**Recommendation:** keep SwiftUI/AppKit for macOS; use **Qt 6/QML** for Windows and Linux. Reasons: native menus and file dialogs, robust IME/RTL/bidi support (a hard requirement for Persian), tablet/stylus events for retouching, mature accessibility, and a clear path to platform color management and GPU interop. Use a shared design-token layer and shared view models so Simple/Pro modes do not fork behavior.

**Simple/Pro implications:** treat “Simple” and “Pro” as two presentations of the same document API, not two applications. Pro features (history panel, workspaces, batch recipes, color-managed soft proof) belong in the shell and core history layer, not in the image kernels.

---

## 9. AI runtime recommendation

### 9.1 Current state

- Python process, JSON-RPC over `AF_UNIX`.
- PyTorch, Transformers, ONNX Runtime and MLX are present in the runtime; the archive is 388,277,063 bytes and arm64-only.
- Intel builds deliberately disable AI (`AIRuntime.package` returns `nil` under `x86_64`).
- Models are downloaded separately with a consent hash; the bundled worker verifies SHA-256 and stages downloads.
- Model weights are **not** in the repository or app bundle.

### 9.2 Recommended target

1. **ONNX Runtime as the common inference layer** with execution providers: Core ML on macOS, DirectML on Windows, CUDA/TensorRT optional on Linux, CPU as the guaranteed fallback.
2. **A small Rust `ai-engine`** owning model manifests, sessions, tiling, tensor layout and provenance. No Python requirement for the core product.
3. **Keep the Python/MLX path only for macOS-only experimental generation** (for example FLUX-style features), isolated behind the existing worker boundary and clearly marked. Do not make it a dependency of segmentation, face landmarks, pose or upscale.
4. **Model manifest** per model: id, version, task, license, source URL, SHA-256, byte size, input/output contract, minimum RAM, hardware requirements. The UI must show license and source before download.
5. **Provenance in projects:** for every AI edit, store model id/version/hash, prompt, seed, strength, mask hash and timestamp. Reproducibility is a product requirement, not metadata decoration.
6. **Memory policy for 16 GB machines:** tiled inference, quantized models where quality permits, hard guards before loading a model, and a clear “not enough memory” path. These are targets until measured on the owner's hardware.

### 9.3 Migration path

- Phase A: keep Python worker; add a shared request/response schema and provenance records.
- Phase B: add ONNX sessions for segmentation/face/pose in the native engine; run both paths on a benchmark corpus.
- Phase C: switch one feature at a time after quality gates; keep Python for the macOS-only generative feature.
- Phase D: remove PyTorch/Transformers from the default runtime and shrink the download.

Never switch a model silently: a model change is a versioned, approved change with a visible diff in output quality.

---

## 10. Project format proposal (v4)

Current v3 is a single JSON sidecar with `imagePath` (absolute) and an Apple bookmark (`Models/Project.swift:20–24`), plus adjustments, crop, orientation, heal spots, stickers, AI edits, analysis and selected face. It is a good non-destructive foundation; it is not portable or asset-complete.

### 10.1 Proposed container

A `.retouch` **directory package** (zipped for transport), with a versioned manifest:

```text
MyEdit.retouch/
  manifest.json          # format version, app version, created/modified, flags
  source.json            # original filename, relative path, size, hash, dimensions, color profile
  operations.json        # ordered non-destructive operations with stable IDs
  masks/                 # content-addressed masks (PNG/16-bit where needed)
  ai/                    # patches, alpha, provenance JSON, model references
  previews/              # optional fast-open JPEG + thumbnail
  platform/macos.json    # bookmark, security-scoped data (never read by other platforms)
```

### 10.2 Rules

- **Relative source paths by default.** Resolve against the project location, then a user-configured search list, then ask the user. No Apple bookmark in `source.json`.
- **Content hashes** (SHA-256 or BLAKE3) for source and every asset. A moved file is relinkable; a changed file is detected.
- **Original is never embedded by default.** Offer “include original” as an explicit, size-warning option for portable handoff.
- **Explicit coordinate spaces.** Every geometric operation records its space (source pixels, normalized top-left, or post-crop pixels). No implicit Core Image coordinates.
- **Stable operation IDs** and an ordered list; undo/history is derived, not stored as duplicated state.
- **Unknown fields are preserved** on read/write so newer projects opened by older builds do not lose data silently.
- **Atomic save:** write to a temporary sibling, fsync, then rename; keep one previous manifest for crash recovery.
- **Migration chain:** v1→v2→v3→v4 with fixtures. A project that cannot be migrated must open read-only with a clear message, never be partially rewritten.
- **No absolute paths, no bookmarks, no platform-only types in shared JSON.**

### 10.3 Sketch

```json
{
  "format": "retouch-project",
  "version": 4,
  "source": {
    "name": "portrait.jpg",
    "path": "originals/portrait.jpg",
    "bytes": 12345678,
    "sha256": "…",
    "pixelSize": { "width": 6000, "height": 4000 },
    "colorSpace": "Display P3"
  },
  "operations": [
    { "id": "op-001", "type": "crop", "space": "source-pixels",
      "rect": { "x": 0, "y": 0, "width": 6000, "height": 4000 } },
    { "id": "op-002", "type": "orient", "turns": 0, "mirror": false, "straighten": 0.0 },
    { "id": "op-003", "type": "skin", "params": { "…": "…" } }
  ],
  "assets": {
    "masks": [{ "id": "mask-face-1", "path": "masks/face-1.png", "sha256": "…" }],
    "ai": [{ "id": "ai-001", "patch": "ai/001.png", "alpha": "ai/001-alpha.png",
             "model": { "id": "…", "version": "…", "sha256": "…" },
             "prompt": "…", "seed": 42, "created": "2026-11-09T12:00:00Z" }]
  },
  "ui": { "selectedFace": 0, "tool": "skin" },
  "platform": { "macos": { "bookmark": "…" } }
}
```

The exact schema is a Phase 1 design deliverable; the rules above are the non-negotiable parts.

---

## 11. Cross-platform feasibility

| Area | Feasibility | Work | Risk |
|---|---|---|---|
| Document model + project format | High | Replace Apple geometry/bookmarks; add migration | Medium |
| UI shell | High | Build Qt 6/QML shell; keep SwiftUI macOS | High effort, medium quality risk |
| Decode/encode (JPEG/PNG/TIFF/HEIC) | High | WIC/libvips/libheif; golden corpus | Medium |
| RAW | Medium | LibRaw + profile pipeline; lens corrections | High quality risk |
| Color management | Medium | lcms2/WCS/ColorSync adapters; ICC fixtures | High |
| Core Image filter graph | Medium | Rust/wgpu + CPU fallback; port kernels | High |
| Vision face/segmentation/pose | Medium | ONNX models; benchmark against Vision | High |
| Healing/warp | Medium | Port kernels; deterministic interpolation | High |
| Analysis overlay/text | High | DirectWrite/HarfBuzz/CoreText adapters | Medium |
| AI runtime | Medium | ONNX Runtime + EPs; provenance | Medium |
| IPC | High | Named pipes / authenticated loopback | Low |
| File dialogs/menus/shortcuts | High | Qt adapters | Low |
| RTL/IME/Persian typography | High | Qt + HarfBuzz + Vazir; test both languages | Medium |
| Accessibility | Medium | Per-shell baseline | Medium |
| Packaging/signing/updates | Medium | Per-platform toolchains; notarization | High |
| Performance parity | Unknown | Benchmark on real hardware | High |

**What cannot be claimed without hardware:** native Windows validation, native Linux validation, DirectML/CUDA behavior, Windows color management, Linux distro packaging, Windows Ink/tablet behavior. This audit ran only on macOS (arm64). Every cross-platform statement above is a feasibility judgment, not a validation result.

---

## 12. Migration roadmap

| Phase | Scope | Duration (pw) | Exit gate |
|---|---|---:|---|
| 0 | This read-only audit | done | Owner approval |
| 1 | Data-integrity fixes: P0-01, P0-02, P0-03, P1-07 + tests | 6–10 | All new tests pass; self-test passes; no algorithm change |
| 2 | Privacy, batch isolation, batch cancellation (P0-04/05, P1-08) + P0-06 regression test | 6–10 | Fixture and batch tests pass |
| 3 | Freeze a golden-image corpus and characterize the current engine | 8–12 | Hashes/tolerances recorded for every tool |
| 4 | Extract `StudioCore` boundaries without changing output | 12–18 | Core compiles/tests without AppKit or SwiftUI |
| 5 | Rust `image-engine` + wgpu/CPU; parity harness | 24–36 | Parity gate on corpus; macOS can opt in |
| 6 | Project format v4 + v1–v3 migration | 6–10 | Round-trip and migration fixtures pass |
| 7 | Windows shell + platform adapters | 20–28 | Native Windows test pass on real hardware |
| 8 | Linux shell + packaging | 8–14 | Native Linux test pass on target distros |
| 9 | AI engine unification on ONNX Runtime | 14–22 | Feature-by-feature quality gates |
| 10 | Pro UI: history, workspaces, Simple/Pro | 18–28 | UX acceptance, both languages |
| 11 | Hardening: CI, signing, notarization, accessibility, docs | 10–14 | Release checklist complete |

**Sequencing rules**

- Phases 1–2 are independent of the architecture work and should land first.
- Phase 3 must precede any engine port; without a frozen oracle, “it looks the same” is not evidence.
- Phase 5 must ship behind a feature flag/alternate backend until parity is proven.
- Phases 7 and 8 can run in parallel once `StudioCore` and `ImageEngine` are stable, but Windows and Linux validation require separate hardware/CI.
- No phase may remove a working macOS feature; the macOS shell remains shippable throughout.

---

## 13. Risk matrix

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Image-quality regression during engine port | High | High | Golden corpus, per-tool tolerances, dual-run, owner sign-off |
| UI divergence / feature lag between shells | High | Medium | Shared view models + design tokens; screenshot tests |
| Color-management mismatch | High | High | ICC fixtures, lcms2 validation, soft-proof tests |
| GPU/driver differences | Medium | High | Deterministic CPU tier; shader tests; per-vendor CI |
| No native Windows/Linux validation | Certain | High | Acquire hardware, CI matrix, explicit “unvalidated” labels |
| Rust ramp-up slows delivery | Medium | Medium | Early spike, pair programming, keep C++ escape hatch |
| Qt licensing/plugin gaps | Low | Medium | Legal review; LGPL dynamic linking or commercial license |
| Model licensing/size | Medium | High | License field in manifest, consent, optional downloads |
| 16 GB memory pressure | Medium | High | Quantization, tiling, guards, measured limits |
| Project backward compatibility | Medium | High | Migration fixtures, read-only fallback, no silent rewrite |
| Scope creep (cloud, social, mobile) | High | High | Milestone gates; explicit non-goals per phase |
| Unsigned/unsandboxed distribution | High | Medium | Signing/notarization plan; sandbox feasibility study |
| Build non-reproducibility | Medium | Medium | Pin SDK/toolchains, lockfiles, CI |
| Bus factor | Medium | High | Docs, tests, pairing, no single-owner modules |

---

## 14. Estimated development effort

Person-weeks (pw), ±40%. Estimates assume the current team is familiar with the code, that the macOS reference stays shippable, and that model licensing does not block release.

| Work package | pw |
|---|---:|
| Stabilization (P0/P1 fixes + regression tests) | 12–20 |
| Engine characterization + golden corpus | 8–12 |
| Shared core extraction | 12–18 |
| Rust image engine + wgpu/CPU parity | 24–36 |
| Project format v4 + migration | 6–10 |
| Windows shell + adapters | 20–28 |
| Linux shell + packaging | 8–14 |
| AI engine unification | 14–22 |
| Pro UI (history, workspaces, Simple/Pro) | 18–28 |
| Hardening, CI, signing, accessibility, docs | 10–14 |
| **Total** | **132–202** |

Calendar scenarios:

- **Three engineers** (Rust/imaging, Qt/platform, Swift/AI): ~10–16 months, with platform validation as the critical path.
- **Two engineers:** ~15–24 months.
- **One senior engineer:** ~31–47 months.
- An earlier planning figure of 126–192 pw covered roughly the same work; this table adds an explicit stabilization line and contingency for platform certification.

Excluded: model research/training, legal licensing work, hardware purchase, cloud services, mobile apps, and any feature not already in the directive.

---

## 15. Recommended first implementation milestone

### Milestone 1 — Data integrity (no architecture change)

**Fix, in this order:**

1. **P0-01 Recovery cancel semantics.** Add an explicit Cancel, make Escape/close defer, never delete on cancel; delete only on the explicit destructive action.
2. **P0-02 Original protection.** Canonicalize and resolve symlinks for destination and source; refuse equality; if an override is desired, require an explicit confirmation. Keep the atomic temp-file write.
3. **P0-03 Transactional runtime install.** Stage → validate → back up current → atomic swap → verify → delete backup; roll back on failure or crash.
4. **P1-07 Failed-load document identity.** Set `imageName`/`imageURL` only after a successful decode; restore the previous document's title and export name on failure.

**Tests to add (the milestone is not done without them):**

- Recovery: Escape, close, cancelled Locate, explicit Discard, once-per-session, relaunch restore.
- Export: exact source path, symlink alias, hardlink alias (where detectable), safe target, batch naming.
- Runtime: injected move failure, crash-between-steps recovery, corrupt archive, successful replacement, staging cleanup.
- Load: failed load with and without a prior document; title and suggested filename unchanged; status correct.
- Both UI languages for every new alert/string.
- Full `./Tests/run.sh` and app `--selftest` must pass.

**Acceptance:** all existing 336 assertions still pass; new tests pass; no image algorithm changes; no project-format change; no UI redesign.

**Duration:** 1.5–2.5 weeks for one engineer familiar with `EditorModel`, `ExportService`, `AIRuntime` and `Recovery`.

**Explicit non-goals:** Rust, Qt, ONNX migration, project format v4, new features, UI changes, model changes.

**Then stop for a second approval.** Milestone 2 (P0-04, P0-05, P1-08, P0-06 regression test) should follow only after Milestone 1 is verified, because privacy and batch isolation need fixtures that are easier to add on a stable base.

---

## Appendix A — Verified facts vs assumptions

### Verified in this audit

- Working tree clean at `5d8642f`; no source changes made.
- 69 Swift files, 31,788 lines under `Sources/`; Views 7,455; Core 13,458; Models 10,575.
- `EditorModel` 3,135 lines; `ImageProcessor` 1,233; `ExportService` 358; `Localization` 471 string properties + 471 Persian overrides.
- Imports: Foundation 47, CoreGraphics 27, SwiftUI 24, CoreImage 19, AppKit 14, UTI 6, ImageIO 6, Vision 2, Combine 2, CryptoKit/CoreVideo/CoreText 1 each.
- 16 `accessibility*` modifiers across the Views.
- Build: direct `swiftc`, universal, ad-hoc signing, self-test gate, Rosetta Intel self-test.
- App bundle 1.3 GB with helper; declared runtime archive 388,277,063 bytes, SHA-256 `cb1485be…`, arm64 only.
- Python worker source absent from the repository; bundled copy present inside the `.app`.
- All P0/P1 code paths quoted above.
- Test suite: see Appendix B.

### Assumptions / open questions

- The published runtime archive was not downloaded; only the bundled worker was inspected.
- XMP survival through the current ImageIO write path is unverified.
- No performance measurement was made with Instruments; no Windows/Linux hardware was used.
- Model licenses and redistribution terms were not legally reviewed.
- The owner has not yet chosen Qt vs another shell, or Simple/Pro UX specifics.
- The directive's long-term cloud-AI option was not designed; it is out of scope for offline workflows.
- Effort estimates are planning ranges, not commitments.

---

## Appendix B — Test evidence

Command: `./Tests/run.sh`
Environment: macOS arm64, Command Line Tools SDK, commit `5d8642f`.
Result: **PASS** — 336 assertions, 0 failures (engine + model suites), 2026-11-09.

The suite is a custom harness because the project builds with `swiftc` and has no Xcode test runner. It links all sources except `App.swift` and `SelfCheck.swift`. It does not cover most P0/P1 items listed above.

---

## Appendix C — Method and limits

- Read the build, manifest, plist, all engine/model entry points, the views inventory, tests, and the bundled worker's download path.
- Re-ran the test suite.
- Did not run the app UI, did not install dependencies, did not download the AI runtime, did not modify files.
- Older `Docs/TECHNICAL_AUDIT.md` line numbers were not trusted; they describe an earlier commit.
- This document supersedes earlier line-number claims where they differ.

---

## Appendix D — Approval request

Phase Zero is complete. No code has been changed.

**Requested approval:** Milestone 1 only (P0-01, P0-02, P0-03, P1-07 plus tests), as described in section 15. Architecture extraction, Rust/Qt work, project v4 and AI migration remain blocked until separate approval.
