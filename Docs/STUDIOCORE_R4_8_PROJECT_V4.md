# StudioCore R4.8 — Project v4 and Geometry Migration

Status: complete on branch `r4-3-document-codec`.

Baseline: `9c7b474` (R4.7).

## 1. Format decision

v4 is a **file format**, not a second in-memory document model. A v4 file
decodes to the same `RetouchProject` every call site already uses, including its
`version` value of 3. Only the file layer knows the difference:

- `ProjectWriteContext` records how the open document was stored: the source
  version, the unknown top-level fields, and the features the file requires.
- `EditorModel` keeps that context next to `projectURL` and passes it to every
  save. A v3 file stays v3; a v4 file stays v4. Nothing is upgraded silently.
- New documents use `ProjectWriteContext.v3`.

`ProjectCodec.currentVersion` is now 4, so the existing guard refuses version 5
and later before decoding.

## 2. v4 schema

`ProjectV4` (`Sources/RetouchStudio/Models/ProjectV4.swift`) writes the same 15
document fields as v3, plus `requiredFeatures`, with portable geometry:

| v3 encoding | v4 encoding |
|---|---|
| `CGRect` as `[[x, y], [w, h]]` unkeyed arrays | `StudioRect` as `{"x", "y", "width", "height"}` |
| `CGPoint` as `[x, y]` | `StudioPoint` as `{"x", "y"}` |
| `CGSize` as `[w, h]` | `StudioSize` as `{"width", "height"}` |
| `Set<AnalysisRegion>` as an array in set order | sorted `[AnalysisRegion]` by raw value |
| endpoints/anchors as unkeyed points | dictionaries of named points |

Healing stamps, stickers, AI edits (box, pixel size, patch orientation) and the
analysis overlay all use the portable records. Data, dates, enums and the
adjustment block keep their v3 representation, so no value changes.

v4 adds `requiredFeatures: [String]?` at the top level. This build supports
`portable_geometry`; reading a file that requires anything else throws
`ProjectCodecError.unsupportedFeatures` instead of opening a document it cannot
honor. This is the same shape a future feature (for example color management)
can extend without a new version number.

## 3. Migration and projection

- v3 → v4: `ProjectV4(project:)` maps CoreGraphics values into `StudioCore`
  records. It is lossless; `v3 → v4 → v3` reproduces the v3 baseline fixture
  bytes exactly.
- v4 → v3: `ProjectV4.project` maps the records back. The result is a normal
  version 3 `RetouchProject`, readable by the 1.0 reader.
- v3 saves remain byte-identical to the baseline; `ProjectCodec.encode(_:)` is
  untouched and still behind the baseline-fixture test.
- v4 saves are deterministic: sorted keys plus the sorted region list mean the
  same project writes the same bytes on arm64 and x86_64.

## 4. Unknown data

`ProjectCodec.read` decodes the file once as `[String: ProjectJSONValue]`,
takes every top-level key the schema does not own, and stores it in the write
context. A later save merges those keys back after encoding the typed document.
Known keys always win, so unknown data cannot overwrite a value this build
understands. This works for both v3 and v4 files; the merge is skipped when
there is nothing unknown, which keeps v3 output byte-identical.

`ProjectJSONValue` preserves null, booleans, integers, doubles, strings,
arrays and nested objects, so a key added by a newer build survives a round
trip unchanged. Nested unknown fields inside known objects are not preserved:
the known object is decoded into its typed model and re-encoded.

## 5. EditorModel wiring

- `load(...)` and `apply(...)` accept an optional `ProjectFile`. After the
  project URL is restored, `projectWriteContext` becomes the file's context
  (or `.v3` for photo/recovery loads). The relink rewrite that follows already
  uses the same context.
- `openProject(at:)` reads through `ProjectCodec.read`, opens
  `file.project`, and passes the file through. `tooNew` still maps to
  `.projectTooNew`; `unsupportedFeatures` and other codec errors map to
  `.projectOpenFailed`.
