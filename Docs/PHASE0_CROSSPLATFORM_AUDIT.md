# Phase Zero — Cross-Platform Architecture Audit (Refresh)

**Project:** Retouch Studio
**Repository:** `iR0ham/RetouchStudio`
**Branch / commit:** `main` at `01da9005663127a513dae704785243f5b5ec8fab` — the merge commit of PR #1, *Stabilization: runtime lifecycle, privacy, batch and recovery reliability*. Merge parents: `2d0affc4b23943f110cb0a2b626462f3ed282763` and `405ae2eea90cde785961254fe0a156555c96a02d`.
**Audit date:** 2026-11-11
**Supersedes:** the Phase 0 audit dated 2026-11-09, taken at `stabilization` / `5d8642f`.
**Mode:** strictly read-only. No source file, test, build script or project file was changed. No dependency was installed, no runtime or model was downloaded, no branch or commit was created, nothing was pushed, and no PR metadata was modified. The only file changed by this refresh is this document.
**Evidence rule:** every important statement is labelled **VERIFIED** (read in this tree or reproduced by a command at this commit), **PARTIAL**, **NOT REPRODUCED**, **UNVERIFIED**, or **ASSUMPTION**. Line numbers refer to `01da900`, not to older documents.

---

## 0. Required item 2 — Executive summary

1. **The repository is in the expected post-merge state.** Local `main`, `origin/main` and the merge commit are all `01da9005663127a513dae704785243f5b5ec8fab`; the working tree was clean before this document was written. **VERIFIED.**
2. **Every reported P0/P1 defect now has a tested disposition:** six are **FIXED**, one is **PARTIALLY FIXED**, one is **NOT REPRODUCED**, and none is **OPEN**. The 2026-11-09 statuses are superseded. **VERIFIED** against implementation and tests, not commit messages.
3. **The stabilization work is real and load-bearing.** Recovery is now an immutable candidate store with an explicit readiness barrier; the runtime installer is a staged, validated, rollback-capable transaction; metadata privacy uses an allowlist; batch export derives per-file snapshots and cancels the file in flight; a failed open preserves the current document; exports refuse the source and every alias.
4. **The product is still a macOS application, and the architecture has not become portable.** It is 78 Swift files / 36,653 lines; the editable document object is 3,518 lines with 92 `@Published` properties; the image layer is 17,433 lines bound to Core Image and Vision; the project file still stores an absolute path plus an Apple bookmark.
5. **Cross-platform delivery still requires extraction and new shells, not recompilation.** The macOS app must remain the quality reference. A Windows or Linux claim cannot be made from this audit: no such hardware was used.
6. **Seven genuine blockers remain:** the EditorModel/UI god object, the missing Core/Models boundary, Apple geometry and bookmarks in the project format, the Core Image/Vision image engine, the external Python AI runtime, the macOS-only build/test path, and the absence of off-macOS testability.
7. **The next architecture milestone must be a design deliverable, not a rewrite.** Recommended milestone: a 4–8 person-week portability design package (interfaces, frozen corpus, one kernel prototype, one UI/color prototype), with no shipping code replaced.
8. **The remaining cross-platform effort is estimated at 122–188 person-weeks (±40%)**, including near-term macOS hardening, corpus work, core extraction, one engine prototype, project v4, Windows, Linux, AI unification and Pro UI. This is a planning range, not a commitment.
9. **The runtime installer is implemented but disabled in this build.** `AIRuntime.package` is `nil`, so no download is offered; the transaction code is exercised only by tests and a real-runtime test that is skipped unless explicitly enabled. **VERIFIED.**
10. **No Windows/Linux compatibility, no native Intel validation, and no published-runtime validation is claimed.** Intel evidence in this document is from Rosetta on Apple silicon.

**Nothing here authorizes implementation. Phase 0 ends with an approval request.**

---

## 1. Required item 1 — Audit date, exact HEAD, and repository state

| Check | Result | Evidence |
|---|---|---|
| Audit date | 2026-11-11 | this document |
| Branch | `main` | `git branch --show-current` |
| Local HEAD | `01da9005663127a513dae704785243f5b5ec8fab` | `git rev-parse HEAD` |
| Remote `origin/main` | same SHA | `git rev-parse origin/main` |
| Merge commit | `01da900` with parents `2d0affc` and `405ae2e` | `git rev-list --parents -n 1 HEAD` |
| Commit subject | `Merge pull request #1 from iR0ham/stabilization` | `git log -1` |
| Working tree before this audit | clean | `git status --short` (empty) |
| PR #1 | merged; merge SHA is HEAD | `gh pr view` in the prior session; merge commit present locally |
| Source changes in this audit | none | only this document written |

**Method.** Inspected the current tree, the four test suites, the recovery and runtime transaction code, the build script and the bundled helper. Ran the suite natively (arm64) and under Rosetta (`RETOUCH_ARCH=x86_64`). Did not run the UI, did not install dependencies, did not download the AI runtime or model weights, and did not modify source.

---

## 2. Required item 3 — Previous P0/P1 status table

The 2026-11-09 register is replaced by the following. A status is assigned only from implementation plus tests at `01da900`.

