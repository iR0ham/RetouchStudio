# StudioCore R4.0 — Document State Characterization

Status: complete; behavior frozen before extraction.

Baseline commit: `f6456b7b69473b65f5ce7318433bc8d0f0e511bf` (branch `main`).

Line references below are to that frozen baseline. R4.1 removed the inline
declaration at `EditorModel.swift:314-323`, so line numbers in that file after
the removed block are 10 lower in the extracted working tree; the behavior and
all cited declarations are unchanged.

Scope: this document records what the current macOS editor actually does with
its private `EditState`, with source evidence and tests that pin it. R4.0 changes
no application code. R4.1 is the extraction described in
`Docs/STUDIOCORE_R4_1_DOCUMENT_STATE_EXTRACTION.md`; the architecture review that
motivated it is `Docs/STUDIOCORE_R4_DOCUMENT_MODEL_REVIEW.md`.

## 1. Exact existing state fields

`EditState` is a private value type inside `EditorModel`
(`Sources/RetouchStudio/Models/EditorModel.swift:314-323`). It has exactly eight
stored properties, in this order:

| # | Field | Type | Source of the value | Owning declaration |
|---|---|---|---|---|
| 1 | `adjustments` | `Adjustments` | `@Published var adjustments` | `EditorModel.swift:17` |
| 2 | `healSpots` | `[HealSpot]` | `@Published private(set) var healSpots` | `EditorModel.swift:119` |
| 3 | `stickers` | `[Sticker]` | `@Published private(set) var stickers` | `EditorModel.swift:124` |
| 4 | `aiEdits` | `[AIEdit]` | `@Published private(set) var aiEdits` | `EditorModel.swift:130` |
| 5 | `analysis` | `AnalysisSettings` | `@Published var analysis` | `EditorModel.swift:176` |
| 6 | `crop` | `CGRect?` | `@Published private(set) var appliedCrop` | `EditorModel.swift:114` |
| 7 | `orientation` | `DocumentOrientation` | `@Published private(set) var documentOrientation` | `EditorModel.swift:204` |
| 8 | `selectedFaceIndex` | `Int?` | `@Published private(set) var selectedFaceIndex` | `EditorModel.swift:94` |

`currentState` (`EditorModel.swift:334-339`) is the only place those eight
published properties are combined:

```swift
private var currentState: EditState {
    EditState(adjustments: adjustments, healSpots: healSpots,
              stickers: stickers, aiEdits: aiEdits, analysis: analysis,
              crop: appliedCrop, orientation: documentOrientation,
              selectedFaceIndex: selectedFaceIndex)
}
```

Roles and mutators, verified in source:

- `adjustments` is the full StudioCore slider model. It changes on a slider or
  preset (`adjustments` didSet `:17-19`), on Auto/Smart application, on
  `resetEffect`/`resetEffects`/`resetGroup`/`resetAll`
  (`:540-616`, `:2283-2308`), and on undo/redo restore (`:413`).
- `healSpots` is the manual stamp list in original-photo coordinates. It changes
  through `tapHeal`/`clearHealSpots` (`:1414-1436`), Smart suggestions
  (`:2538-2555`), Reset All (`:2289`), load (`:1086`) and restore (`:414`).
- `stickers` is the art list in the same coordinate system. It changes through
  `tapArt`/`placeSticker`/move/remove (`:1746-1815`), load (`:1087`), Reset All
  (`:2291`) and restore (`:415`).
- `aiEdits` is the generative layer list. It changes through `addAIEdit`
  (`:1706-1713`), `removeLastAIEdit` (`:1695-1701`), orientation rewrite
  (`:1268`), load (`:1088`), Reset All (`:2290`) and restore (`:416`).
- `analysis` is the callout overlay settings. It changes through its didSet
  (`:176-178`), load (`:1089`), Reset All (`:2293`) and restore (`:417`).
- `crop` is the applied crop (`appliedCrop`), not the crop-tool draft
  (`cropDraft`, `:116`). It changes through `applyCrop`/`resetCrop`
  (`:1184-1200`), load (`:1077`), Reset All (`:2298`) and restore (`:426`).
