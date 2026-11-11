# StudioCore R4 — Document Model Architecture Review

**Status:** review and documentation only. No application source, StudioCore source, test, fixture, build script, project format or recovered record was changed.

**Baseline:** branch `main`, commit `f6456b7b69473b65f5ce7318433bc8d0f0e511bf` (R3 geometry commit).
**Date:** 2026-11-11.
**Scope:** how document truth is represented, persisted, mutated and consumed today; what can become portable; the safe order in which it can leave `EditorModel`; and the first low-risk extraction candidate. No extraction is implemented here.

---

## 0. Evidence labels

Every claim in this document is marked or contextually identifiable as one of:

| Label | Meaning |
|---|---|
| **VERIFIED** | Read directly from the current source, a current fixture, or a test in this repository at the baseline commit. File and line are given. |
| **RECOMMENDATION** | A design proposal derived from the verified facts. It is not current behavior and is not implemented. |
| **HYPOTHESIS — NOT VERIFIED** | Plausible but requires measurement or a prototype. It must not be repeated as fact. |
| **ASSUMPTION** | A planning assumption; if wrong, the plan changes but the current code does not. |

The two untracked design packages (`Docs/STUDIOCORE_ARCHITECTURE.md`, `Docs/STUDIOCORE_INTERFACE_DESIGN.md`, `Docs/STUDIOCORE_EXTRACTION_ROADMAP.md`, `Docs/STUDIOCORE_CANONICAL_JSON.md`, `Docs/CROSS_PLATFORM_TECHNOLOGY_DECISIONS.md`) were read for consistency. Where they propose a future shape that does not exist in code, this review says so and treats the code as authoritative.

A naming collision must be stated once: the roadmap uses “R3” for *ports and pure policy* and “R4” for *`DocumentSession` extraction*. The repository’s local milestones used R2 for pure types and R3 for portable geometry. This document uses **R4** in the roadmap sense (“document model review”), and refers to source files by path, never by milestone label, to avoid ambiguity. See Appendix B.

---

## 1. Executive summary

**VERIFIED.** The application has no single object that means “the document”. Document truth is split across four mechanisms:

1. **`RetouchProject`** — the on-disk v3 sidecar (`Sources/RetouchStudio/Models/Project.swift:9`). It is a flat, keyed JSON object with 16 stored fields, a manual decoder, and no encoder override (synthesized keyed encoder).
2. **`EditorModel`** — a 3,519-line `@MainActor final class` with **92** `@Published` properties (`Sources/RetouchStudio/Models/EditorModel.swift:9-10`). It owns both document state and window/UI/engine state, and it also owns every file dialog, save/open path, autosave timer, recovery prompt, export job and batch job.
3. **`EditorModel.EditState`** — a private eight-field value (`Sources/RetouchStudio/Models/EditorModel.swift:314-323`) used for undo/redo, the clean baseline and therefore `hasUnsavedChanges`.
4. **External asset and preference stores** — AI patch/alpha files (`Sources/RetouchStudio/Models/AIEdit.swift:42`), backdrop images (`Sources/RetouchStudio/Models/Backdrop.swift:7`), user presets (`Sources/RetouchStudio/Models/UserPreset.swift:7`), recovery copies (`Sources/RetouchStudio/Models/Recovery.swift:73`), and `UserDefaults`-backed settings/recents (`Sources/RetouchStudio/Models/AppSettings.swift:10`, `:161`).

**VERIFIED.** The v3 file stores Apple geometry in an Apple-specific wire shape: `CGRect` as `[[x,y],[w,h]]`, `CGPoint` as `[x,y]`, `CGSize` as `[w,h]`. This was captured in R2/R3 and is documented in `Docs/STUDIOCORE_R3_GEOMETRY.md:88-121`. Any swap of a stored `CGRect`/`CGPoint`/`CGSize` for the R3 keyed `StudioRect`/`StudioPoint` changes project bytes and breaks the current decoder. R3 deliberately did not do this.

**VERIFIED.** `RetouchProject`’s manual decoder is the compatibility contract: a missing `version` reads as 3, five fields are required (`imagePath`, `adjustments`, `exportFormat`, `exportQuality`, `autoRetouchStrength`), every newer field uses `decodeIfPresent`, and unknown keys are ignored (`Sources/RetouchStudio/Models/Project.swift:96-115`). `makeProject()` applies deliberate `nil` normalizations for empty collections, default analysis, identity orientation and a zero long edge (`Sources/RetouchStudio/Models/EditorModel.swift:3145-3162`). Those normalizations are part of observed v3 output and must survive any refactor.

**RECOMMENDATION.** Do not start by moving `RetouchProject` or `EditorModel`. Start by extracting the small document aggregate that already exists in private form: `EditState` → a named `DocumentState` value with the same eight fields and the same equality semantics. It has **no serialization surface**, so it cannot change v3 bytes; it is already the exact unit of undo, dirty-state and autosave decisions; and it creates the seam for a later `DocumentSession` without moving a single pixel, panel or engine call.

The rest of this document maps the current responsibilities, inventories every document-bearing type, states the v3 compatibility invariants, defines the portable/platform boundary, proposes the target architecture, sequences the migration, and records the risks and the explicit non-goals.

---

## 2. Current architecture and responsibility map

### 2.1 Build and ownership reality

**VERIFIED.** The app is still one flat Swift compilation unit. `build.sh` collects `find Sources/RetouchStudio -name '*.swift'` (`build.sh:58`) and compiles it together with a separately built Foundation-only `StudioCore` static library (`build.sh:59-68`). The test harness links the whole app source tree except `App.swift` and `SelfCheck.swift` (`Tests/run.sh:35`). There is no SwiftPM target boundary protecting the design; the only enforced boundary is `Tests/run-studiocore.sh`, which rejects platform imports and platform-type tokens in `StudioCore`.

**VERIFIED.** `StudioCore` currently contains only pure value types:

| File | Contents |
|---|---|
| `Sources/StudioCore/Adjustments.swift` | `Adjustments` (custom keyed `Codable`, defaults for missing fields), `RetouchField`, `ColorField`, `HSLBand`, `AdjustmentGroup`, level helpers |
| `Sources/StudioCore/Makeup.swift` | `MakeupFamily`, `MakeupRegion`, `MakeupShade` catalog |
| `Sources/StudioCore/MakeupColor.swift` | `MakeupColor` (HSV, `Double`) |
| `Sources/StudioCore/StudioGeometry.swift` | `StudioPoint`, `StudioSize`, `StudioRect`, `StudioCoordinateSpace` |
| `Sources/StudioCore/UserPreset.swift` | `UserPreset` (id, name, adjustments) |

**VERIFIED.** Core and Models are cyclically dependent at the directory level: `Core/ExportService.swift` imports model values (`Adjustments`, `HealSpot`, `Sticker`, `AIEdit`, `AnalysisSettings`, `DocumentOrientation`, `WatermarkSettings`), while `Models/EditorModel.swift` imports `Core` types (`ImageProcessor`, `LoadResult`, `ExportService`, `RecoveryStore`). Any extraction that assumes a one-way directory graph is wrong until an explicit target/module split exists.

### 2.2 Responsibility classes

