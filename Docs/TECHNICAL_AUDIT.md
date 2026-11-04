# Retouch Studio — Deep Technical Audit

**Document type:** Read-only technical audit and architecture assessment
**Revision audited:** `8cc2d0c` ("fix: ignore window-activating clicks and dim dead background controls") plus 26 uncommitted changes in the working tree (23 modified files and three untracked analysis files); this document is the only file the audit itself added
**Audit date:** 2026-11-04
**Auditor's constraint:** No source file was modified, refactored or rewritten. This document is the only artifact created.
**Post-audit addendum (2026-11-04):** §14 records the disposition of every Critical and High finding and of the P1/P2 items in the companion plan, with commit hashes and test names. The findings below remain as written in the audited snapshot.
**Companion brief:** The task refers to an existing "Project Brief". At the start of the audit no such document existed in the repository (a tree-wide search returned no `*.md`, `README`, `docs/`, or brief of any kind). This audit therefore stands alone and reconstructs intent from source, comments and the verified behaviour of the build.

---

## Scope and Method

The audit covers the entire shipping target:

- `Sources/RetouchStudio/` — 23,232 Swift lines across `App.swift`, `Core/`, `Models/`, `Views/`.
- `Tests/EngineTests.swift` (331 lines) and `Tests/run.sh`.
- `build.sh`, `Package.swift`, `Resources/Info.plist`, `Resources/Fonts/`, `Resources/make-icon.sh`.
- Git working-tree state, `.gitignore`, and the build output directory (inspected, never committed).

Evidence rules applied throughout:

1. A feature is called **Implemented** only when its code path is complete from entry point to output.
2. A feature is called **Verified** only when a test was executed successfully during this audit. Executed commands and their results are in §9.
3. A feature is **Partial** when a real path exists but a named user-facing capability is missing or inconsistent.
4. A feature is **Absent / Planned** when no code path exists, regardless of comments suggesting it.
5. No feature is labelled **Experimental**: every shipped path is reachable from the UI. Where a path is newest or thinly covered, that is stated in the coverage column rather than by downgrading its implementation status.
6. All findings cite a file and line range. Line numbers refer to the audited working tree and will drift after further edits.

**Important:** this is a static-plus-execution audit of the local build. It is not a usability study with representative retouchers, and it does not measure wall-clock performance on a controlled benchmark rig. Performance statements are derived from buffer sizes, render paths and observable behaviour, and are labelled as such.

---

## 1. Executive Summary

### 1.1 Verdict

Retouch Studio is a **complete, self-contained, local-only professional portrait retoucher** with an unusually deep image engine for its size. All twelve tools in the request exist as working code, the preview/export pipeline is a single deterministic Core Image graph, the app speaks English and Persian throughout, and both automated suites pass on the audited revision.

The engine is the strongest part of the product: masks are built once per frame, retouch runs before geometry so features and their masks stay aligned, colour grading is ordered deliberately, and the build refuses to produce an app if the 154-check synthetic self-test fails. The data model is genuinely non-destructive: a project stores slider state, crop, heal stamps, stickers and analysis settings against the untouched original photo.

The main risks are **not** in the pixel engine. They concentrate in **document lifecycle and state transitions**:

- A successful **export marks the document clean**, so unsaved slider work is no longer protected by the discard prompt (`EditorModel.swift:1941-1942`).
- **Smart Analyze overwrites untouched groups wholesale**, silently zeroing user-set finish, iris, lash, lens, teeth-alignment, split-tone, curve, HSL and vignette values (`Adjustments.swift:366-408`, `EditorModel.swift:1666-1688`).
- **Reset All is incomplete**: it clears adjustments and stickers but leaves heal stamps and the analysis overlay (`EditorModel.swift:1469-1476`).
- **Crop is outside undo/redo** because `appliedCrop` is not part of `EditState` (`EditorModel.swift:146-151`).
- **Projects store an absolute image path** with no relink flow (`Project.swift:17`, `EditorModel.swift:1974-1987`).
- **Batch Export does not match single export**: it ignores heal stamps, stickers and the analysis overlay, and applies the current photo's normalized crop to every selected file (`EditorModel.swift:2060-2122`).

These are fixable without touching the engine, and they are the P0/P1 items of §12.

### 1.2 Executed verification (summary)

| Suite | Command | Result |
|---|---|---|
| Engine tests | `./Tests/run.sh` | **PASS** — all 7 groups, exit 0 |
| Build + synthetic self-test | `./build.sh` | **exit 0** — 154 checks passed, 0 failed, `SELFTEST: PASS` |
| Real-photo self-test | `./build/bin/RetouchStudio --selftest --face "$HOME/Documents/image test/IMG_7196.JPG" --out /tmp/rs-audit-face` | **exit 0** — 166 checks passed, 0 failed, `SELFTEST: PASS` |

The real-photo output was written to `/tmp/rs-audit-face` and no private photo was copied into the repository, per the project's privacy constraint.

All three suites were executed again on 2026-11-04 for the advanced audit: engine tests 33/33, synthetic self-test 154/154, and real-photo self-test 166/166, each exiting 0 with `PASS`. The rerun logs are indexed in Appendix C.

### 1.3 Severity distribution

| Severity | Count | Meaning |
|---|---|---|
| Critical | 1 | Silent loss of user work |
| High | 7 | Wrong output, broken workflow, or silent destruction of settings |
| Medium | 18 | Quality, performance, accessibility, or robustness limitation with a workaround (includes L-1 and L-2) |
| Low | 5 | Maintainability, documentation, or cosmetic debt |

The counts include the six findings added by the advanced audit in §13 (H-7, M-13…M-16, L-7); §10 contains the full register.

### 1.4 Top ten findings

| # | Finding | Severity | Primary evidence |
|---|---|---|---|
| 1 | Export marks the document clean, disarming the unsaved-changes guard | Critical | `EditorModel.swift:1941-1942` |
| 2 | Smart Analyze zeroes unrelated retouch and colour fields | High | `Adjustments.swift:366-408`, `EditorModel.swift:1670-1677` |
| 3 | Reset All leaves heal stamps and the analysis overlay behind | High | `EditorModel.swift:1469-1476` |
| 4 | Batch export diverges from single export and reuses one crop for all photos | High | `EditorModel.swift:2060-2122` |
| 5 | Project files store absolute photo paths; no relink | High | `Project.swift:17`, `EditorModel.swift:1974-1987` |
| 6 | Crop changes are not undoable | High | `EditorModel.swift:146-151`, `798-813` |
| 7 | Heal stamps are circles in normalized space, therefore ellipses in pixels on non-square photos | Medium | `Heal.swift:66-74` |
| 8 | Preview and export disagree on blemish kernel size on high-resolution photos | High | `ImageProcessor.swift:702` |
| 9 | Masks are capped at 1600 px and store 4 bytes per pixel | Medium | `MaskBuilder.swift:44-69` |
| 10 | 16 Core Image kernel-language constructions are deprecated since macOS 10.14 | Medium | 16 constructions in 5 Core files |

### 1.5 Advanced audit additions

Section 13 is a second, code-level pass. It adds six findings that the feature-level audit in §2–§12 did not isolate:

| New finding | Severity | One-line statement |
|---|---|---|
| H-7 | High | Every detected face is edited, while the blemish, teeth-align and hair-volume radii and the makeup family are taken from `faces.first`; there is no face selection and no Vision confidence filter. |
| M-13 | Medium | Export, Save, Save As and project Open are not serialised with Load, Crop, preview or each other, and one Boolean `isBusy` is shared by independent tasks. |
| M-14 | Medium | Even Skin Tone is documented as luminance-preserving but blends a full-RGB blurred copy, so it also changes shading and local contrast. |
| M-15 | Medium | Teeth alignment grows the enamel mask before its median repair; the grown band can include the inner lip or gum line. |
| M-16 | Medium | A face observation without landmarks feeds `.null`-derived rectangles into cheek, blush and under-eye masks; `hasLandmarks` is written but never read. |
| L-7 | Low | `Package.swift` is not the build path, and several accessors (`hasLandmarks`, `isBeyondPixelAccuracy`, four `MaskSet` fields) are dead; a fifth, `MaskSet.face`, is read only by the self-test. |

No new Critical finding was added. C-1 remains the only Critical issue, and M-13 is one of the ways it can be amplified across documents.

---

## 2. Project Architecture

### 2.1 Repository structure

```
RetouchStudio/
├── Package.swift                               SwiftPM manifest (5.9, macOS 14) — not used by build.sh
├── build.sh                                    compiler driver + app bundling + self-test gate
├── Resources/
│   ├── Info.plist                              bundle identity, font path, document types
│   ├── AppIcon.icns
│   ├── make-icon.sh                            icon generator (source of the chosen mark)
│   └── Fonts/                                  Vazirmatn Regular/Medium/SemiBold/Bold + OFL
├── Sources/RetouchStudio/
│   ├── App.swift                               @main, AppDelegate, window, menu commands
│   ├── Core/                                   image engines (no UI imports except AppKit types)
│   │   ├── ImageProcessor.swift    (1,109)     load, masks, pipeline, export
│   │   ├── SkinEngine.swift          (749)     frequency separation, blemish, wrinkles, eyes, teeth
│   │   ├── FeatureReshaper.swift     (554)     face and body warp kernels
│   │   ├── LookEngine.swift          (390)     levels, curve, split tone, HSL, cube looks, grain
│   │   ├── MakeupEngine.swift        (289)     lips, cheeks, liner, shadow, brows, hair, lens
│   │   ├── SceneEngine.swift         (387)     person mask, background blur/fill/remove, body helpers
│   │   ├── MaskBuilder.swift         (271)     shape → soft grayscale mask
│   │   ├── FaceAnalyzer.swift        (485)     Vision landmarks → FaceGeometry
│   │   ├── AutoAnalyzer.swift        (526)     512 px statistics, teeth/eye pixel gates
│   │   ├── SmartAnalyzer.swift     (1,364)     report generation for Smart Analyze
│   │   ├── AnalysisRenderer.swift    (749)     analysis overlay, poster, mesh (untracked)
│   │   └── ArtRenderer.swift         (174)     procedural stickers
│   ├── Models/
│   │   ├── EditorModel.swift       (2,132)     @MainActor application state machine
│   │   ├── Adjustments.swift       (1,007)     the edit document + 40 presets
│   │   ├── Localization.swift        (854)     English string table (class)
│   │   ├── PersianL10n.swift         (822)     Persian overrides (class)
│   │   ├── Project.swift                       .retouch JSON schema
│   │   ├── Recovery.swift                      crash-recovery sidecar
│   │   ├── AppSettings.swift                   preferences + recents
│   │   ├── Makeup.swift              (374)     HSV colours, families, 58 shades
│   │   ├── Look.swift                (110)     6 film grades
│   │   ├── ToolMode.swift                     12 tools + shortcut keys
│   │   ├── Heal.swift                          stamps and crop mapping
│   │   ├── Sticker.swift, Crop.swift, Analysis.swift (untracked), UserPreset.swift,
│   │   ├── StatusToken.swift, AppLanguage.swift, Digits.swift
│   └── Views/
│       ├── EditorView.swift          (289)     shell + export sheet
│       ├── TopBar.swift              (160)     tool rail and document title
│       ├── ToolPanel.swift           (313)     left column
│       ├── InspectorView.swift     (1,155)     right accordion, 11 panels
│       ├── CompareCanvas.swift       (662)     canvas, pan/zoom, split, dock
│       ├── CanvasInteraction.swift   (129)     local NSEvent monitor
│       ├── HealOverlay.swift          (73)
│       ├── CropOverlay.swift         (204)
│       ├── ArtOverlay.swift          (174)
│       ├── AnalysisOverlay.swift     (136)     (untracked)
│       ├── SmartAnalyzeSheet.swift   (393)
│       ├── SettingsView.swift        (275)
│       ├── InfoViews.swift           (278)     About and Help windows
│       ├── Theme.swift               (195)     tokens and motion
│       ├── Components.swift          (563)     shared controls
│       └── LineIcon.swift                      SF Symbol wrapper
├── Tests/
│   ├── EngineTests.swift             (331)     7 engine groups; compiled as main.swift
│   └── run.sh                                  compiles sources except App.swift/SelfCheck.swift
└── Docs/TECHNICAL_AUDIT.md                     this document
```

### 2.2 Layering

The dependency direction is clean and one-way:

```
App.swift
   └── EditorView ── TopBar / ToolPanel / CompareCanvas / InspectorView / sheets
           │                    │
           │            CanvasInteraction (NSEvent → EditorModel)
           ▼
      EditorModel  (@MainActor ObservableObject)
        ├── Adjustments, Project, Recovery, AppSettings, Heal, Sticker, Crop, Analysis
        └── ImageProcessor
              ├── FaceAnalyzer / AutoAnalyzer / SmartAnalyzer
              ├── MaskBuilder
              └── SkinEngine / MakeupEngine / FeatureReshaper / LookEngine / SceneEngine
                    └── ArtRenderer, AnalysisRenderer
```

- Engines are stateless `enum`s with static functions, except `ImageProcessor`, a singleton owning the one `CIContext`.
- `Adjustments` is a value type and the single source of truth for an edit. It is `Equatable`; identity/no-op behaviour is asserted by the test suite.
- `EditorModel` owns all mutable session state. Views never call engines; they mutate `@Published` values or call model methods.
- The only AppKit event bridge is `CanvasInteraction.swift`, deliberately implemented as a *local monitor* so SwiftUI gestures on sliders and overlays are not swallowed (comment at `CanvasInteraction.swift:6-9`).

### 2.3 Concurrency model

| Concern | Mechanism | Evidence |
|---|---|---|
| UI state | `@MainActor final class EditorModel` | `EditorModel.swift:8-9` |
| Image load | `loadTask` + `Task.detached(.userInitiated)` | `EditorModel.swift:621-655`, `832-843` |
| Preview render | 40 ms debounce, `generation` token, detached render | `EditorModel.swift:1431-1465` |
| Smart Analyze | detached analysis, `isAnalyzingSmart` guard | `EditorModel.swift:1624-1661` |
| Export | detached full-resolution render | `EditorModel.swift:1873-1948` |
| Batch export | one `batchTask`, sequential files, detached per file | `EditorModel.swift:2060-2122` |
| Person mask | lazy, one Vision pass shared by mask + pose | `SceneEngine.swift:120-126` |
| Crash recovery | 1.5 s debounced write, atomic JSON | `EditorModel.swift:1752-1765`, `Recovery.swift:22-33` |
| Core Image LUT cache | `NSLock`-protected dictionary, capped at 24 cubes | `LookEngine.swift:240-290` |
| Sticker glyph cache | `NSCache<NSString, NSImage>` | `ArtRenderer.swift:18-40` |

The generation-token pattern is consistently applied. Cancellation is only *logical*, however: `Task.cancel()` on a detached Core Image render cannot interrupt work already executing on the GPU/CPU. See §5.4.

### 2.4 Build and packaging

`build.sh` is the real build system. It probes installed Command Line Tools SDKs, type-checks a SwiftUI `@State` snippet against each, and selects the first SDK that supports the SwiftUI macros. It then compiles with:

```
swiftc -target arm64-apple-macosx14.0 -sdk <probe> -O -whole-module-optimization \
       $(find Sources -name '*.swift') \
       -framework SwiftUI -framework AppKit -framework CoreImage \
       -framework Vision -framework UniformTypeIdentifiers
```

It builds `Retouch Studio.app`, copies `Info.plist`, the icon and the Vazir fonts, ad-hoc signs with `codesign --force --sign -`, then runs `--selftest`; a failing self-test **aborts the build** (`build.sh:78-91`).

Notable consequences:

- `Package.swift` exists but `swift build` is not the supported path; the script comments explain that the installed SDK lacks SwiftUI macro plugins (`build.sh:1-9`). The manifest is effectively editor metadata.
- The produced binary is **arm64-only** and **ad-hoc signed**; there is no universal binary, hardened runtime, sandbox or notarization.
- The app is built with `-O -whole-module-optimization`, so engine performance is representative of a release build.

### 2.5 Dependencies

There are **no third-party dependencies** at any layer. Frameworks used: SwiftUI, AppKit, CoreImage, Vision, UniformTypeIdentifiers, ImageIO, CoreGraphics, Foundation, Combine (implicit via `ObservableObject`). The only bundled external asset is the Vazirmatn typeface under the SIL Open Font License (`Resources/Fonts/OFL.txt`).

This is a significant security and supply-chain strength: there is no package resolution, no network fetch at build time, and no vendored binary.

---

## 3. Complete Feature Inventory

Status legend:

- **Verified** — implemented and exercised by a test executed in this audit.
- **Implemented** — complete code path; not covered by an automated assertion.
- **Partial** — works, but a named capability or consistency guarantee is missing.
- **Absent** — no implementation.

### 3.1 Document and workspace

| Feature | Status | Evidence | Notes |
|---|---|---|---|
| Open image (panel, drag-drop, Finder open) | Implemented | `EditorModel.swift:553-620`, `App.swift:180-185`, `CompareCanvas.swift:110-123` | Processor load path verified by self-test; the panel/drag-drop flow is not UI-tested. Drop is accepted on the canvas at any time; the hint appears when empty |
| EXIF orientation normalization | Verified | `ImageProcessor.swift:208-225` | Rendered upright once, orientation written as 1 on export |
| Colour-space preservation | Implemented | `ImageProcessor.swift:213`, `1071` | Uses source `CGColorSpace`; P3 sources stay P3 |
| Preview at 1800 px long edge | Verified | `EditorModel.swift:501`, `ImageProcessor.swift:168` | Debounced 40 ms |
| Pan / zoom / fit | Implemented | `CompareCanvas.swift` | 1× … `effectiveMaxZoom`; ⌘+/−/0 |
| Before/after split | Implemented | `CompareCanvas.swift`, `Components.swift:5-14` | Draggable, persisted position in prefs |
| Hold Space to peek original | Verified | `CanvasInteraction.swift:61-82`, `CompareCanvas.swift:54-67` | Key-code based, ignored in text fields/sheets |
| Face box overlay | Implemented | `CompareCanvas.swift`, `EditorModel.showFaceOverlay` | Setting persisted |
| Status chips and busy indicator | Implemented | `TopBar.swift`, `StatusToken.swift` | Localized |
| Open recent (8 entries) | Implemented | `AppSettings.swift:109-176` | Pruned when files disappear |
| Single-window document model | Implemented | `App.swift` | Opening a photo replaces the current one after discard guard |
| Multi-document / tabs | Absent | — | No `DocumentGroup`, no per-window model |
| Autosave as project | Absent | — | Only crash-recovery sidecar exists |
| Project save / save-as / open | Implemented | `EditorModel.swift:1955-2029` | JSON, atomic write; encode/decode round-trip asserted, UI panels not tested |
| Crash recovery | Implemented | `EditorModel.swift:1748-1790`, `Recovery.swift` | One sidecar, restore prompt at launch |
| Undo / redo | Verified | `EditorModel.swift:142-243` | 350 ms coalescing, cap 100; adjustments/preset paths asserted |
| Crop in undo history | Absent | `EditorModel.swift:146-151` | `appliedCrop` not in `EditState` |

### 3.2 Tools (the twelve modes)

`ToolMode` defines the twelve tools and assigns shortcuts 1–9 and 0 (`ToolMode.swift:5-43`). The art and analysis tools intentionally have no number key because the row only maps ten digits; the comment states this explicitly.