| ID | Title | Previous (2026-11-09) | Current (2026-11-11) | Primary evidence at `01da900` | Regression tests |
|---|---|---|---|---|---|
| P0-01 | Recovery data deleted on cancel | VERIFIED | **FIXED** | `Recovery.swift:181–232, 270–308`; `EditorModel.swift:2668, 2694` | `M1-R0`…`M1-R21`, `M1-R15` |
| P0-02 | Export can overwrite the original | VERIFIED | **FIXED** | `EditorModel.swift:3054, 3084`; `ExportService.swift:363, 382, 404` | `M1-X`, `M1-B` |
| P0-03 | Runtime install deletes the old copy before the new one is in place | VERIFIED | **FIXED** | `AIRuntimeTransaction.swift:162, 221, 273, 404, 536` | `M1-AI`, `M1-AI2`, `M1-AI3`, `M1-AI4` |
| P0-04 | Privacy strip is incomplete | PARTIAL | **FIXED** | `ImageProcessor.swift:1204–1225` | Engine privacy fixtures, including XMP |
| P0-05 | Batch analysis/stamps can leak across photos | PARTIAL | **PARTIALLY FIXED** | `BatchExportPolicy.swift:12–43`; `EditorModel.swift:77–78` | `P0-4`, `P1-1`, `P1-1b` |
| P0-06 | Model download total is per-file | NOT REPRODUCED | **NOT REPRODUCED** | `ModelManager.swift:61, 177, 209`; `Docs/worker-regressions/test_two_file_download_progress.py:112` | manual worker regression (not in the 840-check suite) |
| P1-07 | Failed load changes title/export name | VERIFIED | **FIXED** | `EditorModel.swift:1003, 1042–1043` | `M1-L` |
| P1-08 | Batch cancel does not stop the running file | PARTIAL | **FIXED** | `EditorModel.swift:3315–3319, 3341–3342, 3437, 3450, 3471, 3476` | `P1-8` (two tests) |

Counts: **6 FIXED, 1 PARTIALLY FIXED, 1 NOT REPRODUCED, 0 OPEN, 0 UNVERIFIED.**

### 2.1 P0-01 — Recovery cancel semantics: FIXED

**Implementation.** Recovery no longer has a single mutable session file that an alert can delete. `RecoveryStore` keeps a mutable `working` slot and immutable `candidates/<millis>-<UUID>.retouch` files (`Recovery.swift:122, 236, 250, 270, 279`). `prepareForLaunch()` classifies the working copy and candidates, quarantines damaged files, and sets a lock when the working copy must be preserved (`Recovery.swift:181–232`). A cancel, Escape, or a closed Locate panel returns `.stop` without deleting the candidate; only the explicit Discard path calls `discardRecoveryCandidate`. In the missing-source prompt, a cancelled Locate panel is explicitly not permission to delete the edit (`EditorModel.swift`, `offerRecoveryCandidate`).

**Tests.** `M1-R0` (Escape and Cancel never delete), `M1-R1`…`M1-R5` (restore one candidate without losing another; Cancel while a third document autosaves; missing source; located photo restores only after Restore), `M1-R6`…`M1-R14` (failed writes, failed deletes, failed promotion, damaged candidate quarantine, changed source, unfinished working copy), `M1-R16`…`M1-R19` (restore cannot evict the live document; external opens promote exactly once), `M1-R20`/`M1-R21` (autosave invalidation), `M1-R15` (the suite never writes the production recovery tree).

**Residual.** Durability is still `Data.write(.atomic)` plus a read-back byte comparison, with no `fsync` (`Recovery.swift:390–405`). This is recorded as debt D15, not as an open P0.

### 2.2 P0-02 — Export over the original: FIXED

**Implementation.** `export(to:)` refuses the destination before rendering when it resolves to the opened photo (`EditorModel.swift:3054`). `ExportService` checks again immediately before the atomic replace, closing the window in which the destination could be relinked to the source during the render (`ExportService.swift:363, 382`). `referencesSameFile` compares resolved paths, device/inode identity, and a case-insensitive fallback (`ExportService.swift:404`). Batch export passes each file's own URL as the protected source (`EditorModel.swift:3483`), so batch naming cannot overwrite an input.

**Tests.** `M1-X` covers the source path, symlink and alias refusal; `M1-B` covers batch output that would collide with a source; the older `P0-1` test confirms an export is a copy, not a saved project.

### 2.3 P0-03 — Transactional runtime installation: FIXED (code path disabled in production)

**Implementation.** `AIRuntimeTransaction` implements a state machine: `preparing` → `swapping` → `committed` (`AIRuntimeTransaction.swift:404–523`). It extracts into a staging directory, runs structural and functional validation, records the transaction, moves the old runtime to a backup, moves staging live, validates the live copy, writes the commit marker, and only then removes backup and staging. Failures roll back (`:536`); launch recovery classifies interrupted states (`:221, 273`). The old "delete then move" sequence no longer exists.

**Tests.** `M1-AI` (transactional install and failure injection), `M1-AI2` (damaged marker and symlink escape), `M1-AI3` (failed recovery retried, good recovery cached, AI waits), `M1-AI4` (concurrent installs serialize on one lock). `M1-AI-R` is skipped unless `RETOUCH_REAL_RUNTIME=1`, because no real runtime is installed in this environment.

**Important qualification.** `AIRuntime.package` returns `nil` (`AIRuntime.swift:40`). No protocol-v2 archive URL, byte count or hash is configured, so the installer is not reachable in this build and the UI reports AI as unavailable. The fix is verified in code and tests; it is not verified against a published runtime.

### 2.4 P0-04 — Metadata privacy: FIXED

**Implementation.** The blacklist was replaced by an allowlist (`ImageProcessor.swift:1204–1225`). The output property dictionary starts empty and copies only DPI width/height, the three TIFF resolution keys, and orientation `1` (the pixels are already upright). GPS, EXIF identity, IPTC, XMP, maker notes, camera make/model, serials and unknown dictionaries are not copied unless a future explicit decision adds them.

