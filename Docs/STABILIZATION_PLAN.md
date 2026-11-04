# Retouch Studio — Post-Audit Stabilization Plan

Status: **planning only**. No source file has been modified. This document is the
implementation contract for the findings in `Docs/TECHNICAL_AUDIT.md`
(1909 lines, verified against the working tree of 2026-11-04, branch `main`,
`8cc2d0c` plus uncommitted work).

Scope: every Critical and High finding, plus the Medium findings named in the
request. Architecture, Core Image, Vision, the twelve tools, the immutable
original image and the `.retouch` v1 format are all preserved.

---

## 0. Ground rules and repository state

### 0.1 Repository safety (binding for the whole plan)

- Do not discard, overwrite, reset, clean or stash-drop any existing work.
- Do not commit without explicit approval.
- Do not touch `~/Documents/image test` content, and never add it to git.
- Every edit lands on a branch created after P0-4, never directly on `main`.
- A task is not "done" until its acceptance test has been run and its evidence
  is quoted in the task note. Fixes are re-tested, not assumed.

### 0.2 Current working tree

`git status --short`:

```
 M Resources/AppIcon.icns
 M Resources/make-icon.sh
 M Sources/RetouchStudio/App.swift
 M Sources/RetouchStudio/Core/ImageProcessor.swift
 M Sources/RetouchStudio/Core/SelfCheck.swift
 M Sources/RetouchStudio/Models/AppLanguage.swift
 M Sources/RetouchStudio/Models/AppSettings.swift
 M Sources/RetouchStudio/Models/EditorModel.swift
 M Sources/RetouchStudio/Models/Localization.swift
 M Sources/RetouchStudio/Models/PersianL10n.swift
 M Sources/RetouchStudio/Models/Project.swift
 M Sources/RetouchStudio/Models/Sticker.swift
 M Sources/RetouchStudio/Models/ToolMode.swift
 M Sources/RetouchStudio/Views/ArtOverlay.swift
 M Sources/RetouchStudio/Views/CanvasInteraction.swift
 M Sources/RetouchStudio/Views/CompareCanvas.swift
 M Sources/RetouchStudio/Views/Components.swift
 M Sources/RetouchStudio/Views/EditorView.swift
 M Sources/RetouchStudio/Views/InfoViews.swift
 M Sources/RetouchStudio/Views/InspectorView.swift
 M Sources/RetouchStudio/Views/SettingsView.swift
 M Sources/RetouchStudio/Views/ToolPanel.swift
 M Sources/RetouchStudio/Views/TopBar.swift
?? Docs/
?? Sources/RetouchStudio/Core/AnalysisRenderer.swift
?? Sources/RetouchStudio/Models/Analysis.swift
?? Sources/RetouchStudio/Views/AnalysisOverlay.swift
```

`git diff --stat`: 23 files, +1349 / -118. The uncommitted work is one coherent
feature set, not debris:

1. Face-analysis overlay and analysis export (3 new files + integration).
2. RTL / Persian layout plumbing.
3. Space-to-peek, tool number shortcuts, `[` / `]` brush sizing, sticker
   resize/rotate/duplicate handles.
4. Export long-edge option.
5. Icon refresh (`Resources/AppIcon.icns`, `Resources/make-icon.sh`).

`Docs/` contains only `TECHNICAL_AUDIT.md` at the time of writing.

### 0.3 Non-goals

- No replacement of Core Image or Vision.
- No new third-party dependency.
- No new tool; the twelve existing tools keep their behaviour.
- No parity claim against commercial retouchers.
- Straighten/rotation and backdrop-image replacement remain the separate
  structural passes already recorded in the roadmap; they are not smuggled into
  this plan.

---

## 1. Finding-to-code map

### 1.1 Critical

| ID | Finding | Primary code | Collaborators |
|---|---|---|---|
| C-1 | A successful export marks the document clean, disarming the unsaved-changes guard and recovery | `EditorModel.swift:1936-1946` (`cleanState = exportedState`, `cleanCrop = exportedCrop`, `updateCleanState()`) | `confirmDiscardIfNeeded` 585-610; `App.swift:52-61, 78-83`; `updateCleanState` 291-295; autosave/recovery path 1750-1830 |

Root cause: export writes an image file but treats that file as if it were the
saved project. `hasUnsavedChanges` is the only gate for discard prompts,
autosave, crash recovery and the window title, so one export silently demotes
every later edit to "already saved".

### 1.2 High

| ID | Finding | Primary code | Collaborators |
|---|---|---|---|
| H-1 | Smart Analyze wipes every field it did not measure | `Adjustments.swift:366-408` (`applyingColorLight`, `applyingRetouch` copy whole groups from a zero-based patch); `EditorModel.swift:1666-1688` | `SmartAnalyzer.swift:292-332` (`retouchValues`), 337+ (`merge`), `AutoAnalyzer.swift:408-470` (`autoColorLight`); `Adjustments.swift:413-455` (`scaledRetouch` omits `lensColor`) |
| H-2 | Reset All leaves heal stamps and the analysis overlay in place; the menu is gated on adjustments only | `EditorModel.swift:1469-1476`; `App.swift:261-263` | `EditState` 146-151; `commitAdjustments`; `updateCleanState` |
| H-3 | Batch export ignores heal stamps, stickers and analysis, applies one document crop to every file, and cannot be cancelled or show progress beyond a status string | `EditorModel.swift:2060-2122`; `ExportSheet` / `App.swift:252-254` | `ImageProcessor.load` 143+, `process` 656+, `write` 1047+; `Project` none (batch is not persisted) |
| H-4 | Projects store an absolute `imagePath`; a moved photo cannot be reopened or recovered | `Project.swift:17`; `EditorModel.swift:1974-1987`, `2020-2034`; recovery 1750-1830 | `Docs`/UTType path, `NSOpenPanel` entry points |
| H-5 | Crop lives outside `EditState`, so apply/reset are invisible to undo/redo and to the clean baseline pair | `EditState` 146-151; `applyCrop` 798-805; `resetCrop` 807-813; `reloadCropped` 818-855 | `cleanCrop` 157, 616-617, 720-721, 728-729, 1942; `install` 656-688 |
| H-6 | Blemish radius is a pixel clamp on the working image, so preview (1800 px) and export (full res) heal different amounts | `ImageProcessor.swift:686, 702` (`spotRadius = max(1.5, min(24.0, faceWidthPx * 0.030))`); `SkinEngine.localMedian` 239-262 (`factor` capped at 8) | `SkinEngine.removeBlemishes` 108-200; `spotsMask` 614-654; `MaskBuilder` feathering |
| H-7 | All faces share scalars derived from `faces.first` (blemish/teeth/hair radii, makeup family); no face selection, no confidence filter | `ImageProcessor.swift` 686, 702, 758-766, 834-849; `FaceAnalyzer.analyze` 434-444; `EditorModel` load/`makeupFamily` | `buildMasks` 236-482; `AnalysisRenderer.primaryFace` 76-81; `MakeupEngine`; `AnalysisOverlay` |

### 1.3 Medium in scope