| # | Tool | Status | Key implementation | Automated coverage |
|---|---|---|---|---|
| 1 | **Skin** — smooth, blemish, wrinkle, tone, dark circles, brighten, texture preserve, finish, shine | Verified | `SkinEngine.swift`, `ImageProcessor.swift:681-753` | EngineTests groups 1–3, 6; SelfCheck; real-photo run |
| 2 | **Heal** — manual stamps, brush size | Verified | `Heal.swift`, `ImageProcessor.swift:604-654`, `HealOverlay.swift` | SelfCheck `checkManualHealing` (placement, texture, crop round-trip, radius classes) |
| 3 | **Reshape** — eyes, nose, tip, lips, cheeks, jaw, chin, face width/length | Verified | `FeatureReshaper.swift:337-520`, `ImageProcessor.swift:858-870` | EngineTests groups 4–5 (all eight sliders) |
| 4 | **Face detail** — teeth whiten, eye brighten, eye sharpen, iris, lashes, lens tint, teeth align | Verified | `SkinEngine.swift`, `MakeupEngine.swift:150-210`, `ImageProcessor.swift:749-787` | SelfCheck (iris, teeth gates, lashes, lens); per-slider EngineTests |
| 5 | **Makeup** — lips, gloss, blush, brows, shadow, liner, contour, hair colour/shine/volume | Verified | `MakeupEngine.swift`, `ImageProcessor.swift:789-850` | SelfCheck (lip hue/sat, 40 looks, hair volume); synthetic |
| 6 | **Colour & Light** — exposure, contrast, blacks, whites, saturation, vibrance, warmth, clarity, vignette, split tone, 3-anchor curve, 8-band HSL | Verified | `LookEngine.swift`, `ImageProcessor.swift:885-1008` | EngineTests group 6; SelfCheck HSL and look suite |
| 7 | **Looks** — 6 film grades + 40 presets in 6 groups | Verified | `Look.swift`, `Adjustments.swift:754-1007` | SelfCheck: all 40 looks produce a change; every look is distinct |
| 8 | **Crop** — free/aspect crops, stacked crops, reset | Verified | `Crop.swift`, `CropOverlay.swift`, `ImageProcessor.swift:149-165` | SelfCheck crop geometry + real crop→export flow |
| 9 | **Body** — smooth, tone, slim, waist, arms, legs | Verified | `SceneEngine.swift:100-200`, `FeatureReshaper.swift:430-554` | SelfCheck body skin mask, slim seam/background, waist widths, pipeline |
| 10 | **Background** — blur, tone, saturation, solid fill, remove (alpha) | Verified | `SceneEngine.swift:200-387` | SelfCheck blur parity, fill, removal, group isolation |
| 11 | **Art** — six procedural sticker kinds, move/scale/rotate, delete | Verified | `ArtRenderer.swift`, `ArtOverlay.swift` | SelfCheck composition-after-retouch + crop + project round-trip |
| 12 | **Analysis** — face outline, region contours, leader callouts, mesh; on-photo/poster/lines-only export | Verified | `AnalysisRenderer.swift` (untracked), `AnalysisOverlay.swift` (untracked), `Analysis.swift` | Real-photo checks only (`--face`): lines, ember ink, dragged dot, PNG output |

**Status caveat:** the Analysis tool is implemented and tested but its three files are **untracked in git**. The audited working tree therefore contains work that is not in any commit. This is a repository-hygiene risk, not a functional defect.

No tool is a stub, placeholder or hidden experiment: every mode has a complete entry point, mask path and render path. The newest tool (Analysis) is the least covered and the only one tested exclusively with a real photo. Two tools are functionally partial at the workflow level rather than the engine level: Heal (aspect-ratio bug, M-1) and Crop (not undoable, H-5). Batch export is partial as a *mode*, not a tool (H-3).

### 3.3 Automation

| Feature | Status | Evidence | Notes |
|---|---|---|---|
| Auto Retouch (measured, scaled by user strength) | Verified | `SmartAnalyzer.swift`, `EditorModel.applySmartReport`, `SelfCheck` auto checks | Default strength 70 (`AppSettings.swift:15`) |
| Auto Color & Light | Verified | same | Default strength 100 |
| Smart Analyze report sheet | Verified | `SmartAnalyzeSheet.swift`, `EditorModel.smartAnalyze` | 512 px analysis buffer + 420 px face crops |
| Separate retouch/colour groups | Verified | `SelfCheck` group isolation checks | `usesFaceTools`, `usesPersonTools` |
| Spot suggestions added as heal stamps | Verified | `EditorModel.swift:1692-1720` | Deduplicated against existing stamps |

### 3.4 Export and persistence

| Feature | Status | Evidence | Notes |
|---|---|---|---|
| Export JPEG/PNG/TIFF | Verified | `ImageProcessor.swift:1047-1095`, `EditorView.swift` | PNG/TIFF RGBA16, JPEG RGBA8 |
| Quality slider | Implemented | `ImageProcessor.swift:1090-1092` | Applies to JPEG only (`ExportFormat.supportsQuality`) |
| Long-edge resize (0/4096/2048/1080) | Implemented | `ImageProcessor.swift:1056-1061` | Lanczos; never enlarges |
| Analysis export modes | Verified | `EditorModel.swift:1890-1918` | On-photo, poster, lines-only PNG |
| Batch export | Partial | `EditorModel.swift:2041-2122` | No heal/stickers/analysis; one crop for all; no cancel |
| Project schema v1 | Verified | `Project.swift`, SelfCheck round-trip | Absolute photo path |
| Recovery sidecar | Implemented | `Recovery.swift` | One session copy, atomic, bundle-keyed |
| User looks persistence | Implemented | `UserPreset.swift` | `Application Support/Retouch Studio/presets.json` |
| Recents persistence | Implemented | `AppSettings.swift:109-176` | `UserDefaults` |

### 3.5 Shell and localisation

| Feature | Status | Evidence |
|---|---|---|
| 12-tool top rail with sliding pill | Implemented | `TopBar.swift` (`matchedGeometryEffect`) |
| Left column: Smart Analyze, status, contextual heal/crop | Implemented | `ToolPanel.swift` |
| Right accordion: 11 panels | Implemented | `InspectorView.swift` |
| 40 built-in presets in 6 groups | Verified | `Adjustments.swift:754-1007` |
| Save/delete user looks with live thumbnails | Implemented | `UserPreset.swift`, `Components.swift:PresetTile` |
| English / Persian with RTL layout | Verified | `AppLanguage.swift`, `Localization.swift`, `PersianL10n.swift`, `Theme.swift:96-115` |
| Persian-Indic digits | Implemented | `Digits.swift` |
| Vazir typeface app-wide | Implemented | `Theme.Font`, `Info.plist` `ATSApplicationFontsPath` |
| About and Help windows | Implemented | `InfoViews.swift` |
| Preferences window | Implemented | `SettingsView.swift`, `App.swift` `Settings` scene |
| Motion system (springs) | Implemented | `Theme.swift:120-133` |
| Full keyboard access to canvas tools | Partial | pointer-only overlays; see §6.5 |

---

## 4. Image Processing Pipeline

### 4.1 Overview

All processing is **Core Image**, expressed as a lazily evaluated filter graph. There is no explicit Metal code and no custom `CIKernel` written in Metal Shading Language; custom pixel work uses the legacy Core Image Kernel Language (`CIColorKernel`/`CIWarpKernel`), which is deprecated (§10, L-1). Vision handles face landmarks, person segmentation and body pose. AppKit is used only for image I/O, drawing masks and procedural art.

The single `CIContext` is created with intermediate caching on the GPU:

```swift
context = CIContext(options: [.cacheIntermediates: true, .useSoftwareRenderer: false])
```

`ImageProcessor.swift:135`

### 4.2 Load and analysis

`ImageProcessor.load(from:previewMaxDimension:crop:)` (`ImageProcessor.swift:143-206`) performs:

1. **Decode** with ImageIO (`CGImageSourceCreateWithURL`), preserving the image's `CGColorSpace` and property dictionary. Orientation is normalized by rendering the oriented image once and translating it to a zero origin (`208-225`).
2. **Crop** in normalized top-left coordinates. The crop is converted to Core Image's bottom-left pixel space, intersected with the image extent, applied, then translated back to a zero origin (`149-165`). This makes every downstream stage crop-relative.
3. **Preview downscale** to the longest-edge budget (1800 px in the app; 1400 px in self-checks) using an affine transform; masks and landmarks are then built against the *cropped preview* as well as the full-resolution crop.
4. **Face analysis** on the preview render: `VNDetectFaceLandmarksRequest` → `FaceGeometry`, then two pixel gates (`annotateTeeth`, `annotateEyes`) on a **512 px** analysis buffer (`AutoAnalyzer.analysisBuffer`, `AutoAnalyzer.swift:62-80`).
5. **Mask construction** for both full and preview extents (`buildMasks`).
6. **Identity preview render** through `process(..., adjustments: .zero)` so the first frame shown already reflects geometry normalization and any mask-gated defaults.

The design intent is documented at `ImageProcessor.swift:176-180`: teeth and eye splits are pixel measurements rather than geometry, so they must be resolved before masks; Vision landmarks are normalized to the face box, so preview-resolution analysis yields the same geometry as full resolution.

**Consequence:** all landmark and pixel-gate decisions on a 24 MP export derive from a 1800 px preview and a 512 px statistics buffer. Geometry is scale-invariant, but pixel-gated contours (enamel, sclera/iris, lash line) are upscaled from coarse measurements. This is a quality ceiling, discussed in §4.7.

### 4.3 Masks

`MaskBuilder.makeMask` builds a **small** mask and lets Core Image upscale it:

- Longest mask edge capped at **1600 px** (`MaskBuilder.swift:44`).
- Format is **opaque grayscale stored in RGBA8** (`.premultipliedLast`, device RGB) so that `CIBlendWithMask` reads the gray level consistently (`MaskBuilder.swift:58-68`).
- Shapes are normalized rectangles/ellipses; white = apply, black = leave alone; feather is proportional to image size.
- Person silhouette comes from `VNGeneratePersonSegmentationRequest` at `.balanced`, also bounded to **1600 px**, then scaled to the image extent with a near-empty-mask rejection (`SceneEngine.swift:110-175`).

`MaskSet` (`ImageProcessor.swift:38-84`) carries 21 face/region masks plus optional `person` and `pose`. The person mask is built lazily only when a body, background or hair tool is used (`Adjustments.usesPersonTools`).

### 4.4 Processing order

`ImageProcessor.process` (`ImageProcessor.swift:656-917`) applies steps in this exact order:

```
0. Manual healing (all stamps, grouped by radius)
1. Local retouch on face masks: blemish → wrinkles → even tone → smooth → brighten
   → finish → shine
1b. Body skin: smooth → tone (person mask)
2. Under-eye correction
3. Teeth alignment → teeth whitening → sclera brighten → eye sharpen → iris
   → lash darken → contact lens
3b. Makeup: eyeshadow → liner → lips → gloss → blush → brows → contour →
    hair dye → hair shine → hair volume
4. Geometry: feature warps (eyes/nose/lips/cheeks/jaw/chin/face), then body slim,
   then pose-driven waist/arms/legs
5. Global colour and light:
   levels → exposure → contrast → saturation → vibrance → warmth → curve →
   split tone → HSL → clarity → vignette → film look → grain
6. Background: blur/tone/saturation → fill → remove
7. Art stickers
   Final crop back to the source extent
```

Rationale is documented inline and is coherent:

- Healing runs first so the repaired pixels are what skin passes see, and stamps are not limited to face masks (`669-676`).
- Retouch precedes warp so masks still align with the features they were built from (`678-680`).
- Makeup follows skin work so smoothing does not dilute pigment, but precedes warp so it travels with features (`789-791`).
- Global grade follows local work; the look and grain sit last so a grade reshapes the already-balanced image and grain sits on the finished picture (`1001-1007`).
- Background is last so its falloff never blurs subject detail (`888-890`), and art is on top of everything (`910-914`).

### 4.5 Non-destructive model

The original image is never mutated. `Adjustments` is a value type containing every slider, colour, look and switch (`Adjustments.swift`). The project stores `Adjustments`, crop, heal stamps, stickers and analysis settings; the pixel pipeline is rebuilt from these each time (`Project.swift`, `EditorModel.makeProject` at `1974-1987`).

Coordinate conventions are explicit and consistent:

- Crop, heal stamps and stickers: normalized **top-left** origin.
- Core Image and Vision landmarks: **bottom-left** origin.
- Heal masks flip y when converting stamps to mask shapes (`Heal.swift:66-74`).

This convention discipline is a genuine engineering strength; the self-check suite contains dedicated tests for top/bottom placement and crop round-trips.

### 4.6 Preview vs export

- Preview: `previewMaxDimension = 1800` (`EditorModel.swift:501`), RGBA8 render into an `NSImage`.
- Export: full cropped resolution, RGBA16 for PNG/TIFF and RGBA8 for JPEG (`ImageProcessor.swift:1054`), with optional Lanczos downscale applied **after** processing (`1056-1061`).
- Effects are normalized by image size so radii scale between preview and export: `scale = max(0.5, min(3.0, min(width, height) / 1400))` (`ImageProcessor.swift:665`).
- Mask resolution is capped at 1600 px for **both** preview and export, so the preview does not reveal the edge softness an export will have on a large photo.

Two parity breaks are identified in §10 (M-1 blemish kernel clamp; M-2 mask cap).

### 4.7 Colour management and precision

- Working space: Core Image's default linear working space; the output is rendered with the **source** colour space (or sRGB when untagged) at `ImageProcessor.swift:213`, `1031-1032`, `1071`.
- 16-bit output for PNG/TIFF; JPEG is inherently 8-bit.
- Source metadata is carried over, with orientation forced to 1 and source pixel-dimension/profile-name keys removed (`1078-1089`).
- Makeup colours are stored display-referred sRGB and decoded before linear compositing (`Makeup.swift:11-14`).
- Mask precision is 8-bit; preview and source renders are RGBA8, and only the final PNG/TIFF write is RGBA16. The 16-bit container therefore does not restore precision lost to an 8-bit source or 8-bit masks.

### 4.8 Caching

| Cache | Scope | Eviction | Evidence |
|---|---|---|---|
| Core Image intermediates | GPU, per process | Core Image managed | `ImageProcessor.swift:135` |
| Film-look colour cubes | 32³ LUT per `(look, strength)` | Dictionary cleared above 24 entries | `LookEngine.swift:240-290` |
| Sticker glyphs | Per sticker kind/size/colour | `NSCache` | `ArtRenderer.swift:18-40` |
| Masks / preview / faces | Per loaded frame, held in `EditorModel` | Replaced on load/crop | `EditorModel.swift` |

No mask cache is keyed by adjustment state, which is correct: masks depend only on geometry, not on slider values. Crop changes rebuild everything, which is necessary.

---

## 5. Performance and Memory Analysis

> **Method note:** these figures are derived from declared buffer sizes and render paths; no Instruments trace was captured. They identify structural costs, not benchmark numbers.

### 5.1 Buffers held simultaneously

For a 24 MP (6000 × 4000) photo:

| Buffer | Size | Approx. bytes |
|---|---|---|
| Full decoded `CGImage` (RGBA8) | 6000 × 4000 | **96 MB** |
| Full cropped `CIImage` | lazy, backed by above | shares |
| Preview `CIImage` (1800 long edge) | 1800 × 1200 | **8.6 MB** |
| Preview `CGImage` + `NSImage` | 1800 × 1200 | ~17 MB (two copies) |
| Full mask set (21 masks × 1600 long edge × RGBA8) | ~1600 × 1067 × 4 each | **~143 MB** |
| Preview mask set (same 1600 cap) | same | **~143 MB** |
| Person mask (one-component 8, 1600) | ~1600 × 1067 | ~1.7 MB |
| Undo history (100 × `EditState`) | arrays of doubles/spots/stickers | typically < 1 MB |

Peak steady-state is therefore **roughly 400 MB** before Core Image intermediates, plus export render targets (a 24 MP RGBA16 PNG target is ~192 MB). On the target 16 GB M3 this is survivable, but it is not frugal. Two specific inefficiencies matter:

1. **Masks are 4 bytes per pixel though only one channel is used.** `MaskBuilder.swift:58-69` allocates `CGContext` with `premultipliedLast` DeviceRGB for what is conceptually a grayscale coverage map. A one-component 8-bit context would cut mask memory by 4× (≈ 36 MB instead of 143 MB per set). The comment explains the *alpha* convention but not the RGB choice; blending could read `.r` from a grayscale image.
2. **Preview and full mask sets are built independently at the same 1600 cap.** On a 24 MP photo both sets are effectively identical in resolution (`ImageProcessor.swift:188-189`). Building one 1600-px set and reusing it for both would halve mask memory and mask-build time. The sets differ only in extent/feather scaling, which is already proportional.

### 5.2 CPU/GPU paths

- Core Image renders on the GPU (`.useSoftwareRenderer: false`), so the filter chain is accelerated.
- Custom kernels are legacy `CIColorKernel`/`CIWarpKernel` compiled once at first use; this is GPU-executed but deprecated.
- Vision requests run on Apple's Vision stack (CPU/ANE) and are the dominant latency at load: face landmarks, then two pixel-gate passes, then optional person segmentation.
- Manual mask drawing is CPU (`CGContext`), but bounded to 1600 px.

### 5.3 Preview latency and debounce

`schedulePreview()` (`EditorModel.swift:1431-1465`):

- Sets `isBusy = true` **immediately**, before the 40 ms debounce.
- Cancels the prior task and increments `generation`.
- Sleeps 40 ms; if still current, renders the full retouch graph on the 1800 px preview and publishes the result if the generation still matches.

Strengths: the 40 ms window prevents a render per slider tick, and the generation guard prevents stale frames from overwriting new ones. The debounce is short enough to feel live on an M3.

Weaknesses:

- `isBusy` flickers true on every tick and only clears after the *latest* render completes; menus and crop/export actions disable during a drag (by design, but it reads as constant busy).
- Cancellation is logical only. A superseded detached render continues to completion, consuming GPU time while the newest render waits. Over a long drag this can queue several 1800 px renders.
- `ensurePersonMask()` is invoked from the same path whenever a person-dependent tool is active (`1433`), adding a Vision segmentation pass on first use.

### 5.4 Export cost

`export(to:)` renders at full resolution regardless of the chosen long-edge target, then downscales with Lanczos (`ImageProcessor.swift:1056-1061`). Exporting a 24 MP photo at 1080 px therefore pays the full 24 MP filter chain. This is deliberate for quality (downscaling after retouch preserves detail), but it is the single most expensive user action and has no progress reporting beyond a spinner and no cancellation.

Batch export processes files **sequentially** (`EditorModel.swift:2078-2115`). This is memory-safe (one file in flight) and avoids contention, but it makes a 50-photo batch a long, uninterruptible operation. `batchTask` is only replaced when a new batch starts, and the batch menu item is disabled while `isBusy`, so there is no way to cancel a running batch from the UI.

### 5.5 Memory risks