- `orientation` is the turn/mirror/straighten baked into the pixels. It changes
  through `rotateClockwise`/`rotateCounterClockwise`/straighten
  (`:1218-1234`), load (`:1078`), Reset All (`:2299`) and restore (`:427`).
- `selectedFaceIndex` is the owner's face choice. It changes through
  `selectFace`/`applyFaceSelection` (`:500-519`), load (`:1090`) and restore
  (`:418`).

No field is derived at read time. `crop`, `orientation` and
`selectedFaceIndex` are three separate stored properties whose values happen to
be mirrored from other published properties; the mirroring is exactly what
`currentState` does.

Platform typing:

- The state itself stores no `NSImage`, `CIImage`, `CGImage`, file handle, URL,
  timer, bookmark, Task, or UI object.
- Geometry values are CoreGraphics value types: `CGRect` (crop), `CGPoint` /
  `CGFloat` (`HealSpot`, `Sticker`, `AnalysisSettings.endpoints/anchors`),
  `CGSize` / `CGRect` (`AIEdit`).
- Some field *type declarations* live in files that also import platform
  frameworks for unrelated helpers: `DocumentOrientation.swift` imports
  CoreImage for pixel rotation, `AIEdit.swift` imports ImageIO for its store.
  The stored values are scalars, UUIDs, dates and strings. This transitive type
  coupling is the reason R4.1 keeps `DocumentState` in the application layer and
  is recorded as a known limitation, not changed here.

Companion state outside `EditState` that is intentionally *not* document data:
the before/after split, face overlay, auto strengths, export settings,
watermark, language, healing-brush size, selected sticker, crop draft/aspect,
quick-edit and mask state, faces, preview pixels, project URL and recents.
The auto strengths and export settings are written into a project (§6) but are
excluded from history and dirty tracking (§3).

## 2. Default values and initialization

The declaration (`EditorModel.swift:314-323`) gives every field a default:

| Field | Default |
|---|---|
| `adjustments` | `Adjustments()` (equal to `.zero`, `Sources/StudioCore/Adjustments.swift:310-312`) |
| `healSpots` | `[]` |
| `stickers` | `[]` |
| `aiEdits` | `[]` |
| `analysis` | `AnalysisSettings()` (`Sources/RetouchStudio/Models/Analysis.swift:68-...`) |
| `crop` | `nil` (whole frame) |
| `orientation` | `DocumentOrientation.identity` (`Orientation.swift:13-...`) |
| `selectedFaceIndex` | `nil` (automatic choice) |

History containers are initialized with the same value
(`EditorModel.swift:325-329`):

```swift
private var undoStack: [EditState] = []
private var redoStack: [EditState] = []
private var lastCommitted = EditState()
private var cleanState = EditState()
```

Initialization paths:

- A new photo without a project takes the `else` branch of `apply`
  (`:1079-1083`): zero adjustments, no crop, identity orientation, and empty
  stamps/stickers/edits/analysis from `:1086-1089`.
- A project sets adjustments, crop and orientation from the file
  (`:1070-1078`) and the remaining collections from optional fields with empty
  defaults (`:1086-1090`).
- `cleanState = currentState` at `:1096`, then `resetHistory()` at `:1098`
  copies the current state into `lastCommitted` and `cleanState` (`:533-534`).
- A recovery restore deliberately overrides the clean baseline with an empty
  state (`:1104-1105`) so the recovered document counts as unsaved until it is
  saved.

`isDocumentPristine` (`:2313-2318`) compares seven of the eight fields against a
new document: adjustments identity, three empty collections, default analysis,
no crop, identity orientation. It deliberately ignores `selectedFaceIndex`.
This asymmetry is current behavior and must not be "fixed" during extraction.

## 3. Dirty tracking behavior

The single comparison is in `updateCleanState` (`EditorModel.swift:521-524`):

```swift
private func updateCleanState() {
    hasUnsavedChanges = hasImage && currentState != cleanState
    scheduleAutosave()
}
```

It is called from every document-changing observer:

- `adjustmentsChanged` (`:445-449`)
- `healSpotsChanged` (`:451-458`)
- `stickersChanged` (`:460-466`)
- `analysisChanged` (`:471-477`)
- the `aiEdits` didSet (`:130-136`)
- `updateCleanState` after face selection (`:507`)
- `restore` (`:424`)
- `resetHistory` (`:535`)
- `resetAll` (`:2306`)
- `writeProject` after a successful save (`:3176`)

Fields that participate: all eight of §1. A change to any one of them can make
`currentState != cleanState` and therefore dirty.

Fields that are intentionally excluded from the comparison:

- export format, quality, long edge, AI upscale, metadata stripping, watermark
  (`:48-72`, plus the export-sheet state);
- auto retouch strength and auto color strength (`:32-38`);
- compare position, face overlay, language, healing-brush size
  (`:21-44`, `:184-186`);
- selected sticker, crop draft/aspect, quick-edit and mask state, faces,
  preview state, project URL and recents.

Evidence that these are excluded rather than merely unobserved: they are absent
from `currentState` (`:334-339`), their didSets write preferences only, and two
of them (`exportQuality`, `autoRetouchStrength`) are nevertheless written by
`makeProject` (`:3150-3154`). The R4.0 tests set all of them and assert both
`hasUnsavedChanges == false` and no new undo step.

How a document becomes clean again:

- loading or opening a project sets `cleanState = currentState` (`:1096`,
  then `resetHistory` at `:1098`);
- a successful Save Project sets `cleanState = currentState` (`:3174`);
- `resetHistory` sets both `lastCommitted` and `cleanState` (`:533-534`);
- undoing back to the saved value satisfies `currentState == cleanState`; no
  separate flag is cleared.

Export does **not** clean the document. The comment at `:3102-3103` states that
an exported copy is not a saved project, and the existing P0-1 regression test
pins it.

Recovery restore is a special case: `cleanState = EditState()` (`:1104`) makes a
restored document dirty whenever its current state is not empty, so closing
warns and the crash copy is retained.

No normalization is applied before the comparison. Values are compared as
stored, using the synthesized `Equatable` conformance of `EditState` and of each
field type. Defaults affect the comparison only through the initial/clean
baselines above.

## 4. Undo and redo interaction

Undoable changes are exactly changes to the eight fields. The machinery:

- A change is *offered* as undoable immediately:
  `canUndo = !undoStack.isEmpty || currentState != lastCommitted`
  (`:440-443`). This is why a slider drag offers ⌘Z before the debounce fires.
- A change becomes a *recorded step* only through `commitAdjustments` (`:354-367`):
  cancel the pending coalesce task, compare against `lastCommitted`, append the
  previous `lastCommitted` to `undoStack`, trim to 100, clear `redoStack`, set
  `lastCommitted = current`.
- Slider-like changes coalesce for 350 ms (`scheduleCommit`, `:344-351`;
  delay `350_000_000` ns at `:347`), so one gesture is one step.
- Discrete operations commit explicitly around the mutation: face selection
  (`:504-506`), single/group reset (`:540-616`), AI add/remove
  (`:1697-1708`), preset application (`:2320-2326`), Reset All (`:2285`,
  `:2305`).
- Undo (`:369-385`) first commits any pending debounce (`:378`), pops the
  previous state, pushes the current state onto `redoStack`, restores, and sets
  `lastCommitted = previous`.
- Redo (`:387-403`) refuses while the document differs from `lastCommitted`:
  it commits instead and returns (`:393-396`). Otherwise it pops from
  `redoStack`, pushes the current state onto `undoStack`, restores and advances
  `lastCommitted`.
- Committing a new change clears `redoStack` (`:364`), which discards the redo
  branch.

What a restore does (`:409-431`):

1. compares crop, orientation and face selection to decide follow-up work;
2. assigns `adjustments`, `healSpots`, `stickers`, `aiEdits`, `analysis`;
3. applies the face selection (`applyFaceSelection`, `:512-519`) and clears
   `selectedSticker`;
4. refreshes the analysis overlay and preview when the selected face changed;
5. calls `updateCleanState`;
6. if crop or orientation changed, assigns both, resets the crop draft/aspect
   and re-reads the pixels through `reloadCropped(restoring: true)`. The history
   stacks are not touched by that re-read.