| Class | Definition | Today’s home |
|---|---|---|
| **A — Portable document domain** | Values and policies that describe *what the edit is*: parameters, geometry records, operation order, history transitions, project schema, export/batch policy, recovery policy. Deterministic, testable without a display, no OS objects. | Mostly `StudioCore` values plus app model structs; policy is scattered between `EditorModel`, `RecoveryStore`, `ExportService` and `BatchExportPolicy`. |
| **B — Application coordination** | Shell state and orchestration: published mirrors, operation tokens, sheets, alerts, dirty prompts, timers, view state, localized strings. | `EditorModel` and SwiftUI views. |
| **C — Platform services** | File URLs and dialogs, Application Support paths, bookmarks, `UserDefaults`, file system durability, image decode/encode, color management, process and IPC. | `EditorModel`, `RecoveryStore`, `AIEditStore`, `BackdropStore`, `UserPresetStore`, `AppSettings`, `ImageProcessor`, `AIWorker`. |
| **D — Image/AI engines** | Pixels and inference: Core Image pipeline, Vision detection, masks, rendering, generative worker. | `ImageProcessor`, `AnalysisRenderer`, `ArtRenderer`, `WatermarkRenderer`, `AICompositor`, `AIWorker`, `QuickEditRunner`, `SmartAnalyzer`. |

**VERIFIED.** Almost every document-bearing model struct sits in class **A** *and* depends on class **C** types for its stored fields (`CGPoint`, `CGRect`, `CGSize`, `URL`, `Data`). That is the central architectural problem this review must resolve without changing v3.

### 2.3 Seven questions used for every type

For each type in the inventory, the same seven questions were asked:

1. **Identity/value:** is it a value, a reference, or a UI object?
2. **Owner/mutation:** what code may mutate it, and is mutation a document edit?
3. **Persistence:** is it serialized into a project, a recovery copy, another store, or nowhere?
4. **Platform coupling:** which Apple types or services does it store or call?
5. **Consumers:** which engine, view, store or policy reads it?
6. **Headless testability:** can it be constructed and asserted without AppKit, Core Image or a window?
7. **Portability blocker:** what specifically prevents moving it into `StudioCore` unchanged?

### 2.4 Type inventory

#### A. Document and edit records

| Type | Location | Answers 1–3 | Platform coupling (4) | Main consumers (5) | Headless (6) | Blocker (7) |
|---|---|---|---|---|---|---|
| `RetouchProject` | `Models/Project.swift:9` | Value; built by `EditorModel.makeProject`; persisted as v3 JSON | `CGRect`, `UTType`, `Data` bookmark | `EditorModel` save/open; `RecoverySnapshot` | Decoder/encoder can run headless; bookmark helpers cannot | `CGRect`, `UTType`, Apple bookmark; manual decoder is the compatibility contract |
| `Adjustments` | `StudioCore/Adjustments.swift:14` | Value; mutated by sliders/tools; persisted inside project | None (already Foundation/`Double`) | Pipeline, export, presets, recovery | Yes | Already portable; **not** a blocker |
| `HealSpot` | `Models/Heal.swift:10` | Value; mutated by heal tool; persisted in `healSpots` | `CGPoint`, `CGFloat` | `HealGeometry`, pipeline, export | Construction yes; Codable uses Apple unkeyed shape | `CGPoint`/`CGFloat`; v3 wire shape |
| `Sticker` | `Models/Sticker.swift:20` | Value; mutated by art tool; persisted in `stickers` | `CGPoint`, `MakeupColor` | `ArtGeometry`, `ArtRenderer`, export | Yes except `StickerKind.title` calls `L10n` | `CGPoint`; UI-localized title extension; v3 wire shape |
| `AIEdit` | `Models/AIEdit.swift:11` | Value; appended by Quick Edit; persisted in `aiEdits` plus external files | `CGRect`, `CGSize`, `DocumentOrientation`, `UUID`, `Date` | `AICompositor`, export, `EditorModel` | Mostly; file existence needs `AIEditStore` | `CGRect`/`CGSize`; external asset store; v3 wire shape |
| `AnalysisSettings` | `Models/Analysis.swift:68` | Value; mutated by overlay; persisted in `analysis` | `CGPoint` in dictionaries, `CGFloat` in `AnalysisTint.rgb` | `AnalysisRenderer`, export, `EditorModel` | Value logic yes; drawing no | `CGPoint`; v3 wire shape for endpoints/anchors |
| `AnalysisRegion`, `AnalysisExportMode`, `AnalysisTint` | `Models/Analysis.swift:7`, `:35`, `:45` | Pure enums; persisted as raw strings | `CGFloat` tuple in `rgb` | Analysis UI/renderer | Yes | Tiny; `rgb` can become `Double` |
| `DocumentOrientation` | `Models/Orientation.swift:13` | Value; changed by rotate/flip/straighten; persisted | **`CIImage`, `CGAffineTransform`, `CGSize`** | Load, crop, heal/sticker/analysis mapping, AI patch, renderer | Arithmetic partly; `applied`/`ciTransform` no | Stores only three numbers, but the type embeds Core Image transforms and coordinate mapping |
| `CropGeometry` / `CropAspect` | `Models/Crop.swift:6`, `:31` | Pure geometry policy; crop rect persisted in project | `CGRect`, `CGSize`, `CGFloat` | Crop overlay, load, export, batch | Pure math yes | `CGRect`; no stored state except `RetouchProject.crop` |
| `AIMaskStroke`, `AIMaskSelection` | `Models/AIMask.swift:33`, `:41` | Transient selection; **not persisted** | `CGPoint`, `CGRect`, `CGImage` | Quick Edit runner | Not without Core Graphics | Transient, so not a v3 concern |
| `ExportSnapshot` | `Core/ExportService.swift:11` | Value projection of the document for export; not persisted | `CGRect`, `CGFloat`, `DocumentOrientation` | `ExportService`, `BatchExportPolicy` | Construction yes; rendering no | It is a *projection*, not the document; geometry types block a pure move |
| `WatermarkSettings` | `Models/Watermark.swift:10` | Output preference; persisted in `UserDefaults`, not in the project | None in the value | Export/watermark renderer | Yes | Already nearly portable; belongs to export intent, not document truth |
| `UserPreset` | `StudioCore/UserPreset.swift:4` | Value; persisted in a separate JSON file | None | Preset UI, `Adjustments` | Yes | Already portable; file I/O is a port |
| `RecoverySnapshot` | `Models/Recovery.swift:31` | Value wrapper; persisted in recovery files | `RetouchProject`, `Date` | `RecoveryStore`, `EditorModel` | Codable yes with scratch directory | Wraps a v3 project; file layout is platform |
| `RecoverySourceIdentity` | `Models/Recovery.swift:16` | Value; persisted inside snapshot | `Int64`, `Date` only | `RecoveryStore.sourceState` | Yes | None in the value; obtaining it uses `URLResourceValues` |
| `EditState` | `EditorModel.swift:314` | Value; **not persisted**; the undo/clean unit | `CGRect`, plus app model structs | Undo/redo, dirty state, autosave | Needs the app types, but no UI | Private; fields are the six geometry-bearing app types plus `Adjustments` |
| `ExportFormat` | `Core/ImageProcessor.swift:9` | Pure enum; stored as a string in project | None | Export, naming, UTType | Yes | Only the `utType` extension touches `UniformTypeIdentifiers` |

#### B. Policy and coordination types

