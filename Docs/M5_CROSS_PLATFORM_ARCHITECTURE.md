# M5 — Cross-Platform Core Independence

**Branch:** `m5-cross-platform-core`
**Base:** `main`; the branch was first created on PR #4's head `9a5623a`,
M5 landed as PR #5, and the PR was retargeted to `main` after PR #4 merged
and the CI work reached `main`.
**Date:** 2026-11-12
**Pull request:** #5, base `main`, no longer stacked; not merged.
**Status:** implementation and validation on macOS arm64; no Windows or Linux
build exists and none is claimed.

This milestone does not restart the architecture. It continues M1/M2 and
R1–R4: the same modules, the same file formats and the same macOS shell, with
the platform-independent rules moved one layer down and the remaining
platform edges named explicitly.

---

## 1. Starting state

- Repository: `iR0ham/RetouchStudio`, branch `v1-macos-delivery` at `9a5623a`.
- PR #4 (`V1 macOS: lifecycle, export and redesign hardening`) is open,
  unmerged, with head `v1-macos-delivery` and base `main`.
- Working tree clean at the start of M5; no user work in progress.
- `StudioCore` already existed as a Foundation-only module with its own build
  script (`Tests/build-studiocore.sh`) and boundary gate
  (`Tests/run-studiocore.sh`), but the gate was not part of
  `Tests/run.sh`. A full suite could pass without ever proving the boundary.
- The R4 document units (`DocumentSession`, `RecoveryPolicy`,
  `ProjectCodec`, `ExportPlanner`, `BatchPlanner`) already existed inside the
  app target.

`git log` was the source for the milestone history below; nothing was
reconstructed from memory.

## 2. Verified milestone history