| Risk | Severity | Evidence | Mitigation in code |
|---|---|---|---|
| Large originals decoded fully into memory | Medium | `ImageProcessor.swift:210` (`shouldCache: true`) | No tiling or thumbnail-first path |
| Two 1600-px mask sets plus Core Image cache | Medium | `188-189`, `MaskBuilder.swift:44` | Bounded by 1600 cap |
| Full-res 16-bit PNG target plus graph | Medium | `ImageProcessor.swift:1054-1074` | Sequential export |
| Batch holds one file at a time | Low | `2078-2115` | Good |
| Undo history copies arrays | Low | `EditState`, cap 100 | HSL arrays copied per state, small |

There is no explicit autorelease-pool management around the batch loop, but each iteration is short and Swift/ObjC bridging handles the dominant allocations. Not a demonstrated leak.

### 5.6 Performance recommendations (summary)

1. Reuse one 1600-px mask set for preview and full frame where extents permit, or lower the preview mask cap independently.
2. Store masks as one-component 8-bit.
3. Scale the processing source down *before* `process` when the target long edge is much smaller than the source, while keeping the current full-res path for "original size".
4. Add a cooperative cancellation check between pipeline stages and in the batch loop, and expose a Cancel button.
5. Report export progress (stage or percentage) for files above a size threshold.

None of these affect correctness.

---

## 6. UI/UX Architecture

### 6.1 Window and layout

`EditorView` (`EditorView.swift:1-120`) is a vertical stack:

```
┌──────────────────────────────────────────────────────────────┐
│ TopBar: 12 tool pills · document name · undo/redo · Export   │  52 pt
├───────────────┬──────────────────────────────┬───────────────┤
│ ToolPanel     │ CompareCanvas                │ InspectorView │
│ 292 pt        │ flexible                     │ 318 pt        │
│ Smart Analyze │ photo, split, dock           │ 11 accordion  │
│ status card   │                              │ panels        │
│ contextual    │                              │               │
│ heal/crop card│                              │               │
└───────────────┴──────────────────────────────┴───────────────┘
```

Minimum window 1120 × 700; default 1320 × 860 (`App.swift` `.defaultSize`). The window uses a hidden title bar and custom-drawn chrome; the traffic-light band is reserved by `Theme.Metrics.topGutter`.

### 6.2 Design system

`Theme.swift` defines every surface, text tone, accent, radius and motion curve. The shell is neutral graphite; only chrome carries colour:

- **Chartreuse** = commit/apply actions (Export, Apply, sliders for retouch).
- **Sky** = generative actions (Auto Retouch, Auto Color).
- **Bone** = high-contrast light elements and slider knobs.
- **Positive/warning** = status chips.

Motion uses four springs: `snappy` (taps/hovers), `smooth` (pill slide/accordion), `swell` (content), `press` (button dip). Because the whole UI uses one `PressableButtonStyle`, the app avoids the macOS bezel flash and feels like one product.

### 6.3 Interaction patterns

- **Top rail** selects one of twelve tools; a `matchedGeometryEffect` pill slides between them. Each tool opens its matching inspector panel automatically.
- **Left column** is contextual: Smart Analyze and the status card are always present; Heal and Crop insert their own cards when selected.
- **Inspector** is an accordion; opening a tool opens its panel and collapses others. Panel headers carry a reset button scoped to that group.
- **Sliders** are bipolar when their range crosses zero, fill from zero, support double-click reset, and show a modified dot and live value (`Components.swift:60-220`).
- **Presets** render the open photo through each preset as a live thumbnail (`PresetTile`, `Components.swift:430-505`), so the choice is visual rather than verbal.
- **Canvas** supports drag-to-open when empty, wheel scroll to pan, ⌘-scroll or pinch to zoom, drag on the split handle to compare, and held Space for the original.
- **Overlays** are direct-manipulation: heal stamps on click/drag, crop with handles and aspect lock, stickers selectable with rotate/resize handles, analysis leader dots draggable with a 24 pt grab tolerance.

### 6.4 Keyboard shortcuts

| Shortcut | Action | Evidence |
|---|---|---|
| ⌘O / ⇧⌘O | Open image / open project | `App.swift:219-224` |
| ⌘S / ⇧⌘S | Save project / Save As | `App.swift:241-247` |
| ⌘E / ⇧⌘E | Export / Batch export | `App.swift:249-256` |
| ⇧⌘A | Smart Analyze | `App.swift:257-259` |
| ⌘R | Reset all adjustments | `App.swift:261-263` |
| ⌘Z / ⇧⌘Z | Undo / redo | `App.swift:211-217` |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / fit | `App.swift:268-279` |
| ⌘, | Settings (standard scene) | `App.swift` |
| ⌘W | Close window | `App.swift:238-240` |
| 1–9, 0 | Select tools 1–10 | `ToolMode.swift:40-43` |
| Space (hold) | Show original | `CanvasInteraction.swift:61-69` |
| ⌘↩ / Esc | Apply / cancel Smart Analyze sheet | `SmartAnalyzeSheet.swift:208-233` |
| Return / Esc | Confirm / cancel export sheet | `EditorView.swift:175-193` |

The canvas key monitor deliberately ignores events when the editor window is not key, a sheet is attached, or the first responder is an `NSTextView`, so typing a look name never triggers tool shortcuts (`CanvasInteraction.swift:87-92`).

### 6.5 Accessibility

What exists:

- `BipolarSlider` exposes a native `Slider` through `accessibilityRepresentation` (`Components.swift:167-169`).
- Tool pills have `accessibilityLabel(mode.title)` (`TopBar.swift:79`).
- Switches and settings rows have explicit labels (`SettingsView.swift:144`, `171`).
- `Icon` exposes a label (`LineIcon.swift:39`).
- Buttons use real `Text` titles, so their labels are meaningful.
- Motion is used for feedback rather than as the only carrier of state; controls also change value text and colour.

Gaps:

- **Canvas overlays are pointer-only.** Heal, crop, sticker placement/rotation/resize, and analysis leader dragging have no accessibility actions, no keyboard equivalents, and no VoiceOver representation of their state.
- **`Icon` labels are raw SF Symbol names**, e.g. `arrow.counterclockwise`, not localized human labels (`LineIcon.swift:39`). VoiceOver would read technical identifiers on icon-only buttons that are not otherwise labelled.
- **No dynamic-type-aware layout.** Type sizes are fixed in `Theme.Font`; macOS does not offer Dynamic Type as on iOS, so this is a minor point, but larger accessibility text sizes are not accommodated.
- **Colour is used to distinguish chartreuse vs sky actions**, though the labels and icons differ as well; contrast is generally strong on graphite.
- **No full-keyboard path to tools 11 and 12** (art, analysis). This is documented as intentional but is still an accessibility gap; a menu item or modifier shortcut would close it.

### 6.6 Localisation and RTL

- The app swaps an entire string table at runtime (`L10n.current`), rather than using `.strings` files (`Localization.swift:8-14`).
- English and Persian are two 800+ line classes, 321 string properties each today; `PersianL10n` overrides them.
- The comment at `PersianL10n.swift:3-5` claims "a new string in one file fails to compile until the other has it too." **That is not what Swift does**: an override is optional, so a newly added English string would silently fall back to English in Persian. Current parity happens to be complete (322/322), but it is maintained by discipline, not the compiler. See M-7.
- `AppLanguage.current` is a mutable static backed by `UserDefaults` (`AppLanguage.swift:30-44`); the layout direction follows the language, not the system locale, so a Persian app on an English Mac still mirrors (`AppLanguage.swift:14-16`).
- Digits switch to Persian-Indic in Persian through `Digits.convert` (`Digits.swift:20-35`).
- The numeric slider track deliberately keeps a left-to-right fill even in RTL, because inverting the handle without inverting the numbers would be misleading (`Components.swift:174-177`). This is a thoughtful exception.
- About/Help windows are rebuilt on language switch (`InfoViews.swift`, called from `App.swift`).

### 6.7 Empty, error and busy states

- Empty canvas shows a drop zone and hint (`EditorModel.swift:505`, `CompareCanvas`).
- Status chips distinguish no face / faces detected / no image / busy.
- Export and project panels show localized validation and failure tokens (`StatusToken.swift`).
- Discard prompt defaults to Cancel, not Discard, and wires Esc manually (`EditorModel.swift:585-609`). This is a good safety choice.
- Error strings exist for unreadable image, missing project photo, failed export, failed project save.
- No retry affordance after a failed export; the user must reopen the sheet.

---

## 7. Project and Export Architecture

### 7.1 Project schema

`RetouchProject` (`Project.swift`) is a JSON document with an exported UTI (`local.retouchstudio.project`, conforming to `public.json`) and a `version` field currently `1`.

Fields: `imagePath`, `adjustments`, `exportFormat`, `exportQuality`, `exportLongEdge`, `autoRetouchStrength`, `autoColorStrength`, `crop`, `healSpots`, `stickers`, `analysis`. Optional fields decode as `nil` for older files. Unknown fields are ignored by `JSONDecoder`.

**What is saved:** the full edit intent.
**What is not saved:** the photo itself, the source metadata/profile, per-document UI state (tool, zoom, compare position), undo history.

### 7.2 Save and open

- Save writes atomically to the chosen `.retouch` file, adds it to recents, and marks the document clean (`EditorModel.swift:1989-2006`).
- Save As always writes a new file; no "save a copy" distinction.
- Open requires both a valid JSON document **and** the referenced photo to exist (`2020-2029`); if not, it reports `.projectPhotoMissing` and does nothing.
- The project round-trip (crop, stamps, stickers, sliders) is asserted by the self-test (`SelfCheck.swift:1928-1972`).

**Design risk:** `imagePath` is absolute (`Project.swift:17`). Moving the photo, renaming a folder, or opening the project on another Mac breaks it. There is no relink prompt and no bookmark/relative-path fallback.

### 7.3 Crash recovery and autosave

- While a photo has unsaved changes and recovery is enabled, `updateCleanState()` schedules a 1.5 s debounced write of the same project JSON into `Application Support/Retouch Studio/Recovery/<bundle-id>/session.retouch` (`EditorModel.swift:1752-1765`, `Recovery.swift:7-33`).
- The sidecar is cleared when the document becomes clean for the same source path (`RecoveryStore.clear(ifSourcePath:)`), so a different photo at launch cannot erase pending recovery.
- At launch with no image, the app offers Restore or Discard (`EditorModel.swift:1768-1790`). If the source photo is missing, it silently discards.
- There is **one** recovery copy. A second unsaved session overwrites the first. This is acceptable for a single-window app, but it means recovery is last-session-only.

### 7.4 Undo/redo

`EditState` contains `adjustments`, `healSpots`, `stickers`, `analysis` (`EditorModel.swift:146-151`). Changes coalesce for 350 ms and the stack is capped at 100.

- Verified by `checkUndoHistory` (`SelfCheck.swift:1798-1842`): pending drag undo, redo, stepwise undo, branch clearing, preset as one step.
- Not covered: heal/sticker/analysis assertions (they are in the state, but no test asserts them), and **crop is not in the state at all**.
- Crop applies through `reloadCropped()` (`798-813`), which deliberately preserves the undo stack ("the crop changes the pixels, not the slider values"). The consequence is that ⌘Z after a crop restores slider values but cannot restore the previous framing.

### 7.5 Export

Single export (`EditorModel.swift:1873-1948`) does:

1. Capture a consistent snapshot of adjustments, masks, faces, spots, art, analysis, colour space, metadata, format, quality, long edge, and clean state.
2. Lazily build the person mask if a person-dependent tool is active and the mask is missing.
3. Run the pipeline at full cropped resolution.
4. If analysis export is enabled and faces exist, composite the overlay or render a poster.
5. Lines-only mode returns a PNG on transparency, forcing PNG regardless of the chosen format.
6. Write through `CGImageDestination`, flattening transparency onto white for JPEG.
7. On success, close the sheet, update status, and **set the clean baseline to the exported state**.

Formats and limits:

| Format | Bit depth | Quality control | Alpha |
|---|---|---|---|
| JPEG | 8-bit | Yes (0.4–1.0) | Flattened onto white |
| PNG | 16-bit | No | Preserved |
| TIFF | 16-bit | No | Preserved |

The long-edge options (original/4096/2048/1080) are applied with Lanczos and never upscale.

### 7.6 Batch export

Batch export (`EditorModel.swift:2041-2122`):

- Asks for multiple source images and one destination folder.
- For each file: loads at preview resolution (then uses the full source), lazily builds a person mask if needed, processes with the **current** adjustments, names `base-retouched.ext` with numeric collision suffixes, and writes.
- Reports only `saved / total`.
- Applies the **current crop** to every file (`2069`, `2083-2085`), even when aspect ratios differ.
- Does **not** apply heal stamps, stickers, or the analysis overlay.
- Runs sequentially and cannot be cancelled from the UI.

This is a functional batch *converter*, not a batch version of the single-export pipeline. See H-4.

### 7.7 Missing workflows (document/export)

- No save-on-close option: the discard alert offers only Discard and Cancel (`585-609`).
- No multi-document or tabbed workflow.
- No project relink when the source photo moves.
- No export presets (named combinations of format/size/quality/metadata policy).
- No "export original", "export without adjustments", or side-by-side before/after export.
- No batch per-file analysis or per-file crop.
- No watermark, no print, no share sheet, no Photos integration.
- No metadata-stripping option (privacy; see §8.4).
- No HEIC/AVIF/WebP output.

---

## 8. Security and Privacy Assessment

### 8.1 Network exposure

**No network code exists.** A repository-wide search for `URLSession`, `http://`, `https://`, `NSAllowsArbitraryLoads` and network entitlements returns only the XML DOCTYPE URL in `Resources/Info.plist`. There is no telemetry, analytics, crash reporting, update check, cloud sync, or remote model. Processing is entirely local.

This is a strong privacy posture for portrait retouching. It should be preserved.

### 8.2 Sandbox, entitlements, signing

- The app is **not sandboxed**: there is no entitlements file and no `com.apple.security.*` keys.
- `build.sh` ad-hoc signs the bundle (`codesign --force --sign -`). There is no Developer ID signature, hardened runtime, or notarization.
- Consequences:
  - The app can read and write any path the user can. This is convenient for a local tool and is why `imagePath` can be a plain absolute path.
  - On another Mac, Gatekeeper will treat the app as unsigned/ad-hoc; distribution outside the owner's machine is not viable without notarization.
  - No App Sandbox means a compromised image decoder would have broad file access. This is standard for a local pro tool but worth recording.

### 8.3 File handling and temporary data

| Data | Location | Lifetime | Notes |
|---|---|---|---|
| Recovery sidecar | `~/Library/Application Support/Retouch Studio/Recovery/<bundle-id>/session.retouch` | Until clean or discarded | Atomic writes; keyed by bundle |
| User looks | `~/Library/Application Support/Retouch Studio/presets.json` | Persistent | Atomic writes |
| Preferences / recents | `UserDefaults` | Persistent | Paths only |
| Self-test outputs | Caller-provided `--out` directory | Caller-controlled | Audit used `/tmp` only |
| Export output | User-chosen path | Persistent | Direct write, not atomic |

The app never writes the original photo. It does not create temp copies of the image. The recovery sidecar contains an absolute path and all slider values but **not the photo pixels**; if a user shares their Application Support folder, the sidecar reveals the photo's path and edit history but not the image itself.

### 8.4 Metadata and GPS

`ImageProcessor.write` copies the source metadata dictionary, removes only pixel-dimension/depth/colour-model/profile-name/has-alpha keys, forces orientation to 1, and writes the rest (`ImageProcessor.swift:1078-1089`).

**This preserves EXIF GPS coordinates, camera serial number, owner name and capture timestamps in every export.** For a portrait retoucher, exported images may therefore reveal where the subject was photographed and on which device. There is no stripping option and no warning.

Recommendation: default to stripping GPS and personal EXIF fields on export, or add an explicit "Keep location and camera metadata" switch, default off.

### 8.5 Project-file trust

- A `.retouch` file contains an arbitrary `imagePath`. Opening a project from an untrusted source causes the app to load that path if it exists. It is only read as an image, and the app is unsandboxed, so this is a file-disclosure vector, not code execution. Risk: Low.
- JSON decoding has no size limits; a crafted project with enormous arrays could cause memory pressure. Risk: Low.
- `version` is decoded but never validated or migrated. A future schema could be misread if field meanings change. Risk: Low–Medium (see M-9).
- Export paths are user-selected; there is no path traversal risk beyond the user's own choices.

### 8.6 Private portrait fixtures

The project's own privacy rule is that the owner's personal photos in `~/Documents/image test` must never be copied into the repository or published. During this audit:

- A real photo was read **in place** for the optional self-test.
- All generated outputs were written to `/tmp/rs-audit-face`.
- No fixture was copied, committed, or included in this document.
- `build/`, `.build/` and `*.app` are gitignored; the audit did not change that.

This process should remain the standard for any future verification.

### 8.7 Security summary

| Area | Assessment |
|---|---|
| Network data leakage | None — no network code |
| Telemetry | None |
| Third-party code | None |
| Local file access | Broad (unsandboxed), expected for the tool |
| Metadata leakage on export | **Present** — GPS/EXIF carried through |
| Code signing / distribution | Ad-hoc only; not distributable as-is |
| Project-file parsing | Low risk; no version validation |
| Temp-file residue | Recovery/presets only, in Application Support |

---

## 9. Testing and Verification Matrix

### 9.1 Commands executed in this audit

All three commands were run on 2026-11-04 against the audited working tree. Logs were kept in `/tmp`.

```bash
./Tests/run.sh
# exit 0
# ENGINE TESTS: PASS
# [7] a fresh Adjustments() is a genuine no-op
#   ✓ default settings change nothing — mean delta 0.0000

./build.sh
# build_exit=0
# ✓ خودآزمون پردازش پاس شد
# SELFTEST: PASS
# 154 ✓ / 0 ✗

./build/bin/RetouchStudio --selftest \
  --face "$HOME/Documents/image test/IMG_7196.JPG" \
  --out /tmp/rs-audit-face
# exit 0
# SELFTEST: PASS
# 166 ✓ / 0 ✗
```

Representative executed evidence:

- Engine texture retention: engine 0.73 vs Gaussian blur 0.02 on the same base texture.
- Blemish removal: 3/3 synthetic spots cleared.
- Texture Preserve: 2.72 vs 1.36 retained detail at the two extremes.
- Reshape locality: mean Δ 9.51 inside the face, Δ 0.00 outside.
- Every reshape and retouch/colour slider individually changes output (all deltas > 0.5).
- Identity: mean Δ 0.0000.
- Real photo (2268 × 4032, one face): background unchanged by face-local auto retouch (ratio 0.001), analysis lines 0.24 % inked, weight 240 → 0.67 %, mesh style → 2.32 %, dragged analysis dot drawn at its new position, lines-only PNG written.
- All 40 built-in looks change the image; weakest Δ 59.2; every look distinct (closest pair Δ 1.4).
- Teeth gating: closed mouth 0.00 → not visible; open smile 1.00 → visible.
- Hair volume: crown 189 → 95, face Δ 0.00, room Δ 0.00.
- Waist control: narrows and widens with sign.
- Background fill/removal: isolated to the room, not the subject.
- Project round-trip: crop, stamps, stickers and sliders survive encode/decode, including legacy files without the optional fields.

### 9.2 What each suite covers

| Suite | Layers | Style | Count |
|---|---|---|---|
| `Tests/EngineTests.swift` | `ImageProcessor` + engines | Synthetic 420 px face, per-field deltas | 7 groups |
| `SelfCheck` (app) | Engines + model + project + recovery-adjacent logic + optional real photo | Synthetic fixtures + 3 real-photo checks | 154 synthetic, 166 with `--face` |
| `Tests/run.sh` | Compiles all sources except `App.swift`/`SelfCheck.swift` | Harness exits 0/1 | — |