| Type | Location | Class | Persistence | Note |
|---|---|---|---|---|
| `BatchExportPolicy` | `Core/BatchExportPolicy.swift:11` | A (policy) | None | Pure function over `ExportSnapshot`; calls `ExportService.cropApplies` and compares URLs |
| `ExportService` | `Core/ExportService.swift:112` | C/D | None | Rendering, color space, metadata allowlist, source-path protection, writing |
| `EditorModel.OperationKind` / `OperationToken` | `EditorModel.swift:235-311` | B | None | Async exclusion state; deliberately UI-shell policy |
| `RecoveryStore` | `Models/Recovery.swift:73` | A policy + C store | Recovery files | Candidate ordering/quarantine policy is portable; paths, rename and durability are not |
| `AIEditStore` | `Models/AIEdit.swift:42` | C | App Support files | Patch/alpha bytes live outside the project |
| `BackdropStore` | `Models/Backdrop.swift:7` | C | App Support files | `Adjustments.backgroundImage` stores only a file name |
| `UserPresetStore` | `Models/UserPreset.swift:7` | C | `presets.json` | Load/save with default Application Support path |
| `AppSettings`, `RecentStore` | `Models/AppSettings.swift:10`, `:161` | B/C | `UserDefaults` | Defaults and per-person state, not document truth |
| `FaceGeometry` | `Core/FaceAnalyzer.swift:12` | D | Not persisted | Vision output in normalized bottom-left coordinates; re-detected on every load |
| `LoadResult` | `Core/ImageProcessor.swift:104` | D | Not persisted | Pixels, masks, faces, color space, metadata |
| `ExportSource` | `Core/ExportService.swift:50` | D | Not persisted | `CIImage`, `MaskSet`, `FaceGeometry`, `CGColorSpace`, `[CFString: Any]` |
| `MaskShape`, `MaskSet`, `SpotHealing` | `Core/MaskBuilder.swift:7`, `ImageProcessor.swift` | D | Not persisted | Core Image masks |
| `AIQuickPreset` | `Models/QuickEdit.swift:9` | A/B mix | Preset name stored in `AIEdit.preset` | `engine`, `prompt`, `isFullFrame` are portable; `title`/`instruction` call `L10n` |
| `SmartAnalyzer.Report` | `Core/SmartAnalyzer.swift` | D | Not persisted | Measurements used to produce suggestions |

### 2.5 Dependency direction

```text
SwiftUI / AppKit views
        |
        v
EditorModel (B: 92 @Published, panels, timers, alerts)
   |            |                |
   |            |                +--> AppSettings / RecentStore (C, UserDefaults)
   |            |
   |            +--> ImageProcessor / Vision / AnalysisRenderer / AICompositor / AIWorker (D)
   |            +--> ExportService / BatchExportPolicy (C + A)
   |            +--> RecoveryStore / AIEditStore / BackdropStore / UserPresetStore (C)
   |
   +--> document values (A): Adjustments, HealSpot, Sticker, AIEdit,
        AnalysisSettings, DocumentOrientation, crop, selectedFace
             |
             +--> StudioCore pure values (A, Foundation only)

RetouchProject (A schema, C bookmark/UTType)
   |--> RecoverySnapshot --> RecoveryStore
   +--> ExportSnapshot --> ExportService / BatchExportPolicy
```

**VERIFIED.** There is no separate document object in this graph. The arrow from `EditorModel` to document values is the only place where document truth is held, and the arrow from `EditorModel` to every platform service is direct.

---

## 3. `EditorModel` breakdown

The file is one type with MARK-separated groups. The table below groups it by responsibility, not by line count. “Document?” means the group participates in what is saved, undone or recovered.

| # | Group | Lines | Class | Document? | Notes |
|---:|---|---|---|---|---|
| 1 | Preferences and export toggles mirrored from `AppSettings` | 12-74 | B/C | Export defaults yes, UI prefs no | `@Published` `didSet` writes `UserDefaults` |
| 2 | Batch sheet progress state | 75-85 | B | No | Presentation only |
| 3 | Pixel/face/document display state | 87-111 | B + D | No (pixels, faces); `selectedFaceIndex` yes | `NSImage`, `FaceGeometry`, `URL`, `UserPreset`, thumbnails |
| 4 | Crop and orientation state | 112-117, 201-217 | A/B | Yes | `appliedCrop`, `cropDraft`, `documentOrientation`, `sourcePixelSize` |
| 5 | Heal, stickers, AI edits | 118-136 | A/B | Yes | `didSet` schedules commit, dirty state, preview |
| 6 | Quick Edit and mask selection | 138-172 | B + D | Only the resulting `AIEdit` | Brush/box/refined mask is transient; `CGImage` |
| 7 | Analysis overlay settings and image | 173-186 | A/B + D | Settings yes; rendered overlay no | Overlay is drawn outside the photo pipeline |
| 8 | Smart analysis report and sheet toggles | 188-197 | B/D | No | Measurements are transient |
| 9 | Operation coordination | 231-311 | B | No | Tokens, exclusion, busy flags |
| 10 | Undo/redo/clean state and coalescing | 314-537 | A/B | Yes (as the snapshot unit) | 350 ms coalescing, 100-step cap, `cleanState` |
| 11 | Adjustment reset/preset helpers | 540-711 | B | Mutates document | `Adjustments` key-path helpers |
| 12 | View state | 718-731 | B | No | Zoom, pan, tool mode, makeup family |
| 13 | Engine handles, tasks, generations, recovery flags | 729-810 | C/D | No | `CIImage`, `Task`, `CGColorSpace`, metadata |
| 14 | Open/load/discard lifecycle | 836-1144 | B/C | Replaces document | `NSOpenPanel`, generation guard, failed-load preservation |
| 15 | Crop and orientation actions | 1146-1343 | A/B | Yes | Re-loads pixels; rewrites stored coordinates |
| 16 | Heal, art, analysis actions | 1345-2050 | A/B | Yes | Working-frame vs original-frame mapping |
| 17 | Lens and backdrop colors | 2037-2101 | B/C | Backdrop name yes | Copies a file into `BackdropStore` |
| 18 | Zoom/pan canvas | 2103-2194 | B | No | Presentation |
| 19 | Preview scheduler and person mask | 2195-2282 | D | No | `CIImage`, `Task`, Vision |
| 20 | Built-in and user presets | 2283-2429 | B/C | Applies values | User preset file store |
| 21 | Smart analyze and apply | 2430-2567 | D/B | Applies values | Adds heal spots |
| 22 | Preference refresh/reset | 2568-2596 | B/C | No | `AppSettings` |
| 23 | Autosave and recovery lifecycle | 2597-2908 | A/B/C | Yes | Debounce, epoch, candidate prompts, restore ordering |
| 24 | Status and readouts | 2909-2987 | B | No | Localized strings and digits |
| 25 | Export planning and execution | 2988-3119 | A/B/C/D | Reads document | Snapshot, naming, source protection, detached render |
| 26 | Project save/open/relink | 3120-3277 | A/B/C | Yes | `makeProject`, JSON encoder, panels, bookmark, relink rewrite |
| 27 | Batch planning and execution | 3279-3501 | A/B/D | Reads document | Per-file policy, detached tasks, cancellation |

### 3.1 The document-truth subset

**VERIFIED.** If “document” means the state that undo, dirty-state, autosave and project save agree on, it is exactly `EditState` plus export/auto settings:

```text
adjustments            (StudioCore)
healSpots              [HealSpot]
stickers               [Sticker]
aiEdits                [AIEdit]
analysis               AnalysisSettings
crop                   CGRect?            // appliedCrop
orientation            DocumentOrientation
selectedFaceIndex      Int?

exportFormat, exportQuality, exportLongEdge,
autoRetouchStrength, autoColorStrength     // written by makeProject, outside EditState
```