| Milestone | Commits | What is verifiable in this checkout |
|---|---|---|
| Pre-extraction product work (the directive's M1/M2 shorthand) | `45274b4` → `545a23d` | Modern shell, measured engine work, bilingual UI, local AI runtime and Phase 5 acceptance. The commits exist and are the parents of the extraction series. No milestone file labels them `M1`/`M2`; those names are treated as the directive's shorthand. |
| M4 — architecture and extraction design | `7cfc859`, `d7e97e1` | `STUDIOCORE_ARCHITECTURE.md`, `STUDIOCORE_INTERFACE_DESIGN.md`, `CROSS_PLATFORM_TECHNOLOGY_DECISIONS.md`, `STUDIOCORE_EXTRACTION_ROADMAP.md`. |
| R1 — conformance foundation | `5e4000b` | Canonical fixtures, render plans, C ABI smoke test, corpus lock. |
| R2 — pure Swift types | `deaaf37` | `Adjustments`, `Makeup`, `MakeupColor`, `UserPreset` in `Sources/StudioCore`. |
| R3 — portable geometry | `f6456b7` | `StudioPoint`, `StudioSize`, `StudioRect`, `StudioCoordinateSpace`, keyed Codable and a CoreGraphics boundary adapter. |
| R4.0–R4.1 | `8fd6a83` | Characterization tests; `DocumentState` extracted from `EditorModel`. |
| R4.2 | `a6facd5` | `DocumentSession` extracted with a value-type history. |
| R4.3–R4.7 | `2b1290d`, `e05ac00`, `fd274ad`, `4cf5b38`, `9c7b474` | Project codec and source resolution, restoration, export planner, batch planner, recovery policy. |
| R4.8 and hardening | `0b90024`, `f989142`, `4cac5cb` | Portable v4 file with lossless v3 import; recovery keeps v4 metadata; documentation corrected before merge. |
| V1 hardening | `9a5623a` | Lifecycle, export reporting, batch failure count and inspector layout fixes; PR #4 head. |

PR #3 (R4) is already merged as `a5ceb9b`. PR #4 was open at the start of M5
and stayed unmerged through the M5 commits; it has since merged into `main`.
PR #5 was then retargeted from PR #4's head to `main` and synchronized with a
normal merge of `main` (section 12), so it is no longer stacked.

## 3. Dependency graph before and after

Before M5:

```text
StudioCore (Foundation only)
  Adjustments, Makeup, MakeupColor, UserPreset
  StudioPoint / StudioSize / StudioRect / StudioCoordinateSpace

App model layer
  DocumentState  -> StudioCore + CoreGraphics
  DocumentSession (Foundation, app-owned rules)
  RecoveryPolicy  (Foundation, app-owned rules + RecoverySnapshot)
  ProjectCodec    (CoreGraphics + Foundation, owns port protocols)
  Recovery / Restoration / ExportPlanner / BatchPlanner / EditorModel

Platform layer
  AppKit, SwiftUI, Combine, Core Image, Vision, ImageIO, CoreText, UniformTypeIdentifiers
```

After M5 (M6 then moved the document values; section 5.1):

```text
StudioCore (Foundation only, still one import)
  Adjustments, Makeup, MakeupColor, UserPreset
  geometry types and coordinate spaces
  DocumentHistory<State: HistoryState>       (new)
  RecoveryRules                              (new)
  ProjectSourceAccess, ProjectBookmarkStore  (new ports)
  RetouchProject, ProjectCodec, ProjectV4     (M7)
  ProjectByteStore, ProjectIOError, ProjectStore (M7)
  DocumentState and the document values       (M6)

App model layer
  DocumentSession = DocumentHistory<DocumentState>   (typealias)
  RecoveryPolicy (delegates name/date rules; keeps snapshot rules)
  FileProjectByteStore, URLBookmarkStore, FileProjectSourceAccess (M7)
  ...unchanged...

Platform layer
  unchanged
```

The arrow that changed is the direction of ownership, not the direction of
dependence: the shared rules no longer live in the app, and the app no
longer defines the port protocols it consumes.

## 4. What was already portable

Verified by reading the sources and by the existing boundary gate:

- `Adjustments` and its nested types, `MakeupColor`, `Makeup` and `UserPreset`
  are Foundation-only and already encode byte-identically.
- The geometry types are Foundation-only values with keyed Codable; they are
  the v4 wire shape.
- `RecoveryPolicy`'s date/name decisions were already value-only, but lived
  in the app.
- `DocumentSession`'s transitions were already value-only and testable, but
  lived in the app and were tied to `DocumentState`.
- The canonical JSON fixtures, the render plans and the corpus lock are
  platform-neutral and are checked without AppKit.

## 5. What was newly separated

1. **Document history** — `Sources/StudioCore/DocumentHistory.swift`.
   `HistoryState` is an empty marker (`Equatable`); `DocumentHistory<State>`
   takes the initial state in its initializer and owns the two stacks, the
   last committed state, the clean baseline and the 100-step cap. The
   semantics are the R4.2 semantics, unchanged.
   `DocumentState` opts in through a one-line conformance; `DocumentSession`
   is now a typealias so every existing call site and test keeps its name.
2. **Recovery rules** — `Sources/StudioCore/RecoveryRules.swift`.
   `AutosaveEpoch`, `CandidateOrderKey`, `olderFirst`, `isCandidateFileName`,
   `monotonic` and `quarantineFileName` are public, Foundation-only and
   covered by new headless tests. `RecoveryPolicy` keeps its API through
   type aliases and one-line delegations; `snapshot(from:modified:)`,
   `refusal(for:)` and `sourceState(...)` stay in the app because they read
   project types.
3. **Platform ports** — `Sources/StudioCore/ProjectPlatform.swift`.
   `ProjectSourceAccess` and `ProjectBookmarkStore` are now shared protocols.
   The Foundation adapters (`FileProjectSourceAccess`, `URLBookmarkStore`)
   remain in `ProjectCodec.swift`, so no file-system or bookmark API entered
   the core.
4. **Validation wiring** — `Tests/run.sh` now calls
   `Tests/run-studiocore.sh` instead of building the module directly. A
   forbidden import, a platform type in the core, a non-portable rule or a
   failing core test now fails the full suite.
5. **Conformance tests** — 37 new checks in `Tests/StudioCoreTests.swift`:
   20 for history transitions, 17 for recovery rules and ports. The suite
   still links only Foundation and `StudioCore`.

No existing type was duplicated: the app keeps one name per concept, and the
core is the single home for the moved rules.

### 5.1 M6 — the document value itself

Roadmap item 2 (section 14) is done on the same branch:

- `Sources/StudioCore/DocumentValue.swift` now owns `HealSpot`, `Sticker` and
  `StickerKind`, `AIEdit`, `AnalysisRegion`, `AnalysisTint`,
  `AnalysisExportMode`, `AnalysisSettings`, `DocumentOrientation` and
  `DocumentState`. Every field is a Foundation value (`StudioPoint`,
  `StudioSize`, `StudioRect`, `Double`, `String`, `UUID`), every type is
  `Codable`, and `DocumentState` declares `HistoryState` next to its own
  definition instead of an app-side retroactive conformance.
- `Sources/RetouchStudio/Models/DocumentState.swift` is deleted; no app type
  shadows the shared value.
- CoreGraphics stays on the host: `StudioPoint.cgPoint`, `StudioRect.cgRect`
  and `StudioRect.init(CGRect)` remain app-side adapters, and the call sites
  that cross the boundary convert explicitly (`EditorModel`, `AnalysisRenderer`,
  `AICompositor`, `DocumentRestoration`, `ProjectCodec`).
- **v3 bytes are frozen behind wire records.** `RetouchProject` keeps portable
  stored properties and converts only inside `init(from:)`/`encode(to:)`
  through `HealSpotV3`, `StickerV3`, `AIEditV3` and `AnalysisSettingsV3`, which
  still write CoreGraphics' unkeyed shapes. The fixture
  `Tests/Fixtures/ProjectV3/project-v3-full.retouch` re-encodes byte-identically
  and `testProjectV3BaselineByteIdentity()` passes unchanged.
- **v4 got smaller.** `ProjectV4` dropped `HealSpotV4`, `StickerV4` and
  `AIEditV4` in favour of the core types; `AnalysisSettingsV4` remains only
  because it sorts regions for stable cross-architecture bytes.
- The core suite grew by 34 checks (188 total): portable stamps, stickers,
  edits and analysis defaults; orientation frames, composition, inverse and
  straighten; portable JSON with named coordinates and no Core Graphics array
  shape; and `DocumentState` as a step in the shared `DocumentHistory`.

### 5.2 M7 — portable project I/O

Roadmap item 3 (section 14) is done on the same branch. The project model,
both wire formats and the read/write ordering moved into StudioCore; only the
host APIs stayed behind.

**Moved into `Sources/StudioCore`**

| File | Contents |
|---|---|
| `ProjectDocument.swift` | `RetouchProject` (v3 in memory), its tolerant decode, and the frozen v3 wire records `WirePoint`, `WireSize`, `WireRect`, `HealSpotWire`, `StickerWire`, `AIEditWire`, `AnalysisSettingsWire`. The unkeyed Core Graphics arrays are written by these records, not by Core Graphics. |
| `ProjectCodec.swift` | `ProjectCodec`, `ProjectCodecError`, `ProjectJSONValue`, `ProjectWriteContext`, `ProjectFile`, `ProjectV4`, `AnalysisSettingsV4`, and `ProjectSourceResolver`. The codec preserves every unknown top-level key and required feature through `ProjectWriteContext`, so a v4 file re-saves with the same bytes. |
| `ProjectIO.swift` | `ProjectByteStore`, `ProjectIOError` and `ProjectStore`. The store owns the order read bytes → decode and encode → write bytes, and maps every host failure onto a structured error. |

`Sources/RetouchStudio/Models/Project.swift`, `ProjectV4.swift` and
`ProjectCodec.swift` are deleted. There is one codec, not a parallel one.

**Kept on macOS (`Sources/RetouchStudio/Models/ProjectAdapters.swift`,
`Recovery.swift`)**

- `FileProjectByteStore` reads/writes `Data` with `.atomic`.
- `FileProjectSourceAccess` answers path existence through `FileManager`.
- `URLBookmarkStore` creates and resolves security-scoped bookmarks.
- `RetouchProject.contentType` maps the shared type onto `UTType`.
- Open/save panels, photo relocation prompts and crash recovery remain in
  `EditorModel` and `Recovery.swift`; recovery keeps writing its own snapshot
  wrapper around the shared `RetouchProject` and `ProjectWriteContext`.

No file-system, bookmark or `UTType` type appears in a portable public API.
The only Foundation types crossing the seam are `Data` and `URL`.

## 6. What remains macOS-specific

These are deliberate boundaries, not unfinished moves:

| Area | Why it stays on macOS | Evidence |
|---|---|---|
| CoreGraphics adapters | The document value moved to StudioCore in M6; only the `CGPoint`/`CGRect` adapters and the renderers that consume them stay on macOS. | `Sources/StudioCore/DocumentValue.swift`, `Sources/StudioCore/StudioGeometry.swift` |
| Project bytes, bookmarks, panels | The model and codec moved to StudioCore in M7. `Data` I/O, `URL` bookmarks, `UTType`, open/save panels and photo relocation stay in the host; `URLBookmarkStore`, `FileProjectByteStore` and `FileProjectSourceAccess` implement the shared ports. | `Sources/RetouchStudio/Models/ProjectAdapters.swift`, `Sources/StudioCore/ProjectIO.swift`, `Docs/STUDIOCORE_R4_8_PROJECT_V4.md` |
| `ExportPlanner`, `BatchPlanner` | Use `CGRect`/`CGSize` and `UTType`-adjacent policy. | `Sources/RetouchStudio/Models/ExportPlanner.swift`, `BatchPlanner.swift` |
| `RecoveryStore` | Directory layout, renames, durability and quarantine execution. | `Sources/RetouchStudio/Models/Recovery.swift` |
| Image engines | Core Image, Vision, ImageIO, CoreText, AppKit. | imports in `Sources/RetouchStudio/Core` |
| AI runtime | POSIX/Darwin transport and process identity. | `WorkerClient.swift:171-260`, `ProcessIdentity.swift:32-36` |
| UI | SwiftUI/AppKit. | `Sources/RetouchStudio/Views` |

## 7. Image and color findings

- The pixel path is entirely outside every shared rule: `SkinEngine`,
  `LookEngine`, `MakeupEngine`, `SceneEngine` and `AICompositor` are Core
  Image work, `FaceAnalyzer`/`SmartAnalyzer` are Vision work, metadata is
  ImageIO, and the watermark is CoreText.
- M5 changed no image, color, gamma, alpha, bit-depth, orientation or
  metadata code. The moved units do not read or write pixels.
- Because no renderer code changed, the golden corpus must be unchanged.
  The read-only gate confirms it (section 9).
- A future portable renderer is still unproven: Core Image's color
  management has no verified non-Apple equivalent in this repository. That
  is a future research item, not a claim of this milestone.

## 8. AI portability findings

- Transport is macOS-specific today: `AF_UNIX` sockets, `getsockopt` with the
  Darwin peer-PID option (`WorkerClient.swift:171-231`), `flock`
  (`LockFile.swift:73-118`), `posix_spawn` (`ChildProcess.swift:35-85`),
  `proc_pidinfo`/`proc_pidpath` (`ProcessIdentity.swift:32-36`).
- JSON-RPC framing (newline-delimited, 64 KiB reads) is duplicated in the
  worker client path; it is a candidate for a shared framing type, but M5
  did not touch transport to avoid changing a working AI path.
- `AIRuntime.package` is `nil` (`AIRuntime.swift:40`), so the v2 installer
  path remains dormant by design. M5 added no model, runtime or network
  behavior and makes no new AI-support claim.

## 9. Test results

All runs on the same Mac (Apple silicon), macOS 27.2, Command Line Tools
`swiftc`, SDK auto-probed by the harness.

| Gate | Arch | Result |
|---|---|---|
| `Tests/run-studiocore.sh` (boundary scan, independent build, core suite) | arm64 | PASS — `StudioCore: 201 checks passed` (13 added in M7), binary links only Foundation/StudioCore |
| `Tests/Conformance/run-conformance.sh` (read-only corpus gate) | architecture-neutral (Python) | PASS — 21 fixtures, 78 cases, 21 references, 11 exports, SHA-256 verified; no baseline regenerated |
| `RETOUCH_ARCH=arm64 Tests/run.sh` | arm64 | PASS — `StudioCore: 201 checks`, `ENGINE TESTS: PASS`, `MODEL TESTS: PASS`, `RUNTIME PROCESS TESTS: PASS`, `RUNTIME V2 TESTS: PASS` |
| `RETOUCH_ARCH=x86_64 Tests/run.sh` | x86_64 under Rosetta (supplementary, not native Intel) | PASS — `StudioCore: 201 checks`, `ENGINE TESTS: PASS`, `MODEL TESTS: PASS`, `RUNTIME PROCESS TESTS: PASS`, `RUNTIME V2 TESTS: PASS` |
| `Tests/run-corpus.sh` (golden image corpus) | arm64 | PASS — 376 checks, 0 failures, verified against `baselines.json` twice; the four exported files the harness rewrote were restored, not accepted as new baselines |
| `RETOUCH_ARCH=arm64 ./build.sh release` and `./build/bin/RetouchStudio --selftest` | arm64 | PASS — the app builds with `SelfCheck.swift` included and the headless self-test prints `SELFTEST: PASS` |
| `Tests/run-studiocore-linux.sh` | macOS smoke test only | PASS — 201 checks, toolchain target `arm64-apple-macosx27.2.0`; this is **not** a Linux run (section 13) |

The M7 core checks add: the v3 fixture decodes to portable geometry and
re-encodes byte for byte, the store writes exactly the codec's v3 bytes, a v3
file keeps a v3 write context, a v4 file keeps its version, unknown top-level
field and required feature, saving a read v4 document reproduces its bytes,
and read/write failures map onto `ProjectIOError` without touching the
previous file.

The Linux runner (`Tests/run-studiocore-linux.sh`) compiles and runs the same
201 checks without an SDK probe; it was exercised on the macOS host and now
prints the toolchain target triple, but no Linux runner has executed it, so no
Linux result is claimed here (section 13).

### 9.1 Rosetta result

The x86_64 column is a Rosetta run of the Intel slice on Apple silicon. It is
supplementary evidence and is never described as native Intel validation.
No Windows or Linux test exists.

### 9.2 What the suites prove and do not prove

They prove that the moved rules behave exactly as before on macOS and that
the core still builds and runs with only Foundation. They do not prove that
another platform's Foundation behaves identically, and they do not run a
non-Apple build.

## 10. Build results

`RETOUCH_ARCH=arm64 ./build.sh release` on the same host, re-run after M6:
PASS.

- SDK auto-probed by the script; target `arm64-apple-macosx14.0`.
- StudioCore built as a static library, app bundle assembled, and the shipped
  binary's headless check (`./build/bin/RetouchStudio --selftest`, which
  includes the project round-trip) prints `SELFTEST: PASS`.