`SelfCheck` is unusually broad for an app of this size. It includes model-level tests (undo coalescing, project round-trip, crop geometry, export formats) and engine-level tests (texture, gates, warp locality, group isolation). This is the main reason the engine is trustworthy.

### 9.3 Coverage matrix by tool

| Tool | Automated assertions | Gaps |
|---|---|---|
| Skin | Strong: texture vs blur, blemishes, texture preserve, all sliders, real-photo face locality | No test on very dark/very fair skin extremes |
| Heal | Strong: placement, clearing, texture, crop round-trip, radius classes | **Square fixtures only** — aspect-ratio distortion not caught |
| Reshape | Strong: all eight sliders, locality | No test for combined extreme warps or multiple faces |
| Face detail | Strong: teeth gate, alignment, iris, lashes, lens, per-slider | Pixel-gate precision at full resolution not tested |
| Makeup | Strong: lip hue/sat, shades, 40 looks, hair volume | No per-shade rendering assertion |
| Colour | Strong: all sliders, curve, split tone, HSL, look distinctness | No exported-file colour-profile test |
| Looks | Strong structural test (Δ) | No visual regression/baseline comparison |
| Crop | Strong geometry + real load/export | **No undo test**; no aspect-ratio matrix beyond 3:4 |
| Body | Strong synthetic mask/slim/waist/pipeline | No real-photo pose test; no missing-joint UI test |
| Background | Strong blur/fill/remove/group isolation | No real-photo hair-edge matte test |
| Art | Composite order, crop mapping, project round-trip | No pixel-fidelity or handle-interaction test |
| Analysis | Real photo (`--face` only): ink, weight, mesh, dot drag, export | No synthetic coverage; no multi-face layout stress test |
| **Editor state** | Undo/redo, crop flow, project round-trip | **Export clean-state, resetAll, batch parity, project relink, recovery restore path untested** |

### 9.4 Critical untested paths

These are exactly the paths where the audit found defects:

1. `export(to:)` success mutating `cleanState` — no test asserts that exporting must not clear the dirty flag.
2. `applySmartReport` preserving fields the report did not measure — no test.
3. `resetAll` clearing **all** edit components — no test.
4. Crop participating in undo — no test (and the design excludes it).
5. Batch export parity with single export — no test.
6. Project reopening after the photo moved — no test.
7. Recovery restore and missing-source discard — no test.
8. Localization parity/non-empty strings — no test.
9. Export metadata policy (GPS retention) — no test.
10. Non-square heal stamp geometry — no test.
11. Preview/export parity for the blemish kernel on large images — no test.
12. UI interaction flows (sheets, overlays, keyboard) — no UI test target.

### 9.5 Test infrastructure observations

- `Tests/run.sh` compiles `EngineTests.swift` as `main.swift` plus all sources except `App.swift` and `SelfCheck.swift`. This keeps engine tests independent of the app shell and avoids a test framework dependency. It also means engine tests cannot exercise `SelfCheck`, and `SelfCheck` is only available inside the app binary.
- `build.sh` treats the synthetic self-test as a **hard build gate**. A build that fails 154 checks does not produce an app. This is a strong practice.
- There is no CI configuration; the gate runs only when the owner runs `build.sh`.
- There is no code coverage instrumentation, no snapshot testing, and no performance test.
- The real-photo checks are opt-in via `--face`; the default build gate runs synthetic checks only. This keeps private photos out of CI but also means real-face regressions are only caught when the owner remembers to pass a photo.

---

## 10. Known Issues and Technical Debt

Each issue lists severity, evidence, affected files and a recommendation. Severities: **Critical** = silent loss of work; **High** = wrong output or a broken core workflow; **Medium** = quality/robustness limitation with a workaround; **Low** = maintainability/cosmetic.

The register is extended by §13 with H-7, M-13…M-16 and L-7. Those six findings are kept in §13 so the deep-audit evidence and the original register remain separately readable; the counts in §1.3 include both.

### C-1 — Export marks the document clean (Critical)

**Evidence:** `EditorModel.swift:1941-1942`:

```swift
self.cleanState = exportedState
self.cleanCrop = exportedCrop
self.updateCleanState()
```

`hasUnsavedChanges` compares `currentState` to `cleanState` (`291-294`). The discard guard (`App.swift:55-56`, `78-79`) and the edited dot in the title bar both depend on it. After a successful export, the app reports "no unsaved changes" even though no `.retouch` project was written.

**Affected files:** `Models/EditorModel.swift`, `App.swift`, `Views/TopBar.swift`.

**Impact:** the user tweaks sliders, exports a JPEG, then closes the window or quits. No prompt appears; the slider work is gone unless a project was saved earlier. Crash recovery may also clear the sidecar because the document became clean (`1756-1757`).

**Recommendation:** do not touch `cleanState`/`cleanCrop` on export. If an "exported since last change" indicator is desired, add a separate `lastExportedState` used only for UI. Add a regression test that exports to a temp path and asserts `hasUnsavedChanges` remains true when changes are still unsaved.

### H-1 — Smart Analyze overwrites fields it did not measure (High)

**Evidence:** `Adjustments.applyingColorLight` (`366-385`) and `applyingRetouch` (`388-408`) copy **every** field of their group from the patch. `applySmartReport` builds `appliedRetouch` from `Adjustments()` and the report (`EditorModel.swift:1670-1677`); `SmartAnalyzer.retouch` only writes smooth, texture preserve, blemish, wrinkle, even tone, dark circles, shine, skin brighten, teeth whiten, eye brighten and eye sharpen (`SmartAnalyzer.swift:300-331`). Therefore fields the analyzer does not measure—`skinFinish`, `irisEnhance`, `lashDarken`, `lensTint`, `lensColor`, `teethAlign`, plus `vignette`, `splitTone`, `curveShadows`, `curveMidtones`, `curveHighlights`, `hslHue`, `hslSaturation`, `hslLuminance` in the colour group—are set to their zero/default values whenever the corresponding group is applied.

**Affected files:** `Models/Adjustments.swift`, `Models/EditorModel.swift`.

**Impact:** a user who set a lens tint, teeth alignment, a split tone or an HSL band and then runs Smart Analyze loses those settings silently. The change is undoable, but the UI does not warn and the status line reports success.

**Recommendation:** make the automatic patches opt-in per field, or merge only non-identity fields from the scaled patch. A robust shape is `applyingRetouch` taking a mask of fields, or a dedicated `mergingRetouch(_ measured:)` that only replaces values the analyzer actually produced. Add a test that sets every retouch/colour field, applies a report, and asserts unmeasured fields survive.

### H-2 — Reset All is incomplete (High)

**Evidence:** `EditorModel.swift:1469-1476` clears `adjustments`, `stickers`, `selectedSticker` and compare position. It does not clear `healSpots` or `analysis`. Separately, the menu item is disabled when `model.adjustments.isIdentity` (`App.swift:261-263`), so a document whose only edit is a heal stamp or an analysis overlay cannot use Reset at all.

**Affected files:** `Models/EditorModel.swift`, `App.swift`.

**Impact:** "Reset All" leaves visible edits on the photo, contradicting its label. A user may export believing the image is clean.

**Recommendation:** include `healSpots.removeAll()` and `analysis = AnalysisSettings()` in `resetAll`, and base the menu's enabled state on `currentState != .zero` (plus crop) rather than `adjustments.isIdentity`. Add a model test.

### H-3 — Batch export is not the single-export pipeline (High)

**Evidence:** `runBatch` (`2060-2122`) passes only `adjustments` and a person mask to `process`; it never passes heal spots, stickers or analysis. It captures `crop = appliedCrop` once (`2069`) and passes it to every file (`2083-2085`), although each photo has a different aspect ratio. There is no cancel affordance; the batch menu is disabled while busy (`App.swift:254-256`), and `batchTask` is only replaced when a new batch starts.

**Affected files:** `Models/EditorModel.swift`, `App.swift`.

**Impact:** a user who heals a blemish, places a sticker and exports one photo correctly will get different output for the same edit in a batch. A portrait crop applied to a landscape file may crop away most of the subject. Long batches cannot be stopped.

**Recommendation:** either scope batch explicitly as "apply slider adjustments only" in the UI, or make it run the full single-export path per file (with the crop reset unless the aspect matches). Add progress/cancel, and confirm before applying a non-full crop to heterogeneous aspect ratios.

### H-4 — Projects depend on absolute photo paths (High)

**Evidence:** `RetouchProject.imagePath` (`Project.swift:17`); `makeProject()` stores `imageURL.path` (`EditorModel.swift:1974-1987`); `openProject(at:)` refuses if that path is missing (`2020-2029`); recovery does the same (`1772-1776`).

**Affected files:** `Models/Project.swift`, `Models/EditorModel.swift`, `Models/Recovery.swift`.

**Impact:** moving or renaming the photo/folder, or moving the project to another Mac, makes the project unusable with only a generic "photo missing" status. There is no relink.

**Recommendation:** store a relative path when the photo is beside the project, plus a bookmark or a user-relink flow when it is not. On open, if the absolute path fails, prompt to locate the photo and rewrite the path. Test by moving a project+photo pair.

### H-5 — Crop is outside undo/redo (High)

**Evidence:** `EditState` (`146-151`) has adjustments, heal spots, stickers and analysis only. `applyCrop`/`resetCrop` (`798-813`) mutate `appliedCrop` and reload the photo without recording history. The comment at `815-817` explicitly preserves the undo stack across crop changes.

**Affected files:** `Models/EditorModel.swift`, `Views/CropOverlay.swift`.

**Impact:** after applying a crop, ⌘Z cannot recover the previous framing. The user must re-enter the crop tool and reconstruct it, which is impossible exactly for freehand crops.

**Recommendation:** add `crop: CGRect?` to `EditState` (or a parallel crop-history stack) and restore it through `reloadCropped()`. Note that restoring crop requires a reload, so treat it as an asynchronous undo step with a busy state. Add a test.

### H-6 — Preview and export disagree on blemish kernel size (High)

**Evidence:** `spotRadius = max(1.5, min(24.0, faceWidthPx * 0.030))` (`ImageProcessor.swift:702`). `faceWidthPx` scales with the working extent. On a 24 MP export a face may be ~1500 px wide, giving a desired radius of 45 px, clamped to 24 px (1.6 % of face width). On the 1800 px preview the same face is ~450 px wide, giving 13.5 px (3 % of face width). The preview therefore heals a relatively wider area than the export.

**Affected files:** `Core/ImageProcessor.swift`.

**Impact:** a blemish that disappears in the preview may remain partially visible in a full-resolution export, or the preview may overstate healing. This undermines WYSIWYG.

**Recommendation:** express the clamp as a fraction of face width with a resolution-aware upper bound (e.g. `min(faceWidthPx * 0.045, …)` scaled by `scale`), or remove the 24 px cap and bound by a cost budget instead. Verify with a synthetic face rendered at two resolutions and compare normalized deltas.

### M-1 — Heal stamps are ellipses on non-square photos (Medium)

**Evidence:** `HealSpot.radius` is a fraction of the image's short side (`Heal.swift:1-10`), but `HealGeometry.shapes` builds a normalized **square** rect:

```swift
CGRect(x: spot.center.x - spot.radius, y: 1 - spot.center.y - spot.radius,
       width: diameter, height: diameter)
```

`Heal.swift:66-74`. In pixel space that is `2r·W` wide and `2r·H` tall, an ellipse whose aspect ratio equals the photo's. The "keep the stamp's own radius" test (`SelfCheck.swift:2100-2106`) uses a square fixture, so it cannot catch this.

**Affected files:** `Models/Heal.swift`, `Core/ImageProcessor.swift` (uses `shapes`).

**Precedent:** the sticker path already solves the same problem correctly: `ArtGeometry.shortSides` converts a short-side fraction into the working frame using the photo's pixel aspect ratio (`Sticker.swift:34-47`). Healing should use the same conversion.

**Impact:** on a 3:4 or 9:16 portrait, a round brush covers a wider horizontal band than intended; on landscape it covers a taller band. Healing quality and the on-canvas brush preview disagree with the actual repair footprint.

**Recommendation:** convert the short-side radius into per-axis normalized radii before building the ellipse: `dx = radius * shortSide / width`, `dy = radius * shortSide / height` (equivalently, reuse the `ArtGeometry.shortSides` approach). Add a non-square self-check (e.g. 240 × 320) asserting a circular mask footprint.

### M-2 — Mask resolution is capped at 1600 px (Medium)

**Evidence:** `MaskBuilder.maxMaskDimension = 1600` (`MaskBuilder.swift:44`); both full and preview mask sets are built with that cap (`ImageProcessor.swift:188-189`). Person segmentation is also bounded to 1600 (`SceneEngine.swift:110`).

**Affected files:** `Core/MaskBuilder.swift`, `Core/ImageProcessor.swift`, `Core/SceneEngine.swift`.

**Impact:** on a 24 MP export, feature masks (lips, eyes, lash line, teeth, brows) are upscaled ~3.75×. Edges are smooth but their precision is limited; thin features such as the lash line or the boundary between enamel and gum can bleed. Because the preview uses the same cap, the preview does not reveal this.

**Recommendation:** retain the cap for preview, but build feature masks at full resolution (or at 2× the current cap) for export. Alternatively, refine only the small feature masks at full resolution while keeping region masks capped. Measure export edge accuracy on a high-resolution face.

### M-3 — Full-resolution processing before downscale (Medium)

**Evidence:** `write` receives the already-processed full-resolution image and only then applies Lanczos (`ImageProcessor.swift:1056-1061`).

**Affected files:** `Core/ImageProcessor.swift`, `Models/EditorModel.swift`.

**Impact:** exporting a 24 MP photo at 1080 px runs the entire filter graph at 24 MP. This is the dominant cost of small exports and of large batches.

**Recommendation:** for targets well below the source, pre-scale the source and all geometry to the target size, then process (all radii are already normalized). Keep the current path for "original size". This preserves visual results and cuts export time substantially.

### M-4 — Preview renders cannot be interrupted (Medium)

**Evidence:** `schedulePreview` cancels `renderTask`, but the work runs in `Task.detached` (`EditorModel.swift:1451-1456`); cancellation does not propagate to a detached task already executing Core Image work. The `generation` guard discards the result, not the work.

**Affected files:** `Models/EditorModel.swift`.

**Impact:** rapid slider movement can queue multiple 1800 px renders. On a large photo this can cause lag and fan noise, and it keeps `isBusy` true.

**Recommendation:** add a shared cancellation flag checked between pipeline stages, or serialize renders through a single worker that replaces the pending request. Another option is to render a reduced "draft" scale during the drag and a full preview on release.

### M-5 — Unsaved-changes alert offers no Save (Medium)

**Evidence:** `confirmDiscardIfNeeded` adds only Discard and Cancel (`EditorModel.swift:585-609`).

**Affected files:** `Models/EditorModel.swift`.

**Impact:** closing with unsaved work forces the user to cancel, save manually, then close. Combined with C-1, an export can remove the prompt entirely.

**Recommendation:** add a "Save Project…" button as the default action, with Discard destructive and Cancel available. If no project URL exists, route to Save As.

### M-6 — Exports retain GPS and personal EXIF (Medium)

**Evidence:** `ImageProcessor.write` copies `metadata` and removes only pixel/profile keys (`1078-1089`); no GPS or personal fields are removed.

**Affected files:** `Core/ImageProcessor.swift`.

**Impact:** exported portraits can reveal capture location, device serial and owner name. This is a privacy leak in the primary output path.

**Recommendation:** strip GPS and owner/camera identifiers by default, with an explicit "preserve metadata" option. Document the policy in the export sheet.

### M-7 — Localisation parity is not compiler-enforced (Medium)

**Evidence:** `PersianL10n` overrides `L10n` properties, but Swift does not require an override. The comment at `PersianL10n.swift:3-5` claims the opposite. Both files currently have 321 string properties, but nothing prevents a new English-only string. There is no test for empty or identical values.

**Affected files:** `Models/Localization.swift`, `Models/PersianL10n.swift`.

**Recommendation:** replace inheritance with a protocol whose requirements are all properties (a conforming type must implement them), or add a self-check that reflects over the string list and asserts every Persian value is non-empty and differs where appropriate. Add a test for plural/placeholder strings.

### M-8 — Canvas accessibility (Medium)

**Evidence:** overlays are gesture-driven (`HealOverlay.swift`, `CropOverlay.swift`, `ArtOverlay.swift`, `AnalysisOverlay.swift`); no accessibility actions or keyboard alternatives. `Icon` labels raw symbol names (`LineIcon.swift:39`). Tools 11 and 12 have no keyboard shortcut (`ToolMode.swift:37-43`).

**Affected files:** `Views/*Overlay.swift`, `Views/LineIcon.swift`, `Models/ToolMode.swift`.

**Impact:** VoiceOver and keyboard-only users cannot place a sticker, adjust a crop, heal a spot, or drag an analysis leader.

**Recommendation:** expose overlays as accessibility elements with adjustable actions (position, size, rotation), add menu commands and shortcuts for art/analysis, and give icon-only buttons human-readable localized labels rather than SF Symbol identifiers.

### M-9 — Project version is not validated (Medium)

**Evidence:** `RetouchProject.version` is written (`Project.swift:14`) but `openProject(at:)` never checks it (`EditorModel.swift:2020-2029`).

**Affected files:** `Models/Project.swift`, `Models/EditorModel.swift`.

**Impact:** a future schema or an older incompatible file would be decoded on a best-effort basis, potentially applying wrong meanings to fields. There is no migration path.

**Recommendation:** check `version` on decode; accept ≤ current with migrations, and refuse newer versions with a clear message. Add a test for an unsupported version.

### M-10 — Mask memory footprint (Medium)

**Evidence:** 21 masks × 1600 × ~1067 × 4 bytes per set, two sets held (`ImageProcessor.swift:188-189`, `MaskBuilder.swift:58-69`). See §5.1.

**Affected files:** `Core/MaskBuilder.swift`, `Core/ImageProcessor.swift`.

**Impact:** ~286 MB of mask buffers before Core Image intermediates, for grayscale data that needs one byte per pixel.

**Recommendation:** use a one-component 8-bit context and share one mask set between preview and export where possible.

### M-11 — Real-photo checks are opt-in (Medium)

**Evidence:** `--face` gates `checkRealFace`, `checkAutoRetouchIsFaceLocal`, `checkAnalysisOverlay` (`SelfCheck.swift:56-90`, invocation around `560-780`).

**Affected files:** `Core/SelfCheck.swift`, `build.sh`.

**Impact:** the default build gate never exercises Vision on a real face, auto-retouch face locality, or the analysis overlay. Regressions there ship unnoticed.

**Recommendation:** add a small, synthetic, license-clean face fixture (or a procedurally generated realistic face) to the default suite, while keeping the private photo path optional. Alternatively, run the real-photo suite manually before releases and record the result.

### M-12 — Analysis export silently degrades on a photo with no detected face (Medium)

**Evidence:** `export(to:)` sets `drawAnalysis = analysis.isEnabled && !faces.isEmpty` and, when false, falls through to the normal write path (`EditorModel.swift:1892-1918`). The suggested file name still says `-analysis-lines.png` or `-analysis-poster` (`1900-1912`), and the dialog still shows the chosen analysis mode.