**VERIFIED.** `hasUnsavedChanges` compares `currentState` against `cleanState`, where `currentState` is built from the eight `EditState` fields only (`Sources/RetouchStudio/Models/EditorModel.swift:334-339`, `:521-524`). Export choices and auto strengths are therefore **not** part of the dirty comparison, even though `makeProject()` writes them (`:3145-3162`). This is existing behavior, not a bug claimed here; any `DocumentState` extraction must either preserve it exactly or make an explicit, approved change.

**VERIFIED.** `EditState` is not encoded anywhere. It is a private in-memory value. This is why it is the safest first extraction: it cannot alter v3 bytes.

### 3.2 What is coordination, not document

`zoom`, `panOffset`, `toolMode`, `cropDraft`, `compareEnabled`, `comparePosition`, `isPeekingOriginal`, all sheet booleans, `statusToken`, `isBusy`, `isExporting`, `batch*` progress, `smartReport`, `quickEdit*`, `aiMask*`, `subjectState`, `hasBodyPose`, `faces`, `masksPreview`, `sourceFull`, `sourcePreview`, `originalImage`, `previewImage`, operation tokens, tasks and generations are **not** document truth. They must stay in the macOS shell or in an engine adapter. Moving them into a portable core would move AppKit, Core Image and workflow policy into the wrong layer.

---

## 4. Document Model dependency inventory

### 4.1 `RetouchProject` stored fields

**VERIFIED.** Fields and lines from `Sources/RetouchStudio/Models/Project.swift`:

| v3 key | Type (line) | Wire shape | Required? | Portable? | Blocker |
|---|---|---|---|---|---|
| `version` | `Int` (21) | number | No; missing → 3 | Yes | Version policy must remain |
| `imagePath` | `String` (22) | string | **Yes** | Value yes, meaning no | Absolute OS path; not portable across OS/sandbox |
| `imageBookmark` | `Data?` (25) | base64 string | No | No | macOS security-scoped bookmark |
| `adjustments` | `Adjustments` (26) | keyed object | **Yes** | Yes | None (already StudioCore) |
| `exportFormat` | `String` (27) | string | **Yes** | Yes | Enum raw value in app code |
| `exportQuality` | `Double` (28) | number | **Yes** | Yes | None |
| `exportLongEdge` | `Int?` (31) | number | No | Yes | `0` normalized to `nil` by `makeProject` |
| `autoRetouchStrength` | `Double` (32) | number | **Yes** | Yes | None |
| `autoColorStrength` | `Double?` (36) | number | No | Yes | Missing → editor uses 100 (`EditorModel.swift:1075`) |
| `crop` | `CGRect?` (39) | `[[x,y],[w,h]]` | No | Value shape no | Apple unkeyed geometry |
| `orientation` | `DocumentOrientation?` (42) | keyed object | No | Numbers yes; type no | Type embeds Core Image transforms |
| `healSpots` | `[HealSpot]?` (46) | array of keyed objects with `[x,y]` center | No | No | `CGPoint` wire shape |
| `stickers` | `[Sticker]?` (49) | array of keyed objects with `[x,y]` center | No | No | `CGPoint` wire shape |
| `aiEdits` | `[AIEdit]?` (52) | array with `[[x,y],[w,h]]` box and `[w,h]` size | No | No | `CGRect`/`CGSize` wire shape plus external assets |
| `analysis` | `AnalysisSettings?` (56) | keyed object; endpoint/anchor values are `[x,y]` | No | No | `CGPoint` wire shape |
| `selectedFace` | `Int?` (59) | number | No | Yes | Index into current detection order |

**VERIFIED.** `RetouchProject` has a manual `init(from:)` (`Project.swift:96`) but no manual `encode(to:)`. Encoding is synthesized and keyed. The manual decoder gives missing `version` the value `currentVersion` (3), requires the five fields above, and reads every newer field with `decodeIfPresent`. Unknown keys are not preserved.

**VERIFIED.** `openProject(at:)` rejects `project.version > currentVersion` with `.projectTooNew` (`EditorModel.swift:3202-3206`). Older projects, including version-less projects, open.

### 4.2 External state the document depends on

| Dependency | Location | What the project stores | What lives outside | Consequence for portability |
|---|---|---|---|---|
| AI patch and alpha | `AIEditStore` (`AIEdit.swift:42-52`) | `id`, `patchFile`, `alphaFile`, `box`, `imagePixels`, orientation | PNG bytes under `Application Support/RetouchStudio/AI/edits/<uuid>/` | A project is not self-contained; a missing asset is detected by `AICompositor.missing` but the document has no content hash |
| Backdrop image | `BackdropStore` (`Backdrop.swift:7-17`) | `Adjustments.backgroundImage` (stored name) and `backgroundImageName` (display name) | Image bytes under `Application Support/RetouchStudio/backdrops/` | Same non-self-contained problem; no hash/identity |
| Recovery copies | `RecoveryStore` (`Recovery.swift:73`) | A `RecoverySnapshot` wraps a full v3 project | `working.retouch`, immutable `candidates/*.retouch`, `quarantine/` | Snapshot payload migrates with the project codec; directory layout and durability are platform |
| User presets | `UserPresetStore` (`UserPreset.swift:7-30`) | Not in the project | `Application Support/Retouch Studio/presets.json` | Per-person data; file I/O is a port |
| Settings and recents | `AppSettings`, `RecentStore` | Not in the project | `UserDefaults` | Defaults and shell preferences |

**VERIFIED.** `RecoverySnapshot` version 1 stores `{version, savedAt, project, source?}` where `source` is `{bytes, modified}` (`Recovery.swift:31-50`). A legacy bare project decodes as version 0 with no identity (`Recovery.swift:378-389`; `readLoose`). Recovery ordering, quarantine and source comparison are policy; the writes, renames and directory layout are platform.

### 4.3 Dependency cycles and boundaries

**VERIFIED.** `Models` and `Core` depend on each other. A portable document module cannot be produced by moving files; it needs an explicit interface. The minimum cycle-breaking seam is:

```text
DocumentSession / DocumentCodec  (A)
        ^                   |
        |                   v
   value records      ports: SourceAccess, FileStore, RecoveryStore,
   (A, Foundation)           PresetStore, SettingsStore, Dialogs
                               |
                               v
                     macOS adapters (C) -> engines (D)
```

---

## 5. v3 serialization compatibility findings

### 5.1 Verified wire facts

**VERIFIED.** Apple’s synthesized `Codable` for `CGRect`, `CGPoint` and `CGSize` uses unkeyed arrays. The R3 probe recorded:

```text
CGRect  -> [[0.1,0.2],[0.3,0.4]]
CGPoint -> [0.1,0.2]
CGSize  -> [0.3,0.4]
```

(`Docs/STUDIOCORE_R3_GEOMETRY.md:88-110`). Corresponding v3 locations: `crop`, `healSpots[].center`, `stickers[].center`, `aiEdits[].box`, `aiEdits[].imagePixels`, `analysis.endpoints`, `analysis.anchors`.

**VERIFIED.** `StudioPoint`/`StudioSize`/`StudioRect` encode as keyed objects (`{x,y}`, `{width,height}`, `{x,y,width,height}`) and their synthesized decoder rejects the legacy unkeyed arrays (`Tests/StudioCoreTests.swift`; `Docs/STUDIOCORE_R3_GEOMETRY.md:112-121`). The two shapes are not interchangeable.

