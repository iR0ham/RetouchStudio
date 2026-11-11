# StudioCore R4.1 — DocumentState Extraction

Status: complete; uncommitted for review.

Baseline commit: `f6456b7b69473b65f5ce7318433bc8d0f0e511bf` (branch `main`).

Companion documents:

- `Docs/STUDIOCORE_R4_DOCUMENT_MODEL_REVIEW.md` — the architecture review that
  selected this extraction.
- `Docs/STUDIOCORE_R4_0_CHARACTERIZATION.md` — the frozen behavior this
  extraction must preserve. Its line references are baseline references; the
  removal described here shifts later `EditorModel.swift` lines by 10.

## 1. What was extracted

The private `EditState` value inside `EditorModel` was moved verbatim into an
application-layer type named `DocumentState`
(`Sources/RetouchStudio/Models/DocumentState.swift:12-21`):

```swift
struct DocumentState: Equatable {
    var adjustments = Adjustments()
    var healSpots: [HealSpot] = []
    var stickers: [Sticker] = []
    var aiEdits: [AIEdit] = []
    var analysis = AnalysisSettings()
    var crop: CGRect?
    var orientation = DocumentOrientation.identity
    var selectedFaceIndex: Int?
}
```

Preserved exactly:

- the eight fields, their order and their types;
- the defaults (including `DocumentOrientation.identity`);
- value semantics and the synthesized memberwise initializer, so
  `DocumentState()` and the labeled eight-argument call both keep working;
- synthesized `Equatable`, which compares the same fields in the same way as
  before;
- array copy-on-write behavior through Swift value semantics;
- no serialization: the type is not `Codable`, was not `Codable` before, and is
  never written to a project or recovery file.

No fields were added for future use. No behavior was moved into the type: it
has no methods beyond the compiler-synthesized initializer, equality and copy.

## 2. Why the type remains in the application layer

`Adjustments` is already portable StudioCore code, but the other field types are
application types:

| Field | Type location | Why it is not portable yet |
|---|---|---|
| `healSpots` | `Sources/RetouchStudio/Models/Heal.swift:10` | CoreGraphics geometry plus app healing conversion helpers |
| `stickers` | `Sources/RetouchStudio/Models/Sticker.swift:20` | CoreGraphics, StudioCore color, and `L10n` titles on the kind |
| `aiEdits` | `Sources/RetouchStudio/Models/AIEdit.swift:11` | CoreGraphics plus an ImageIO-backed edit store in the same file |
| `analysis` | `Sources/RetouchStudio/Models/Analysis.swift:68` | CoreGraphics points, regions, tint and export enums |
| `crop` | `CGRect?` | CoreGraphics value |
| `orientation` | `Sources/RetouchStudio/Models/Orientation.swift:13` | three scalar fields, but the file also carries CoreImage pixel rotation |
| `selectedFaceIndex` | `Int?` | portable already |

Moving the value into StudioCore now would either drag those application types
along or force a geometry/type migration that is explicitly out of this
milestone's scope. The extraction therefore stops at the seam: document data is
named and separated, while the field types stay where their behavior lives.

The type itself has no UI or platform-service dependency. Its complete import
set is CoreGraphics, Foundation and StudioCore. It contains no `NSImage`,
`CIImage`, `CGImage`, `FileManager` call, URL, bookmark, timer, Task, dialog,
notification or SwiftUI/AppKit/UIKit/Vision/ImageIO reference.

## 3. How EditorModel now uses it

The editor still owns the value and every policy around it. The only changes
are type names:

| Location (extracted tree) | Before | After |
|---|---|---|
| `EditorModel.swift:315-318` | `[EditState]`, `EditState()` | `[DocumentState]`, `DocumentState()` |
| `EditorModel.swift:324-329` | `currentState: EditState` built with `EditState(...)` | `currentState: DocumentState` built with `DocumentState(...)` |
| `EditorModel.swift:399` | `restore(_ state: EditState)` | `restore(_ state: DocumentState)` |
| `EditorModel.swift:1094-1095` | recovery baseline `EditState()` | `DocumentState()` |

`currentState` still reads the eight published properties in the same order.
The undo/redo rules, coalescing, commit boundaries, dirty comparison, autosave,
recovery, project creation, export snapshots, batch and AI coordination are
unchanged and remain in `EditorModel`. `makeProject`,
`makeExportSnapshot` and `RecoverySnapshot` were not modified; they still
consume the eight published properties directly.

## 4. Behavior preserved

Everything characterized in R4.0 is still true, including:

- dirty = `hasImage && currentState != cleanState`, with export and auto
  preferences excluded;
- 350 ms coalescing, commit deduplication, the 100-step cap, redo cleared by a
  new commit, undo flushing a pending debounce, redo committing instead of
  replaying while dirty;
- restore order, mask/preview rebuilds, and the crop/orientation pixel re-read
  that leaves history untouched;
- clean baselines on load, save and undo, plus the forced dirty baseline after a
  recovery restore;
- 1.5 s autosave debounce, value-copied snapshots, epoch/path guards, working
  copy removal when clean;