**Affected files:** `Models/EditorModel.swift`, `Views/EditorView.swift`, `Models/Analysis.swift`.

**Impact:** exporting an "overlay only" analysis of a landscape, a back-turned subject, or a photo where Vision missed the face produces a normal photograph named as an analysis artifact. The user may not notice until the file is opened.

**Recommendation:** disable analysis export modes when `faces.isEmpty`, or fail with a clear localized message ("no face detected — analysis cannot be drawn"). Do not silently write a different artifact.

### L-1 — Deprecated Core Image kernel language (Medium/Low)

**Evidence:** 16 `CIColorKernel`/`CIWarpKernel` constructions across `SkinEngine.swift`, `LookEngine.swift`, `FeatureReshaper.swift`, `MakeupEngine.swift`, `MaskBuilder.swift`; each raises a deprecation diagnostic in the build (`'init(source:)' was deprecated in macOS 10.14`).

**Affected files:** the five Core files above.

**Impact:** kernels still run, but Apple has deprecated the language. A future macOS/SDK may remove support; the build is already noisy, which hides new warnings.

**Recommendation:** migrate kernels to Metal Shading Language (`CIKernel(functionName:fromMetalLibraryData:)`) or to `CIColorCube`/built-in filters where possible. Until then, silence the known warnings explicitly so new warnings remain visible.

### L-2 — God objects and duplicated field plumbing (Medium)

**Evidence:**

- `EditorModel.swift` is 2,132 lines and owns loading, masks, previews, tools, healing, stickers, crop, analysis, export, batch, projects, recovery, undo and preferences.
- `InspectorView.swift` is 1,155 lines and builds eleven panels.
- `ImageProcessor.swift` is 1,109 lines and owns loading, masks, the pipeline, person analysis, smart crops and export.
- `SmartAnalyzer.swift` is 1,364 lines.
- `Adjustments` repeats every field in `retouchOnly`, `reshapeOnly`, `colorLightOnly`, `lookOnly`, `makeupOnly`, `bodyOnly`, `backgroundOnly`, `applyingX`, `scaledX` — the same list written six to nine times. This duplication is the direct cause of H-1.

**Affected files:** as listed.

**Impact:** adding one slider requires edits in many places, and omissions (like H-1) are invisible to the compiler. Review and testing surface is large.

**Recommendation:** introduce field-set abstractions (key paths or generated group descriptors) so a group is defined once. Split `EditorModel` into document, rendering, tools and persistence collaborators. Split `ImageProcessor` into loader, mask factory, pipeline and exporter. This is refactoring, not redesign; behaviour can stay identical and the existing self-check suite provides a safety net.

### L-3 — Dead code and stale comments (Low)

**Evidence:** `HealGeometry.largestRadius` (`Heal.swift:79-82`) is unused; `spotsMask` now groups stamps into up to four radius classes (`ImageProcessor.swift:619-650`). The doc comment on `largestRadius` still claims "one healing pass serves every stamp, sized by the largest of them." Also, `PersianL10n`'s comment about compile-time parity is inaccurate (M-7).

**Affected files:** `Models/Heal.swift`, `Models/PersianL10n.swift`.

**Impact:** misleading documentation for future maintainers; harmless at runtime.

**Recommendation:** delete `largestRadius` and correct the comments.

### L-4 — Build is arm64-only, ad-hoc signed (Low)

**Evidence:** `build.sh:40-50` fixes `-target arm64-apple-macosx14.0`; `codesign --sign -`.

**Affected files:** `build.sh`, `Resources/Info.plist`.

**Impact:** no Intel support, no universal app, no Gatekeeper-clean distribution. Fine for the owner's M3; not a shippable product.

**Recommendation:** if distribution is ever required, build a universal binary, add hardened runtime, sign with a Developer ID and notarize. Until then, document the limitation in the README (which does not exist yet).

### L-5 — No repository documentation (Low)

**Evidence:** no `README.md`, no `AGENTS.md`, no architecture document, no project brief. `.gitignore` and script comments are the only onboarding material.

**Affected files:** repository root.

**Impact:** future work must rediscover conventions (coordinate systems, mask polarity, build path) from source.

**Recommendation:** keep this audit as `Docs/TECHNICAL_AUDIT.md` and add a short `README.md` covering build, run, test, and the privacy rule for fixtures.

### L-6 — Untracked analysis feature (Low)

**Evidence:** `Sources/RetouchStudio/Core/AnalysisRenderer.swift`, `Models/Analysis.swift`, `Views/AnalysisOverlay.swift` are untracked; `Resources/AppIcon.icns`, `make-icon.sh`, and many source files are modified but uncommitted.

**Affected files:** working tree.

**Impact:** the feature exists only in the working tree. A clone of `HEAD` lacks the Analysis tool; a disk failure loses it. This also makes the audited revision ambiguous.

**Recommendation:** commit the analysis feature and the current modifications as a coherent change before further work. Do not commit `build/`, `.build/`, `*.app`, or private fixtures (already ignored).

---

## 11. Missing Features and Recommendations

### 11.1 Professional workflow gaps

1. **Straighten / rotation.** No horizon or angle control exists. Crop supports aspect ratios and freeform only. This is the most conspicuous omission for portrait work.
2. **Backdrop image replacement.** Background supports blur, tone, saturation, solid fill and removal, but not dropping the subject onto another image.
3. **Save-on-close.** The discard alert has no Save path.
4. **Project relink.** Absolute paths only.
5. **Batch parity and batch control.** No per-file crop, stickers, healing, analysis, progress or cancel.
6. **History panel.** Undo is keyboard-only with no visible list of steps.
7. **Multi-document / tabs.** One photo at a time; opening replaces the current document.
8. **Export presets and metadata policy.** Format/size/quality are per-session defaults; there is no named preset and no strip/preserve metadata switch.
9. **Watermark / proofing.** No text or logo overlay.
10. **Before/after export.** No side-by-side or split export artifact.
11. **Print / share / Photos integration.** Not present.
12. **HEIC/AVIF/WebP export.** JPEG, PNG, TIFF only.

### 11.2 Quality and engine improvements

1. Full-resolution feature masks for export (M-2).
2. Resolution-aware blemish kernel (H-6).
3. One-component masks and one shared mask set (M-10).
4. Migrate kernels to Metal (L-1).
5. Real 16-bit intermediate processing for PNG/TIFF exports, or explicitly document that 16-bit is the storage container, not the working precision.
6. Skin-tone-aware auto thresholds already exist; add explicit validation across deep/fair skin in the default suite rather than relying on one private photo.
7. Optional detail-preserving upscale for cropped exports.

### 11.3 UX and accessibility

1. Accessible, keyboard-operable canvas overlays (M-8).
2. Localized human labels for icon-only controls (M-8).
3. Save in the discard alert (M-5).
4. Reset All that truly resets (H-2).
5. Clear, non-destructive behaviour messaging for Smart Analyze (H-1).
6. Progress and cancel for export/batch (H-3, §5.4).
7. Localization parity test and a documented string workflow (M-7).
8. Visible keyboard cheat sheet in Help.

### 11.4 Reliability and data safety

1. Export must not clear the dirty flag (C-1).
2. Crop in undo (H-5).
3. Project relink and relative paths (H-4).
4. Version check and migration (M-9).
5. Multiple recovery slots or a recovery-on-quit prompt.
6. Export write to a temporary file then rename, so a failed write cannot leave a truncated image.
7. Metadata privacy default (M-6).

### 11.5 Testing

1. Add model tests for export clean-state, resetAll, smart-merge, crop undo, batch parity, relink, recovery.
2. Add a non-square heal geometry test.
3. Add a preview/export parity test at two resolutions.
4. Add a localization completeness test.
5. Add a synthetic face that exercises Vision in the default build gate (M-11).
6. Add a UI smoke test target (even a minimal one) for sheet flows and keyboard shortcuts.

---

## 12. Prioritized Development Roadmap

Priority definitions:

- **P0** — stops silent data loss or wrong output in the primary path. Fix before any further feature work.
- **P1** — restores expected professional behaviour and consistency.
- **P2** — quality, performance and accessibility improvements.
- **P3** — maintainability, documentation, and optional capabilities.

### P0 — Data integrity (do first, small and well-scoped)

| Item | Work | Why |
|---|---|---|
| P0-1 | Remove `cleanState`/`cleanCrop` assignment from export; add regression test | C-1: silent loss of unsaved work |
| P0-2 | Preserve unmeasured fields in Smart Analyze; add field-preservation test | H-1: silent destruction of settings |
| P0-3 | Make Reset All clear heal stamps and analysis; enable menu by real edit state | H-2: visible edits survive "Reset" |
| P0-4 | Commit the untracked analysis feature and current modifications | L-6: work exists only on disk |

**Exit criteria:** a user can export, run Smart Analyze and reset without losing or retaining unintended state; tests fail if any of these regress.

### P1 — Core workflow correctness

| Item | Work | Why |
|---|---|---|
| P1-1 | Bring batch export to parity (or label it "adjustments only") and add cancel/progress | H-3 |
| P1-2 | Add crop to undo/redo | H-5 |
| P1-3 | Add project relink / relative path fallback | H-4 |
| P1-4 | Add Save to the discard alert | M-5 |
| P1-5 | Fix heal stamp aspect conversion; add non-square test | M-1 |
| P1-6 | Fix blemish kernel scaling so preview and export agree | H-6 |

**Exit criteria:** batch output matches single output for the same edit; crop is reversible; moving a project+photo pair does not break it; closing with unsaved work offers Save; a heal brush is round on every aspect ratio.

### P2 — Quality, performance and accessibility

| Item | Work | Why |
|---|---|---|
| P2-1 | Export feature masks at full resolution (keep preview cap) | M-2 |
| P2-2 | Pre-scale before processing for small export targets | M-3 |
| P2-3 | One-component masks, shared preview/full set | M-10 |
| P2-4 | Cancellable/coalesced preview renders | M-4 |
| P2-5 | Accessibility actions and keyboard for overlays; localized icon labels | M-8 |
| P2-6 | Strip GPS/personal metadata by default, with an opt-in | M-6 |
| P2-7 | Localization parity self-check | M-7 |
| P2-8 | Validate project version and add migration hook | M-9 |
| P2-9 | Add a license-clean synthetic face to the default self-test | M-11 |
| P2-10 | Disable or clearly fail analysis export when no face exists | M-12 |

**Exit criteria:** full-resolution exports have full-resolution feature edges; 1080 px exports of large photos are materially faster; mask memory drops; VoiceOver can place a sticker and adjust a crop; exported portraits carry no location by default; a new English string cannot silently ship untranslated.

### P3 — Maintainability and product expansion

| Item | Work | Why |
|---|---|---|
| P3-1 | Migrate kernels to Metal; silence known deprecations | L-1 |
| P3-2 | Split `EditorModel`, `ImageProcessor`, `InspectorView`; define adjustment groups once | L-2 |
| P3-3 | Delete dead `largestRadius`; correct stale comments | L-3 |
| P3-4 | Add `README.md` and keep this audit under `Docs/` | L-5 |
| P3-5 | Universal build / hardened runtime / notarization (if distribution is intended) | L-4 |
| P3-6 | Straighten/rotation tool | §11.1 |
| P3-7 | Backdrop-image replacement | §11.1 |
| P3-8 | Export presets, metadata policy UI, watermark, before/after export | §11.1 |
| P3-9 | History panel and multi-document workflow | §11.1 |
| P3-10 | HEIC/AVIF export and share/Photos integration | §11.1 |

Findings introduced by §13 slot into the same lanes:

| Item | Work | Priority | Why |
|---|---|---|---|
| P1-7 | Add an explicit selected-face policy (default largest), filter by confidence, route per-face radii and makeup family through it | P1 | H-7: every face is edited, first-face scalars |
| P1-8 | Replace `isBusy` with an operation coordinator; give export a document-scoped token and cancellation; gate Save/Open | P1 | M-13: uncoordinated operations, stale export completion |
| P2-11 | Guard `.null`/infinite rectangles and consume `hasLandmarks` | P2 | M-16: landmarkless faces produce empty or invalid masks |
| P2-12 | Implement luminance-preserving Even Skin Tone or correct its contract | P2 | M-14: undocumented shading/contrast flattening |
| P2-13 | Constrain the teeth-alignment search mask to the mouth opening | P2 | M-15: grown mask can reach the inner lip |
| P3-11 | Remove `Package.swift` or make it a supported path; delete dead accessors | P3 | L-7: misleading build path and dead state |

---

## 13. Advanced Engineering Audit

This section is the deeper, code-level pass requested after the main audit. It does not replace §2–§10; it tests their claims against the call graph, the actual arithmetic, the state transitions and fresh executions. No source file was changed for this section.

Each statement carries one of three statuses:

- **Confirmed** — the code path is present and the stated behaviour follows from it.
- **Suspected** — the path is present, but the visible outcome depends on data or runtime behaviour that was not reproduced here.
- **Runtime verification required** — the effect is plausible and testable, but no measurement was taken. No timing, memory or quality number in this section is invented.

The executed evidence for this section is listed in §13.G and Appendix C.

### 13.A Dependency and Call-Graph Analysis

#### 13.A.1 Runtime call graph

The shipping app is one Swift module. The compile-time graph therefore has no enforced module boundary; the important edges are runtime ownership and data flow:

```text
Views (EditorView, TopBar, InspectorView, CompareCanvas, overlays)
   │  bindings / commands / gestures
   ▼
EditorModel (@MainActor, 2,132 lines)
   ├── load / reloadCropped ──► ImageProcessor.load
   │                              ├── FaceAnalyzer.analyze (Vision, preview pixels)
   │                              │       └── FaceGeometry (normalized landmarks)
   │                              ├── AutoAnalyzer.annotateTeeth / annotateEyes
   │                              ├── MaskBuilder.makeMask / subtract / union
   │                              └── process(…, adjustments: .zero)
   ├── schedulePreview ──────► ImageProcessor.process ──► SkinEngine
   │                                                    ├── MakeupEngine
   │                                                    ├── FeatureReshaper
   │                                                    ├── SceneEngine (person / pose)
   │                                                    ├── LookEngine
   │                                                    └── ArtRenderer
   ├── export ───────────────► process + AnalysisRenderer + ImageProcessor.write
   ├── runBatch ─────────────► ImageProcessor.load + process + write per file
   ├── smartAnalyze ─────────► AutoAnalyzer + ImageProcessor.faceCrop + SmartAnalyzer
   ├── ensurePersonMask ─────► PersonAnalyzer (SceneEngine)
   ├── analysis overlay ─────► AnalysisRenderer (separate canvas layer)
   └── persistence ──────────► RetouchProject / RecoveryStore / AppSettings / L10n
```

The engine itself is a set of stateless enums that take a `CIImage` plus parameters and return a `CIImage`. That is the strongest structural decision in the codebase: the pixel work is deterministic and testable without a view. The stateful parts are concentrated in two places: `EditorModel` (document, history, tasks) and `ImageProcessor` (loader, mask factory, pipeline, writer).

#### 13.A.2 Critical interaction-to-render paths

| User action | Entry point | Path to pixels | Weak point |
|---|---|---|---|
| Move any slider | `EditorView.swift:34-35` (`onChange(of: model.adjustments)`) | `schedulePreview` (`EditorModel.swift:1431-1465`) → 40 ms sleep → `Task.detached` → `ImageProcessor.process` → `previewImage` | One detached render per change; older renders cannot be stopped once started (M-4). |
| Add / move / delete a heal stamp | `healSpots` `didSet` (`EditorModel.swift:82`, `251-258`) | `rebuildSpotMasks` → `schedulePreview` | Stamps are stored against the original photo; a crop re-maps them before the next render. |
| Add / move / delete a sticker | `stickers` `didSet` (`EditorModel.swift:87`, `260-266`) | `ArtGeometry.workingStickers` → `schedulePreview` → `ArtRenderer.apply` | Sticker coordinates are working-frame coordinates; crop is applied at render time. |
| Drag analysis dot | `AnalysisOverlay` gesture → `dragAnalysisEnd` (`EditorModel.swift:1237-1243`) | `analysisChanged` → `refreshAnalysisOverlay` only | Analysis is an AppKit/SwiftUI overlay, not part of the photo graph; export re-renders it separately. |
| Apply crop | `applyCrop` (`EditorModel.swift:798-806`) | `reloadCropped` (`818-855`) → `ImageProcessor.load` → `install` (`657-700`) → rebuild masks → preview | Crop mutates pixels and masks but is not in `EditState` (H-5). |
| Smart Analyze | `smartAnalyze` (`1618-1655`) | detached `AutoAnalyzer` + `SmartAnalyzer` → report sheet | Report is a snapshot; applying it is a separate, destructive group merge (H-1). |
| Export | `saveExport` → `export` (`1873-1948`) | detached `process` (and optional `AnalysisRenderer`) → `ImageProcessor.write` | No generation token, no cancel, no busy guard; completion writes clean baselines (C-1, M-13). |
| Batch export | `runBatch` (`2060-2122`) | per file: `load` → `process` → `write` | Ignores heal, stickers and analysis; one crop for all files (H-3). |

#### 13.A.3 Coupling and duplication

1. **Core ↔ Models is bidirectional.** The engines in `Core/` depend on model types (`Adjustments`, `Sticker`, `AnalysisSettings`, `FaceGeometry`), while `Models/Localization.swift:752-775` depends on `SmartAnalyzer.Finding`. In a single target the compiler cannot flag the layering violation. It means a change to a UI-facing enum can require a Core change and vice versa.
2. **Engines reach back into the singleton.** `AutoAnalyzer.swift:77`, `FeatureReshaper.swift:236`, `SceneEngine.swift:142` and `:222` call `ImageProcessor.shared` for a `CIContext` or a rendered bitmap. A pure engine is therefore not independently testable without the singleton, and every such call competes for the same context.
3. **`EditorModel` is the only hub.** Every gesture, menu command, task, history entry and persistence operation is a method on the same `@MainActor` object. The view layer holds almost no state of its own. This is why `EditorModel` is 2,132 lines and why concurrency findings in §13.E concentrate there.
4. **The adjustment vocabulary is copied by hand.** `retouchOnly`, `reshapeOnly`, `colorLightOnly`, `lookOnly`, `makeupOnly`, `bodyOnly`, `backgroundOnly`, `applyingRetouch`, `applyingColorLight`, `applyingReshape`, `applyingMakeup`, `applyingBody`, `applyingBackground`, `scaledRetouch` and `scaledColorLight` each repeat a field list (`Adjustments.swift:140-470`). The compiler cannot see an omitted field; H-1 is the direct result.
5. **Repeated geometry plumbing.** Eye, under-eye, cheek and blush rectangles are recomputed from the face box in several places (`FaceAnalyzer.swift:286-355`, `MaskBuilder` call sites, `FeatureReshaper.swift:504-513`). A change to the definition has to be made consistently, and the missing `.null` guard (M-16) exists in more than one of those copies.

#### 13.A.4 Dead code and unused state