**VERIFIED.** `Adjustments` has custom keyed encoding and decoding; missing fields decode to current defaults, and legacy makeup shade identifiers are migrated on decode (`Sources/StudioCore/Adjustments.swift:780-958`). Its v3 wire shape is stable and already portable.

**VERIFIED.** `DocumentOrientation` has a custom decoder that treats every key as optional and normalizes `quarterTurns` into `0...3` (`Models/Orientation.swift:207-216`). It is encoded by synthesis as a keyed object.

**VERIFIED.** `AnalysisSettings` has a synthesized keyed codec; its `endpoints`/`anchors` are dictionaries whose values are `CGPoint` and therefore unkeyed pairs; `regions` is a `Set<AnalysisRegion>` encoded as an array of raw strings (`Models/Analysis.swift:68-118`).

**VERIFIED.** `Sticker` and `HealSpot` have synthesized keyed codecs with `CGPoint`/`CGFloat` fields. `AIEdit` has a synthesized keyed codec with `CGRect`, `CGSize`, `UUID`, `Date`, and an optional `DocumentOrientation`.

### 5.2 Decoder and projection behavior that must not change

| Behavior | Evidence | Why it matters |
|---|---|---|
| Missing `version` reads as current (3) | `Project.swift:98` | Version-less projects must keep opening |
| Required fields stay required | `Project.swift:99-105` | A malformed project must still fail, not silently default |
| Newer fields use `decodeIfPresent` | `Project.swift:106-114` | Older projects open with “off” semantics |
| Unknown keys are ignored | no unknown-key container | Adding preservation would be a behavior change, not a pure refactor |
| `exportLongEdge == 0` is written as `nil` | `EditorModel.swift:3152` | Changes the on-disk shape for “full size” |
| Empty `healSpots`/`stickers`/`aiEdits` are written as `nil` | `:3156-3158` | Same |
| Default `AnalysisSettings()` is written as `nil` | `:3159` | Equality, not merely `isEnabled`, decides |
| Identity orientation is written as `nil` | `:3161` | Old readers see “upright” |
| `selectedFace` is always written as `Int?` | `:3160` | `nil` means automatic |
| Save uses pretty-printed, sorted-key JSON, atomic write | `EditorModel.swift:3164-3169`; `:3271-3273` | Byte-level diffs and review tools depend on it |
| Recovery snapshot version is 1; legacy bare project is version 0 | `Recovery.swift:31-50`, `:378-389` | Candidate interpretation must stay |

**VERIFIED.** A project write is an ordinary single-file JSON write; a recovery autosave is a different path that goes through `RecoveryStore.writeWorking` and `RecoverySnapshot.capture`. A refactor that unifies them must preserve both call sites’ timing and source-identity capture.

### 5.3 Transition options for geometry

| Option | What changes | Compatibility | Recommendation |
|---|---|---|---|
| **A. Leave stored types alone; add portable projections** | Keep `CGPoint`/`CGRect`/`CGSize` in v3 models; add `StudioPoint(healSpot.center)` adapters at the boundary | Byte-identical v3; zero migration | **Recommended for the next steps.** It unblocks policy extraction without touching bytes. |
| **B. Replace stored types + custom `Codable` that reads and writes the legacy shape** | Stored type becomes `StudioPoint`; encoder writes `[x,y]` | Byte-identical if implemented exactly; decoder still accepts old files | Viable, but the custom codec is a compatibility risk and must be proven byte-for-byte against fixtures. |
| **C. Introduce v4 and migrate** | New package format and writer | v3 must remain readable; dual read and explicit upgrade | **Not now.** Requires owner approval, migration fixtures and a compatibility bridge. |

**RECOMMENDATION.** Use option A for all extraction steps that are not explicitly a format milestone. Any use of option B must ship with a byte-for-byte v3 round-trip test over every field, and must not change `RetouchProject.version` or the decoder’s required-field behavior. Option C belongs to a separate, approved project-format milestone.

---

## 6. Portable vs platform-specific boundaries

### 6.1 Classification

| Concern | Portable document domain (A) | Platform service (C) | Engine (D) |
|---|---|---|---|
| Retouch parameters | `Adjustments`, `MakeupColor`, presets | — | Pipeline reads them |
| Geometry values | Normalized coordinates, spaces, rect math | Pixel decoding, display transforms | Mask rasterization, Core Image transforms |
| Edit records | Heal, sticker, AI patch metadata, analysis settings, crop, orientation numbers | Asset file lookup, bookmark resolution | Patch compositing, callout rendering |
| Operation order | The fixed 17-stage contract | — | Implementation of each stage |
| History | Snapshot state, transition rules, dirty comparison | Timer/debounce, UI undo enablement | — |
| Project schema | Field names, defaults, nil projection, version rules | Atomic write, path, bookmark, UTType | — |
| Source identity | Byte size + modification time comparison | `URLResourceValues`, bookmark, file existence | — |
| Export intent | Format, quality, long edge, naming, privacy policy, source protection | Save panel, destination resolution, file write | Render, color space, metadata embedding |
| Batch policy | Per-file snapshot policy, unique naming policy | Folder panel, per-file load | Per-file render |
| Recovery policy | Candidate ordering, quarantine decision, source-state classification | Directory layout, atomic rename, durability | — |
| Presets | `UserPreset` value | JSON file store | — |
| Localization | Message keys/parameters | — | — |
| UI | — | AppKit/SwiftUI | — |

### 6.2 Four coupling clusters

1. **Cocoa UI** — `NSOpenPanel`, `NSSavePanel`, `NSAlert`, `NSApplication.ModalResponse`, `NSImage`, `NSEvent` (`EditorModel.swift:836`, `:873`, `:3018`, `:2850-2901`).
2. **Apple imaging** — `CIImage`, `CGImage`, `CGColorSpace`, `CGContext`, ImageIO metadata, Vision (`ImageProcessor`, `MaskBuilder`, `AICompositor`, `AnalysisRenderer`, `FaceAnalyzer`, `Watermark.swift`).
3. **File system and user state** — Application Support paths, bookmarks, `UserDefaults`, `FileManager` (`RecoveryStore`, `AIEditStore`, `BackdropStore`, `UserPresetStore`, `AppSettings`).
4. **Process and model runtime** — helper process launch, sockets/stdio, model files, Python worker (`AIWorker`, `WorkerClient`, `AIRuntime*`, `ChildProcess`).

**RECOMMENDATION.** The portable core must see none of these. It sees values, stable enum raw strings, message keys, and ports. Every cluster stays behind an adapter owned by the macOS shell.

---

## 7. Proposed target architecture

**RECOMMENDATION.** A Swift-first target, because the roadmap’s own principle is “behavior first, language second” (`Docs/STUDIOCORE_EXTRACTION_ROADMAP.md:14`). No Rust, no Qt, no new UI, and no build-system change is proposed in this milestone.

