# StudioCore R4.5 — Export Planner

Status: complete on branch `r4-3-document-codec`.

Baseline: `e05ac00` (R4.4).

## 1. What was extracted

`EditorModel` made the export decisions in six computed properties and two
methods. Those decisions now live in `ExportPlanner`
(`Sources/RetouchStudio/Models/ExportPlanner.swift`):

| Decision | Rule |
|---|---|
| `effectiveFormat` | Analysis enabled, overlay-only and at least one face → PNG; otherwise the chosen format |
| `suggestedFileName()` | `<base>-retouched`, `-analysis`, `-analysis-poster`, or `-analysis-lines.png`; empty base → `retouched`; no face means no analysis suffix |
| `upscaleAvailable` | Long edge > 0, photo smaller than it, and `ExportUpscale.canHandle` |
| `usesUpscale` | Requested and available |
| `upscaleEstimate` | `ExportUpscale.estimatedSeconds` |
| `pixelSize` | Downscale to the requested edge; upscale only through `ExportUpscale.outputLongEdge`, never past 4x |
| `snapshot(includeStamps:includeAnalysis:)` | The same `ExportSnapshot` fields, including privacy policy, watermark and the resolved upscale flag |

`EditorModel` keeps the same public computed properties as one-line delegates,
so the sheet, size text and export path read one planner. `saveExport`, the
save panel, source protection, the engine call, busy flags and status tokens
stay in the shell. `ExportService` and the renderer are untouched.

## 2. What stayed in the shell

- `NSSavePanel`, the export sheet and the suggested name's UI use.
- The pre-render and commit-time source-protection checks in `ExportService`.
- Operation tokens, cancellation, detached render, progress status and result
  tokens.
- The clean baseline: exporting still does not mark the document saved.

## 3. Tests

- `testExportPlannerNaming` — base names, empty name, on-photo/poster/
  overlay-only suffixes, overlay-only PNG, and a face-less document falling back
  to the plain name and chosen format.
- `testExportPlannerPixelSize` — no edge, downscale, upscale off/on, the 4x
  ceiling, the 40-megapixel guard and the measured estimate.
- `testExportPlannerSnapshot` — every snapshot field, batch inclusion toggles,
  `nil` long edge and an overlay-only snapshot.

Results: full model suite 837 checks, zero failures, on arm64 and Rosetta
x86_64 (the x86 log interleaves one runtime log line, so its raw `✓` count is
one higher). Corpus hashes unchanged; `git diff --check` clean.