| Symbol | Evidence | Status |
|---|---|---|
| `HealGeometry.largestRadius` | `Heal.swift:79-82`; no caller in `Sources/` or `Tests/` | Dead; its comment still describes a single-pass healing design that `ImageProcessor.spotsMask` replaced. |
| `FaceGeometry.hasLandmarks` | Written at `FaceAnalyzer.swift:427` and `:483`; no read anywhere | Dead flag; no fallback or UI warning uses it. |
| `EditorModel.isBeyondPixelAccuracy` | `EditorModel.swift:1319`; no caller | Dead; the UI never uses the pixel-accuracy hint. |
| `MaskSet.face`, `.leftEye`, `.rightEye`, `.forehead`, `.nose` | Declared at `ImageProcessor.swift:45-59` and built in `buildMasks`. `.face` is read only by the self-test (`SelfCheck.swift:164`, `622`); the other four have no reader in `process`, the engines or the views | Built and stored but not used by the product; they still consume mask memory (M-10). |
| `Package.swift` | Repository root; `build.sh:40-50` compiles with `swiftc` directly and `Tests/run.sh:4-8` explains that SwiftPM is not the build system | The manifest is not exercised by build, test or release. |

The dead mask fields are worth calling out separately from L-3 because they are not harmless: five mask bitmaps are materialised at up to 1600 px per mask set (each `makeMask` allocates a `CGContext` and calls `makeImage()`), yet four have no reader and the fifth is drawn only by the self-test. That is a concrete part of the mask-memory figure in §5 and M-10.

### 13.B Algorithm and Image-Quality Audit

#### 13.B.1 Skin smoothing (frequency separation)

`SkinEngine.smoothSkin` (`SkinEngine.swift:325-364`) builds a base band and a detail band, then recombines them through a kernel with amplitude-aware retention:

- `base = Gaussian(CINoiseReduction(image), radius = max(1.6, 3.2 × scale))`.
- `detail = image − base`.
- `keep = mix(retention, 1, smoothstep(knee, 2.5 × knee, |detail|))`, with `retention = 1 − amount × (1 − 0.70 × preserve)` and `knee = 0.55`.
- `result = base + detail × keep`, blended through the skin mask at full strength.

At `retention = 1` the reconstruction is the identity (`base + image − base`). At `texturePreserve = 100` and full strength, retention is 0.30, so the slider never becomes a pure blur. The amplitude-aware knee keeps high-contrast edges (lashes, lip edge, specular highlights) even when the smooth slider is high.

**Assessment.** This is a real split, not a blur blended over the original; the self-test checks the identity case and the texture ratio. The remaining quality questions are not answered by the suite:

- The self-test measures texture on one synthetic cheek and compares against a Gaussian of a different radius; it does not test a high-contrast edge for halos or a real face at two resolutions.
- `CINoiseReduction` is an Apple filter with its own internal behaviour; the fixed `inputNoiseLevel 0.018` and `inputSharpness 0.55` are not adapted to skin tone, ISO or resolution.
- The base radius scales with the image, but the mask resolution is capped (M-2), so at export the mask edge is upscaled while the base radius is not. Edge precision, not the smoothing math, is the limiting factor at high resolution.

Status: **Confirmed** implementation; **Runtime verification required** for halo and high-resolution edge quality.

#### 13.B.2 Blemish removal

`SkinEngine.removeBlemishes` (`108-200`) is a detection-and-transplant pipeline, not a blanket median:

1. `cleaned = localMedian(image, radius = 1.15 × spotRadius)`. The median is implemented by Lanczos-downscaling by `factor = min(8, radius)`, applying the fixed 3×3 `CIMedianFilter`, then upscaling (`239-262`). The `factor` ceiling is why radii above roughly 7–8 px stop increasing the median window.
2. `donor = image` translated by `2.6 × spotRadius` on x only; `donorClean = localMedian(donor)`.
3. `healKernel` transplants only the donor's luminance detail:
   `detail = dot(donor − donorClean, luma)`, `similar = 1 − smoothstep(0.06, 0.20, ‖donorClean − clean‖₂)`, `repaired = clean + detail × 0.85 × similar`.
4. `deviation = |image − cleaned|`; gate = `clamp(luma × 18 − 0.17 × 18)`; dilate by `0.55 × spotRadius`, blur by `0.45 × spotRadius`; intersect with `skinTexture`; blend at the slider amount.

Manual healing reuses the same transplant with three differences (`SkinEngine.healSpots`, `210-235`): it skips the deviation gate because the user pointed at the pixels, transplants donor texture at `0.9` instead of `0.85`, and blends with a Gaussian rim of `0.4 × radius` at full strength. `spotsMask` (`ImageProcessor.swift:614-654`) sorts stamps by radius, forms at most four size classes (a new class starts when a stamp is less than half the current anchor), builds one mask per class with a feather of `max(1.2, min(0.004 × shortSide, 0.35 × radius))`, and runs the repair once per class with `radius = largestClassRadius × shortSide`. That keeps a small stamp from inheriting the smear of a large one, at the cost of several full-image passes when the stamps are heterogeneous.

The thresholds are stated as measured in the working colour space (clean skin max 0.096, real blemishes min 0.251). The design is deliberately conservative: clean skin is left bit-for-bit alone, and only pixels above the dead zone are replaced.

**Assessment.** Confirmed strengths: no median wash over clean skin, donor texture rather than a flat patch, a similarity gate against hair/lens/shadow, and separate size buckets for manual stamps. Confirmed limitations:

- The donor is a fixed horizontal offset. On the left/right edge of a face it can land on background or another feature; the similarity gate reduces but does not eliminate that risk.
- The median window ceiling (`factor ≤ 8`) plus the `spotRadius ≤ 24` clamp is the H-6 preview/export mismatch.
- `spotRadius` is derived from `faces.first` (`ImageProcessor.swift:686,702`), so a group photo can size the blemish repair for the wrong face (H-7).
- The self-test's blemish fixture uses one synthetic skin tone and three spots. It does not test edge-of-face donors, freckles, stubble, or a real blemish at full resolution.

Status: **Confirmed** implementation; **Suspected** for donor-on-feature artifacts; **Runtime verification required** for high-resolution parity beyond the arithmetic in H-6.

#### 13.B.3 Even Skin Tone

The doc comment at `SkinEngine.swift:368-369` promises "without touching luminance, so skin colour becomes uniform while shading stays." The implementation does not do that:

```swift
let blurred = image.clampedToExtent()
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(3, 9.0 * scale)])
    .cropped(to: extent)
let flattened = blurred.applyingFilter("CIColorControls", parameters: [
    kCIInputSaturationKey: 1 - 0.55 * amount,
    kCIInputContrastKey: 1 - 0.10 * amount
])
return blend(flattened, over: image, mask: mask, strength: amount * 0.6)
```

The comment at `378-393` describes mixing the original luminance with the blurred chroma, but the final line blends the **full RGB** `flattened` image over the original. At full strength and `amount = 1`, 60% of the pixel is the blurred, desaturated, contrast-reduced copy. That changes shading and local contrast inside the mask, not only chroma. It can flatten a cheekbone or a nose shadow and reduce texture in the same pass.

The self-test only checks that the slider changes pixels (`skinToneEvens` in group [6]); it does not measure luminance preservation or texture retention. This is finding M-14.

Status: **Confirmed** implementation/documentation mismatch; visual magnitude **Runtime verification required**.

#### 13.B.4 Teeth alignment and whitening

`ImageProcessor.process` computes `gapRadius` from the first face's `enamelRect` height (`759-761`) and grows the **already gated enamel mask** by `0.8 × gapRadius` with a feather of `0.35 × gapRadius` (`762-765`). `SkinEngine.alignTeeth` then applies a median-based gap fill to that search mask (`589-601`), blending at `0.9 × amount`. The gap kernel only changes pixels that are darker than the local median by a smoothstep of 0.18–0.42 (`607-615`), which protects ordinary tooth shading.

The risk is the search mask, not the kernel: growing an enamel mask outward by roughly a tooth-gap radius can reach the inner lip or the gum line. Those pixels are also darker than the enamel median, so they satisfy the gap condition. The result is not a white slab — the blend is 90% and the kernel keeps a trace of shadow — but it can lighten the inner lip edge on an open smile. The comment at `589-590` claims the radius is "too narrow to reach the lips"; the code computes it from `enamelRect.height × 0.45` and then grows by another 0.8×, which is a geometric argument, not a measured one.

Status: **Suspected**; **Runtime verification required** on a close-up open-smile photo. This is M-15.

#### 13.B.5 Makeup, colour and grain

- **Makeup** is luminance-preserving by construction for pigment layers: `tinted` builds `luma × tone × shade / luminance(shade)` and multiplies it over a flat shade layer (`MakeupEngine.swift:60-79`), so the original highlights and creases remain. Powder (blush/shadow) uses soft light; liner uses multiply; gloss uses a blurred screen bloom. The fixed blend floors (`0.10 + 0.5 × amount`, `0.15 + 0.6 × amount`, etc.) mean the slider never reaches zero effect at non-zero strength, which is intentional but means the labels are not literal percentages.
- **Colour** is a deterministic chain: levels → exposure → contrast → saturation → vibrance → warmth → curve → split tone → HSL → clarity → vignette → look → grain (`ImageProcessor.swift:931-1009`). The order is documented and deliberate. The output is 8-bit for JPEG and RGBA8 for the preview; PNG/TIFF containers are 16-bit but the working graph is not a 16-bit pipeline (existing finding; the document previously corrected this).
- **Grain** uses a full-resolution random field, softened by `radius = min(1.5, shortSide / 1600 × 0.5)` and compensated with `slope ×= 1 + radius` (`LookEngine.swift:355-389`). This makes the apparent grain size track image size, but the random field is still generated on the output pixel grid, so a preview and a full-resolution export do not contain the same grain pattern. That is acceptable for a grain effect; it does prevent pixel-identical preview/export comparisons.

Status: **Confirmed** implementation; **Runtime verification required** for perceived grain consistency and makeup behaviour across skin tones.

#### 13.B.6 Geometry and warping

`FeatureReshaper` applies a local inverse-scale warp:

```text
d = |(p − c) / r|
if d ≥ 1: p unchanged
w = smoothstep(1 − d)
scale = mix(1, 1/s, w)
p' = c + (p − c) × scale
```

Each control has an elliptical influence radius, and the falloff is C¹. The kernel composes up to eight controls **sequentially inside one pass** (`FeatureReshaper.swift:48-84`); `apply` splits more than eight controls into multiple full-image warp passes (`44`, `106-167`). The comment claims this "composes correctly because each pass only affects its own influence region." That is true only where influence regions do not overlap. Face-shape, cheek, jaw and chin controls intentionally overlap, and two faces multiply the control count. With more than eight active controls the image is resampled more than once, and overlapping displacements compound.

That is not automatically a defect — sliders are meant to combine — but it is a quality limitation that the test suite does not measure: the self-test checks only that each slider moves its region and that the background is unchanged. It does not check for softening, double displacement, or identity when two opposing sliders are used.

Two further geometry limits are structural, not numerical:

- **No roll/pose compensation.** Derived regions are fractions of the axis-aligned `boundingBox` (`FaceAnalyzer.swift:286-355`). A tilted head moves the cheeks and under-eye bands relative to the actual features, and a profile face has a different landmark topology.
- **Feature protection is incomplete.** Shape moves protect eyes, lips and brows (`ImageProcessor.swift:919-927`), but not the nose or teeth. A strong cheek or jaw warp whose influence ellipse reaches the nose can move it; the protection mask does not include it.

Status: **Confirmed** mechanism; **Suspected** visual softening/compounding at high control counts; **Runtime verification required**.

#### 13.B.7 Segmentation and background

`PersonAnalyzer` runs `VNGeneratePersonSegmentationRequest` at `.balanced` with an 8-bit one-component output (`SceneEngine.swift:145-173`). The mask is upscaled to the image extent; a mask covering ≤1% of the frame is rejected. `backgroundRadii` scales blur and feather with the short side and the working scale (`255-268`), and the same mask drives blur, tone and saturation so they share one seam.

Limits:

- `.balanced` is a speed/quality compromise; the code adds no alpha matting or edge refinement, so fine hair and semi-transparent edges receive only whatever precision the model itself provides. No test in the repository measures segmentation edge quality.
- The person mask is capped to 1600 px like the face masks (M-2/M-10), then upscaled for export.
- Body skin is a person-mask ∩ YCbCr skin gate (`230-252`); clothing that falls inside the skin chroma box can still be smoothed, and the gate's fixed ranges are not adapted to skin tone.

Status: **Confirmed** implementation; **Runtime verification required** for hair/veil edges and cross-skin-tone body smoothing.

#### 13.B.8 Analysis overlay

`AnalysisRenderer` draws all faces' mesh or outline, but leader callouts only for `primaryFace`, defined as the largest bounding box (`AnalysisRenderer.swift:68-81`). The overlay is rendered at preview size for the canvas and separately at export size for the file, with normalized coordinates, so geometry is consistent. The UI exposes only the primary face's draggable dots (`EditorModel.swift:1206-1240`). That is a product limitation, not an algorithm defect: a group photo cannot annotate a second face without changing the primary-face rule.

#### 13.B.9 Mask construction, feathering and edge quality

All face and feature masks are produced by `MaskBuilder.makeMask` (`MaskBuilder.swift:48-137`):

```text
scale  = min(1, 1600 / max(extent.width, extent.height))
bitmap = RGBA8, opaque, antialiased; black = 0, white = 1
for each shape: fill polygon / ellipse / rounded rect in normalized mask space
feather: if max(feather, softness) > 0.5, Gaussian(radius = that × scale) on the small bitmap
upscale: transform by (extent.width / bitmapWidth), then translate and crop
```

Two properties follow directly from that order:

- **Feather size is preserved in output pixels.** When the mask is downscaled by `scale`, the blur radius is also multiplied by `scale`; the later upscale divides it back out, so a requested feather of *n* image pixels stays *n* image pixels at any output size. This is deliberate and is why preview and export halos match in radius.
- **Edge precision is not preserved.** The mask exists at most at 1600 px on the long edge. After upscaling, one mask pixel spans `maxDimension / 1600` output pixels on a larger photo, so the finest edge the mask can describe is coarser than the photo. The Gaussian then smooths what is left. On a 4032 px export, one mask pixel is about 2.5 output pixels before the resampling filter, and the mask edge is a resampled 1600-px edge, not a full-resolution one. This is the mechanism behind M-2; it is an edge-precision limit, not an error in the compositing math.

The mask algebra is also deliberate (`MaskBuilder.swift:139-190`):

- **Subtract** uses a kernel that decodes to sRGB (`pow 1/2.2`), computes `base × (1 − hole)`, and re-encodes. The fallback (`CIColorInvert` + multiply) blends in linear light and can leave residue at near-white coverage; the comment records a 98%-white hole leaving roughly 20% of the base, which is enough to put smoothing on lashes.
- **Union** uses `CIMaximumCompositing`, not addition, because these masks are opaque grayscale: adding two pieces of the same region would push values past 1.
- **Intersect** uses `CIMultiplyBlendMode`, which is correct for opaque grayscale (0.3 × 0.5 gives 0.15 coverage) but not for alpha-keyed masks.

Edge preservation inside the warp is a separate mechanism: eyes, lips and brows are unioned by `featureProtection` (`ImageProcessor.swift:919-929`) and composited back over the warped image once, after all warp passes (`FeatureReshaper.swift:163-165`). The nose and teeth are not in that protection set (13.B.6), and the segmentation mask has no matting refinement (13.B.7). Feather quality is therefore bounded by three different things depending on the tool: the 1600-px mask grid for face tools, the protection polygon for reshape, and the Vision mask resolution for body/background.

Status: **Confirmed** implementation and arithmetic; **Runtime verification required** for perceived edge quality at high export resolutions.

#### 13.B.10 Algorithmic versus UI limitations

| Observation | Kind | Where |
|---|---|---|
| Round heal brush becomes an ellipse on non-square photos | Implementation / coordinate conversion | M-1, `Heal.swift:66-74` |
| Preview and export heal different relative areas | Implementation / resolution clamp | H-6, `ImageProcessor.swift:702` |
| Even Skin Tone changes luminance | Implementation / documentation mismatch | M-14, `SkinEngine.swift:368-395` |
| Teeth alignment may reach the inner lip | Algorithmic mask growth | M-15 |
| All faces are edited; parameters come from the first face | Product + implementation policy | H-7 |
| No straighten/rotation, backdrop replacement, or face selection | Missing feature | §11.1; no code path |
| Reshape controls split into sequential warp passes | Algorithmic composition limit | §13.B.6 |
| No 16-bit working pipeline | Architecture / precision | §4, §5 |

### 13.C Multi-Face and Detection Reliability

#### 13.C.1 Detection facts

- `FaceAnalyzer.analyze` creates `VNDetectFaceLandmarksRequest()` with default revision and no confidence threshold; it returns `results.compactMap { geometry(from: $0) }` (`FaceAnalyzer.swift:434-444`).
- Detection runs on `originalPreview`, the image capped by `previewMaxDimension` (1800 px in the app; `ImageProcessor.swift:174-185`). Landmarks are then normalized to the image and reused for the full-resolution masks. The full-resolution export therefore does not re-detect at full resolution.
- `FaceGeometry` carries `hasLandmarks`, but no caller reads it (`FaceAnalyzer.swift:29`; grep evidence in §13.A.4).
- There is no face-selection state in `EditorModel`; `faceCount` only drives status strings and panel notes (`EditorModel.swift:67`, `1829-1833`, `ToolPanel.swift:73`, `InspectorView.swift:276,356`).

#### 13.C.2 Multi-face policy

| Consumer | Behaviour | Consequence |
|---|---|---|
| `ImageProcessor.buildMasks` | Loops every face and unions all shapes into one `MaskSet` (`236-482`) | Skin, makeup and detail masks apply to every detected face. |
| `ImageProcessor.process` (blemish, teeth, hair) | Uses `faces.first` for `spotRadius` (`686,702`), `gapRadius` (`759`) and hair volume (`834`) | A group photo sizes these effects from whichever face Vision returns first, not from the face being edited or the largest face. |
| `EditorModel.install` | `makeupFamily` from `faces.first` (`669-674`) | A single shade family is chosen for all faces. |
| `SmartAnalyzer.analyze` | Reads every face, weights the merged suggestion by bounding-box area (`SmartAnalyzer.swift:136-145, 260-290`) | The report is multi-face aware; the applied sliders are still global. |
| `AnalysisRenderer` | Mesh/outline for all faces; callouts for `primaryFace` only (`68-81`) | Only one face can receive leader labels. |
| UI | No face picker, no per-face toggles | The user cannot exclude a bystander or choose the subject. |

This is H-7. It is a policy problem first and a code problem second: the pipeline has no concept of a selected face, so a single global set of sliders is applied to all faces while three important radii are borrowed from `faces.first`.

#### 13.C.3 Failure modes

| Condition | What the code does | Status / risk |
|---|---|---|
| Two or more faces | Masks union; all faces edited; first face drives blemish/teeth/hair geometry; largest face drives analysis | **Confirmed** code path; group-photo visual **Runtime verification required**. |
| Face with no landmarks | `boundingBox` still valid; eye rects are `.null`; `cheekRect`/`underEyeRect` produce infinite-origin or zero-width rectangles; `hasLandmarks` is never consulted | **Confirmed** code path (M-16); visual/crash impact **Suspected**. |
| Low-confidence false positive | Included because confidence is not filtered | **Suspected**; can add masks over a non-face region. |
| Profile / extreme yaw | Landmark topology changes; axis-aligned derived regions do not compensate | **Suspected**; masks can sit off the feature. |
| Head roll/tilt | Bounding box and derived rectangles remain axis-aligned | **Suspected**; under-eye and cheek masks drift. |
| Small background face | Detected on the 1800 px preview; masks are later upscaled to full resolution | **Confirmed** resolution limit (M-2); reliability of the landmarks is **Runtime verification required**. |
| Occlusion (hand, hair, glasses) | Vision may omit landmarks; no fallback or warning | **Suspected**; same path as M-16. |
| Face set changes after crop | `install` rebuilds masks; analysis endpoints reset; history/clean state preserved | **Confirmed** handling; no stale-mask bug found here. |
| Wrong-face analysis | `AnalysisRenderer.primaryFace` = largest area; `smartAnalyzer` merge = area-weighted | **Confirmed** policy; no user override. |