- Warnings are pre-existing deprecations in Core Image kernels and unused
  notices; M5 and M6 introduced none.
- No signing or notarization step ran, and none is claimed.

## 11. Commits and branch

- Branch: `m5-cross-platform-core`, created from `9a5623a` and later
  synchronized with `main` by a normal merge.
- M5 commit(s): one reviewable commit containing the three core files, the
  three app-side integrations, the test additions and the `run.sh` wiring.
- M6 commit(s): `Sources/StudioCore/DocumentValue.swift`, the deletion of the
  app-side `DocumentState.swift`, the frozen v3 wire records in `Project.swift`,
  the `ProjectV4` collapse, the boundary conversions in the editor and
  renderers, the new core tests and the Linux runner. Exact SHAs are recorded
  in PR #5 and the delivery report, not here (a commit cannot contain its own
  hash).
- M7 commit(s): `Sources/StudioCore/ProjectDocument.swift`,
  `ProjectCodec.swift` and `ProjectIO.swift`; deletion of the three app-side
  project files; `Sources/RetouchStudio/Models/ProjectAdapters.swift`; the
  `EditorModel`, `Recovery`, `RecoveryPolicy`, `DocumentRestoration` and
  `SelfCheck` call-site changes; the M7 core tests; the Linux runner target
  check; and this document.