```text
+---------------------------------------------------------------+
| macOS shell: SwiftUI views + AppKit panels + menu commands    |
+-----------------------------+---------------------------------+
                              |
                    EditorModel (shell adapter)
                    - published mirrors for views
                    - operation tokens, timers, dialogs
                    - calls session; owns no document truth
                              |
                              v
+---------------------------------------------------------------+
| DocumentSession (portable in Swift, Foundation only)          |
|   - DocumentState (the eight EditState fields)                |
|   - undo/redo stacks, coalescing boundaries                   |
|   - clean state / dirty comparison                            |
|   - project encode/decode (v3 now, v4 later)                  |
|   - export plan and batch plan                                |
|   - recovery candidate policy                                 |
+-----------------------------+---------------------------------+
                              |
          +-------------------+-------------------+
          |                                       |
          v                                       v
  StudioCore pure values                 Ports (protocols)
  Adjustments, MakeupColor,              SourceAccess, FileStore,
  UserPreset, geometry,                  RecoveryFileStore, PresetStore,
  DocumentState, policies                SettingsStore, DialogPort
                                                  |
                                                  v
                                       macOS adapters (C)
                                                  |
                                                  v
                                       Engines (D): Core Image,
                                       Vision, AI worker
```

### 7.1 Component responsibilities

| Component | Owns | Must not own |
|---|---|---|
| `DocumentState` | The eight document fields, equality, construction from/into app values | Pixels, URLs, panels, export defaults |
| `DocumentSession` | Document state, history, clean baseline, project value construction, load/open orchestration | Published UI mirrors, AppKit, Core Image |
| `DocumentCodec` | v3 field mapping, defaults, version guard, future v4 | Bookmarks, file access, atomic writes |
| `ExportPlanner` | Export snapshot, naming, privacy policy, source-protection policy, analysis-mode format rule | Save panel, rendering, metadata embedding |
| `BatchPlanner` | Per-file snapshot policy, unique names, include flags | Folder panel, per-file load/render, cancellation plumbing |
| `RecoveryPolicy` | Candidate ordering, quarantine classification, source-state comparison, epoch invalidation | Directory layout, rename, durability |
| `EditorModel` | Published mirrors, sheets, alerts, timers, task lifecycle, engine invocation | Document truth |

### 7.2 Dependency rules

**RECOMMENDATION.**

1. `StudioCore` imports only `Foundation` (already enforced by `Tests/run-studiocore.sh`).
2. `DocumentSession` may live in `StudioCore` only if it imports no AppKit/CoreImage/ImageIO/Vision and no app-only type. Until the six geometry-bearing record types are portable, the session lives in an app-layer file with the same dependency rules.
3. Adapters may import app types; portable code may not import adapters.
4. The shell may read published mirrors but must mutate document state only through the session.
5. No new operation graph: the 17-stage order is a quality invariant (`Docs/STUDIOCORE_ARCHITECTURE.md:221-233`).
6. v3 remains readable for the entire transition. No writer deletes the v3 reader.

### 7.3 What deliberately stays out

- No Rust core in this milestone.
- No Qt/Windows/Linux shell.
- No v4 package, migration or compat projection.
- No engine rewrite or 17-stage reordering.
- No AI runtime or contract change.
- No new module/build target until an approved implementation step requires it.

---

## 8. Incremental migration sequence

The sequence below is dependency-aware and intentionally smaller than the roadmap’s R4a–R4d. Each step is independently revertible. “Serialization” states whether v3 bytes can change.

### Step R4.0 — Characterization and freeze (no product code)

- **Scope:** capture v3 JSON for a project containing every field, including empty-collection and identity cases; record undo/coalescing/dirty traces; record export and batch outcomes.
- **Adapters:** none.
- **Depends on:** current baseline.
- **Serialization:** read-only.
- **Tests:** fixture round-trip, byte snapshot, scripted model interactions.
- **Risk:** low; only test/fixture work, which this review does not perform.
- **Rollback:** delete the added characterization artifacts (later milestone only).
- **DoD:** the fixture is stable across two runs and covers all 16 fields.

### Step R4.1 — Extract `DocumentState` (first real candidate)

- **Scope:** move the eight-field `EditState` out of `EditorModel` into a named value type; keep `Adjustments`, `HealSpot`, `Sticker`, `AIEdit`, `AnalysisSettings`, `CGRect`, `DocumentOrientation` as-is. Add construction from the editor’s current published values and equality based on the same fields.
- **Adapters:** none; the fields keep their current types.
- **Depends on:** R4.0.
- **Serialization:** none. `DocumentState` is never encoded.
- **Tests:** state equality, undo coalescing, dirty comparison, export-settings exclusion.
- **Risk:** low. A subtle equality mismatch would change undo granularity.
- **Rollback:** restore the private struct; no persistent data exists.
- **DoD:** identical undo counts, identical dirty transitions, no changed project bytes.

### Step R4.2 — Extract history into `DocumentSession` (state only)

- **Scope:** move `undoStack`, `redoStack`, `lastCommitted`, `cleanState`, `currentState`, `commitAdjustments`, `undo`, `redo` and `restore` behaviour into a session object. Keep the 350 ms timer in the shell, passing explicit transaction boundaries.
- **Adapters:** shell forwards user gestures; published `canUndo`/`canRedo` mirror the session.
- **Depends on:** R4.1.
- **Serialization:** none.
- **Tests:** undo/redo sequences, 100-step cap, redo clearing, crop/orientation restore path, reload-on-restore behaviour.
- **Risk:** medium. Async timer and observer ordering can change.
- **Rollback:** session can call back into the old methods during transition.
- **DoD:** scripted editing session produces the same undo steps and pixel state.

### Step R4.3 — Project codec and source-resolution port

- **Scope:** extract `makeProject`, v3 encode/decode and version guard into a codec with injected `SourceAccess`/`BookmarkStore` ports. Keep `NSOpenPanel`/`NSSavePanel`, alerts and `UserDefaults` in the shell.
- **Adapters:** macOS bookmark/path resolution; `.retouch` UTType stays in the shell.
- **Depends on:** R4.2.
- **Serialization:** **v3 bytes must not change.** Codec tests compare against the R4.0 fixtures.
- **Tests:** all fields, missing/unknown keys, version guard, nil normalizations, relink rewrite, bookmark-first resolution, sibling fallback.
- **Risk:** high. A single changed default or key changes compatibility.
- **Rollback:** revert to `EditorModel` methods; the file format is untouched.
- **DoD:** byte-identical JSON for the characterization fixture on arm64 and Rosetta.

### Step R4.4 — Load/open lifecycle and recovery handoff

- **Scope:** move document installation/restoration into the session; keep failed-load preservation, generation guards, recovery-readiness barrier and prompt flow in the shell/session boundary.
- **Adapters:** `ImageProcessor.load`, dialogs, recovery file store.
- **Depends on:** R4.3.
- **Serialization:** recovery snapshot payload unchanged.
- **Tests:** open project, open image, relink, missing source, recovery restore/cancel/discard, failed load preserves previous document.
- **Risk:** high; timing-sensitive.
- **Rollback:** each sub-step independently; forwarding shim.
- **DoD:** all recovery and load regressions identical.

### Step R4.5 — Export planner

- **Scope:** move `makeExportSnapshot`, naming, effective format, privacy policy, source-protection policy and source construction (except pixels) into a planner. Keep the save panel and detached render in the shell.
- **Adapters:** `ExportService` remains the engine-facing adapter.
- **Depends on:** R4.3.
- **Serialization:** none (export is not persisted).
- **Tests:** naming table, analysis-mode format, long-edge/upscale decisions, destination-equals-source refusal, metadata policy, cancellation.
- **Risk:** medium.
- **Rollback:** planner can wrap the old methods.
- **DoD:** same output bytes, metadata and error status for every export case.

### Step R4.6 — Batch planner