No multi-face fixture exists in the repository (`Tests/` contains only `EngineTests.swift` and `run.sh`), and the real-photo self-test used one photo with one face. The multi-face conclusions above are derived from code, not from a group-photo render. That limitation is stated again in §13.G.

#### 13.C.4 Recommendations

1. Add an explicit `selectedFaceID` (or index) to the document, default to the largest face, and let the user pick a face on the canvas. Route masks, `spotRadius`, `gapRadius`, hair volume and `makeupFamily` through that selection.
2. Filter `VNFaceObservation` by `confidence` (and optionally by minimum face size at preview scale) before building masks. Surface a status when a face is below the threshold rather than silently including it.
3. If the product intends to edit every face, make that a visible choice ("apply to all faces") and compute per-face radii where the effects are per-face.
4. Add a synthetic two-face fixture (two face-like shapes at different sizes) for the mask/radius selection logic, and keep a private group photo for the optional real-photo suite.
5. Guard every derived rectangle with `isNull`/`isInfinite` and fall back to face-box fractions, then test a `FaceGeometry` with empty eye/nose arrays.

### 13.D Undo, Redo and State Integrity

#### 13.D.1 What the document stores

`EditState` is `adjustments + healSpots + stickers + analysis` (`EditorModel.swift:146-151`). Crop is stored separately (`appliedCrop`), and the clean baseline is `cleanState + cleanCrop` (`157`, `291-294`). Heal stamps are stored in original-photo coordinates; stickers in working-frame coordinates; analysis endpoints in normalized working-frame coordinates (`Analysis.swift`). The coordinate conventions are correct and deliberate (Appendix A).

#### 13.D.2 Operation trace

| Operation | Mutation | History | Preview / masks | Clean state | Caveat |
|---|---|---|---|---|---|
| Slider drag | `adjustments` | `scheduleCommit` after 350 ms; one step per gesture | `onChange` → `schedulePreview` | `updateCleanState` immediately | A 350 ms idle resets the coalescing window; a slow drag can split into several undo steps. |
| Reset one effect / group | `adjustments` | `commit` before and after | via `onChange` | updated | Group reset preserves other groups by hand-copying fields (L-2). |
| Preset | `adjustments` | one commit | via `onChange` | updated | Preset application is a full replacement, not a merge. |
| Auto Retouch / Auto Color | `adjustments` via group copy | one commit | via `onChange` | updated | Group copy overwrites unmeasured fields (H-1). |
| Smart Analyze apply | `adjustments` + optional heal spots | one commit | via `onChange` / `healSpots` | updated | Same wipe as H-1. |
| Add / move / erase heal stamp | `healSpots` | `didSet` → `scheduleCommit` | `rebuildSpotMasks` + preview | updated | Stored in original coordinates; crop maps them. |
| Add / move / rotate / delete sticker | `stickers` | `didSet` → `scheduleCommit` | preview | updated | Working coordinates; crop applied at render/export. |
| Analysis toggle / region / tint / dot | `analysis` | `didSet` → `scheduleCommit` | overlay only | updated | Not part of the photo graph; exported separately. |
| Apply / reset crop | `appliedCrop` | **none** | async reload + masks | `cleanCrop` updated only at load/export | H-5: ⌘Z cannot restore framing. |
| Undo / redo | `restore` 4 fields | stack, cap 100 | `didSet` repaints | not changed | `restore` deliberately sets `selectedSticker = nil`. |
| Save project | writes JSON | none | none | `cleanState/cleanCrop` = current | Absolute photo path (H-4). |
| Open project | replaces document | `resetHistory` | load | new baseline | No busy guard (M-13). |
| Export | writes image | none | full-res render | **set to exported state** | C-1. |
| Batch export | writes files | none | per-file load/process | none | H-3. |

#### 13.D.3 Integrity findings

- **Crop is not undoable.** `EditState` excludes `appliedCrop`; `applyCrop`/`resetCrop` do not record history (`798-813`), and `reloadCropped` explicitly preserves the undo stack (`815-817`). A freehand crop cannot be reconstructed after the fact.
- **Reset All is incomplete.** `resetAll` (`1469-1476`) clears adjustments, stickers and compare position, but leaves `healSpots` and `analysis`. The menu is disabled by `adjustments.isIdentity` (`App.swift:261-263`), so a photo edited only with a heal stamp or analysis overlay cannot invoke Reset at all. H-2.
- **Smart Analyze wipes unmeasured fields.** `applyingRetouch`/`applyingColorLight` copy whole groups from a zero-based patch (`Adjustments.swift:366-408`), so finish, iris, lash, lens, teeth-align, split tone, curve, HSL and vignette are reset even though the analyzer did not measure them. H-1.
- **Export marks the document clean.** `cleanState = exportedState` and `cleanCrop = exportedCrop` (`1941-1942`) disarm the discard guard even though no project was written. C-1.
- **Project paths are absolute and unversioned.** `RetouchProject.imagePath` is an absolute path (`Project.swift:17`); `openProject` refuses a missing path (`2020-2029`); `version` is never checked (M-9). H-4.
- **Batch is a different pipeline.** `runBatch` passes only adjustments and a person mask (`2060-2122`); heal, stickers and analysis never reach the batch output, and one crop is reused for heterogeneous aspect ratios. H-3.
- **Positive findings.** `isLoadingState` prevents project installation from being recorded as a user edit (`EditorModel.swift:707-714`); `restore` assigns all four state fields so masks and canvas repaint (`222-232`); `resetHistory` prevents undo from crossing photos (`298-310`); `reloadCropped` re-maps heal stamps and resets analysis endpoints (`842-849`). These are correct and should be preserved in any refactor.

#### 13.D.4 State risks introduced by concurrency

The state model assumes one operation at a time, but the UI does not enforce that assumption. `export`, `saveProject` and `saveProjectAs` are reachable while `isBusy` is true (`App.swift:242-251`), and `openProject` is reachable at any time because its menu item has no `.disabled` modifier (`App.swift:219-235`; no busy guard in `openProject` at `2020-2029`). If a crop reload or a new load is running, Save can capture a document whose pixels and state are between two generations, and Export can run against the previous `sourceFull`. This is treated in §13.E and M-13.

### 13.E Concurrency and Race Conditions

#### 13.E.1 Concurrency inventory

| Work | Started by | Cancellation / guard | Result guard | Notes |
|---|---|---|---|---|
| Load | `load` (`621-651`), `reloadCropped` (`818-855`) | `loadTask.cancel()`, `renderTask.cancel()`, `batchTask.cancel()`, `generation += 1` | `self.generation == generation` | Does not cancel an in-flight export. |
| Preview render | `schedulePreview` (`1431-1465`) | `renderTask.cancel()`; 40 ms sleep cancelled before the detached block | `self.generation == generation` | `Task.detached` already running is not stopped (M-4). |
| Person mask | `ensurePersonMask` (`1395-1429`) | `personGeneration` token; `install` increments it (`666`) | token equality | Stale segmentation after a photo swap is correctly discarded. |
| Smart Analyze | `smartAnalyze` (`1618-1655`) | `smartGeneration`; `install` increments it (`735`) | token equality | `isAnalyzingSmart` also blocks a second run. |
| Batch | `runBatch` (`2060-2122`) | `batchTask.cancel()`, `batchGeneration`, `load` cancels it | token equality | Cancellation checks only at file boundaries. |
| Export | `export` (`1873-1948`) | **none** | **none** | No `isBusy` guard, no task handle, no generation token. |
| Save / Save As | `saveProject` / `saveProjectAs` (`1952-1987`) | **none** | none | Menu gated only by `hasImage`. |
| Project open | `openProject` (`2020-2029`) | none | none | Menu is always enabled (`App.swift:219-235`); the discard guard is the only barrier, and it does not check `isBusy`. |

#### 13.E.2 Confirmed race conditions

1. **One Boolean cannot represent concurrent work.** `isBusy` is set by preview, load, crop reload, Smart Analyze, export and batch (`EditorModel.swift:62`). Preview completion unconditionally sets `isBusy = false` when its generation still matches (`1463`). If a preview and an export overlap — which the menu permits — the preview can clear `isBusy` while the export is still rendering. Batch and Crop then become enabled during the export (`App.swift:252-255`; `applyCrop` guard `798`), so a second heavy operation can start on the same model and context.
2. **Export has no generation or cancellation token.** If the user opens another photo or applies a crop while an export is running, the export continues against its captured `sourceFull` and, on completion, writes `isBusy = false`, a "saved" status, and the old `cleanState`/`cleanCrop` into the new document (`1936-1943`). C-1 already makes that clean-state write wrong for the same document; across a document swap it is also stale. The result can be a wrong status/busy state and an incorrect clean baseline.
3. **Save and project Open are not serialised with Load.** `saveProject` can write a project while `load` is between generations, and `openProject` can replace the document while an export or batch is running. Save is enabled whenever `hasImage` is true, and Open is always enabled (`App.swift:219-235`, `241-251`); both stay usable during a crop reload.
4. **Preview work is not actually cancelled.** `renderTask.cancel()` stops the 40 ms delay, but once `Task.detached` begins, Core Image continues to completion (M-4). Rapid slider movement therefore creates overlapping renders that the generation guard discards only at the end.
5. **Batch and export can overlap.** Batch is gated by `isBusy` at the menu, but the preview-completion race above can clear that flag during an export; `runBatch` cancels the previous batch, not the export.
6. **Person segmentation can run twice for the same photo.** `ensurePersonMask` is triggered by `schedulePreview` when person tools are active, while `export` independently runs `PersonAnalyzer.analysis` when the mask is missing (`1895-1903`). Both are guarded against stale assignment, but they duplicate the expensive Vision pass. This is a cost issue, not a correctness race.

Main-thread stalls are not part of the race list, but they were checked. Preview renders, loads, crops and exports all run in `Task.detached`; project JSON encode/write (`writeProject`, `1989-2006`) and decode (`openProject`, `2024-2025`) run synchronously on the model actor. A normal project is small, but a document with a very large heal/sticker list could delay the UI during save or open. No stall or freeze was reproduced; this remains **Suspected** and unmeasured.

The `CIContext` singleton is documented by Apple as safe to use from multiple threads; no race was found in the context itself. The problem is the surrounding task ownership and the shared UI state, not Core Image thread-safety.

#### 13.E.3 Recommended structure

- Replace the Boolean with an operation coordinator: either a serial `TaskQueue` for load/crop/export/batch, or `activeOperations: Set<OperationID>` with `isBusy` derived from it. Menu enablement should read the coordinator, not the raw flag.
- Store the export task, give it a generation token tied to a document ID, and check both on completion. Cancel it when the document is replaced.
- Either disable Save/Export/Open while busy, or queue the request and show it as pending. Do not let a modal save panel start a second export over a running one.
- Keep the existing `personGeneration`/`smartGeneration` pattern; it is correct and should be extended to export.
- Add a model-level test that starts a preview and an export simultaneously and asserts that `isBusy` stays true until both finish. This is a unit-testable coordinator question, not a UI test.

### 13.F Build and Distribution Audit

#### 13.F.1 What the build actually does

`build.sh` is the real build system:

- Probes installed Command Line Tools SDKs by type-checking a SwiftUI `@State` snippet against each, and selects the newest SDK that supports the macro (`build.sh:16-36`).
- Compiles every `Sources/**/*.swift` with `swiftc -O -whole-module-optimization -target arm64-apple-macosx14.0` (`build.sh:40-50`), linking SwiftUI, AppKit, Core Image, Vision and Uniform Type Identifiers.
- Assembles `Retouch Studio.app` by hand: binary, `Resources/Info.plist`, `PkgInfo`, app icon, Vazir fonts (`build.sh:53-76`).
- Signs ad-hoc: `codesign --force --sign - "$APP_BUNDLE"` (`build.sh:78`).
- Runs the synthetic `--selftest` and fails the build if it does not pass (`build.sh:80-90`).

`Package.swift` declares an executable target for the same sources, but neither `build.sh` nor `Tests/run.sh` uses it. `Tests/run.sh` links the app sources into a temporary `main.swift` harness because SwiftPM/XCTest is not available in the Command Line Tools-only environment (`Tests/run.sh:1-20`).

#### 13.F.2 Measured artifact facts

The following were read from the existing build artifact, not inferred:

| Property | Observed | Command |
|---|---|---|
| Architecture | `Mach-O 64-bit executable arm64`, thin | `file`, `lipo -archs` |
| Code signature | `flags=0x2(adhoc)`, `Signature=adhoc` | `codesign -dv --verbose=4` |
| Entitlements | none printed | `codesign -d --entitlements :-` |
| Gatekeeper assessment | `Retouch Studio.app: rejected` | `spctl -a -vv` |
| Minimum macOS | `minos 14.0` | `vtool -show-build` |
| SDK used | `sdk 27.0` | `vtool -show-build` |
| Bundle version | `2.1` / build `3` | `Resources/Info.plist` |

The Gatekeeper rejection is expected for an ad-hoc-signed local build; it is evidence of distribution status, not a runtime defect. There is no `Developer ID`, no hardened runtime, no notarization, no sandbox and no universal binary.

#### 13.F.3 Distribution assessment

- **Local use:** the build is self-contained and runs on the owner's arm64 Mac. The synthetic self-test is a genuine release gate, which is unusually strong for a local tool.
- **Sharing:** an ad-hoc app downloaded from another machine will be rejected by Gatekeeper and cannot be notarized as built. Sharing requires a Developer ID signature, hardened runtime, notarization and usually a universal binary (or an explicit Apple-silicon-only statement).
- **Sandbox:** there is no `com.apple.security.app-sandbox` entitlement. The app can read/write anywhere the user can; for a local-only tool that is a deliberate convenience, but it is not App Store compatible and it widens the blast radius of a file-path bug.
- **Reproducibility:** the SDK probe picks the newest compatible SDK, so two machines can compile with different SDKs. The binary is arm64-only. `Package.swift` is not a reproducible alternative because it produces neither the bundle nor the resources.
- **Build diagnostics:** the 16 deprecated kernel constructions (L-1) are the known warning source. There is no `-warnings-as-errors`, so new warnings can hide among them.
- **No usage descriptions are required** for the current file-open/file-save model. There is no Photos, camera, microphone or network API; no privacy manifest is needed for the current feature set. Adding Photos integration later would require usage descriptions and possibly a privacy manifest.

#### 13.F.4 Recommendations

1. Keep `build.sh` as the supported path, and either delete `Package.swift` or make it a real alternative with a bundle-assembly step (L-7).
2. Add `-warnings-as-errors` after silencing the known deprecations, so new warnings fail the build.
3. If distribution is intended, add a Developer ID signing identity, hardened runtime, notarization and a universal build; do not change the current signing config for local builds.
4. Document the local-only status and the macOS 14 floor in a README (L-5).
5. Keep the real-photo self-test as a manual pre-release gate (M-11); it is the only test that exercises Vision on real pixels.

### 13.G Regression and Stress Testing

#### 13.G.1 Executed in this audit

All commands were run on 2026-11-04 against the audited working tree. Logs are temporary and outside the repository.

| Suite | Command | Result |
|---|---|---|
| Engine regression | `./Tests/run.sh` | **exit 0**; 33 ✓ / 0 ✗; `ENGINE TESTS: PASS` (7 groups) |
| Synthetic self-test | `./build/bin/RetouchStudio --selftest --out /tmp/rs-audit-13-synth` | **exit 0**; 154 ✓ / 0 ✗; `SELFTEST: PASS` |
| Real-photo self-test | `./build/bin/RetouchStudio --selftest --face "$HOME/Documents/image test/IMG_7196.JPG" --out /tmp/rs-audit-13-face` | **exit 0**; 166 ✓ / 0 ✗; `SELFTEST: PASS`; 2268×4032, 1 face, teeth/sclera/iris/lash masks present |

The real-photo output was written to `/tmp/rs-audit-13-face`; no private photo was copied into the repository. The logs are `/tmp/rs-audit-13-engine.log`, `/tmp/rs-audit-13-synth.log` and `/tmp/rs-audit-13-face.log`.

#### 13.G.2 What the executed suites cover

- Engine tests: smoothing vs Gaussian texture ratio, blemish clearing, texture preserve, reshape locality, every reshape slider, every skin/detail/colour slider, identity. All use one synthetic face.
- Synthetic self-test: mask orientation, masked pipeline, eye/lip protection, full chain, auto separation, teeth gates, body/background, crop/sticker geometry, looks, export formats and analysis overlay geometry.
- Real-photo self-test: Vision on one real face, teeth/eye annotations, masks, retouch locality, analysis overlay, selected export paths.

The per-tool assertion matrix and its gaps are in §9.3; this subsection records what was executed in this pass, not the full coverage map.

#### 13.G.3 Scenarios that were not executed

| Scenario | Why it was not run | What the code suggests |
|---|---|---|
| Two-face group photo | No multi-face fixture in the repo; generating a Vision-reliable group photo would require a new asset or a private photo, and the audit is read-only | H-7: all-face masks, first-face scalars; runtime visual impact unmeasured. |
| 24 MP / 48 MP export timing | No Instruments run and no timing harness; this audit does not invent performance numbers | The graph runs at full resolution before downscale (M-3); mask cap (M-2) and blemish clamp (H-6) are the known quality limits. |
| Repeated undo/redo stress | No model-level test target; adding one would modify the test suite, which the brief forbids | `commitAdjustments` caps at 100; `restore` covers four state fields; crop is outside history (H-5). |
| Batch export end-to-end | Would write files and requires a UI flow; not executed in this audit | `runBatch` ignores heal/stickers/analysis and reuses one crop (H-3). |
| Long-session memory growth | No Instruments or memory measurement | Two 1600-px mask sets plus intermediates; `cacheIntermediates: true` (M-10, §5). |
| Rapid slider stress | Would require UI automation or a model stress harness | 40 ms debounce, detached renders cannot be interrupted (M-4). |
| Export during edit / edit during export | Would require UI automation; no test target | No generation guard on export; shared `isBusy` (M-13). |
| Crop during export | Same | Crop guard only checks `isBusy`; preview can clear it during export (M-13). |
| Non-square heal brush | No non-square test exists | M-1; the code path is a normalized square. |
| Preview/export parity at two resolutions | No parity test exists | H-6 arithmetic; mask cap M-2. |
| Analysis on a face-less photo | Real-photo suite used a face; synthetic suite has a face | `drawAnalysis = analysis.isEnabled && !faces.isEmpty`; export silently falls back to a normal image named as analysis (M-12). |
| Accessibility / keyboard-only flow | No UI test target; manual interaction not performed in this audit | M-8 remains open. |

#### 13.G.4 Stress-risk summary