**Tests.** The engine privacy section (`Tests/EngineTests.swift:1013` onward) builds a fixture with GPS, EXIF, TIFF, IPTC and XMP data and checks the written files, with an XMP negative assertion and a positive control that can read XMP when present (`:1089, 1104`). The old audit's statement that XMP survival was "unverified" is **superseded**: it is now a fixture assertion.

### 2.5 P0-05 — Batch isolation: PARTIALLY FIXED

**Implementation.** `BatchExportPolicy.snapshot` (`BatchExportPolicy.swift:12`) returns the edited document's snapshot unchanged for the document's own file (`:22`). For every other file it:
- keeps the crop only when the document shares the file's unturned frame and the crop applies to the file's aspect (`:27–33`);
- clears AI edits and orientation (`:37–38`);
- clears the selected face and resets analysis endpoint and anchor coordinates (`:40–42`).

Batch defaults keep stamps and analysis overlays off (`EditorModel.swift:77–78`), so the default path is safe. Tests `P0-4`, `P1-1` and `P1-1b` cover shared settings, different image shapes, and a turned document.

**Why not FIXED.** When the owner explicitly enables `batchIncludeStamps`, the document's `healSpots` and `stickers` still travel to every file. They are pixel-space edits made for one photo and are not adapted to another. This is an intentional opt-in product behavior, but it is still document-specific data applied across photos. Analysis label style and content remain shared by design; only coordinates are reset. Closing this would require a product decision (disable stamps for non-document files, or define a per-file placement policy), not just a code change.

### 2.6 P0-06 — Model download total: NOT REPRODUCED

**Evidence.** `ModelManager.plan.totalBytes` is the plan-wide total (`ModelManager.swift:177`). `consume` adds the cumulative `offset` from the worker to the current file's received bytes and keeps the plan total as the denominator (`:209`). When no total is known, the UI reports indeterminate progress instead of inventing a denominator (`:61`). The worker regression (`Docs/worker-regressions/test_two_file_download_progress.py:112`) asserts that a two-file plan reports `total_bytes` as the sum of both files.

**Qualification.** The published 1.0.0 runtime archive was not downloaded; the legacy archive is documented as 388,277,063 bytes in `Docs/AI_RUNTIME.md:19`, but it is not a compatible protocol-v2 package and the installer is disabled. The repo's worker regression is manual and is not part of the 840-check Swift suite. The bug is not reproduced against the inspected code.

### 2.7 P1-07 — Failed load identity: FIXED

**Implementation.** `load` no longer assigns the incoming file name before decoding. `imageName` and `imageURL` are assigned only from a successful result (`EditorModel.swift:1042–1043`); failure sets `.couldNotRead` (`:1003`) and leaves the current document's title, URL and suggested export name untouched. Test `M1-L` opens A, attempts an unreadable B, and asserts that the document still describes A.

### 2.8 P1-08 — Batch cancellation: FIXED

**Implementation.** `cancelBatchExport` cancels both the batch loop and the detached file task (`EditorModel.swift:3315–3319`); the current file task is stored by reference (`:3341–3342`) and cancelled by name because it does not inherit the parent's cancellation. `exportOne` checks cancellation before loading, before rendering, before the write hook, and immediately before the write (`:3437, 3450, 3471, 3476`). Tests `P1-8` (cancel stops the file in flight before it writes) and `P1-8` (a failed write is not counted as saved) pass.

### 2.9 Findings that are now superseded

| Old statement | Disposition |
|---|---|
| P0-01…P1-08 statuses in the 2026-11-09 register | **Superseded** by §2; do not reuse. |
| "69 Swift files, 31,788 lines" | **Superseded**: 78 files, 36,653 lines. |
| "EditorModel 3,135 lines" | **Superseded**: 3,518 lines. |
| "Views 18 files, 7,455 lines" | **Superseded**: 20 files, 7,463 lines. |
| "Core 13,458 lines; Models 10,575" | **Superseded**: Core 17,433; Models 11,457. |
| "Imports Foundation 47, CoreGraphics 27" | **Superseded**: Foundation 56, CoreGraphics 28. |
| "336 assertions" | **Superseded**: 840 checks at this commit. |
| "Metadata privacy is a blacklist (D8)" | **Resolved**: allowlist implemented; D8 closed. |
| "XMP survival is unverified" | **Superseded**: fixture-tested. |
| "388,277,063-byte archive declared in `AIRuntime.swift`" | **Superseded/stale**: current code has no package metadata; the figure is documented only as a legacy release asset. |
| "Milestone 1 (data-integrity fixes) is the recommended next change" | **Completed**: commit `405ae2e`, merged as `01da900`. |
| "Localization has 471 strings" | **Superseded**: 482 base properties and 482 Persian overrides. |
| "P0-05 default path safe, opt-in path not" | **Partly superseded**: coordinates are now reset; opt-in stamps remain document-specific. |

---

## 3. Required item 4 — Updated architecture measurements

Measured at `01da900`; none of the previous counts were reused. Every value in this section is **VERIFIED** by a direct `find`, `wc`, `grep` or `du` command at this commit; the instrument is named beside each table.

### 3.1 Source inventory

| Area | Files | Lines |
|---|---:|---:|
| `Sources/RetouchStudio/Core/` | 28 | 17,433 |
| `Sources/RetouchStudio/Models/` | 29 | 11,457 |
| `Sources/RetouchStudio/Views/` | 20 | 7,463 |
| `Sources/RetouchStudio/App.swift` | 1 | 300 |
| **Total `Sources/`** | **78** | **36,653** |

Test code: 4 suites, 7,467 lines (`EngineTests` 1,604; `ModelTests` 4,231; `RuntimeProcessTests` 914; `RuntimeV2Tests` 718).