Fields intentionally excluded from history: everything outside the eight
fields, notably export/auto settings, the compare split, view state, the
selected sticker, and the crop draft. Tests confirm a crop-only change is one
step and that the re-read preserves the stack (existing `[P1-2]` test).

History and save state interact only through the equality comparison: undoing
to the saved values clears `hasUnsavedChanges`; saving moves `cleanState`
without clearing the undo stack. History belongs to one photo: every load calls
`resetHistory` (`:528-537`, invoked at `:1098`) and clears both stacks.

## 5. Autosave and recovery interaction

Autosave is driven by dirty tracking: `updateCleanState` always ends with
`scheduleAutosave()` (`:523`).

`scheduleAutosave` (`EditorModel.swift:2603-2631`):

1. cancels any pending task;
2. returns unless recovery is enabled and the editor is not loading;
3. if the document is clean, has no image, or cannot produce a project, it
   removes the working copy (unless this document was itself restored) and
   returns (`:2607-2614`);
4. otherwise it builds the project with `makeProject()`, captures
   `RecoverySnapshot.capture(project)` at schedule time (`:2616`), records the
   store epoch, and schedules a write after 1.5 s
   (`autosaveDebounceNanoseconds = 1_500_000_000`, `:795`; used at `:2618`);
5. before writing, the task re-checks cancellation, the epoch, loading state and
   that the image path still matches (`:2625-2628`), then calls
   `persistAutosave`.

`flushAutosave` (`:2656-2662`) runs the same path synchronously for tests and
teardown.

What is serialized: a `RecoverySnapshot` (`Sources/RetouchStudio/Models/Recovery.swift:31-50`)
whose version 1 wraps the same `RetouchProject` that Save Project writes, plus a
timestamp and a source identity. `RecoverySnapshot.capture` (`:54-57`) takes the
project by value; R4.0 verifies that mutating the local project afterwards does
not change the snapshot. The project itself is a struct, so the snapshot owns a
copy, not a reference to editor properties.

How changes are detected: through the same `updateCleanState` calls as §3; there
is no polling or file watching in the save path.

Platform/filesystem parts, all outside the state value: the recovery directory
and working/candidate files (`RecoveryStore`), `FileManager`, process/lease
locking, the image bookmark built by `makeProject`, and the source identity.
Recovery restore re-enters `apply` with a decoded project and forces the dirty
baseline described in §3.

## 6. Project creation and serialization interaction

`makeProject` (`EditorModel.swift:3145-3162`) is the single project factory
shared by Save Project and autosave. It supplies:

| Project field | Source |
|---|---|
| `imagePath` | `imageURL.path` |
| `imageBookmark` | `bookmark(for: imageURL)` |
| `adjustments` | state field 1 |
| `exportFormat` / `exportQuality` / `exportLongEdge` | application export settings (`0` becomes `nil`) |
| `autoRetouchStrength` / `autoColorStrength` | application settings |
| `crop` | state field 6 |
| `healSpots` / `stickers` / `aiEdits` | state fields 2-4, empty becomes `nil` |
| `analysis` | state field 5, default becomes `nil` |
| `selectedFace` | state field 8 |
| `orientation` | state field 7, identity becomes `nil` |

Normalization that affects existing behavior and must not change:

- empty `healSpots`, `stickers`, `aiEdits` are written as absent;
- `analysis == AnalysisSettings()` is written as absent;
- identity orientation is written as absent;
- `exportLongEdge == 0` is written as absent;
- `selectedFace == nil` is written as absent.

`RetouchProject` itself is unchanged: version constant `3`
(`Sources/RetouchStudio/Models/Project.swift:12`), stored `version` default
(`:21`), manual keyed decoder with legacy defaults (`:96-115`). The encoder and
all serialized field names are untouched by R4.0; no project file is read or
written differently.

Save succeeds in `writeProject` (`:3164-3181`): pretty-printed sorted-key JSON,
atomic write, recent entry, then `cleanState = currentState`,
`documentRecovered = false`, `updateCleanState()`.

Export snapshot (`makeExportSnapshot`, `:3029-3048`) reads the same eight fields
plus export settings and the two batch switches. It is an export description,
not a document write; it does not alter the clean baseline. The effective format
can differ from the chosen format for overlay-only analysis exports
(`:3011-3015`); this is unchanged.