- **Large image:** the pipeline is resolution-scaled and deterministic, but the full-resolution process happens before downscale (M-3), masks are capped (M-2), and blemish radius is clamped (H-6). Expect quality, not correctness, to degrade first.
- **Many faces:** masks are summed (H-7); the control count per image grows, which can push `FeatureReshaper` past one warp pass (§13.B.6).
- **Repeated history:** bounded at 100 states; crop is outside history; `EditState` is value-typed, so no aliasing issue was found.
- **Long session:** the singleton `CIContext` and `cacheIntermediates` are the main memory lever; no measurement was taken (M-10/§5).
- **Concurrent operations:** the highest-risk area in this audit; see M-13 and the export/clean-state interaction with C-1.

### 13.H Evidence-Based Findings

Status labels: **Confirmed** = follows from source; **Suspected** = source path exists but the visible effect depends on runtime data; **Runtime** = needs a measurement or a UI reproduction.

#### H-7 — Multi-face editing is implicit and parameterised from the first face (High)

**Evidence:**
- `ImageProcessor.buildMasks` loops every face and appends all shapes to one set (`ImageProcessor.swift:266-482`); the pipeline consumes one `MaskSet`.
- `process` derives `spotRadius` from `faces.first` (`686,702`), `gapRadius` from `faces.first?.enamelRect` (`759`), and hair-volume center/radius from `faces.first` (`834`).
- `ensurePersonMask`/`install` choose `makeupFamily` from `faces.first` (`EditorModel.swift:669-674`).
- `FaceAnalyzer.analyze` accepts every observation without a confidence filter (`FaceAnalyzer.swift:434-444`).
- `AnalysisRenderer` calls out only `primaryFace`, defined by area (`AnalysisRenderer.swift:68-81`); the UI has no face picker (`EditorModel.swift:1206-1240`).

**Affected files:** `Core/ImageProcessor.swift`, `Core/FaceAnalyzer.swift`, `Core/SmartAnalyzer.swift`, `Core/AnalysisRenderer.swift`, `Models/EditorModel.swift`.

**Impact:** in a group photo, skin/makeup/detail work lands on every detected face, including bystanders; blemish, teeth-align and hair-volume geometry are sized for whichever face Vision returns first, which may be a small background face; a low-confidence false positive can add masks over a non-face region. There is no way for the user to choose the subject or exclude a face.

**Recommended solution:** add an explicit selected face (default largest), route per-face radii and makeup family through it, filter by confidence/minimum size, and make "apply to all faces" a visible choice. Add a two-face fixture for selection and radius logic.

**Status:** Confirmed for the code path; multi-face visual impact **Runtime**.

#### M-13 — Concurrent operations share one Boolean and are not serialised (Medium)

**Evidence:**
- `isBusy` is a single `@Published` Boolean (`EditorModel.swift:62`) written by load, preview, crop, Smart Analyze, export and batch (`645`, `733`, `839`, `852`, `1463`, `1649`, `1937`, `2119`).
- `schedulePreview` sets `isBusy = false` when its generation matches (`1463`), even if an export is still running.
- `export` has no task handle, no generation token and no cancellation (`1873-1948`); it writes `cleanState`/`cleanCrop` on completion (`1941-1942`).
- `saveProject`, `saveProjectAs` and `openProject` have no busy guard (`1952-1987`, `2020-2029`); the menu disables only Batch by `isBusy` (`App.swift:252-255`).
- `load` cancels load/preview/batch but not an export (`621-627`).

**Affected files:** `Models/EditorModel.swift`, `App.swift`.

**Impact:** preview completion can re-enable Batch and Crop during an export, while Save and Export were never disabled by `isBusy` in the first place; a second export or a crop can start on the same model. A stale export completion can overwrite status and clean baselines after the document changed. This amplifies C-1 and can leave the UI reporting "idle" while work is still running.

**Recommended solution:** replace the Boolean with an operation coordinator (`activeOperations` or a serial task queue), give export a document-scoped generation token and a task handle, cancel it on document replacement, and gate Save/Export/Open on the coordinator. Add a model test that overlaps a preview and an export.

**Status:** Confirmed code path; the exact overlap requires UI timing but the state transitions are deterministic.

#### M-14 — Even Skin Tone changes luminance despite its contract (Medium)

**Evidence:** `SkinEngine.swift:368-395`. The comment promises "without touching luminance" and describes mixing original luminance with blurred chroma, but line 394 blends the full-RGB `flattened` image at `amount × 0.6`. `flattened` is the blurred image with saturation reduced and contrast reduced; it carries a different luminance field.

**Affected files:** `Core/SkinEngine.swift`.

**Impact:** at high strength the effect flattens shading and local contrast inside the skin-texture mask, not just colour blotches. Cheekbone and nose shadows can lose definition, and pore-level texture is reduced in the same pass. The self-test does not measure luminance or texture for this slider.

**Recommended solution:** either implement the documented operation (recombine the original luminance with the blurred chroma, e.g. `YCbCr` or a luminance mask), or rewrite the comment and expose the behaviour honestly. Add a luminance-preservation assertion and a texture-retention assertion to the engine suite.

**Status:** Confirmed implementation mismatch; visual magnitude **Runtime**.

#### M-15 — Teeth alignment grows its mask beyond enamel (Medium)

**Evidence:** `ImageProcessor.swift:759-765` computes `gapRadius = enamelRect.height × imageHeight × 0.45`, then grows the enamel mask by `0.8 × gapRadius` with a `0.35 × gapRadius` feather. `SkinEngine.alignTeeth` fills any pixel in that mask that is darker than the local median (`589-615`). The grown band can include the inner lip or gum line, which are darker than enamel.

**Affected files:** `Core/ImageProcessor.swift`, `Core/SkinEngine.swift`.

**Impact:** on an open smile, the inner lip edge can be lightened along with the tooth gaps. The kernel keeps a trace of shadow and the blend is 90%, so the artifact is likely a subtle light rim rather than a white slab, but it is exactly the kind of edge a retoucher notices.

**Recommended solution:** restrict the search mask to the mouth opening (e.g. intersect with the inner-lip polygon or a tooth-band rectangle) instead of growing the enamel mask freely, or gate the repair by proximity to enamel. Add an open-smile close-up check that measures the inner-lip delta.

**Status:** Suspected; **Runtime**.

#### M-16 — A landmarkless face feeds `.null` geometry into masks (Medium)

**Evidence:**
- `FaceGeometry.boundingBox(of:)` returns `.null` for an empty point array (`FaceAnalyzer.swift:369-378`).
- `cheekRect` uses `eye.minY`/`eye.minX` without a null guard (`286-302`); `underEyeRect` uses `eye.minY`, `eye.width` and `eye.midX` (`346-355`).
- `buildMasks` appends `leftCheekRect`, `leftBlushRect`, `leftUnderEyeRect` and `rightUnderEyeRect` unconditionally (`ImageProcessor.swift:278`, `318-325`).
- `FeatureReshaper.controls` appends cheek controls without a null guard (`504-513`).
- `hasLandmarks` is written (`FaceAnalyzer.swift:427,483`) but never read.

**Affected files:** `Core/FaceAnalyzer.swift`, `Core/ImageProcessor.swift`, `Core/FeatureReshaper.swift`.

**Impact:** a face observation without eye landmarks (profile, occlusion, small/blurred face) produces infinite-origin cheek rectangles and zero-width under-eye rectangles. The cheek mask is missing or invalid, the under-eye mask is empty, and the cheek slider becomes a no-op; in the worst case an infinite coordinate reaches a Core Graphics path. `hasLandmarks` would have been the signal to fall back, but nothing consumes it.

**Recommended solution:** guard every derived rect with `isNull`/`isInfinite`/positive size, fall back to face-box fractions when an eye is missing, and use `hasLandmarks` to suppress geometry controls or show a warning. Add a `FaceGeometry` fixture with empty eye/nose arrays.

**Status:** Confirmed code path; visible/crash impact **Suspected**.

#### L-7 — The SwiftPM manifest is unused and several accessors are dead (Low)

**Evidence:** `Package.swift` exists but `build.sh:40-50` and `Tests/run.sh:4-20` bypass it; `FaceGeometry.hasLandmarks` is never read (`FaceAnalyzer.swift:29`); `EditorModel.isBeyondPixelAccuracy` has no caller (`EditorModel.swift:1319`); `MaskSet.leftEye`, `.rightEye`, `.forehead` and `.nose` have no reader anywhere (`ImageProcessor.swift:45-59`), while `MaskSet.face` is read only by the self-test (`SelfCheck.swift:164`, `622`); `HealGeometry.largestRadius` is unused (`Heal.swift:79-82`).

**Affected files:** repository root, `Models/EditorModel.swift`, `Core/FaceAnalyzer.swift`, `Core/ImageProcessor.swift`, `Models/Heal.swift`.

**Impact:** the manifest suggests a build/test path that does not work with the actual resources; four mask fields consume memory with no reader and a fifth exists only for the self-test, so all five imply a product consumer that does not exist. Dead accessors mislead future maintainers.

**Recommended solution:** either make `Package.swift` a supported alternative (including bundle assembly and test target) or remove it; delete the unused accessors and mask fields, or document why they are retained. Fold this into L-3 rather than treating it as a separate refactor.

**Status:** Confirmed.

#### Existing findings reinforced by this pass

| Existing | New evidence / connection |
|---|---|
| C-1 | Export completion writes `cleanState`/`cleanCrop` (`1941-1942`); M-13 shows the same write can land after a document swap. |
| H-1 | The group-copy functions are the only merge mechanism; `applySmartReport` uses them for both retouch and colour (`1666-1688`). |
| H-3 | `runBatch` passes only adjustments and person mask (`2060-2122`); no heal/sticker/analysis path exists. |
| H-5 | `EditState` still has no crop field (`146-151`); `reloadCropped` still preserves history (`815-817`). |
| H-6 | `spotRadius` is still clamped to 24 px (`702`), independent of export scale. |
| M-2 | `MaskBuilder.maxMaskDimension` is still 1600 (`44`); both full and preview masks use it. |
| M-4 | `Task.detached` still runs to completion after `renderTask.cancel()` (`1451-1458`). |
| M-10 | Four fields in the 21-mask set have no reader and a fifth is drawn only by the self-test, so part of the measured footprint is wasted. |
| M-11 | The build gate still runs synthetic checks only (`build.sh:80-90`); real-photo checks are opt-in. |
| L-4 | The artifact remains arm64-only, ad-hoc signed, without entitlements or notarization (§13.F.2). |

#### Suggested order for the new findings

1. **H-7 (P1):** define the face-selection policy before adding more face-dependent tools; it changes masks, radii, makeup family and analysis callouts.
2. **M-13 (P1):** introduce the operation coordinator; it is the umbrella for M-4 and the export side of C-1.
3. **M-16 (P2):** guard null geometry and use `hasLandmarks`; small, local, testable.
4. **M-14 (P2):** either implement the documented luminance-preserving path or correct the contract.
5. **M-15 (P2):** constrain the teeth search mask; verify on an open smile.
6. **L-7 (P3):** remove the unused manifest/dead accessors during the next refactor.

---

## Appendix A — Coordinate and Mask Conventions

These conventions are relied on throughout and should not be changed casually:

| Context | Origin | Units | Evidence |
|---|---|---|---|
| Crop overlay / project crop | Top-left | Normalized 0…1 | `Crop.swift`, `ImageProcessor.swift:149-156` |
| Heal stamps / stickers | Top-left | Normalized; radius is a fraction of the short side | `Heal.swift`, `Sticker.swift` |
| Core Image extents | Bottom-left | Pixels | Core Image |
| Vision landmarks | Bottom-left, normalized to the image | 0…1 | `FaceAnalyzer.swift` |
| `MaskShape` ellipses | Bottom-left | Normalized | `MaskBuilder.swift`, `Heal.swift:66-74` |
| Mask pixels | Opaque grayscale; white = apply, black = leave alone | 8-bit | `MaskBuilder.swift:58-68` |
| UI layout direction | Follows `AppLanguage`, not the system | LTR/RTL | `AppLanguage.swift:14-16` |

## Appendix B — Adjustment Groups

`Adjustments` is partitioned into groups used by Auto, presets and the pipeline:

| Group | Fields | Used for |
|---|---|---|
| Retouch | smooth, blemish, wrinkle, tone, dark circles, brighten, texture preserve, teeth, eyes, iris, lashes, lens, teeth align | Auto Retouch, skin/detail panels |
| Reshape | eyes, nose, nose tip, lips, cheeks, jaw, chin, face width/length | Geometry pass |
| Colour/Light | exposure, contrast, blacks, whites, saturation, vibrance, warmth, clarity, vignette, split tone, curve, HSL | Auto Color, colour panel |
| Look | look ID, strength, grain | Film looks |
| Makeup | lips, gloss, blush, brows, shadow, liner, hair colour/shine/volume, contour | Makeup panel |
| Body | smooth, tone, slim, waist, arms, legs | Body panel; needs person mask/pose |
| Background | blur, tone, saturation, fill, fill colour, remove | Background panel; needs person mask |

The group views are defined in `Adjustments.swift:150-470`. The manual copy functions are the source of H-1.

## Appendix C — Executed Evidence Index

| Log | Location | Contents |
|---|---|---|
| Engine tests (first pass) | `/tmp/rs-audit-engine.log` | 7 groups, per-slider deltas, identity |
| Build + synthetic self-test (first pass) | `/tmp/rs-audit-build.log`, `build/selftest/selftest.log` | SDK probe, compile, 154 checks, warnings |
| Real-photo self-test (first pass) | `/tmp/rs-audit-face.log`, `/tmp/rs-audit-face/` | 166 checks, analysis outputs |
| Engine tests (§13 rerun) | `/tmp/rs-audit-13-engine.log` | exit 0; 33 ✓ / 0 ✗; `ENGINE TESTS: PASS` |
| Synthetic self-test (§13 rerun) | `/tmp/rs-audit-13-synth.log`, `/tmp/rs-audit-13-synth/` | exit 0; 154 ✓ / 0 ✗; `SELFTEST: PASS` |
| Real-photo self-test (§13 rerun) | `/tmp/rs-audit-13-face.log`, `/tmp/rs-audit-13-face/` | exit 0; 166 ✓ / 0 ✗; `SELFTEST: PASS`; 2268×4032, 1 face |

These logs are temporary and deliberately outside the repository. Reproduce them with the commands in §9.1 and §13.G.1. No private photo was copied into the repository.

---

## 14. Post-audit addendum — closed findings

The stabilization plan (companion document, branch `stabilization`) has been
carried out through item P2-6. This table is the evidence index: each closed
finding names the commit that fixed it and the check that now guards it.
Finding text is struck through here; the original entries in §10 and §13 are
left untouched as the audited snapshot.

| Finding | Planned item | Commit | Guarding check |
|---|---|---|---|
| ~~C-1 — Export marks the document clean (Critical)~~ | P0-1 | `7a8bc54` | ModelTests `[P0-1]` `testExportDoesNotSave` |
| ~~H-1 — Smart Analyze overwrites fields it did not measure (High)~~ | P0-2 | `7f74527` | ModelTests `[P0-2]` `testSmartKeepsUnmeasuredFields` |
| ~~H-2 — Reset All is incomplete (High)~~ | P0-3 | `7f74527` | ModelTests `[P0-3]` `testResetAllClearsEverything` |
| ~~H-3 — Batch export is not the single-export pipeline (High)~~ | P1-1 | `cbc4038` | ModelTests `[P1-1]` `testBatchMatchesSingleExport`; self-test batch geometry |
| ~~H-4 — Projects depend on absolute photo paths (High)~~ | P1-3 | `0301660` | ModelTests `[P1-3]` `testProjectRelink` |
| ~~H-5 — Crop is outside undo/redo (High)~~ | P1-2 | `6f63200` | ModelTests `[P1-2]` `testCropIsUndoable` |
| ~~H-6 — Preview and export disagree on blemish kernel size (High)~~ | P1-6 | `a057a3f` | EngineTests `[9]` a blemish is the same fraction at every resolution |
| ~~H-7 — Every face is edited while radii come from `faces.first` (High)~~ | P1-4 | `447a108` | EngineTests `[8]` ordered faces, focus width, per-face mask coverage |
| ~~M-1 — Heal stamps are ellipses on non-square photos~~ | P1-7 | `6e6286c` | EngineTests `[10]` heal stamps stay round |
| ~~M-2 — Mask resolution is capped at 1600 px~~ | P2-2 | `b2873b8` | EngineTests `[12]` export masks at export resolution; `--memcheck` transient report |
| ~~M-3 — Full-resolution processing before downscale~~ | P1-6 | `a057a3f` | ModelTests `[P1-6]` `testPreviewStaysAtPreviewResolution` |
| ~~M-4 — Preview renders cannot be interrupted~~ | P1-5 | `ee71b86` | ModelTests `[P1-5]` `testOperationCoordination` (cancel paths) |
| ~~M-6 — Exports retain GPS and personal EXIF~~ | P2-6 | `1169f1f` | EngineTests `[16]` exports drop location and camera identity; ModelTests `[P2-6]` `testPrivacySettingDefaults`; self-test `checkPrivacyMetadata` |
| ~~M-9 — Project version is not validated~~ | P1-3 | `0301660` | ModelTests `[P1-3]` `testProjectVersionGuard` |
| ~~M-10 — Mask memory footprint~~ | P2-1 | `c8bfe13` | EngineTests `[11]` 1024 px preview set is visually indistinguishable |
| ~~M-13 — Export/Save/Open are not serialised~~ | P1-5 | `ee71b86` | ModelTests `[P1-5]` `testOperationCoordination` |
| ~~M-14 — Even Skin Tone changes shading and contrast~~ | P2-3 | `08e84cb` | EngineTests `[13]` luminance held, chroma evened |
| ~~M-15 — Teeth alignment grown band reaches the lips~~ | P2-4 | `c78ad80` | EngineTests `[14]` teeth alignment never reaches the lips |
| ~~M-16 — Landmarkless face feeds null-derived rects~~ | P1-4 / P2-5 | `447a108` / `655f226` | EngineTests `[8]` landmarkless masks; `[15]` finite analysis anchors and ink |
| ~~P0-4 — Analysis work existed only on disk~~ | P0-4 | `aa8399a` (+ icon `3688d57`) | Build, both suites and the packaged self-test pass at the addendum revision |

### 14.1 Verification at this addendum

Run on `stabilization` at `1169f1f`, 2026-11-04:

| Suite | Result |
|---|---|
| `./Tests/run.sh` | `ENGINE TESTS: PASS` (sections 1–16); `MODEL TESTS: PASS` (P0-1…P2-6) |
| `./build.sh` | App bundle built; built-in self-test passed |
| Packaged `--selftest --face "$HOME/Documents/image test/IMG_8264.JPG"` | `SELFTEST: PASS`, including the new privacy check |
| Settings window, live | "Remove location and camera info" visible and on; toggled off and back on; the saved preference read back as `1` |

The private portrait was read in place; no private fixture, export or log was
committed. Nothing was pushed.

### 14.2 Not closed by this pass

The deferred findings in the plan's §7 remain open by design: M-5 (no Save in
the discard alert), M-7 (localisation parity), M-8 (canvas accessibility), M-11
(opt-in real-photo checks), M-12 (analysis export with no face), and the Low
items L-1…L-7. In particular, the deprecated Core Image kernel warnings are
still emitted exactly as described in L-1; they are a warning, not a failure,
and fixing them would rewrite working kernels without a behavioural test that
requires it.