- No rebase, no amend, no force push, no reset.

## 12. Pull request

PR #5: head `m5-cross-platform-core` → base `main`. It was opened against
PR #4's head while that PR was unmerged, then retargeted to `main` after PR #4
merged, and the branch was brought up to date with a normal merge of `main`
(no rebase, reset or force push). Required checks are the three jobs in
`.github/workflows/ci.yml` (`StudioCore Boundary`, `Platform-neutral
Conformance`, `macOS Integration`). The `Tests/run-studiocore-linux.sh` runner
is in the branch, but wiring it into the workflow needs a credential with the
GitHub `workflow` scope; the repository's current token does not have it, so
the job was not added and no Linux claim is made. PR #5 is not merged by this
milestone.

## 13. Risks and limitations

- **No Windows/Linux build.** Nothing here is compiled, linked or tested on
  a non-Apple platform. The shared core is Foundation-only, which is a
  portability property, not proof that another platform builds it.
- **Generic history init.** `DocumentHistory` takes its initial state
  explicitly; the app adds a convenience `init()` constrained to
  `DocumentState`. A future platform must supply its own initial state.
- **Ports are only three.** Project bytes, file existence and bookmarks are
  separated; HTTP, image decoding and process supervision are not.
- **v3 remains CoreGraphics-shaped on the wire.** The in-memory values are
  portable since M6, but `RetouchProject` still converts through the frozen
  `WirePoint`/`WireRect`/`*Wire` records to keep old file bytes. Every future
  field must be added to both the value and the wire record; the fixture
  byte-identity test and the self-test round trip are the guard, and they only
  cover what they exercise.