## 7. Tests added and what each test proves

All new tests live in `Tests/ModelTests.swift` under
`// MARK: - R4.0 document-state characterization` and use only public editor
API, so they exercise the same code before and after R4.1. They are registered
at the end of `runAll()`.

| Section | Checks | What it proves |
|---|---|---|
| `testDocumentStateDefaultsAndDirtyTracking` | 37 | All eight fields start at the documented defaults; a fresh load is pristine, clean and history-free; each of adjustments, healing stamp, sticker, analysis and AI edit is document data that marks the document dirty and travels through undo/redo; removing the last AI edit and undoing restores it; export settings, auto strengths, compare position and face overlay are neither dirt nor undo steps. |
| `testDocumentStateHistoryBehavior` | 12 | A no-op commit records nothing; a pending debounce is flushed by undo; a repeated commit does not duplicate a step; editing after undo discards the redo branch while the older branch stays reachable; the stack retains exactly the most recent 100 states (after 105 commits and 100 undos the oldest retained value is 5). |
| `testDocumentStateAutosaveCapture` | 7 | A clean document has no working copy; autosave carries the adjustment, the image path and the current project version; empty stamps stay normalized to `nil`; the snapshot owns a value copy; returning to the clean baseline removes the working copy. |
| `testDocumentStateProjectNormalization` | 11 | An opened project starts clean; export/auto preferences are written but are not dirt; Save moves the clean baseline; the saved file is version 3, names the photo, carries the adjustment and the preferences, and normalizes empty collections, default analysis, nil crop/orientation/face and zero long edge to absent. |
| `testDocumentStateExportSnapshot` | 11 | The export snapshot reads the same eight fields (including crop, orientation and face selection), takes export settings from the application layer, takes batch switches from the caller, and uses the same runtime gate for upscaling. |

Total: 78 new checks, all passing.

The existing suite already pins behavior this characterization relies on and was
kept unchanged:

- `[P0-1]` export does not clean the document;
- `[P1-2]` crop is undoable, undo returns to the clean baseline, and the
  cropping re-read preserves history;
- `[O1]` orientation maps coordinates and survives project write/read;
- `[P2-3]` an AI edit is one undo step and reaches the export;
- recovery tests covering working-slot writes, promotion, candidate retention,
  discard and autosave invalidation.

## 8. Known behavior that must remain unchanged

1. The eight fields, their types, order and defaults.
2. `currentState` built only from those eight values.
3. Dirty = `hasImage && currentState != cleanState`; export/auto/view
   preferences are excluded; save and load move the baseline; recovery restore
   forces a dirty baseline.
4. `isDocumentPristine` compares seven fields and ignores `selectedFaceIndex`.
5. 350 ms coalescing, commit deduplication, 100-step cap, redo cleared on a new
   commit, undo flushing a pending debounce, redo committing instead of
   replaying while dirty.
6. Restore order: assign state, clear the selected sticker, refresh analysis and
   preview for a face change, update clean state, then re-read pixels when crop
   or orientation changed without touching history.
7. History is per photo and is cleared on every load.
8. Autosave is debounced 1.5 s, captures the project at schedule time, is
   guarded by the store epoch and image path, removes the working copy when the
   document is clean, and keeps it for a restored document until a save.
9. `makeProject` field mapping and nil normalization; project v3 field names,
   decoder defaults and encoder output.
10. Export snapshots read the same eight fields and never move the clean
    baseline.
11. Coordinates remain as stored: stamps/stickers in original-photo space,
    analysis endpoints in normalized working-frame space, crop in normalized
    photo space, orientation as turn/mirror/angle.

## R4.0 acceptance result

- New characterization tests: 78 checks, pass.
- Full suite (`./Tests/run.sh`): pass (engine, model, runtime process, runtime
  v2).
- Application sources: unchanged; the only modified file is
  `Tests/ModelTests.swift`.
- Project v3 serialization: unchanged; no project or geometry source touched.
- Pre-existing untracked documentation and conformance fixtures: hashed before
  work and unchanged (see the R4.1 report).