| ID | Finding | Primary code | Collaborators |
|---|---|---|---|
| M-1 | Heal stamps are square normalized rects, so they become ellipses on non-square photos | `Heal.swift:66-74` (`HealGeometry.shapes`) | `ImageProcessor.spotsMask` 614-654; `Sticker.swift` `ArtGeometry.shortSides` is the correct precedent |
| M-2 | Masks are built at `maxMaskDimension = 1600` and upscaled, including for export | `MaskBuilder.swift:44`; `ImageProcessor.buildMasks` 236-482; export 1873-1948 | `gatedMask` 487+; `MaskSet` 43-83 |
| M-3 | Preview work can run against full-resolution pixels and full-resolution masks | `ImageProcessor.process` 656+; `ImageProcessor.write` 1047-1075; `EditorModel.schedulePreview` 1431+ | `LoadResult`, `install`, mask set selection |
| M-4 | Detached render tasks cannot be interrupted; completion still commits | `EditorModel.schedulePreview` 1431+; `renderTask`/`generation` | `Task.detached` in export/batch too |
| M-6 | Export copies GPS and personal EXIF from the source | `ImageProcessor.write` 1047-1100 (metadata copy, only pixel-profile keys removed) | `EditorModel.export` metadata capture 1881-1883; batch 2098-2111 |
| M-10 | Preview mask memory ≈ 286 MB (21 masks × 1600 × ~1067 × 4 B × 2 sets) | `MaskBuilder.swift:44`; `MaskSet` 43-83; `load`/`buildMasks` | `spotsMask`, `gatedMask`, `install` |
| M-13 | One `isBusy` Boolean and no token serialize export/save/open/batch; a finishing preview can clear `isBusy` during export | `EditorModel` 1890-1946, 2060-2122, `load` 621+, `install` 656-688 | `App.swift` menu enablement; `EditorView` overlays |
| M-14 | Even Skin Tone blends full RGB, so it changes luminance | `SkinEngine.swift:370-395` (`flattened` at `amount * 0.6`) | `blend` helper, `MaskBuilder.subtract` |
| M-15 | Teeth alignment grows the enamel mask past the enamel and can lighten the inner lip | `ImageProcessor.swift:758-766`; `SkinEngine.alignTeeth` 589-601, `toothGapKernel` 603-622 | `teethMask` 236-482, `gatedMask` |
| M-16 | A face with no landmarks feeds `.null` / infinite rects into cheek, blush and under-eye masks; `hasLandmarks` is written but never read | `FaceAnalyzer.swift:29, 369-378, 427, 483`; `ImageProcessor.buildMasks` 236-482 | `FaceGeometry` accessors 286-355; `MakeupEngine`; `AnalysisOverlay` |

### 1.4 Audit findings intentionally deferred

M-5 (no Save in discard alert) is folded into P1-3 only if the relink flow needs
a third button; otherwise it stays deferred. M-7 (localization parity), M-8
(canvas accessibility), M-9 (folding into P1-3 version check), M-11 (opt-in real
photo checks), M-12 (analysis export with no face) and L-1..L-7 are listed in
section 7. None of them is a prerequisite for P0/P1.

---

## 2. Dependency impact analysis

### 2.1 Shared seams

| Seam | Current shape | Findings that must change it |
|---|---|---|
| `EditState` (146-151) | adjustments + healSpots + stickers + analysis | H-2, H-5, P0-3, P1-2 |
| `Adjustments` group copiers (366-455) | whole-group copy | H-1, P0-2 |
| `isBusy` / generation tokens | one Boolean, separate per-workload counters | C-1, H-3, M-4, M-13, P1-1, P1-5 |
| Export render path (1873-1948) vs batch (2060-2122) | duplicated pipelines | H-3, H-6, M-2, M-3, M-6, P1-1, P1-6, P2-1 |
| Mask construction (236-482, `MaskBuilder`) | one 1600 px set per resolution | H-6, H-7, M-2, M-10, M-16, P2-1/P2-2 |
| `FaceGeometry` + `FaceAnalyzer.analyze` | all faces accepted, first face drives scalars | H-7, M-15, M-16, P1-4, P2-4/P2-5 |
| `RetouchProject` schema (v1) | absolute `imagePath`, optional newer fields | H-4, P1-3 |
| `ImageProcessor.write` metadata copy | copies every key except pixel profile | M-6, P2-6 |
| `SkinEngine` blend kernels | full RGB blending in EST/teeth | M-14, M-15, P2-3/P2-4 |

### 2.2 Overlap groups (fix once, not twice)

1. **Document truth group**: C-1 + H-2 + H-5 all answer "what counts as saved
   and undoable". Land the clean-state fix first (P0-1), then Reset All
   (P0-3), then fold crop into `EditState` (P1-2). If P1-2 lands last, it must
   also convert Reset All's crop handling in the same commit; until then Reset
   All deliberately leaves the crop alone and says so in its status text.
2. **Export parity group**: H-3 + H-6 + M-2 + M-3 + M-6 all rebuild the same
   pipeline. P1-1 extracts a single `ExportSnapshot` + renderer used by both
   entry points. P1-6 fixes the radius math inside that renderer. P2-1/P2-2
   change only mask resolution inside it. P2-6 changes only the metadata
   argument. Doing them out of order means writing the export path three times.
3. **Face group**: H-7 + M-15 + M-16 share `FaceGeometry` and `buildMasks`.
   P1-4 introduces `selectedFaceIndex`, a confidence filter and a landmark
   guard. P2-4 and P2-5 refine the engine inside those guards.
4. **Adjustment-field group**: H-1 is the same duplication L-2 describes. A
   single `RetouchField` / `ColorField` OptionSet fixes both; do not add a
   second field list anywhere.
5. **Operation group**: M-13 + M-4 + H-3 cancellation. P1-1 gives batch its own
   token; P1-5 generalizes it into one coordinator. Do not introduce two
   competing busy flags.

### 2.3 Ordering constraints

- P0-4 (review/commit existing work) must precede any edit: the diff is large
  and would otherwise contaminate every later review.
- P0-1 must precede P1-2: the clean baseline moves from `(cleanState,
  cleanCrop)` to a single state value, and doing it in the other order forces
  the export fix to be rewritten.
- P1-2 (crop in history) must precede the crop half of P0-3's acceptance
  ("Reset All clears the crop"). The P0-3 commit ships content reset only, with
  an explicit note; P1-2 extends it.
- P1-5 (coordinator) must precede P2-1/P2-2 (export mask memory), because the
  coordinator owns when full-resolution masks are retained.
- P1-4 (face selection) must precede P2-5 (landmarkless fallback), because the
  fallback is exercised through the same selection code.
- P1-6 (radius parity) must precede P2-1 (mask resolution), otherwise the
  parity test would pin the wrong mask resolution.

### 2.4 Files touched (blast radius)

