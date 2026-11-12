# StudioCore R4.3 — Project Codec and Source Resolution

Status: complete on branch `r4-3-document-codec`.

Baseline: `280fe71` (`main`, merge of R4.2).

Companion documents:

- `Docs/STUDIOCORE_R4_DOCUMENT_MODEL_REVIEW.md` — step R4.3 scope.
- `Docs/STUDIOCORE_R4_2_DOCUMENT_SESSION.md` — the session this codec follows.

## 1. What was extracted

`EditorModel` previously carried the v3 mapping, the encoder settings, the
version guard and the photo-resolution order inline. Those now live in
`Sources/RetouchStudio/Models/ProjectCodec.swift`:

| Member | Responsibility |
|---|---|
| `ProjectInput` | One snapshot: photo URL, the eight `DocumentState` fields, export settings and both auto strengths |
| `ProjectCodec.makeProject(_:bookmarks:)` | The same v3 mapping and normalization as before: zero long edge, empty collections, default analysis and identity orientation become `nil` |
| `ProjectCodec.encode(_:)` | `JSONEncoder` with `[.prettyPrinted, .sortedKeys]`, no other strategies |
| `ProjectCodec.decode(_:)` | `JSONDecoder` plus the version guard; newer files throw `ProjectCodecError.tooNew(version)` |
| `ProjectSourceAccess` | Port asking whether a path exists; `FileProjectSourceAccess` is the Foundation adapter |
| `ProjectBookmarkStore` | Port making and resolving bookmarks; `URLBookmarkStore` is the Foundation adapter |
| `ProjectSourceResolver` | Bookmark → absolute path → sibling, unchanged order |

`EditorModel` now builds a `ProjectInput` from `currentState`, delegates
`makeProject`, `writeProject`, `rewriteProject`, `openProject(at:)` and
`resolveProjectImage`, and maps `tooNew` to the existing `.projectTooNew`
status. Panels, alerts, `UserDefaults`, autosave, recovery, UTType and the
save/load ordering stay in the shell.

## 2. Serialization lock

`Tests/Fixtures/ProjectV3/project-v3-full.retouch` was written by the
pre-extraction encoder. It covers all 16 stored fields, including optional
collections, a bookmark, crop, orientation, analysis and one AI edit. Fixed
identifiers and date make it deterministic; a single analysis region avoids
unordered-set iteration.

Two tests compare bytes:

- `testProjectV3BaselineByteIdentity` decodes with `JSONDecoder` and re-encodes
  with the recorded encoder settings.
- `testProjectCodecReproducesBaseline` does the same through `ProjectCodec`.

Both reproduce 4717 bytes exactly on arm64 and Rosetta x86_64.

## 3. Tests

| Test | Checks |
|---|---|
| `testProjectCodecFieldMapping` | Every input field reaches the project |
| `testProjectCodecNormalization` | All five normalization rules |
| `testProjectCodecLegacyDecode` | Missing version reads as 3, later optionals as `nil`, unknown keys ignored |
| `testProjectCodecVersionGuard` | v4 refused with its version; v3 and v1 still decode |
| `testProjectCodecReproducesBaseline` | Codec bytes equal the fixture |
| `testProjectSourceResolverOrder` | Bookmark first, absolute fallback, sibling fallback, no source |
| `testProjectCodecRelinkRewrite` | Relink records the new path, bookmark and survives a round trip |

Results: 56 focused checks pass on arm64 and Rosetta; the full model suite
reports 789 checks, zero failures, on both architectures.

## 4. Known property

`AnalysisSettings.regions` remains a `Set`, so its unkeyed array order is not
stable across processes when more than one region is selected. The baseline
fixture therefore uses one region. This predates R4.3 and is not a format
change; a future portability step must not rely on set order.
