# StudioCore R4.4 — Document Restoration and Load Boundary

Status: complete on branch `r4-3-document-codec`.

Baseline: `2b1290d` (R4.3).

## 1. What was extracted

`EditorModel.apply(_:)` used to map a decoded project, or the absence of one,
onto fourteen published fields inline. That mapping now lives in
`DocumentRestoration` (`Sources/RetouchStudio/Models/DocumentRestoration.swift`):

| Field | Project value | Plain photo |
|---|---|---|
| `exportFormat` | `ExportFormat(rawValue:) ?? .jpeg` | left unchanged (`nil`) |
| `exportQuality` | recorded | left unchanged |
| `exportLongEdge` | recorded, `nil` → 0 | left unchanged |
| `autoRetouchStrength` | recorded | left unchanged |
| `autoColorStrength` | recorded, `nil` → 100 | left unchanged |
| `state.adjustments` | recorded | `Adjustments()` |
| `state.healSpots` / `stickers` / `aiEdits` | recorded, `nil` → `[]` | `[]` |
| `state.analysis` | recorded, `nil` → `AnalysisSettings()` | default |
| `state.crop` / `orientation` / `selectedFaceIndex` | recorded, `nil` → identity/none | identity/none |
| `isProject`, `projectURL` | true, file URL | false, nil |

`EditorModel.apply` now installs the pixels, then applies one restoration value,
and keeps every side effect: overlay rebuild, clean baseline, recovery dirty
state, view reset, recent list, status token, missing-asset status and relink
rewrite.

## 2. What stayed in the shell

- `load(url:restoring:projectURL:relinkURL:recoveryRestore:)` and its operation
  token, generation guard, cancellation of batch work and failed-load
  preservation.
- Panels, discard alert, recovery-readiness barrier, `locatePhoto`, recovery
  restore finishing and autosave invalidation.
- `install(_:)` pixel state (`CIImage`, masks, `NSImage`, preset thumbnails).

The recovery files and `RecoverySnapshot` are untouched; recovery handoff
ordering is identical to R4.3.

## 3. Tests

- `testDocumentRestorationFromProject` — all restored fields, including a
  non-identity orientation, crop, analysis, selected face and both auto
  strengths.
- `testDocumentRestorationDefaultsAndPhoto` — v3 defaults (`nil` long edge → 0,
  `nil` auto color → 100, unknown format → JPEG), empty state for a project
  without document fields, and a plain photo leaving export/auto settings
  untouched.

Results: full model suite 807 checks, zero failures, on arm64 and Rosetta
x86_64. Corpus hashes unchanged; `git diff --check` clean.