### 3.2 Editor and UI coupling

| Measure | Value | Evidence |
|---|---:|---|
| `EditorModel.swift` lines | 3,518 | `wc -l` |
| `@Published` properties | 92 | `grep -c '@Published'` |
| Lines containing an `NS*` AppKit symbol in `EditorModel` | 38 | `grep -cE '\bNS[A-Z]'` |
| `@ObservedObject` injections in `Views/` | 22 | `grep -r` |
| `@EnvironmentObject` injections in `Views/` | 0 | `grep -r` |
| View files | 20 | `find Views` |
| Accessibility modifiers in `Views/` | 16 | `grep -r accessibility` |

The model is passed explicitly into 22 view sites. There is no environment-object indirection; every view that needs editing state observes the same large object.

### 3.3 Framework imports

| Framework | Files importing it | Portability |
|---|---:|---|
| Foundation | 56 | Mostly portable; process/socket/file APIs need adapters |
| CoreGraphics | 28 | Geometry and bitmap types must be replaced |
| SwiftUI | 24 | macOS shell only |
| CoreImage | 19 | No direct portable equivalent; needs a new engine |
| AppKit | 14 | Platform shell/adapters only |
| Darwin | 10 | POSIX locks, signals, process identity |
| UniformTypeIdentifiers | 6 | MIME/extension registry |
| ImageIO | 6 | WIC / libheif / libvips |
| Vision | 2 | ONNX or platform ML |
| Combine | 2 | Swift-only plumbing |
| CryptoKit | 1 | RustCrypto/OpenSSL |
| CoreVideo | 1 | Engine buffer type |
| CoreText | 1 | DirectWrite/HarfBuzz |

Core Image is still the image engine. Vision remains inside the image layer for face, segmentation and pose data. The test suite compiles every source except `App.swift` and `SelfCheck.swift`, so any new AppKit/SwiftUI import in a core file breaks off-macOS testability.

### 3.4 Build, test and distribution

| Concern | Current state | Evidence |
|---|---|---|
| Build system | Direct `swiftc -O`, WMO; `Package.swift` is not the shipping build | `build.sh`; 13-line manifest |
| Architectures | arm64, x86_64, universal via `lipo` | `build.sh:71` |
| Signing | Ad-hoc `codesign --force --sign -`; no notarization | `build.sh:160` |
| Self-test | Native plus Intel slice through Rosetta | `build.sh:164, 179` |
| Tests | Four compiled executables; custom harness; 840 checks at this commit | `Tests/run.sh` |
| CI | None; `.github` absent | `ls -d .github` |
| Coverage | No line/branch coverage instrumentation | harness prints check counts only |
| Light app | README states about 3.5–4 MB | README |
| App with helper | 1.3 GB measured | `du -sh "Retouch Studio.app"` |
| Worker source | Not in this repository | no `worker/` directory |

### 3.5 Project format and platform dependencies

`RetouchProject.currentVersion` is 3 (`Project.swift:11`). It is a single JSON sidecar with:
- absolute `imagePath` (`:21`);
- Apple bookmark `Data` (`:24`);
- `CGRect` crop and `CGPoint` analysis endpoints/anchors;
- adjustments, heal spots, stickers, AI edits, analysis settings and selected face;
- atomic write and hand-written decoding with defaults for older versions.

The format is non-destructive and migration-aware, but it is not portable: the source location and every geometric type are Apple-specific.

### 3.6 Localization and accessibility

- `Localization.swift`: 482 string properties; `PersianL10n.swift`: 482 overrides. The key sets match structurally, but there is no parity test. A missing override falls back silently.
- 16 `accessibility*` occurrences across 7,463 lines of view code. This is not an accessibility baseline for either future shell.

### 3.7 AI runtime packaging

- The worker is an external Python process reached over `AF_UNIX` and JSON-RPC; Python source is not in the repository.
- The current local `.app` contains `Contents/Resources/Worker` and measures 1.3 GB (`du -sh` on the Worker directory itself: 1.3 GB).
- The protocol-v2 installer exists but is disabled: `AIRuntime.package` is `nil` (`AIRuntime.swift:40`); install directory is `AI/runtimes/protocol-v2` (`:47`); a backup directory is reserved (`:50`).
- The legacy 1.0.0 archive is documented as 388,277,063 bytes and explicitly not compatible (`Docs/AI_RUNTIME.md:19`); it was not downloaded in this audit.
- Intel builds deliberately have no AI path; the editor, analysis and export work.

---

## 4. Required item 5 — Remaining technical debt

Status at this commit. D8 is closed; D15 and D16 are new or newly precise.

