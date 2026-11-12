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
trip unchanged.

Inside the records this build models (the top-level known keys), the same
guarantee now holds recursively. `ProjectCodec.read` re-encodes the decoded
`ProjectV4` and diffs it against the file: every key, object value or array
entry the typed model did not explain is captured as a `ProjectUnknownFields`
overlay in the write context, and a later save writes that overlay back over
the freshly encoded record. Known keys always win, and an overlay never
re-introduces a record the owner deleted. Array entries are matched by their
`id` first, then by their exact known JSON, and by position only when the array
kept its length, so inserting or removing a neighbour cannot hand one record's
unknown data to another. This replaces the earlier limitation that nested
unknown fields were dropped (Section 10).

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
- ~~Unknown fields nested inside known objects are not preserved.~~ Superseded
  by Section 10 (2026-11-12).
- No Windows or Linux build or test was run. StudioCore itself is
  Foundation-only and the v4 encoding uses Foundation JSON, but that is a
  design property, not a validated platform claim.

## 9. Hardening addendum (2026-11-12)

This addendum supersedes the recovery statements in Sections 5, 6 and 8.

- Recovery snapshots now optionally store `fileContext`, a `ProjectWriteContext`
  describing the open document's file: its version, unknown top-level keys and
  required features. Autosave and the rest of the restore path pass it through,
  and a restore opens the recovered document with that context, so a crash-
  recovered v4 document saves as v4 again and keeps its `requiredFeatures` and
  unknown top-level keys.
- The stored payload is still the v3 `RetouchProject`. Only the file-level facts
  travel beside it; `ProjectV4` JSON is never written into `project`.
- A context that carries no file metadata is not stored at all
  (`ProjectWriteContext.carriesFileMetadata`), so a snapshot of a v3 document
  with no extra file metadata is byte-identical to what earlier builds wrote and
  a legacy version 0 bare project still decodes. A v3 document that did carry
  unknown top-level keys does store the context, so those keys survive.
- A recovery copy whose `fileContext` reports a newer version, or a required
  feature this build does not support, is refused: no prompt is shown, nothing
  is restored, and the candidate is left byte-identical on disk for a build that
  can read it. It is not deleted and not promoted. This refusal-and-retention
  behavior applies when the snapshot decodes and its `fileContext` can be
  inspected.
- That guarantee does not extend to unreadable snapshots. A snapshot whose
  payload this build cannot decode at all is quarantined by
  `RecoveryStore.loadCandidates()` and `prepareForLaunch()` before the refusal
  logic can run; `quarantine(_:)` moves the file into `quarantine/` without
  deleting it. Refusal is therefore not an unconditional guarantee against
  quarantine for unreadable future formats.
- ~~Nested unknown fields remain a documented limitation.~~ Superseded by
  Section 10 (2026-11-12): nested unknown fields are now captured and written
  back. The recovery context stores the nested overlay beside the top-level
  keys, so a crash-restored v4 document keeps it too.
- This is preservation of the file facts the document was opened with, not a
  full forward-compatibility claim. A newer build's semantics, nested data and
  unknown enum values are still outside this build's contract.

## 10. Nested unknown-field addendum (2026-11-12)

This section supersedes the "nested fields are dropped" statements in Sections
4, 8 and 9.

- `ProjectCodec.read` now captures the difference between the file and the
  record this build writes back, for every top-level key it models. The
  difference is stored as a `ProjectUnknownFields` overlay (a value, an object
  or an array of elements) in `ProjectWriteContext.nestedUnknowns`.
  `ProjectWriteContext` is Codable, so recovery snapshots carry the overlay
  beside `unknownFields` and `requiredFeatures`. A context without an overlay
  encodes without the key, so v3 snapshot bytes are unchanged.
- `ProjectCodec.encode(_:context:)` applies the overlay after encoding the
  typed record. A known key is never replaced by captured data, and an overlay
  for a record that no longer exists is dropped instead of resurrecting it.
- Array elements are matched by `id` (stickers, AI edits), then by their exact
  known JSON, and by position only when the captured and current arrays have
  the same length. Inserting a neighbour keeps each record's unknown data with
  it; removing a record discards that record's data.
- v3 is intentionally unchanged: `read` captures no nested data for a v3 file,
  and the baseline fixture still round-trips byte for byte.
- Tests: `testProjectV4NestedUnknownFieldsArePreserved` (four depths, every
  JSON value kind, edits on known siblings, byte-identical second save),
  `testProjectV4UnknownFieldsFollowArrayRecords` (inserted, surviving and
  removed records), `testProjectV3NestedCaptureIsAbsent` (v3 untouched), and
  the `ProjectStore` read-modify-write and failed-write checks in
  `Tests/StudioCoreTests.swift`.
- Residual limitation: when the owner edits an id-less array element (for
  example a healing stamp's centre) *and* the array length changes in the same
  save, the element can no longer be matched, so its unknown data is dropped
  rather than attached to the wrong record. Elements with an `id`, and id-less
  elements whose array length is unchanged, keep their data.