| File | P0 | P1 | P2 |
|---|---|---|---|
| `EditorModel.swift` | 1,3,4 | all | 1,2,5,6 |
| `Adjustments.swift` | 2 | — | — |
| `SmartAnalyzer.swift` / `AutoAnalyzer.swift` | 2 (mask constants only) | — | — |
| `App.swift` | 3 (menu gate) | 3,5 | — |
| `Project.swift` | 4 (commit) | 3 | — |
| `ImageProcessor.swift` | 4 (commit) | 1,4,6,7 | 1,2,4,5 |
| `MaskBuilder.swift` | — | 4,6 | 1,2,5 |
| `SkinEngine.swift` | — | 6,7 | 2,3,4 |
| `FaceAnalyzer.swift` | — | 4 | 5 |
| `Heal.swift` | — | 7 | — |
| `Views/*` | 4 | 1,2,3,4,5 | — |
| `Tests/*` | all | all | all |
| `SelfCheck.swift` | all | all | all |

`AppSettings.swift` and `PersianL10n.swift` are touched only for new UI strings
and the privacy default; both must stay backward-compatible (missing keys decode
to the existing defaults).

---

## 3. Proposed implementation sequence

Each numbered unit is one commit-sized change with its own tests. "Gate" means
no later unit starts until the gate passes.

### Phase 0 — Protect and baseline

**P0-4. Review and commit the existing uncommitted work** (no source changes).
Prerequisite to everything else. Detailed in section 6.1.

Gate: `./build.sh`, `Tests/run.sh` and `--selftest` all pass on the current
tree; the split below is applied with `git add -p` and reviewed hunk by hunk.

### Phase 1 — P0 data integrity

**P0-1. Export must not mark the document clean** (C-1).
Files: `EditorModel.swift`.
Design: delete the `cleanState`/`cleanCrop` assignment from export success;
record `lastExportedState` only for a status hint ("Exported …"); a second edit
after export must re-arm the prompt. Keep `writeProject` as the only path that
marks clean.
Acceptance: see 6.2.

**P0-2. Smart Analyze field preservation** (H-1).
Files: `Adjustments.swift`, `SmartAnalyzer.swift`/`AutoAnalyzer.swift` (field
set constants), `EditorModel.swift`.
Design: `RetouchField` and `ColorField` OptionSets and masked copiers; apply
only fields the analyzer can produce. Detailed in 6.3.

**P0-3. Reset All completeness** (H-2).
Files: `EditorModel.swift`, `App.swift`.
Design: clear adjustments, heal spots, stickers, analysis in one history step;
enable the menu whenever anything is non-pristine. Crop is included once P1-2
lands. Detailed in 6.4.

Gate: model suite green; manual check that export → quit prompts, Save project →
quit does not, Reset All is one undo step, and Smart Analyze on a photo with a
manual lens tint keeps the tint.

### Phase 2 — P1 workflow reliability

Order follows the requested priority. Each unit leaves the app shippable.

**P1-1. Batch export parity** (H-3, batch half of M-4).
Shared `ExportSnapshot` and `ExportRenderer`; per-file masks and faces; crop
only when aspect matches; optional stamps/analysis; cancel button and progress.
Detailed in 6.6.