| # | Debt | Status | Evidence / consequence |
|---|---|---|---|
| D1 | `EditorModel` is a 3,518-line god object with 92 `@Published` fields | Open, worse than 2026-11-09 | Every shell and feature touches one file; high regression and merge risk |
| D2 | No enforced module boundary between Core and Models | Open | Core imports document types; the engine cannot compile without the app model |
| D3 | AppKit inside the model | Open; 38 lines with `NS*` symbols | Business logic is not headless and not portable |
| D4 | UI is 7,463 lines of SwiftUI | Open | A second UI must be built for Windows/Linux |
| D5 | Image engine is 17,433 lines tied to Core Image/Vision | Open, larger than before | The product's core value is the least portable layer |
| D6 | Python AI runtime is external and large | Open | Reproducibility, auditability, Windows/Linux story, 1.3 GB bundle |
| D7 | Absolute source path + Apple bookmark in project v3 | Open | Projects break when moved across machines/platforms |
| D8 | Metadata privacy was a blacklist | **Closed** | Allowlist at `ImageProcessor.swift:1204`; fixtures pass |
| D9 | No CI | Open | Quality depends on manual local runs; no platform matrix |
| D10 | Localization parity is unenforced | Open; 482/482 today | A forgotten Persian key falls back silently |
| D11 | Accessibility is sparse | Open; 16 modifiers | Both future shells need a baseline |
| D12 | Ad-hoc, unsandboxed distribution | Open | Gatekeeper/security expectations and store distribution unmet |
| D13 | Test harness compiles the whole app | Open | Platform-specific imports block off-macOS testing |
| D14 | Older audit docs contain stale line numbers and claims | Open | `Docs/TECHNICAL_AUDIT.md` still audits `8cc2d0c`; superseded claims are mapped here |
| D15 | Recovery writes are atomic but not fsynced | Open | Read-back proves content, not power-loss durability (`Recovery.swift:390`) |
| D16 | Batch opt-in stamps are document-specific | Open, product decision | `healSpots`/`stickers` apply to other photos when `batchIncludeStamps` is on |

---

## 5. Genuine architectural blockers versus ordinary debt

These are the items that must change before a second platform shell can share this product. Ordinary debt does not block portability and should be scheduled separately.

### 5.1 Genuine blockers

| ID | Blocker | Why it blocks portability | What must be designed |
|---|---|---|---|
| B1 | EditorModel/UI coupling | A 3,518-line main-actor object with 92 published fields cannot be reused or tested without SwiftUI/AppKit | Command/query document API; feature modules; observable view-model boundary |
| B2 | No Core/Models boundary | Core engines depend on `Adjustments`, `Project`, `HealSpot`, `AnalysisSettings`; Models call concrete Core types | A shared document/operation model and engine protocols |
| B3 | Apple geometry and bookmarks in the project format | `CGRect`, `CGPoint` and bookmarks are not portable or stable across platforms | Owned value types; relative paths; content hashes; platform-only extension block |
| B4 | Core Image/Vision image engine | 19 files use Core Image; Vision supplies face/segmentation/pose | Portable engine contract; CPU reference path; GPU backend; golden corpus |
| B5 | External Python AI runtime | No worker source in repo; 1.3 GB bundled helper; installer disabled; no compatible package | Model manifest, inference contract, runtime distribution, provenance |
| B6 | macOS-only build and distribution | Direct `swiftc`, `lipo`, ad-hoc signing, no CI, no Windows/Linux toolchain | Reproducible build, CI matrix, per-platform packaging and signing |
| B7 | No off-macOS testability | Tests compile the whole app except two files; core files import AppKit | A platform-neutral core test target and fakes for file/dialog/IPC adapters |

### 5.2 Ordinary debt (does not require architecture change)

D9 (CI), D10 (localization parity), D11 (accessibility), D12 (signing/notarization), D14 (stale docs), D15 (`fsync`), D16 (batch stamp policy), plus performance measurement and the missing published-runtime validation. These should be scheduled in the near-term macOS track, not folded into the portability design.

### 5.3 What should not be rewritten

The working Core Image pipeline, the analysis renderer, the export renderer and the tested recovery/runtime transaction logic are product assets. They should be characterized, wrapped and ported behind contracts. Rewriting them first would throw away the only quality reference the project has.

---

## 6. Required item 6 — Revised Rust / C++ / Swift evaluation

Classifications: **Confirmed recommendation**, **Needs a technical prototype**, **Needs more research**, **Not recommended**.

| Option | Classification | Rationale at this commit |
|---|---|---|
| Rust for `StudioCore` (document model, operations, project format, export policy, recovery/runtime transaction policy) | **Confirmed recommendation** | Pure data/logic; testable without UI or GPU; strong memory safety for code that handles user originals; stable C ABI for Swift and Qt. The API boundary still needs a design, not a prototype of the language choice. |
| Rust for the portable image engine (`wgpu` + deterministic CPU tier) | **Needs a technical prototype** | The engine must reproduce 36,653 lines of Core Image/Vision behavior. No prototype exists. A single-kernel parity spike (skin, heal or warp) is required before committing. |
| Swift for the macOS shell and the reference backend | **Confirmed recommendation** | It is the working product; keeping it preserves quality reference and delivery. |
| C++ for engine and shell | **Not recommended** | The imaging ecosystem is strong, but memory-safety risk in a photo editor that writes user originals is a poor trade. Keep C++ only if the team already has deep Qt/OpenCV/LibRaw expertise. |
| Swift on Windows/Linux as the sole language | **Not recommended** | No production-grade SwiftUI/AppKit equivalent; Apple-centric imaging; immature off-macOS toolchain. A second UI would still be required. |

**Why this changed from 2026-11-09.** The previous audit recommended Rust broadly. After measuring the stabilized tree, the low-risk part (core logic) and the high-risk part (pixel parity) must be separated. The core choice is sound; the engine choice is not yet evidenced.

---

## 7. Required item 7 — Revised UI framework evaluation

| Framework | macOS | Windows | Linux | Classification for this product |
|---|---|---|---|---|
| SwiftUI + AppKit | Native, current | No | No | **Confirmed recommendation** for the macOS shell |
| Qt 6 / QML | Good | Native-quality | Native-quality | **Needs a technical prototype** for Windows/Linux: RTL/Persian shaping, IME, tablet events, color management, GPU interop, licensing |
| Flutter | Good | Good | Good | **Not recommended** for a color-managed pro editor: plugin/text/IME/color gaps |
| Tauri + web UI | Good | Good | Good | **Not recommended**: WebView color/performance/memory risk for pixel-accurate editing |
| Avalonia (.NET) | Good | Good | Good | **Needs more research** only if the team chooses .NET; adds a third runtime |
| Slint | Good | Good | Good | **Not recommended** now: ecosystem/accessibility maturity |
| Electron | Good | Good | Good | **Not recommended**: memory, color management, bundle size |