- `writeProject` and `rewriteProject` encode with the stored context.
- Undo/redo, recovery candidates, autosave timing and the project resolver are
  unchanged.

## 6. Compatibility

- v3 projects remain readable; the baseline fixture still encodes to the same
  bytes.
- v3 files stay v3 after edits; v4 files stay v4 after edits.
- Recovery snapshots still store the v3 projection of the document. A v4 file's
  unknown fields and `requiredFeatures` are therefore not carried through crash
  recovery (see Limitations).
- No image-processing, color, AI or UI code changed.

## 7. Tests

New tests, all registered in the model suite:

- `testProjectV4PortableGeometry` — keyed crop/stamp/sticker/AI records, named
  analysis pins, sorted regions, v4 context, and every geometry value surviving
  the read-back.
- `testProjectV3ToV4Migration` — the v3 baseline is read, written as v4,
  projected back, and reproduces the baseline bytes; the projected document
  opens with the 1.0 reader.
- `testProjectV4FixtureCrossArchitecture` — the committed
  `Tests/Fixtures/ProjectV4/project-v4-full.retouch` (generated once from the
  v3 baseline, with one unknown key and `requiredFeatures`) reads, re-encodes
  byte-identically, and projects to the v3 baseline bytes on both
  architectures.
- `testProjectUnknownFieldsSurvive` — scalar, object and array unknown values
  survive a re-encode.
- `testProjectV4Capabilities` — a supported requirement opens; an unknown
  requirement is refused without changing the project.
- `testProjectV4EditorRoundTrip` — opening a v4 file, editing and saving keeps
  version 4, the unknown key and keyed geometry, and persists the edit; the
  same flow on a v3 file keeps version 3 and its unkeyed crop. The byte check
  compares geometry values because v3's `Set` encoding depends on insertion
  order, not only on content.
- The version-guard tests now use `currentVersion + 1`.

Results: full model suite 917 checks, zero failures, on arm64 and Rosetta
x86_64 (identical check counts). Corpus 47 files unchanged; `git diff --check`
clean.

## 8. Limitations

- Recovery snapshots keep the v3 projection, so a crash-restored v4 document
  loses its unknown top-level fields and `requiredFeatures` on the next save.
  The document itself is intact; only unknown future data is dropped. Carrying
  the context through `RecoverySnapshot` would be a format change and was left
  out of R4.8.
- Unknown fields nested inside known objects are not preserved.
- No Windows or Linux build or test was run. StudioCore itself is
  Foundation-only and the v4 encoding uses Foundation JSON, but that is a
  design property, not a validated platform claim.

## 9. Hardening addendum (2026-11-12)

This addendum supersedes the recovery statements in Sections 6 and 8.

- Recovery snapshots now optionally store `fileContext`, a `ProjectWriteContext`
  describing the open document's file: its version, unknown top-level keys and
  required features. Autosave and the rest of the restore path pass it through,
  and a restore opens the recovered document with that context, so a crash-
  recovered v4 document saves as v4 again and keeps its `requiredFeatures` and
  unknown top-level keys.
- The stored payload is still the v3 `RetouchProject`. Only the file-level facts
  travel beside it; `ProjectV4` JSON is never written into `project`.
- A context that carries no file metadata is not stored at all
  (`ProjectWriteContext.carriesFileMetadata`), so a v3 snapshot is
  byte-identical to what earlier builds wrote and a legacy version 0 bare
  project still decodes.
- A recovery copy whose `fileContext` reports a newer version, or a required
  feature this build does not support, is refused: no prompt is shown, nothing
  is restored, and the candidate stays on disk byte-identical for a build that
  can read it. It is never deleted, quarantined or promoted.
- Nested unknown fields remain a documented limitation. The writer rule for
  future changes is: nested additions require a version or `requiredFeatures`
  bump. A build that adds a nested key without one cannot count on it
  surviving a round trip through an older build.
- This is preservation of the file facts the document was opened with, not a
  full forward-compatibility claim. A newer build's semantics, nested data and
  unknown enum values are still outside this build's contract.
