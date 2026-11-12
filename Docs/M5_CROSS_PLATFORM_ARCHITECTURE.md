# M5 — Cross-Platform Core Independence

**Branch:** `m5-cross-platform-core`
**Base:** `9a5623a` (head of PR #4, `v1-macos-delivery`)
**Date:** 2026-11-12
**Stacked PR:** targets `v1-macos-delivery`, not `main`
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

PR #3 (R4) is already merged as `a5ceb9b`; PR #4 is the open V1 PR and stays
unmerged in M5.

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

After M5:

```text
StudioCore (Foundation only, still one import)
  Adjustments, Makeup, MakeupColor, UserPreset
  geometry types and coordinate spaces
  DocumentHistory<State: HistoryState>       (new)
  RecoveryRules                              (new)
  ProjectSourceAccess, ProjectBookmarkStore  (new ports)

App model layer
  DocumentState (unchanged value, now conforms to HistoryState)
  DocumentSession = DocumentHistory<DocumentState>   (typealias)
  RecoveryPolicy (delegates name/date rules; keeps snapshot rules)
  ProjectCodec (imports StudioCore; adapters stay here)
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

## 6. What remains macOS-specific

These are deliberate boundaries, not unfinished moves:

| Area | Why it stays on macOS | Evidence |
|---|---|---|
| `DocumentState` | Holds `CGRect?` and app-owned `HealSpot`, `Sticker`, `AIEdit`, `AnalysisSettings`; moving it now would change field identity without a portability win. | `Sources/RetouchStudio/Models/DocumentState.swift:12-21` |
| `ProjectCodec`, `ProjectV4`, `Project` | v3 JSON is CoreGraphics' unkeyed encoding; v4 uses portable geometry but is file-only. Changing the v3 types would change existing file bytes. | `Sources/RetouchStudio/Models/ProjectCodec.swift:1-16`, `Docs/STUDIOCORE_R4_8_PROJECT_V4.md` |
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
| `Tests/run-studiocore.sh` (boundary scan, independent build, core suite) | arm64 | PASS — `StudioCore: 154 checks passed` (36 new), binary links only Foundation/StudioCore |
| `Tests/Conformance/run-conformance.sh` (read-only corpus gate) | architecture-neutral (Python) | PASS — 21 fixtures, 78 cases, 21 references, 11 exports, SHA-256 verified; no baseline regenerated |
| `RETOUCH_ARCH=arm64 Tests/run.sh` | arm64 | PASS — `StudioCore: 154 checks`, `ENGINE TESTS: PASS`, `MODEL TESTS: PASS`, `RUNTIME PROCESS TESTS: PASS`, `RUNTIME V2 TESTS: PASS` |
| `RETOUCH_ARCH=x86_64 Tests/run.sh` | x86_64 under Rosetta (supplementary, not native Intel) | PASS — `StudioCore: 154 checks`, `ENGINE TESTS: PASS`, `MODEL TESTS: PASS`, `RUNTIME PROCESS TESTS: PASS`, `RUNTIME V2 TESTS: PASS` |

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

`RETOUCH_ARCH=arm64 ./build.sh release` on the same host: PASS.

- SDK probed by the script: `MacOSX26.5.sdk`; target `arm64-apple-macosx14.0`.
- StudioCore built as a static library, app bundle assembled, engine
  self-test passed (`✓ خودآزمون پردازش پاس شد`), bundle
  `Retouch Studio.app` version `1.0.0 (1)`.
- Warnings are pre-existing deprecations in Core Image kernels and three
  unused-value notices; M5 introduced none.
- No signing or notarization step ran, and none is claimed.

## 11. Commits and branch

- Branch: `m5-cross-platform-core`, created from `9a5623a`.
- M5 commit(s): one reviewable commit containing the three core files, the
  three app-side integrations, the test additions and the `run.sh` wiring.
  The exact SHA is recorded in the PR and the delivery report, not in this
  file (a commit cannot contain its own hash).
- No rebase, no amend, no force push, no reset.

## 12. Pull request

Stacked PR: head `m5-cross-platform-core` → base `v1-macos-delivery`
(PR #4's head), because PR #4 is unmerged. PR #4 itself is untouched and
remains unmerged. The M5 PR is not merged by this milestone.

## 13. Risks and limitations

- **No Windows/Linux build.** Nothing here is compiled, linked or tested on
  a non-Apple platform. The shared core is Foundation-only, which is a
  portability property, not proof that another platform builds it.
- **Generic history init.** `DocumentHistory` takes its initial state
  explicitly; the app adds a convenience `init()` constrained to
  `DocumentState`. A future platform must supply its own initial state.
- **Ports are only two.** File existence and bookmarks are separated; HTTP,
  image decoding and process supervision are not.
- **v3 remains CoreGraphics-shaped.** The portable geometry is used for v4
  files only. Any future migration must keep the v3 bytes stable or ship a
  migration with fixtures.
- **The boundary gate is textual.** It scans imports and type names; it
  cannot prove that a Foundation API behaves the same on another platform.
- **Rosetta is not Intel.** The x86_64 run exercises translation, not native
  Intel hardware.

## 14. Prioritized Windows/Linux roadmap

1. Make the boundary gate a first-class CI job (the script already exists;
   wiring it into `run.sh` is done, CI is still not configured).
2. Extract the document value itself: make `HealSpot`, `Sticker`, `AIEdit`
   and `AnalysisSettings` portable or define portable mirrors with explicit
   boundary conversion, then move `DocumentState`.
3. Extract project reading/writing behind the shared ports, keeping v3 bytes
   frozen and v4 as the portable shape.
4. Define a renderer interface and prove it with the existing canonical
   fixtures before choosing a backend; do not assume Core Image parity.
5. Port the AI transport seam (newline framing and peer identity) behind a
   protocol, keeping the macOS implementation.
6. Only after 1–5: a Windows/Linux shell prototype against the shared core.
   UI work and engine parity are separate, later decisions.