- **Scope:** move per-file snapshot policy and unique naming into the planner; keep folder panel, task lifecycle and cancellation in the shell.
- **Adapters:** per-file `ImageProcessor.load` and `ExportService.write`.
- **Depends on:** R4.5.
- **Serialization:** none.
- **Tests:** own file keeps crop; other file drops crop when orientation/aspect differ; AI edits cleared; selected face and analysis pins cleared; unique names; cancellation before load, before write, after write.
- **Risk:** medium.
- **Rollback:** planner call can be removed; old batch code remains.
- **DoD:** batch regression suite identical.

### Step R4.7 — Recovery policy extraction

- **Scope:** move candidate ordering, quarantine classification, source-state comparison and epoch policy into a pure policy; keep directory layout, rename and durability in a store adapter.
- **Adapters:** `RecoveryFileStore`.
- **Depends on:** R4.4.
- **Serialization:** `RecoverySnapshot` version 1 unchanged; legacy version 0 interpretation unchanged.
- **Tests:** A–G recovery scenarios, concurrent independence, cancellation, working-slot lock, source moved vs changed, quarantine failure.
- **Risk:** high; data-preservation path.
- **Rollback:** keep the current store as the only implementation until the policy is proven.
- **DoD:** every preservation scenario passes on arm64 and Rosetta; no candidate is deleted.

### Step R4.8 — Portable geometry records and v4 (separate approval)

- **Scope:** optionally convert stored records to `StudioPoint`/`StudioRect` with legacy-compatible codecs, or introduce v4.
- **Serialization:** byte-sensitive; requires the full v3 fixture suite and a dual-read plan.
- **Risk:** high.
- **DoD:** not defined by this review; requires its own design and approval.

**Dependency order:** R4.0 → R4.1 → R4.2 → R4.3 → {R4.4 → R4.7, R4.5 → R4.6} → R4.8. R4.8 never runs in parallel with a format change.

---

## 9. First recommended extraction candidate

### 9.1 Recommendation

**RECOMMENDATION.** Extract **`EditorModel.EditState`** into a named **`DocumentState`** value as the first step. Do **not** move it into `StudioCore` yet, and do not change its field types.

Why this is the lowest-risk document-model extraction:

1. **No serialization surface.** It is private and in-memory only (`EditorModel.swift:314-323`). It cannot alter a project byte or a recovery file.
2. **It is already the document unit.** Undo, redo, the clean baseline and `hasUnsavedChanges` already compare exactly these eight fields (`:325-339`, `:521-524`).
3. **It is small and bounded.** Eight fields, `Equatable`, no methods, no platform services.
4. **It creates the right seam.** A `DocumentSession` cannot be extracted before a named document snapshot exists; `EditState` is that snapshot in disguise.
5. **It is already covered indirectly.** Undo/coalescing, crop/orientation restore, recovery and save tests exercise it; the first move can be proven by those tests plus equality tests.
6. **It has an obvious rollback.** If behavior diverges, restore the private struct; there is no persistent data to migrate.

### 9.2 Scope of the first step

In scope:

- Move the struct to a new app-layer file with the same eight fields and `Equatable`.
- Add explicit construction from the editor’s published values and an explicit list of fields.
- Keep `Adjustments` and all geometry-bearing record types unchanged.
- Keep the 350 ms coalescing timer, the undo stacks and all UI callbacks in `EditorModel` for this step.

Out of scope:

- Moving `HealSpot`, `Sticker`, `AIEdit`, `AnalysisSettings`, `DocumentOrientation` or `CGRect`.
- Encoding `DocumentState`.
- Changing dirty-state semantics for export settings.
- Moving the timer, the UI, or any engine call.
- Creating a new build target.

### 9.3 Why not the alternatives first

| Alternative | Why not first |
|---|---|
| `RetouchProject` | Its decoder, bookmark, UTType and v3 bytes are the compatibility contract; highest risk. |
| `EditorModel` | Mixes 92 published properties, panels, timers and engines; explicitly rejected by the roadmap as a wholesale move. |
| `HealSpot` / `Sticker` / `AIEdit` / `AnalysisSettings` | Each has an Apple unkeyed wire shape; moving them changes bytes or requires a delicate custom codec. |
| `ExportSnapshot` + `BatchExportPolicy` | Good second candidate, but their fields are the same geometry-bearing records; they become cleaner after R4.1 and R4.5. |
| `RecoverySourceIdentity` | Already portable, but it is auxiliary source metadata, not document truth; moving it first creates little architectural value. |
| `UserPreset` | Already in `StudioCore`; file store remains platform. |

### 9.4 Expected benefit and boundary

After R4.1, `EditorModel` still owns the published mirrors and the undo stacks, but the definition of “the document” has a single named home. R4.2 can then move the stacks and transitions without touching bytes. The first step deliberately does **not** claim portability; it claims **separation**, which is the prerequisite for portability.

---

## 10. Testing and regression strategy

### 10.1 Existing gates that must stay green

| Gate | Command | What it proves |
|---|---|---|
| StudioCore boundary and types | `Tests/run-studiocore.sh` | Foundation-only imports, no platform tokens, R2/R3 types |
| Four model/engine/runtime suites | `Tests/run.sh` | 852 checks per architecture at the R3 baseline (arm64 and x86_64 under Rosetta) |
| Conformance fixtures | `Tests/Conformance/run-conformance.sh` | 28 canonical/ABI fixture files, schema and canonical JSON |
| Golden corpus | `Tests/run-corpus.sh` | 46 tracked corpus files, 376 checks, exact same-host digests |
| App build and self-test | `./build.sh` / self-test gate | Universal/per-arch build, runtime self-check |
| Diff hygiene | `git diff --check` | No whitespace damage |

**VERIFIED.** The corpus harness can rewrite tracked export files (`Tests/Corpus/Exports/*`). Any run must restore exactly the rewritten tracked files from Git and re-verify all 46 hashes; it must never regenerate baselines.

### 10.2 Tests to add when a step is approved

| Step | New evidence |
|---|---|
| R4.0 | A complete v3 fixture with all 16 fields, plus a scripted undo/dirty trace |
| R4.1 | `DocumentState` equality; export-only change does not mark dirty; every document field does |
| R4.2 | Undo/redo/coalesce/cap; redo invalidation; crop/orientation restore; failed-load preservation |
| R4.3 | Byte-for-byte v3 JSON; missing/unknown keys; version guard; bookmark/path/sibling resolution |
| R4.4 | Recovery A–G; cancel keeps candidates; failed promotion locks working slot; epoch invalidation |
| R4.5 | Naming/format/metadata/source-protection/cancellation matrix |
| R4.6 | Per-file crop policy; unique names; cancellation before load/write |
| R4.7 | Candidate ordering, quarantine, source moved vs changed, independence of copies |

**RECOMMENDATION.** For a behavior-preserving step, compare before/after *observable* outputs: v3 JSON bytes, export pixels and metadata, recovery file set, and undo counts. Do not accept “it looks right” as evidence for any serialization or pixel path.

### 10.3 What is not covered

