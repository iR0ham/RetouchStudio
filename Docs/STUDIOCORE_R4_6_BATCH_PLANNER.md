# StudioCore R4.6 — Batch Planner

Status: complete on branch `r4-3-document-codec`.

Baseline: `fd274ad` (R4.5).

## 1. What was extracted

`exportOne` used to decide, inline, which part of the document snapshot one
batch file inherits, whether the crop was skipped, whether the upscaler still
applies after loading the file, and what unique name to write. Those decisions
now live in `BatchPlanner` (`Sources/RetouchStudio/Models/BatchPlanner.swift`):

| Member | Rule |
|---|---|
| `plan(for:fileAspect:)` | Delegates to the existing `BatchExportPolicy`: the open document keeps its exact snapshot; other files keep the crop only when orientation is identity and the aspect matches, always drop AI patches, reset orientation and face choice, and clear dragged endpoints and anchors |
| `skippedCrop` | True only when the document had a crop and this file did not keep it |
| `fitUpscale(_:to:)` | Disables upscaling when the loaded file already reaches the requested edge or exceeds the helper's 4x ceiling |
| `uniqueOutputURL(for:in:format:exists:)` | `<base>-retouched.ext`, then `-2`, `-3` …; the existence check is injectable |

`EditorModel.exportOne` now asks the planner, then performs the same steps:
cancellation check, per-file load, render, cancellation check, name, write hook,
cancellation check, write and outcome. The batch sheet, folder picker, task
lifecycle, generation guard, per-file detached task, progress counters and
cancellation tokens stay in the shell. `BatchExportPolicy` and `ExportService`
are unchanged.

## 2. Tests

- `testBatchPlannerFilePolicy` — the document's own snapshot is returned
  unchanged even when its aspect is unknown; a same-shape file keeps the crop,
  look, format and quality but loses patches, orientation, face choice and
  callout pins; a different shape and a turned document both drop the crop and
  report the skip.
- `testBatchPlannerUpscaleAndNaming` — upscale kept, dropped at the requested
  edge, dropped past the 4x ceiling and left off when unrequested; plain, `-2`
  and `-3` names plus the format extension.

Results: full model suite 855 checks, zero failures, on arm64 and Rosetta
x86_64. Corpus hashes unchanged; `git diff --check` clean.