**Hard requirements for the prototype.** Persian/Arabic shaping and bidi, IME composition, menu shortcuts, tablet pressure, font fallback (Vazir), ICC-aware display, and a GPU surface that can host the engine's output. A Qt prototype that only draws a rectangle does not retire these risks.

**Simple/Pro.** Treat them as two presentations of one document API. History, workspaces, batch recipes and soft proof belong in the shell/core, not in image kernels.

---

## 8. Required item 8 — Revised AI architecture

### 8.1 Current state (VERIFIED)

- A separate Python process over `AF_UNIX` and JSON-RPC.
- The worker source is not in this repository; the local bundle contains a 1.3 GB `Worker` directory.
- The protocol-v2 installer is implemented with a staged transaction, but `AIRuntime.package` is `nil`, so it is disabled. No URL, size or hash is current in code.
- The legacy 1.0.0 arm64 archive is documented as 388,277,063 bytes and is not treated as compatible.
- Model weights are not in the repository or the app; downloads require explicit consent and are hash-verified by the worker.
- Intel builds have no AI path.

### 8.2 Recommended target

1. **Keep the Python worker for the near term.** It is the only working AI path and should not be replaced during portability design. **Confirmed recommendation.**
2. **Define a platform-neutral inference contract** (request/response schema, tensor layout, tiling, cancellation, provenance) before choosing an inference runtime. **Confirmed recommendation.**
3. **ONNX Runtime as the common inference layer** with Core ML, DirectML, CUDA/TensorRT (optional) and CPU execution providers. **Needs more research**: quality parity against Vision, model licensing, EP behavior, memory on 16 GB machines, and model size are all unmeasured.
4. **A Rust `ai-engine` owning manifests, sessions and tiling.** **Needs a technical prototype** after the contract exists.
5. **Provenance per AI edit** (model id/version/hash, prompt, seed, strength, mask hash, timestamp). **Confirmed recommendation** as a product requirement.

### 8.3 Migration path

- Phase A: keep Python; add the shared schema and provenance records.
- Phase B: prototype ONNX sessions for one task (segmentation or face) and compare against Vision on a frozen corpus.
- Phase C: switch one feature at a time behind quality gates.
- Phase D: only then consider removing PyTorch/Transformers from the default runtime.

Never switch a model silently. A model change is a versioned, approved change with a visible quality diff.

---

## 9. Required item 9 — Revised project-format recommendations

**Recommendation: a v4 directory package with a versioned manifest, relative source location, content hashes and platform-only extensions. Classification: Confirmed recommendation. Exact schema: needs a design deliverable.**

Current v3 is a good non-destructive foundation but stores an absolute path and an Apple bookmark (`Project.swift:11, 21, 24`) and uses Apple geometry types. It cannot be shared with a Windows or Linux shell without translation.

### 9.1 Target shape

```text
MyEdit.retouch/
  manifest.json          # format version, app version, created/modified, flags
  source.json            # name, relative path, bytes, SHA-256, pixel size, color space
  operations.json        # ordered operations with stable IDs and explicit spaces
  masks/                 # content-addressed masks
  ai/                    # patches, alpha, provenance, model references
  previews/              # optional fast-open preview and thumbnail
  platform/macos.json    # bookmark and security-scoped data; never read elsewhere
```

### 9.2 Rules

- Relative source paths by default; resolve against the project location, then a user search list, then ask.
- SHA-256 (or BLAKE3) for the source and every asset; a moved file is relinkable, a changed file is detected.
- Never embed the original by default; offer it as an explicit, size-warning handoff option.
- Record an explicit coordinate space for every geometric operation (source pixels, normalized top-left, post-crop pixels).
- Stable operation IDs; history is derived, not duplicated.
- Preserve unknown fields on read/write.
- Atomic save with a previous-manifest fallback; `fsync` before rename.
- Migration chain v1→v2→v3→v4 with fixtures; an unmigratable project opens read-only with a clear message.
- No absolute paths, no bookmarks and no platform-only types in shared JSON.

The v4 schema is a Phase 1 design deliverable. The rules are the non-negotiable part.

---

## 10. Required item 10 — Updated migration roadmap

macOS remains the quality reference and the only shipping platform throughout. All durations are person-weeks, ±40%, for a team already familiar with the code.

| Phase | Scope | Duration | Exit gate |
|---|---|---:|---|
| 0 | 2026-11-09 audit | done | superseded by this refresh |
| 1 | Stabilization: recovery, runtime transaction, privacy, batch, failed load, export protection, autosave invalidation | **done** (`405ae2e`, merged `01da900`) | 840 checks / 0 failures; self-test passes |
| 2 | Near-term macOS hardening: CI, `fsync`, localization parity test, accessibility baseline, signing plan, docs cleanup | 6–10 | CI green on arm64 and Rosetta; new tests pass |
| 3 | **Portability design milestone** (recommended next): StudioCore interface spec, engine contract, corpus plan, one kernel spike, one Qt/RTL/color spike | **4–8** | Owner approves the written design; no shipping code replaced |
| 4 | Freeze golden-image corpus and characterize current engine | 8–12 | Hashes/tolerances recorded for every tool |
| 5 | Extract `StudioCore` behind contracts without changing output | 12–18 | Core compiles/tests without AppKit or SwiftUI |
| 6 | Rust image engine prototype and parity harness (`wgpu` + CPU tier) | 16–24 | Parity gate on the corpus; macOS can opt in |
| 7 | Project format v4 + v1–v3 migration | 6–10 | Round-trip and migration fixtures pass |
| 8 | Windows shell + platform adapters | 20–28 | Native Windows test pass on real hardware |
| 9 | Linux shell + packaging | 8–14 | Native Linux test pass on target distributions |
| 10 | AI engine unification on ONNX Runtime | 14–22 | Feature-by-feature quality gates |
| 11 | Pro UI: history, workspaces, Simple/Pro | 18–28 | UX acceptance in both languages |
| 12 | Release hardening: signing, notarization, accessibility, docs | 10–14 | Release checklist complete |