**VERIFIED.** The corpus excludes Vision detection, AI output, RAW/HEIC and UI behavior (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md:265`, cited in the roadmap). A document-model refactor does not need new pixel coverage, but it must not hide a pixel regression behind that gap.

---

## 11. Risks and unresolved questions

| # | Risk | Severity | Mitigation | Evidence needed |
|---:|---|---|---|---|
| 1 | A geometry type swap silently changes v3 bytes | High | Keep stored types; use option A; byte-diff fixtures | JSON byte comparison |
| 2 | Decoder defaults drift (required vs optional) | High | Freeze the R4.0 fixtures and test every field | Fixture suite |
| 3 | Undo granularity changes when history moves | Medium | Keep timer in shell; explicit transaction boundaries; scripted traces | Interaction trace |
| 4 | Dirty-state semantics accidentally include export settings | Medium | Test “export-only change is not dirty” explicitly | Model test |
| 5 | Recovery ordering/epoch regresses | High | Independently revertible steps; preserve current barrier | Recovery A–G |
| 6 | Async generation/token ordering changes | Medium | State-machine test before moving load/export | Scripted flow |
| 7 | AI/backdrop assets remain outside the document | Medium | Document the non-self-contained state; future content hashes | Asset inventory |
| 8 | Localization leaks into portable types | Low | Keep `L10n` in shell extensions; core returns keys | Import check |
| 9 | `CGRect`/`CGPoint` unkeyed Codable differs across toolchains | Low but byte-critical | Pin the fixture; test on both architectures | Cross-arch fixture |
| 10 | File system durability is not `fsync`-backed | Medium | Do not claim crash safety; document the gap | Durability audit |
| 11 | Flat module hides dependency violations | Medium | Add structural checks before new targets | Build/test scripts |
| 12 | Windows path/bookmark semantics differ | High (future) | Keep source access behind a port; no absolute paths in shared JSON (future v4) | Windows prototype |

### Open questions

1. **Export settings and dirty state.** Should changing only export quality mark the document dirty? Current behavior says no (`EditState` excludes them). This review preserves current behavior; a change needs explicit approval.
2. **Source identity strength.** Recovery uses bytes + modification date, not a content hash (`Recovery.swift:16-27`). A future document format may need a hash; that is a format decision, not a refactor.
3. **AI asset identity.** `AIEdit` stores file names but no hash. A missing file is detected; a replaced file is not. Should a portable document store a hash? **HYPOTHESIS — NOT VERIFIED** that this is required; it would change the project schema.
4. **Backdrop identity.** Same as AI assets: the name is stored, the bytes are not identified.
5. **Stored detector output.** The interface design proposes an optional `AnalysisSnapshot`; no such type exists in code. Do not treat it as current behavior.
6. **v3 → v4 timing.** Depends on owner approval and on the engine portability track; not part of R4.

---

## 12. Explicitly not-yet work

This review does **not** authorize or perform:

- any change to `Sources/RetouchStudio`, `Sources/StudioCore`, tests, fixtures, corpus, baselines or build scripts;
- refactoring `EditorModel` or moving any model type;
- changing project serialization, defaults, version, decoder, encoder, `makeProject` or recovery snapshots;
- changing image processing, the 17-stage pipeline, masks, color management or export behavior;
- changing AI worker behavior, runtime, assets or models;
- changing autosave or recovery behavior;
- introducing a v4 format, migration writer or compatibility projection;
- introducing Rust, Qt, a new UI or a new build target;
- adding runtime dependencies;
- staging, committing, pushing or opening a pull request;
- implementing the first extraction candidate described in §9.

Any implementation requires a separate, explicit approval for exactly one step, with that step’s scope, tests and rollback.

---

## Appendix A — Verified source index

| Subject | Location |
|---|---|
| App is a flat module | `build.sh:58-68`; `Tests/run.sh:35` |
| StudioCore module boundary | `Tests/build-studiocore.sh`; `Tests/run-studiocore.sh` |
| `RetouchProject` fields | `Sources/RetouchStudio/Models/Project.swift:21-59` |
| `RetouchProject` manual decoder | `Sources/RetouchStudio/Models/Project.swift:96-115` |
| `EditState` and history | `Sources/RetouchStudio/Models/EditorModel.swift:314-537` |
| Dirty state | `Sources/RetouchStudio/Models/EditorModel.swift:521-524` |
| Autosave and recovery | `Sources/RetouchStudio/Models/EditorModel.swift:2597-2908` |
| Export planning | `Sources/RetouchStudio/Models/EditorModel.swift:2988-3119` |
| Project save/open | `Sources/RetouchStudio/Models/EditorModel.swift:3120-3277` |
| Batch | `Sources/RetouchStudio/Models/EditorModel.swift:3279-3501` |
| `makeProject` normalizations | `Sources/RetouchStudio/Models/EditorModel.swift:3145-3162` |
| Export snapshot type | `Sources/RetouchStudio/Core/ExportService.swift:11` |
| Export source type | `Sources/RetouchStudio/Core/ExportService.swift:50` |
| Batch policy | `Sources/RetouchStudio/Core/BatchExportPolicy.swift:11` |
| Pipeline entry | `Sources/RetouchStudio/Core/ImageProcessor.swift:151` |
| `LoadResult` | `Sources/RetouchStudio/Core/ImageProcessor.swift:104` |
| `ExportFormat` | `Sources/RetouchStudio/Core/ImageProcessor.swift:9` |
| `FaceGeometry` | `Sources/RetouchStudio/Core/FaceAnalyzer.swift:12` |
| `MaskShape` / `MaskBuilder` | `Sources/RetouchStudio/Core/MaskBuilder.swift:7`, `:39` |
| AI compositor | `Sources/RetouchStudio/Core/AICompositor.swift:24` |
| Heal record and geometry | `Sources/RetouchStudio/Models/Heal.swift:10`, `:15` |
| Sticker record and geometry | `Sources/RetouchStudio/Models/Sticker.swift:20`, `:33` |
| AI edit record and store | `Sources/RetouchStudio/Models/AIEdit.swift:11`, `:42` |
| Analysis settings | `Sources/RetouchStudio/Models/Analysis.swift:68` |
| Orientation record and transforms | `Sources/RetouchStudio/Models/Orientation.swift:13` |
| Crop geometry | `Sources/RetouchStudio/Models/Crop.swift:31` |
| Recovery snapshot and store | `Sources/RetouchStudio/Models/Recovery.swift:31`, `:73` |
| Backdrop store | `Sources/RetouchStudio/Models/Backdrop.swift:7` |
| Preset store | `Sources/RetouchStudio/Models/UserPreset.swift:7` |
| Settings and recents | `Sources/RetouchStudio/Models/AppSettings.swift:10`, `:161` |
| Portable values | `Sources/StudioCore/Adjustments.swift`, `Makeup.swift`, `MakeupColor.swift`, `StudioGeometry.swift`, `UserPreset.swift` |
| v3 unkeyed geometry evidence | `Docs/STUDIOCORE_R3_GEOMETRY.md:88-121` |
| Proposed v4 contract (not current) | `Docs/STUDIOCORE_INTERFACE_DESIGN.md:146-480`, `:528-846` |
| Proposed boundary (not current) | `Docs/STUDIOCORE_ARCHITECTURE.md:154-263` |
| Proposed sequence (not current) | `Docs/STUDIOCORE_EXTRACTION_ROADMAP.md:243-295` |

## Appendix B — Milestone naming note

**VERIFIED.** The local commits use:

- R2 — pure value types in `StudioCore` (commit `deaaf37`).
- R3 — portable geometry primitives and Core Graphics adapters (commit `f6456b7`).

The design roadmap uses a different sequence: R2 = Swift pure types, R3 = ports and pure policy, R4 = `DocumentSession` extraction (`Docs/STUDIOCORE_EXTRACTION_ROADMAP.md:151-295`). This document is the **review** that precedes the roadmap’s R4 implementation; it does not claim that the roadmap’s R3 (ports/policy) has been executed. The only implementation milestone completed so far is geometry values plus adapters.