- `makeProject` mapping and nil normalization; project v3 field names, encoder
  and decoder untouched;
- export snapshots reading the same eight fields and never cleaning the
  document;
- per-photo history reset.

The previously documented asymmetry remains: `isDocumentPristine` still
compares seven fields and ignores `selectedFaceIndex`. That is existing behavior,
not a defect introduced or fixed here.

## 5. Test evidence

### Added tests

`Tests/ModelTests.swift`:

- R4.0 section, five functions, 78 checks, written against the public editor
  API and unchanged by the extraction:
  - `testDocumentStateDefaultsAndDirtyTracking` (37)
  - `testDocumentStateHistoryBehavior` (12)
  - `testDocumentStateAutosaveCapture` (7)
  - `testDocumentStateProjectNormalization` (11)
  - `testDocumentStateExportSnapshot` (11)
- R4.1 section, `testDocumentStateValueSemantics` (18 checks): defaults,
  construction from all eight fields, equality, copy/array independence, and
  per-field inequality distinguishing each of the eight values.

The R4.0 tests passed before the extraction and again after it, which is the
strongest evidence that the value the editor observes did not change.

### Gates and actual results

| Gate | Command | Result |
|---|---|---|
| Focused R4.0 + R4.1 checks | `./Tests/run.sh` (model suite) | 96/96 checks pass (78 R4.0 + 18 R4.1) |
| Full suite, arm64 | `./Tests/run.sh` | exit 0; ENGINE, MODEL, RUNTIME PROCESS and RUNTIME V2 all PASS; 947 checks |
| Full suite, x86_64 under Rosetta | `RETOUCH_ARCH=x86_64 ./Tests/run.sh` | exit 0; all four suites PASS; 947 checks. This is Rosetta-translated x86_64, not native Intel hardware |
| StudioCore build and tests | `./Tests/run-studiocore.sh` | 117 checks passed; Foundation-only boundary check unchanged |
| R1 conformance | `./Tests/Conformance/run-conformance.sh` | PASS: 21 fixtures (15 valid, 6 invalid), corpus lock 12 fixtures / 78 cases / 21 references / 11 exports, canonical JSON SHA-256 verified, 17 render stages |
| C ABI smoke | same command | `studioscore abi=1 status_count=20 error_codes=20` |
| Golden corpus | `./Tests/run-corpus.sh` | 376 checks, 0 failures |
| macOS build + self-test | `./build.sh` (universal) | exit 0; processing self-test passed natively and on the Intel slice; bundle produced |
| Whitespace | `git diff --check` | exit 0, no output |

No Windows or Linux compatibility is claimed or was tested.

### Corpus protection

- All 46 tracked `Tests/Corpus` files were hashed before running the harness.
- The harness rewrote exactly three tracked exports:
  `F01_export_256.png`, `F01_export_256.tif`, `F11_export_256.png`.
- Only those three were restored from `HEAD`; no fixture or baseline was
  regenerated.
- All 46 hashes were re-verified and match the pre-run snapshot byte for byte.

## 6. Remaining dependencies and future candidates

Known limitation: some field *type declarations* still live in files that import
platform frameworks for unrelated helpers (`DocumentOrientation` for pixel
rotation, `AIEdit` for its ImageIO store, `StickerKind` for localized titles).
The extracted value stores only scalars, UUIDs, dates, strings and CoreGraphics
structs, so no platform service is reachable through the state's own API, but
the transitive type coupling is why this milestone stops at the app layer.

Future candidates, in the order suggested by the R4 review, are documented and
not started:

1. split the pure scalar parts of `DocumentOrientation`, crop and analysis
   geometry from their rendering helpers;
2. extract history/commit policy into a session type;
3. extract the project/export/recovery snapshot construction (codec);
4. only then consider a portable document model in StudioCore, with a format
   decision for geometry — v3 currently uses unkeyed Apple arrays and must not
   be changed casually.

## 7. Rollback procedure

The change is small and has no data migration:

1. delete `Sources/RetouchStudio/Models/DocumentState.swift`;
2. in `EditorModel.swift`, restore the inline
   `private struct EditState: Equatable` block and change the four
   `DocumentState` type references back to `EditState`;
3. keep the R4.0 tests and document; the R4.1 value-semantics test must be
   removed or renamed because the type would no longer exist.

No project, recovery, corpus or fixture file needs to be restored: none was
modified. `git checkout -- Sources/RetouchStudio/Models/EditorModel.swift`
followed by deleting the new file is the exact reversal, while the test and
documentation changes can be reverted independently.

## 8. Scope statements

- `RetouchProject`, its decoder/encoder, serialized names and v3 wire shape:
  untouched.
- Geometry models, image processing, the 17-stage pipeline, AI worker behavior:
  untouched.
- Autosave and recovery behavior: untouched.
- No History, DocumentSession, DocumentCodec, RecoveryPolicy, ExportPlanner or
  BatchPlanner extraction.
- No new dependency, package manager or build-system change.
- No commit, stage, push, PR or merge; all changes are left uncommitted.