- **Unknown fields are preserved at the top level only.** `ProjectWriteContext`
  re-emits unknown top-level keys and required features byte-for-byte; an
  unknown key nested inside a known object is dropped on re-save, and fixing
  that would change the format. The v4 fixture and the round-trip tests cover
  the top-level contract.
- **No Linux run yet.** `Tests/run-studiocore-linux.sh` compiles the module and
  runs its tests without an SDK probe, now prints the toolchain target triple,
  and was smoke-tested on the macOS host, but no Linux runner has executed it.
  Wiring it into `.github/workflows/ci.yml` requires a token with the
  `workflow` scope, which this checkout does not have. Linux coverage is
  therefore a prepared runner, not evidence.
- **The boundary gate is textual.** It scans imports and type names; it
  cannot prove that a Foundation API behaves the same on another platform.
- **Rosetta is not Intel.** The x86_64 run exercises translation, not native
  Intel hardware.

## 14. Prioritized Windows/Linux roadmap

1. ~~Make the boundary gate a first-class CI job.~~ Done for macOS: `StudioCore
   Boundary` and `Platform-neutral Conformance` are required checks on `main`.
   `Tests/run-studiocore-linux.sh` is ready, but adding its job needs a token
   with the GitHub `workflow` scope; until then no Linux run exists.
2. ~~Extract the document value itself.~~ Done in M6 (section 5.1): the value
   types and `DocumentState` live in StudioCore, with the v3 wire records
   frozen at the codec boundary.
3. ~~Extract project reading/writing behind the shared ports.~~ Done in M7
   (section 5.2): the model, codec and store live in StudioCore and the file,
   bookmark and content-type adapters stay on the host. The next step is
   running the Linux file round-trip on a real Linux runner; the runner exists
   but has not executed there.
4. Define a renderer interface and prove it with the existing canonical
   fixtures before choosing a backend; do not assume Core Image parity.
5. Port the AI transport seam (newline framing and peer identity) behind a
   protocol, keeping the macOS implementation.
6. Only after 1–5: a Windows/Linux shell prototype against the shared core.
   UI work and engine parity are separate, later decisions.