**Remaining total (phases 2–12): 122–188 person-weeks (±40%)**, roughly 9–14 months with three engineers, or 28–43 months with one senior engineer. Excluded: model research/training, legal licensing, hardware purchase, cloud services, mobile.

**Sequencing rules**

- Phase 2 is independent of portability and should land first.
- Phase 3 must precede any extraction; it is a design deliverable, not a rewrite.
- Phase 4 must precede the engine port; without a frozen oracle, "it looks the same" is not evidence.
- Phase 5 must produce a core that tests without SwiftUI/AppKit before Phase 6 starts.
- Phases 8 and 9 require separate hardware and CI; they can run in parallel only after Phases 5–7 are stable.
- No phase may remove a working macOS feature. The macOS app remains shippable throughout.

---

## 11. Required item 11 — Remaining risks and unknowns

| Risk / unknown | Probability | Impact | Mitigation / next evidence |
|---|---|---|---|
| Image-quality regression during an engine port | High | High | Corpus, per-tool tolerances, dual-run, owner sign-off |
| UI divergence between shells | High | Medium | Shared view models/design tokens; screenshot tests |
| Color-management mismatch | High | High | ICC fixtures, lcms2/ColorSync validation, soft-proof tests |
| Qt RTL/IME/tablet/accessibility gaps | Medium | High | Phase 3 prototype on real Windows hardware |
| GPU/driver differences | Medium | High | Deterministic CPU tier; shader tests; per-vendor CI |
| No native Windows/Linux validation | Certain today | High | Acquire hardware and CI; label all claims unvalidated until then |
| No native Intel validation | Certain today | Medium | Rosetta tests only; native Intel hardware still required |
| Published runtime archive unverified | Certain today | Medium | Download only with owner approval; verify hash/size; installer is disabled |
| AI quality parity with Vision | Unknown | High | Benchmark one task before adopting ONNX |
| Model licensing/size | Medium | High | Manifest license/source; consent; optional downloads |
| 16 GB memory pressure | Medium | High | Quantization, tiling, measured limits |
| Project backward compatibility | Medium | High | v1–v4 fixtures, read-only fallback, no silent rewrite |
| EditorModel churn during extraction | High | Medium | Contract-first extraction; small commits; regression suite |
| Swift toolchain/CI reproducibility | Medium | Medium | Pin SDK/toolchain; CI; document the CLT/SDK matrix |
| Ad-hoc signing and Gatekeeper | High | Medium | Signing/notarization plan; sandbox feasibility study |
| Scope creep (cloud, social, mobile) | High | High | Milestone gates and explicit non-goals |

**Not claimed by this audit:** Windows compatibility, Linux compatibility, native Intel behavior, DirectML/CUDA behavior, Windows color management, Windows Ink behavior, Linux packaging, published-runtime compatibility, or image-quality parity on any non-macOS backend. All cross-platform statements are feasibility judgments.

---

## 12. Required item 12 — Evidence and test references

### 12.1 Test runs at this commit

| Run | Command | Result |
|---|---|---|
| Native arm64 | `./Tests/run.sh` | **PASS** — 840 checks, 0 failures: Engine 130, Model 609, Runtime Process 55, Runtime V2 46 |
| Rosetta x86_64 | `RETOUCH_ARCH=x86_64 ./Tests/run.sh` | **PASS** — 840 checks, 0 failures (same four suites); Rosetta is not native Intel validation |
| Real runtime contract | `M1-AI-R` | skipped by default (`RETOUCH_REAL_RUNTIME=1` required) |
| Worker progress regression | `Docs/worker-regressions/test_two_file_download_progress.py` | manual; asserts plan-wide `total_bytes` for a two-file plan |

The suite is a custom harness: it compiles the sources into four executables and links every source except `App.swift` and `SelfCheck.swift`. It has no line-coverage instrumentation and no CI.

### 12.2 Code references

| Area | Location |
|---|---|
| Recovery store, candidates, launch classification | `Sources/RetouchStudio/Models/Recovery.swift:94, 122, 143, 181, 236, 250, 270, 279, 390` |
| Recovery prompts, barrier, autosave invalidation | `Sources/RetouchStudio/Models/EditorModel.swift:767, 797, 860, 2602, 2638, 2668, 2694` |
| Failed load identity | `Sources/RetouchStudio/Models/EditorModel.swift:1003, 1042–1043` |
| Export protection | `Sources/RetouchStudio/Models/EditorModel.swift:3049, 3054, 3084`; `Core/ExportService.swift:346, 362, 404` |
| Batch policy and cancellation | `Sources/RetouchStudio/Models/EditorModel.swift:77–78, 3315–3319, 3426–3483`; `Core/BatchExportPolicy.swift:12–43` |
| Privacy allowlist | `Sources/RetouchStudio/Core/ImageProcessor.swift:1141, 1176, 1204` |
| Runtime transaction | `Sources/RetouchStudio/Core/AIRuntimeTransaction.swift:162, 221, 273, 404, 536` |
| Disabled installer | `Sources/RetouchStudio/Core/AIRuntime.swift:40, 47, 50` |
| Project v3 | `Sources/RetouchStudio/Models/Project.swift:11, 21, 24` |
| Model progress | `Sources/RetouchStudio/Models/ModelManager.swift:61, 177, 209` |
| Build and signing | `build.sh:20, 71, 160, 164, 179`; `Package.swift` |