**P1-2. Crop in undo history** (H-5, completes P0-3's crop clause).
Move `crop` into `EditState`, drop `cleanCrop`, make restore asynchronous but
history-safe. Detailed in 6.7.

**P1-3. Project relinking and version safety** (H-4, M-9).
Bookmark + relative-path fallback, "Locate…" flow, recovery path, version check.
Detailed in 6.8.

**P1-4. Face selection and multi-face behaviour** (H-7, M-16 safety half).
`selectedFaceIndex`, confidence filter, landmark guard, per-face scalars by
median instead of `faces.first`, makeup family by selection. Detailed in 6.9.

**P1-5. Operation coordination and cancellation** (M-13, M-4).
One operation token replaces ad-hoc `isBusy` writes; export/open/save/batch are
serialized; stale completions are discarded. Detailed in 6.10.

**P1-6. Preview/export consistency** (H-6, M-3).
Normalized blemish radius, resolution-aware median factor, preview pipeline
assertion. Detailed in 6.11.

**P1-7. Heal stamp aspect correction** (M-1).
Short-side geometry matching the sticker precedent. Detailed in 6.12.

Gate after each: engine suite + model suite + self-check on the private real
photo set (never committed), plus the specific acceptance test.

### Phase 3 — P2 engine quality

**P2-1. Preview mask memory reduction** (M-10, first half of M-2).
**P2-2. Full-resolution export masks built lazily** (second half of M-2).
**P2-3. Even Skin Tone preserves luminance** (M-14).
**P2-4. Teeth alignment mask restriction** (M-15).
**P2-5. Landmarkless face fallback** (M-16 remainder).
**P2-6. EXIF/GPS privacy controls** (M-6).

Order is deliberate: mask work after the coordinator; skin work after the face
guards; metadata last because it touches only `write`.

---

## 4. Test plan

Tests are written before their fix. The existing suites are extended, not
replaced, and no assertion is weakened. Where a threshold must change because
the fix changes the intended output, the old assertion stays and a new, sharper
one is added; the diff must show both.

### 4.1 Harness layout

The project has no XCTest (Command Line Tools only), so:

- `Tests/run.sh` keeps compiling all sources except `App.swift` and
  `SelfCheck.swift` into a scratch `main.swift`, then runs it.
- Add `Tests/ModelTests.swift`, compiled by the same script into a second
  scratch `main.swift` and run after the engine suite. Both exit non-zero on
  failure.
- Add a tiny shared helper block (plain functions, no module):
  `check(_:_:_:)`, `waitUntil(timeout:_:)` pumping the main run loop,
  `tempDir()`, `makeImage(...)`, `writeProject(...)`.
- `SelfCheck` gains one check per fixed finding so the packaged app validates
  itself with `--selftest`; real-photo checks stay opt-in behind `--face`.

New model seams (production-visible but internal, no behaviour change):

- `EditorModel.loadForTesting(url:)` wrapping the existing private load, so a
  test can open a file without `NSOpenPanel`.
- `EditorModel.performExport(to:) async -> Bool` extracted from `export(to:)`;
  the sheet calls the async form inside its `Task`.
- `EditorModel.relinkImage(to:)` used by both the UI flow and tests.
- `EditorModel.applySmartReport(report:)` internal overload.

No `#if DEBUG` branches in behaviour: tests drive the same code paths as the UI.

### 4.2 Test matrix

| Test | Level | Asserts |
|---|---|---|
| `test_export_does_not_clear_dirty` | model | open fixture, change slider, `await export`, `hasUnsavedChanges == true`; `saveProject` then false |
| `test_export_stale_completion_ignored` | model | start export, change adjustment before completion; finishing export leaves dirty true and status not "saved" |
| `test_smart_preserves_unmeasured_fields` | unit | base adjustments with a distinct non-zero value in every field; apply a report whose measured fields are zero; every unmeasured field byte-identical |
| `test_smart_field_sets_cover_analyzer_output` | unit | run real `retouchValues`/`autoColorLight` on a synthetic buffer; assert every changed field is a member of `smartRetouch` / `autoColorLight` |
| `test_scaled_retouch_covers_every_field` | unit | enumerate `Adjustments` key paths; scaling by 100% equals input for every field in the mask, including `lensColor` |
| `test_reset_all_clears_everything` | model | set all groups, reset, assert identity/empty; undo restores all; menu predicate true |
| `test_batch_matches_single_export` | model | export file A singly, export A + B via batch with identical snapshot; decoded pixels differ < 1/255 mean |
| `test_batch_aspect_mismatch_leaves_crop` | model | batch a 3:2 and a 1:1 file with a document crop; square file keeps full frame; status reports one skipped crop |
| `test_batch_applies_stamps_when_enabled` | model | stamp visible in both outputs when enabled, absent when disabled |
| `test_batch_cancel_stops_remaining` | model | cancel after first file; no output for the rest; `isBusy` false |
| `test_crop_undo_redo` | model | apply crop, undo, assert frame and `previewSize` restored, redo re-applies; stack not cleared |
| `test_crop_reset_is_undoable` | model | reset crop, undo restores frame |
| `test_project_relink` | model | move image, open project, relink, reopen succeeds; stored path updated; bookmark survives a second move |
| `test_project_version_guard` | model | version 2 rejected with a specific status; version 1 and missing version accepted |
| `test_face_selection_drives_makeup` | model | two-face fixture; selecting B changes makeup family to B's measurement, A untouched |
| `test_face_confidence_filter` | unit | low-confidence observation dropped |
| `test_landmarkless_face_masks` | engine | face with `hasLandmarks == false`: no `.null`/infinite rects, no NaN, empty makeup masks, crop tools still work |
| `test_landmarkless_face_still_retouched` | engine | smoothing/blemish still apply within the face bounds |
| `test_preview_export_blemish_parity` | engine | 3000 px synthetic face: preview vs export downscaled, spot-region delta < 2% |
| `test_preview_export_tolerance_scaling` | engine | face width 400 px and 1600 px produce the same normalized spot radius |
| `test_heal_stamp_is_round` | engine | 3:2 image: stamp mask width/height ratio 1.0 ± 0.02 in pixel space |
| `test_est_preserves_luminance` | engine | EST on a patch: mean luma delta < 0.5/255, chroma spread reduced |
| `test_teeth_alignment_keeps_lip` | engine | lip red channel delta < 1/255; tooth-gap closure retained |
| `test_export_strips_gps` | engine | JPEG with GPS + serial written; read back GPS nil, serial nil, orientation 1, ICC present |
| `test_mask_memory_budget` | engine (opt-in) | mask build peak RSS below the budget printed by `--memcheck` |
| `test_preview_never_uses_full_source` | unit | preview render receives the preview extent |

### 4.3 Fixtures

- Existing synthetic 420 px face generator in `Tests/EngineTests.swift` is
  reused for geometry and mask assertions.
- New synthetic fixtures: 3:2 canvas, high-resolution 3000 px canvas, two-face
  canvas, landmarkless face (Vision-free constructed `FaceGeometry`).
- Real-photo validation uses the private set in `~/Documents/image test` only
  through `--selftest --face`, never copied into the repo. Any committed
  fixture must be synthetic or CC0.

### 4.4 Manual protocol (every P1 unit)

1. Build, launch, open a private portrait.
2. Run the unit's golden path and its failure path.
3. Take before/after screenshots at 100% zoom for engine work.
4. Quit and relaunch to confirm persistence.
5. Re-run `--selftest --face` on the same photo and record the result.

---

## 5. Regression risk matrix

| Fix | Plausible regression | Detection | Mitigation |
|---|---|---|---|
| C-1 | Every export now leaves the document dirty, so the owner sees a discard prompt after exporting and quitting | `test_export_does_not_clear_dirty`; manual quit-after-export | Document the intent; status line says "Exported copy — project not saved"; Save Project remains one click; no prompt when the project was already saved |
| C-1 | Recovery autosave may resurrect states the owner believes exported | recovery test; manual relaunch | Recovery only reads the autosaved project state, same as before; export no longer touches it |
| H-1 | Masking fields could drop a value Smart legitimately set to zero (measured "nothing to fix") | `test_smart_preserves_unmeasured_fields` plus `test_smart_field_sets_cover_analyzer_output` | Mask is exactly the analyzer's output set, zeros included; unmeasured fields preserved |
| H-1 | A field added to `retouchValues` later silently falls outside the mask | coverage test fails when the analyzer writes a field outside the set | Keep the set adjacent to `retouchValues` with a comment; test enumerates changed fields |
| H-2 | Reset All now also discards analysis endpoints and heal stamps, which the owner may want back | `test_reset_all_clears_everything` asserts one undo restores everything | Single history step, no confirm dialog beyond the existing menu action |
| H-2 / H-5 | Reset clears crop and triggers an async reload; a stale reload could install the wrong frame | generation-token test; `test_crop_reset_is_undoable` | Restore path bumps `generation`; stale results discarded before `install` |
| H-3 | Applying stamps/analysis to unrelated batch photos produces nonsense on each | aspect guard and explicit toggles; manual batch on mixed photos | Off by default for stamps/analysis unless the owner enables them; crop auto-skips mismatched aspect with a count |
| H-3 | Shared renderer changes single-export output | `test_batch_matches_single_export`, existing export self-checks | Renderer extracted verbatim; first commit is pure refactor with pixel-identical output |
| H-4 | Bookmarks fail after the photo is moved to another volume | relink test with a second move | Path fallback, then explicit Locate panel; user-visible reason |
| H-4 | New optional project keys break old files | decode v1 fixture with none of the new keys | Additive optional fields only; never bump `currentVersion` unless decoding actually changes shape |
| H-5 | Crop undo resets the undo stack via `install`/`resetHistory` | `test_crop_undo_redo` asserts stack length across crop | `reloadCropped(restoring:)` skips history reset and clean-state marking; explicit flag |
| H-5 | Undo after crop restores old crop but old masks, causing misaligned edits | compare mask extents after undo in the model test | Reload rebuilds masks and spot positions for the restored frame before preview |
| H-6 | Removing the 24 px clamp increases export time and memory | timing in `--selftest`; Instruments sample | Radius is a fraction of face width; median runs on a downscaled copy; cap raised to a measured budget, not unbounded |
| H-6 | Preview and export become pixel-identical but lose the intended strength | parity test plus visual before/after at 100% | The normalized radius is the existing preview behaviour on a 1800 px photo; export moves toward preview, not the reverse |
| H-7 | Selecting one face stops skin work on the others | group-photo mask test | Selection drives scalars and makeup only; smoothing/blemish masks still union all accepted faces |
| H-7 | Confidence filter drops a real background face | manual group photo; `test_face_confidence_filter` | Threshold documented and deliberately low; faces sorted by area |
| M-1 | Round stamps leave a corner of the old square spot | visual stamp test at 100%; spot-prominence check | Verify blemish clearing signal on a 3:2 fixture before/after |
| M-2 / M-10 | Reduced mask resolution softens acne/blemish edges in export | export mask-edge test; 100% inspection | Preview masks shrink; export masks are built at full resolution in P2-2 so no edge loss in the file |
| M-2 | Full-res masks blow the memory budget | `--memcheck` peak RSS | Build one set, release before writing, reuse preview set when extent matches |
| M-3 | Processing the preview at preview scale changes look versus earlier versions | golden-image comparison on a fixture | Engine is resolution-aware already; difference must be below the existing identity threshold on a clean image |
| M-4 | Cancelling a preview leaves `isBusy` stuck | coordinator test; manual rapid slider drag | Token owns `isBusy`; cancellation settles the token before the next render |
| M-13 | Serializing export/open/save deadlocks a waiting preview | coordinator unit test with overlapping requests | Previews are coalesced and cancellable; blocking operations never wait on previews |
| M-14 | Chroma-only EST leaves blotchy colour | visual check; chroma-spread assertion | Preserve luma exactly; smooth only chroma; amount still scales the effect |
| M-15 | Restricting the mask reopens the tooth gap | gap-closure assertion retained alongside the lip assertion | Grow within `teethMask ∩ enamel gate` only |
| M-16 | Fallback boxes darken the whole face for blush/under-eye | landmarkless mask test asserts empty makeup masks | No landmarks means no makeup/under-eye; smoothing/blemish use the face box |
| M-6 | Stripping metadata removes orientation/ICC and breaks colour | metadata round-trip test | Strip an explicit allowlist of privacy keys only; keep orientation, ICC, DPI, pixel dimensions |

---

## 6. Detailed task breakdown

Each task lists goal, files, design, acceptance criteria and tests. Line
numbers refer to the current tree; re-verify after P0-4.

### 6.1 P0-4 — Review and commit the existing work

Goal: get to a known-good baseline without losing anything.

Steps:

1. Run `./build.sh`, `Tests/run.sh`, and the built binary with `--selftest`
   (plus `--face` on one private photo). Record output.
2. Split the diff into reviewable commits with `git add -p`; never `git add -A`
   over `Docs/` plus sources in one go:
   - `docs: add technical audit` — `Docs/TECHNICAL_AUDIT.md`.
   - `feat: face analysis overlay and analysis export` — `Analysis.swift`,
     `AnalysisRenderer.swift`, `AnalysisOverlay.swift`, the analysis fields in
     `Project.swift`/`EditorModel.swift`, `SelfCheck` analysis checks, strings.
   - `feat: right-to-left layout for Persian` — language/localization/views.
   - `feat: canvas peek, tool shortcuts, sticker handles` — canvas/interaction,
     `Sticker`, `EditorView`, `ToolMode`.
   - `feat: export long-edge option` — settings, project, `write`, self-check.
   - `chore: refresh app icon` — `Resources/`.
3. Hunk-splitting rules: `EditorModel.swift` and `ImageProcessor.swift` contain
   hunks for several groups; keep each hunk with the feature it serves. If a
   hunk cannot be separated (shared plumbing), put it in the earliest commit
   that needs it and note the dependency in the message.
4. After the split, run the gates again at each commit (`git stash` is not
   needed and must not be used; check out each commit in a separate worktree if
   build-time bisection is wanted).
5. Create branch `stabilization` from the resulting `main`. All later work
   lands there.

Acceptance:

- `git status` is clean except ignored build output.
- Every commit builds and passes both suites independently.
- The private photo directory is untouched and untracked.
- No commit contains a private image or build artifact.

### 6.2 P0-1 — Export no longer marks the document clean (C-1)

Files: `EditorModel.swift`.

Design:

```swift
// remove from export completion
self.cleanState = exportedState
self.cleanCrop = exportedCrop
self.updateCleanState()

// replace with
self.lastExportedState = exportedState
self.lastExportedCrop = exportedCrop
self.statusToken = .saved(url.lastPathComponent)
```

`lastExportedState` is diagnostic only (window-status hint, "Exported"; not
persisted, not used by `hasUnsavedChanges`). `updateCleanState()` still runs on
adjustments changes, so the dirty flag stays exactly as before the export.

Acceptance criteria:

1. Open A, change a slider, export, quit → discard prompt appears.
2. Open A, change a slider, Save Project, quit → no prompt.
3. Open A, Save Project, edit, export, quit → prompt appears.
4. Export failure leaves the document untouched and reports failure.
5. `hasUnsavedChanges` never flips to false as a side effect of export.
6. Recovery after a crash following export restores the post-export edits.

Tests: `test_export_does_not_clear_dirty`,
`test_export_stale_completion_ignored` (the second is completed by P1-5; a
simple generation guard is added here so a late completion cannot mark the
wrong state).

### 6.3 P0-2 — Smart Analyze preserves unmeasured fields (H-1)

Files: `Adjustments.swift`, `SmartAnalyzer.swift`, `AutoAnalyzer.swift`,
`EditorModel.swift`, tests.

Design:

```swift
struct RetouchField: OptionSet, Equatable {
    let rawValue: UInt32
    static let smooth          = RetouchField(rawValue: 1 << 0)
    static let blemish         = RetouchField(rawValue: 1 << 1)
    static let wrinkle         = RetouchField(rawValue: 1 << 2)
    static let skinToneEvens   = RetouchField(rawValue: 1 << 3)
    static let darkCircles     = RetouchField(rawValue: 1 << 4)
    static let skinBrighten    = RetouchField(rawValue: 1 << 5)
    static let texturePreserve = RetouchField(rawValue: 1 << 6)
    static let shine           = RetouchField(rawValue: 1 << 7)
    static let teethWhiten     = RetouchField(rawValue: 1 << 8)
    static let eyeBrighten     = RetouchField(rawValue: 1 << 9)
    static let eyeSharpen      = RetouchField(rawValue: 1 << 10)

    /// Exactly what `SmartAnalyzer.retouchValues` writes. Measured zeros are
    /// part of the answer; everything outside this set is the owner's.
    static let smart: RetouchField = [.smooth, .blemish, .wrinkle, .skinToneEvens,
        .darkCircles, .skinBrighten, .texturePreserve, .shine,
        .teethWhiten, .eyeBrighten, .eyeSharpen]
}

func applyingRetouch(_ patch: Adjustments, fields: RetouchField) -> Adjustments
func applyingColorLight(_ patch: Adjustments, fields: ColorField) -> Adjustments
```

`ColorField.autoColorLight` covers exactly the fields `AutoAnalyzer.autoColorLight`
can assign (`blacks`, `whites`, `contrast`, `exposure`, `warmth`, plus whatever
the tail of the function writes). Vignette, split tone, curves and HSL are never
in it, so they survive.

Call sites:

- `applySmartReport`: `applyingRetouch(patch, fields: .smart)` and
  `applyingColorLight(patch, fields: .autoColorLight)`.
- Any other existing caller of the group copiers passes `.all`, preserving
  current behaviour.
- `scaledRetouch` scales every field in `.smart`; add `lensColor` handling to
  the generic colour path only if it ever enters a field set, and add a test
  that would catch the omission.

Acceptance criteria:

1. Apply Smart Analyze with manual lens tint, lash darken, iris enhance, teeth
   align, skin finish, vignette, split tone, curve and HSL values set: every
   one of those fields is unchanged.
2. Measured fields still change, including measured zeros (a clean face sets
   `blemish` to 0 when the owner had 60).
3. Undo after apply restores the full pre-apply state in one step.
4. Auto Retouch and Auto Color/Light standalone behaviour is unchanged.
5. A field added to the analyzer later triggers a failing coverage test.

Tests: the four from the matrix; plus a self-check that applies a fabricated
report with all fields set to sentinels and prints the preserved set.

### 6.4 P0-3 — Reset All completeness (H-2)

Files: `EditorModel.swift`, `App.swift`.

Design:

```swift
func resetAll() {
    guard hasImage, !isBusy else { return }
    commitAdjustments(force: true)
    adjustments = Adjustments()
    healSpots = []
    selectedSticker = nil
    stickers = []
    analysis = AnalysisSettings()
    comparePosition = 0.5      // existing behaviour, now explicit
    commitAdjustments(force: true)
    rebuildSpotMasks()
    schedulePreview()
    statusToken = .resetDone
}
```

Menu gate:

```swift
var isDocumentPristine: Bool {
    adjustments.isIdentity && healSpots.isEmpty && stickers.isEmpty
        && analysis == AnalysisSettings()
}
// App.swift:263
.disabled(!model.hasImage || model.isDocumentPristine)
```

Crop is included in P1-2 (see 6.7 acceptance 6). Until then, the status text
says "Edits reset — crop kept" so the behaviour is not silent.

Acceptance criteria:

1. After any combination of sliders, stamps, stickers and analysis, Reset All
   produces an identity document (crop excepted until P1-2).
2. One undo restores the entire previous document, including stamps and
   endpoints.
3. The menu item is enabled whenever any of the four groups is non-default.
4. Reset All while busy is refused, not queued.
5. Preview, thumbnails and the analysis overlay all return to the unedited
   frame.

Tests: `test_reset_all_clears_everything`, plus a self-check verifying the menu
predicate for each group.

### 6.5 P1-1 — Batch export parity (H-3)

Files: `EditorModel.swift`, new `ExportService.swift` (or an extension file),
`ExportSheet` view, `SelfCheck`.

Design:

```swift
struct ExportSnapshot: Equatable {
    var adjustments: Adjustments
    var healSpots: [HealSpot]
    var stickers: [Sticker]
    var analysis: AnalysisSettings
    var crop: CGRect?
    var format: ExportFormat
    var quality: Double
    var longEdge: CGFloat?
    var includeStamps: Bool
    var includeAnalysis: Bool
    var stripLocation: Bool        // P2-6
}

enum ExportService {
    static func render(_ snapshot: ExportSnapshot,
                       source: CIImage, masks: MaskSet?, faces: [FaceGeometry],
                       spots: SpotHealing?, art: StickerArt?,
                       colorSpace: CGColorSpace?, metadata: [CFString: Any],
                       maxDimension: CGFloat?) -> CIImage?
}
```

Single export builds a snapshot from the document; batch builds the same struct
once and reuses it per file. Per file:

- masks and faces come from that file's `LoadResult` (never the open document);
- `crop` is applied only when
  `abs(log(fileAspect / documentAspect)) < 0.01`; otherwise `nil` and a
  `cropsSkipped` counter is reported;
- `healSpots`/`stickers`/`analysis` are applied only when the snapshot says so;
  the batch sheet exposes two checkboxes, default off for stamps and analysis;
- the face count is per file; a file with no face still exports.

Batch UI: replace the status-only progress with a determinate bar, a Cancel
button bound to `batchTask?.cancel()`, and a completion line
`"12/12 saved · 2 crops skipped"`.

Acceptance criteria:

1. Exporting the same file through the single path and the batch path with the
   same snapshot yields pixels within 1/255 mean delta.
2. Batch on files of different aspect does not crop the mismatched ones and
   reports how many were skipped.
3. Each batch file uses its own masks and faces; a two-face file gets two-face
   processing.
4. Stamps and analysis appear only when enabled, and follow each file's own
   geometry.
5. Cancel stops after the current file; no partial file remains (write to a
   temporary name, then atomically rename).
6. Batch failure on one file does not abort the rest and is counted.
7. `isBusy` is released exactly once on success, cancel and failure.

Tests: batch row of the matrix; plus a self-check with two synthetic files of
different aspect.

### 6.6 P1-2 — Crop enters undo history (H-5)

Files: `EditorModel.swift`, tests.

Design:

```swift
private struct EditState: Equatable {
    var adjustments = Adjustments()
    var healSpots: [HealSpot] = []
    var stickers: [Sticker] = []
    var analysis = AnalysisSettings()
    var crop: CGRect?
}
private var currentState: EditState {
    EditState(adjustments: adjustments, healSpots: healSpots,
              stickers: stickers, analysis: analysis, crop: appliedCrop)
}
// cleanCrop is deleted; cleanState.crop replaces it.
```

`applyCrop` and `resetCrop` call `commitAdjustments(force: true)` before
changing `appliedCrop`, then `reloadCropped(restoring: false)`.

`restore(_ state:)`:

```swift
let cropChanged = state.crop != appliedCrop
adjustments = state.adjustments
healSpots = state.healSpots
stickers = state.stickers
analysis = state.analysis
appliedCrop = state.crop
rebuildSpotMasks()
if cropChanged { reloadCropped(restoring: true) } else { schedulePreview() }
```

`reloadCropped(restoring:)` must not call `resetHistory`, must not set
`cleanState`, and must bump `generation` so a stale load cannot install.

Additional rules:

- `reloadCropped` keeps spot positions in original-photo coordinates, so a
  restored crop shows the same stamps (existing behaviour, now tested).
- The crop draft (`cropDraft`) is UI state, not document state; it is not in
  `EditState`.
- Project IO is unchanged; `Project.crop` already exists and stays optional.

Acceptance criteria:

1. Apply crop, undo → previous frame, previous `previewSize`, same adjustments
   and stamps; redo re-applies.
2. Reset crop, undo → crop returns.
3. Undo stack length grows by exactly one per crop action and is not cleared by
   the reload.
4. `hasUnsavedChanges` is true after a crop-only edit and false after undo of
   that edit.
5. Save project after crop, reopen → crop restores; clean state matches.
6. Reset All (P0-3) now clears crop as part of the same single undo step.
7. A slow reload cancelled by a second undo never installs the first frame.

Tests: `test_crop_undo_redo`, `test_crop_reset_is_undoable`,
`test_reset_all_clears_everything` extended, plus a generation race test.

### 6.7 P1-3 — Project relinking and version safety (H-4, M-9)

Files: `Project.swift`, `EditorModel.swift`, `App.swift`, `InfoViews` if a
missing-file sheet is added.

Design:

- `RetouchProject` gains optional `imageBookmark: Data?` and keeps
  `imagePath` for display. Encoding stays additive; `currentVersion` stays 1
  because the decode shape is unchanged (all new keys optional).
- On open: resolve in order bookmark → absolute path → project-relative path
  → Ask. The relative path is `projectURL.deletingLastPathComponent()
  .appendingPathComponent(lastPathComponent)` so a moved folder still works.
- `relinkImage(to:)` updates `imageURL`, refreshes the bookmark, and rewrites
  the project (marking clean only if it was clean before the relink).
- Recovery uses the same resolver; if the image is gone, the recovery sheet
  offers Locate or Discard instead of silently failing.
- Version guard: `guard project.version <= RetouchProject.currentVersion` with
  a specific status token (`projectTooNew`); missing version decodes as 1.
- Open is guarded by the operation coordinator (P1-5); until then it uses the
  existing `isBusy` guard.

Acceptance criteria:

1. Move the image, reopen the project: Locate prompt appears, relink succeeds,
   a second reopen needs no prompt.
2. Move the whole folder (image + project together): opens with no prompt via
   the relative path.
3. Move to another volume: bookmark fails, path fails, Locate works.
4. A version-2 project is rejected without crashing and the reason is shown.
5. A v1 project written by the previous build opens unchanged.
6. Recovery and normal open share one code path (no duplicated resolution).

Tests: `test_project_relink`, `test_project_version_guard`, plus a
fixture-based decode test of a hand-written v1 JSON with none of the newer keys.

### 6.8 P1-4 — Face selection and multi-face behaviour (H-7, M-16 guard)

Files: `EditorModel.swift`, `FaceAnalyzer.swift`, `ImageProcessor.swift`,
`InspectorView`/`AnalysisOverlay`, `Project.swift` (optional persisted
selection), `MakeupEngine` call site.

Design:

- `@Published var selectedFaceIndex: Int?`, persisted as optional in projects.
- `faces` sorted by bounding-box area descending after analysis; selection is
  an index into that stable order.
- Confidence filter: drop observations with `confidence < 0.35` or area
  `< 0.2%` of the frame; log the count into the analysis report so an empty
  photo explains itself.
- Scalar radii: replace `faces.first` with `medianFaceWidth` (median of all
  accepted face widths). `spotRadius` and teeth/hair radii become functions of
  the selected face when there is a selection, else the median.
- Makeup family: one family per face, `makeupFamily` mirrors the selected
  face; switching selection switches the palette.
- Overlay: `AnalysisRenderer.primaryFace` uses the selection, not largest.
- Landmark guard: `buildMasks` skips cheek/blush/under-eye/teeth/eye shapes
  when `!face.hasLandmarks`, and every rect is validated with
  `rect.isNull || rect.isInfinite || rect.isEmpty` before use.

Acceptance criteria:

1. Two-face photo: selecting face B changes the makeup palette and the
   blemish radius class to B's measurements; face A's skin work is unchanged.
2. Skin smoothing and blemish removal still apply to all accepted faces.
3. The analysis overlay callouts point at the selected face.
4. A landmarkless face produces no NaN/infinite extent, no crash, and no
   makeup/under-eye mask; smoothing still works inside its box.
5. A low-confidence background face is excluded from masks and from the
   analysis count.
6. Perspective: a group photo opens in the same time (no extra Vision pass)
   and selection survives save/reopen.

Tests: `test_face_selection_drives_makeup`, `test_face_confidence_filter`,
`test_landmarkless_face_masks`, `test_landmarkless_face_still_retouched`.

### 6.9 P1-5 — Operation coordination (M-13, M-4)

Files: `EditorModel.swift`, `App.swift`, views with busy overlays.

Design:

```swift
private enum OperationKind { case preview, load, export, batch, save, open, smart }
private struct OperationToken: Equatable {
    let kind: OperationKind
    let id: Int
}
private var activeOperation: OperationToken?
private var operationCounter = 0

private func begin(_ kind: OperationKind) -> OperationToken {
    operationCounter += 1
    let token = OperationToken(kind: kind, id: operationCounter)
    activeOperation = token
    isBusy = true
    return token
}
private func end(_ token: OperationToken) {
    guard activeOperation == token else { return }   // stale completion
    activeOperation = nil
    isBusy = false
}
```

Rules:

- Only `end(token)` may clear `isBusy`.
- Blocking operations (export, save, open, batch) refuse to start while
  another blocking operation is active; previews are allowed to coalesce
  behind them and are cancelled, not queued.
- Previews carry a generation; a stale completion calls `end` with its own
  token and does nothing else.
- Export keeps `exportTask`, batch keeps `batchTask`; both are cancellable and
  both check `Task.isCancelled` before committing.
- `Task.detached` work that cannot be interrupted is still safe: its result is
  discarded when the token is stale.
- Menu enablement reads `activeOperation` rather than raw `isBusy` where the
  distinction matters (Batch disabled during export, etc.).

Acceptance criteria:

1. Starting export while a preview render is in flight does not let the
   preview completion clear `isBusy`.
2. Save, open, export and batch cannot run concurrently; the second request is
   refused with a visible status, not queued forever.
3. Cancel export leaves no partial file and releases `isBusy` once.
4. Rapid slider dragging causes at most one committed preview per settled
   value; intermediate results are discarded.
5. A cancelled preview never overwrites a newer preview or the export state.
6. Unit tests can drive overlapping operations with `waitUntil`.

Tests: `test_export_stale_completion_ignored`, `test_preview_cannot_clear_export_busy`,
`test_concurrent_blocking_refused`, `test_cancel_releases_busy`.

### 6.10 P1-6 — Preview/export consistency (H-6, M-3)

Files: `ImageProcessor.swift`, `SkinEngine.swift`, `EditorModel.schedulePreview`.

Design:

- `faceWidthPx` is converted to a normalized fraction:
  `let spotFraction = faceWidthPx / max(shortSide, 1) * 0.030`.
- `SkinEngine.removeBlemishes` takes `radiusFraction` and multiplies by the
  current render's short side; no 24 px clamp.
- `localMedian`'s `factor` cap becomes resolution-aware: the factor is the
  pixel radius, capped at 64 (measured cost on 16 GB M3), not 8. Because the
  normalized radius now scales with the short side, preview and export agree
  within the cap range.
- Preview path assertion: `schedulePreview` renders `sourcePreview` and
  `masksPreview`; `process` is never called with `sourceFull` from the preview
  path. Add a unit test around the extracted `PreviewPipeline`.

Acceptance criteria:

1. On a 3000 px photo, a preview export and a full export downscaled to the
   preview size have a spot-region mean delta below 2%.
2. Normalized spot radius is within 2% between a 400 px face and a 1600 px
   face.
3. A clean image remains a no-op at both resolutions (mean delta < 0.01).
4. Export time on a 4000 px photo increases by less than 25% versus baseline.
5. Preview uses `sourcePreview` for every render triggered by a slider.

Tests: `test_preview_export_blemish_parity`,
`test_preview_export_tolerance_scaling`, `test_preview_never_uses_full_source`.

### 6.11 P1-7 — Heal stamp aspect correction (M-1)

Files: `Heal.swift`, `ImageProcessor.spotsMask`, tests.

Design: follow `ArtGeometry.shortSides`.

```swift
static func shapes(for spot: HealSpot, aspect: CGFloat) -> [CGRect] {
    let diameter = spot.radius * 2          // short-side fraction
    let width = aspect >= 1 ? diameter / aspect : diameter
    let height = aspect >= 1 ? diameter : diameter * aspect
    ...
}
```

The same aspect source (source pixel aspect, not preview) is passed at every
resolution so a stamp is round on screen and in the export.

Acceptance criteria:

1. On a 3:2 photo, a single stamp's mask bounding box is square in pixel
   space (ratio 1.0 ± 0.02).
2. On a 2:3 portrait, same.
3. A blemish under the stamp is cleared as effectively as before (prominence
   drops by the same relative amount).
4. Stamps survive crop and coordinate conversion unchanged.
5. Existing square-photo output is pixel-identical.

Tests: `test_heal_stamp_is_round` on three aspects; self-check with synthetic
blemish.

### 6.12 P2-1 — Preview mask memory (M-10)

Files: `MaskBuilder.swift`, `ImageProcessor.buildMasks`, `EditorModel`.

Design: build the preview set at `min(1600, max(previewShortSide, 768))` with a
default target of 1024; keep feather expressed in output pixels so the visual
edge does not change. Export never reuses this set (see P2-2). Add
`--memcheck` to `SelfCheck` printing peak RSS for load, preview and export.

Acceptance criteria:

1. Mask memory for a 1800 px preview drops by at least 55% versus baseline
   (from ~286 MB to ≤ 130 MB for the two sets).
2. Visual mask edges at 100% are indistinguishable (diff < 0.5% of pixels
   crossing the feather band).
3. Engine tests for smoothing, blemish and makeup pass with unchanged
   thresholds.
4. Peak RSS during a normal edit session stays under 1.2× the baseline
   measured before the change.

Tests: `test_mask_memory_budget` (opt-in), existing engine suite.

### 6.13 P2-2 — Full-resolution export masks (M-2)

Files: `ImageProcessor`, `ExportService`, `MaskBuilder`.

Design: during export, build one mask set at the export resolution (capped at
the photo's own size, or 4096 for memory), use it, then release. Reuse the
preview set only when `previewExtent == exportExtent`. Person/pose masks keep
their existing analysis path. No retention between exports.

Acceptance criteria:

1. Export mask feather measured in pixels matches the preview feather scaled by
   the resolution ratio within 5%.
2. Export of a 4000 px photo succeeds on the 16 GB M3 without swap pressure;
   peak RSS documented.
3. Batch exports build and release one file's masks at a time.
4. Single-export pixel output differs from baseline only inside mask feather
   bands (no global shift).

Tests: export mask-edge check, `--memcheck` on a 4000 px synthetic.

### 6.14 P2-3 — Even Skin Tone preserves luminance (M-14)

Files: `SkinEngine.swift`.

Design: split the flattened result into luma and chroma; keep the original
luma, mix only chroma with the smoothed chroma at `amount * 0.6`, then
recombine. Implement with a color kernel (existing kernel style) or a
YCbCr-style matrix; use the existing `CIColorKernel` pattern to avoid a new
dependency. Only the skin mask is affected.

Acceptance criteria:

1. Mean luminance of a skin patch changes by < 0.5/255.
2. Chroma standard deviation drops measurably (unevenness reduced).
3. Slider 0 is still an exact no-op; slider 100 does not clip.
4. No colour fringing at the mask feather.

Tests: `test_est_preserves_luminance`, self-check patch.

### 6.15 P2-4 — Teeth alignment mask restriction (M-15)

Files: `ImageProcessor.swift`, `SkinEngine.alignTeeth`.

Design: the grown mask is intersected with the enamel gate and the teeth mask
before the gap kernel; the kernel's displacement is clamped so it never samples
across the lip line.

Acceptance criteria:

1. Lip red-channel delta < 1/255.
2. Tooth-gap closure retains at least the current result on the synthetic
   fixture.
3. Slider 0 is a no-op.
4. No dark halo at the gum line.

Tests: `test_teeth_alignment_keeps_lip`, existing teeth checks retained.

### 6.16 P2-5 — Landmarkless face handling (M-16 remainder)

Files: `FaceAnalyzer.swift`, `ImageProcessor.buildMasks`, `AnalysisRenderer`.

Design: `hasLandmarks` is read; the face box is derived from the observation
with a validated finite rect; mask construction skips landmark-only regions;
analysis callouts fall back to face-box anchors. P1-4 already prevents null
rects; this task adds the quality fallback and the analysis copy.

Acceptance criteria:

1. A landmarkless face yields a finite face box and non-empty smoothing mask.
2. Makeup, under-eye, teeth and eye masks are empty rather than invalid.
3. Analysis overlay renders without NaN anchors and says "no landmarks".
4. No crash and no infinite extent in any tool.

Tests: `test_landmarkless_face_masks`, `test_landmarkless_face_still_retouched`.

### 6.17 P2-6 — EXIF/GPS privacy (M-6)

Files: `ImageProcessor.write`, `AppSettings`, `SettingsView`, export snapshot.

Design: strip an explicit allowlist of privacy keys: `kCGImagePropertyGPSDictionary`
and the camera identifiers (`CameraOwnerName`, `BodySerialNumber`,
`LensSerialNumber`, `UserComment`, `Artist`, `ImageUniqueID`). Preserve
orientation, ICC profile, DPI and pixel dimensions. Setting
`stripLocationMetadata` defaults to `true`; existing preferences decode to the
default when the key is missing.

Acceptance criteria:

1. A JPEG with GPS, owner and serial exports with none of them.
2. Orientation is 1, ICC profile present, colour unchanged.
3. Turning the setting off preserves the original behaviour.
4. PNG/TIFF keep their depth and profile keys.
5. Batch uses each file's own metadata and the same policy.

Tests: `test_export_strips_gps`, metadata round-trip self-check.

---

## 7. Deferred findings and why

| Finding | Reason deferred | Trigger to schedule |
|---|---|---|
| M-5 no Save in discard alert | Needs an async save inside the termination handler; P1-2/P1-3 change that flow, so it is cheaper afterwards | After P1-3 if termination still feels unsafe |
| M-7 localization parity | Low risk, no data loss; a key-count self-check is enough for now | A Persian string bug is found |
| M-8 canvas accessibility | Design pass, not a correctness fix | Accessibility milestone |
| M-11 real-photo checks opt-in | Intentional: fixtures are private | Keep opt-in |
| M-12 analysis export without a face | Needs product decision (disable vs export unannotated) | Decide with P0-4 commit review |
| L-1 deprecated CI kernels | Speed-bump only; kernels work | Bundle with P2-3/P2-4 |
| L-2 god objects | P0-2/P1-1 extract the worst duplication; a full split is a refactor project | After P2 |
| L-3 dead `largestRadius` | Cosmetic; remove inside P1-7 since it touches `Heal.swift` | P1-7 |
| L-4 arm64/ad-hoc | Distribution decision, not a bug | Only if distribution changes |
| L-5 no docs | This plan plus the audit start the docs; no separate task | — |
| L-6 untracked analysis feature | Solved by P0-4 | P0-4 |
| L-7 dead Package.swift/accessors | Cosmetic; remove when their files are next touched | Opportunistic |

---

## 8. Definition of done

For the whole plan:

1. Every P0 and P1 acceptance criterion is demonstrated with a test or a
   recorded manual run; no criterion is waived silently.
2. `Tests/run.sh` (engine + model) and `--selftest` pass on `main`.
3. `--selftest --face` on at least three private portraits passes, covering a
   close-up, a group shot and a high-resolution photo.
4. No regression in the twelve tools: each tool is exercised once manually in
   preview and once in export.
5. A v1 project written before the plan opens, edits and saves.
6. No private fixture and no build artifact is committed.
7. The audit's Critical and High findings are struck through in a short
   addendum to `TECHNICAL_AUDIT.md`, each with the commit hash and test name.