### 12.3 Regression tests

| Test | Location | Covers |
|---|---|---|
| `M1-R0`…`M1-R21` | `Tests/ModelTests.swift:1972–3127` | Recovery cancel, candidates, failures, promotion, autosave invalidation |
| `M1-R15` | `Tests/ModelTests.swift:4121` | No production recovery writes from the suite |
| `M1-L` | `Tests/ModelTests.swift:3181` | Failed open leaves the current document intact |
| `M1-X` | `Tests/ModelTests.swift:3228` | Export refuses source path and aliases |
| `M1-B` | `Tests/ModelTests.swift:3299` | Batch output cannot replace a source |
| `M1-AI`, `M1-AI2`, `M1-AI3`, `M1-AI4`, `M1-AI-R` | `Tests/ModelTests.swift:3331, 3750, 3915, 4015, 4080` | Transactional install, rollback, recovery, concurrency, real runtime (skipped) |
| `P0-4`, `P1-1`, `P1-1b` | `Tests/ModelTests.swift:399, 494, 594` | Batch snapshot policy, per-file shape, turned crop |
| `P1-8` (two tests) | `Tests/ModelTests.swift:981, 1052` | Cancellation stops the file in flight; failed write is not saved |
| Privacy fixtures | `Tests/EngineTests.swift:1013–1240` | GPS/EXIF/TIFF/IPTC/XMP absent; DPI/orientation survive; XMP control |
| Runtime process and v2 suites | `Tests/RuntimeProcessTests.swift`, `Tests/RuntimeV2Tests.swift` | Lease, identity, registry, recovery ordering, production-default support |

### 12.4 Documentation evidence and stale artifacts

- `README.md` — arm64/Intel images, AI requires Apple silicon, runtime download disabled, light app 3.5–4 MB, helper 1.3–1.6 GB.
- `Docs/AI_RUNTIME.md:19` — legacy 1.0.0 archive 388,277,063 bytes, not installed.
- `Docs/RELEASING.md` — installer disabled; release procedure.
- `Docs/TECHNICAL_AUDIT.md` — still audits `8cc2d0c`; treat as historical (D14).
- `Docs/PHASE5_ACCEPTANCE.md`, `Docs/PRIVACY_AUDIT.md` — post-audit history; not re-verified here.

---

## 13. Recommended next milestone

### Milestone A — Portability design package (4–8 person-weeks, no rewrite)

This is the first architecture milestone. It produces decisions and evidence, not a second shipping app.

**Deliverables**

1. **StudioCore interface specification**: document, operation graph, project manifest, export policy, recovery/runtime policy; explicit non-UI types; ownership of undo/history.
2. **Image-engine contract**: buffer/color-space model, filter graph, mask and coordinate spaces, deterministic CPU tier, GPU backend boundary, tiling and cancellation.
3. **Frozen corpus plan**: 8–12 test photos covering portrait, group, landscape, RAW, HEIC, rotated crop, mixed aspect, Persian text overlay; expected outputs and tolerances.
4. **One kernel spike**: port one real kernel (skin or heal) to Rust CPU and `wgpu`; measure output difference and runtime against macOS.
5. **One shell spike**: Qt 6/QML window on Windows hardware with Persian shaping, IME, tablet input and an ICC-managed image surface. If hardware is unavailable, record the blocker and do not claim the risk retired.
6. **AI decision memo**: one task (segmentation or face) benchmarked on ONNX Runtime versus Vision, including license and memory.
7. **Project v4 schema draft** with migration fixtures for v1–v3.

**Exit gate:** the owner approves the written design and the corpus plan. No production source is replaced; macOS remains the reference and stays shippable.

**Explicit non-goals:** no Rust/Qt migration, no engine replacement, no installer enablement, no project-format rewrite in shipping code, no new features.

**Then stop for a second approval.** Near-term macOS hardening (Phase 2) can run in parallel; it does not depend on the design.

---

## Appendix A — Method and limits

- Read the current tree, not only the previous audit: build script, plist, project/recovery/runtime/export code, tests, docs, and the bundled worker directory.
- Re-ran the Swift suites at `01da900` natively and under Rosetta; did not run the UI, did not download the runtime or models, did not install dependencies.
- Counted files, lines, imports, published properties and test checks directly with `find`, `wc`, `grep` and the test harness output.
- Did not use Instruments; no performance numbers are claimed.
- No Windows, Linux or native Intel hardware was used. Rosetta results are not native validation.
- Older `Docs/TECHNICAL_AUDIT.md` evidence was not trusted; its snapshot predates this commit.
- The metadata-privacy test reads XMP from written files; XMP survival is therefore tested, not assumed.
- The disabled installer means its production behavior is unexercised; the transaction is verified by tests only.

## Appendix B — Approval request

Phase 0 refresh is complete. No source code, test, build file or project file was changed. No commit, push or PR metadata change was made.

**Requested approval:** Milestone A only — the portability design package described in §13. Near-term macOS hardening (§10, phase 2) may be approved separately. Architecture extraction, Rust/Qt migration, installer enablement, project v4 implementation and AI migration remain blocked until separate approval.
