# Project Schema v5 — persistent masks

**Status:** codec, ABI and macOS app wiring IMPLEMENTED, locally tested and CI
verified; merged to `main` as `49a0a15` (PR #58) on 2026-11-15 and carried into
`develop` by `0b55606` (codec committed as `a675078`, app wiring as `b0a8676`
plus the recovery snapshot fix on top). A Quick Edit now stores the mask it was
drawn from beside the edit as one undo step, a reopened project shows its mask
again when the pixels still match, the refined raster lives in a cache keyed by
the mask id, and an autosave keeps masks and face identities so a crash restore
does not lose them. A `requiredFeatures` entry this build cannot honor is
refused on v5 exactly as on v4 (`testProjectV5Capabilities`).

Evidence:

| Check | Result |
|---|---|
| `Tests/run-studiocore.sh` (arm64 and x86_64) | 287 checks passed |
| `Tests/run-abi.sh` (arm64 and x86_64) | ABI TESTS: PASS (104 checks) |
| `Tests/run.sh` (arm64: engine, model, runtime process, runtime v2) | all four suites PASS, exit 0; the model suite carries the `[v5]` checks, including the recovery snapshot and the capability refusal |
| Windows suite (CI only; no Windows machine here) | run 43719176158 on `3996049`: `Windows StudioCore` 287 core checks, ABI 104 checks, `R1 conformance: PASS`; `Windows App` 295 host checks and the twelve UI modes |

Windows reads and writes v5 through this same Swift codec behind the C ABI
(`StudioCoreABI`); there is no second parser to keep in step.

## 1. Three concepts, kept apart

| Concept | Lives in | Is authoritative? |
|---|---|---|
| **Face identity** | `faceIdentities` array (`FaceIdentityRecord`) plus the runtime `FaceIdentityTracker` | The persisted record keeps an *association* resolvable; it is not a detection cache. Detection still runs on every open. |
| **Persistent mask data** | `masks` array (`MaskRecord`) | Yes. Ids, strokes, box, inversion, parameters, revision and the face association are user data. |
| **Derived cache** | files an optional `refined` reference points at | No. Deleting it costs recomputation, never the mask. |

A mask never owns a face, and a face record never contains masks: the mask
carries `faceId`, the identity record carries the box.

## 2. Version rules

| Rule | Where |
|---|---|
| Readable ceiling is 5; a higher `version` is refused as `tooNew` | `Sources/StudioCore/ProjectCodec.swift`, `read(_:)` |
| `version >= 5` decodes `ProjectV5`; `4` decodes the frozen `ProjectV4`; below that the legacy v3 model | same function |
| A v3 or v4 file keeps its version on save | `encode(_:context:)` |
| A document that carries masks or face identities saves as v5 even when read as v3/v4 | `writeVersion(for:context:)` — the one deliberate upgrade, because no earlier version has a key that could hold the data |
| No v5-only required feature: a v5 reader always understands masks; an older reader is refused by the version guard rather than silently dropping them | `ProjectV5.supportedFeatures` |

## 3. The `masks` record

Array order is insertion order and is stable; identity never comes from the
position. Every field is typed; unknown keys are preserved (section 6).

| Key | Type | Meaning |
|---|---|---|
| `id` | UUID string | Stable forever. Never derived from an index or a face rank. |
| `kind` | string | `"selection"` today. An unknown kind is carried and not applied. |
| `revision` | int | Increments when the owner changes the mask; a cache raster older than the revision is stale. |
| `updatedAt` | number | Foundation reference-date seconds, like `AIEdit.createdAt`. |
| `space` | string | `"source_normalized"` today. |
| `frame` | `{width, height}` ints | Pixel size of the source photo the mask was drawn against. |
| `strokes` | array | `{points: [{x,y}…], width, erase}`; `width` is a fraction of the photo width. |
| `box` | optional rect | `{x, y, width, height}` in the same space. |
| `inverted` | bool | The selection means "everything except". |
| `parameters` | optional | `{feather?, opacity?}`; absent means the tool default. |
| `refined` | optional | `{file, sha256, width, height}` — a derived raster beside the mask id, never authoritative. |
| `faceId` | optional UUID | Names a `faceIdentities` entry. Not a container, not a rank. |

`faceIdentities` entries are `{id, box, source}`: the person's original-photo
box in the same top-left space, as evidence for re-finding them after a reopen.

## 4. Coordinates and lifecycle

Masks live in **source-normalized, top-left, upright, uncropped** space — the
space `crop`, `healSpots`, the AI edit `box` and `selectedFace`'s detector all
already use (`Sources/StudioCore/StudioGeometry.swift`).

- **Crop, quarter turn, straighten, export resize**: never rewrite mask numbers.
  The crop is stored separately and applied around them. A regression check
  asserts masks are byte-identical after a crop and a turn.
- **Image replacement**: a mask whose `frame` differs from the open photo's
  decoded pixel size is not applied; the host must say so instead of placing it
  at coordinates that now mean something else. Same-size replacement is not
  detectable from `frame` alone — NOT VERIFIED as detectable, and treated as a
  limitation rather than a promise.
- **Derived raster**: `refined.file` lives in a store named by the mask id. A
  missing file or a digest mismatch means "recompute or redraw", never "apply
  anyway". The geometry alone is a complete mask; `hasContent` is true without
  any raster.
- **Crash recovery**: an autosave is a save, so `RecoverySnapshot` stores the
  masks and face identities beside the project body, which the frozen v3 writer
  cannot express, and a restore puts them back on the document before load. A
  snapshot without them omits both keys, so unchanged v3 snapshots keep their
  exact bytes and the wrapper stays version 1.

## 5. Determinism and cross-host bytes

Writers use `JSONEncoder` with `.prettyPrinted, .sortedKeys`; analysis regions are
already sorted for this reason. Windows never writes the file itself: it edits a
JSON tree and calls `sc_project_write`, whose output is the Swift codec's
canonical bytes, so both hosts produce **identical files** for the same
document. The Windows in-memory compact encoding is history/recovery only.

## 6. Unknown fields

- Top level: keys outside `ProjectV5.knownKeys` are captured in the write context
  and merged on save; a known key always wins.
- The v3 writer is frozen and has no nested capture: unknown keys *inside* a
  v3 array element are not preserved when a v3 file is resaved as v3. v4 and v5
  preserve them.
- Nested inside `masks`, `faceIdentities`, geometry and parameters: captured as
  a raw-vs-typed diff and re-applied. Array elements attach by `id` first, then
  by exact known value, then by position only when the length is unchanged — so
  a removed mask cannot hand its data to a neighbour. This is the same machinery
  v4 already used for `healSpots` and `stickers`.

## 7. Windows

- `sc_project_read` now emits the canonical **v5** document for a v5 file (a
  v1–v4 file still arrives as v4), so masks cross the boundary. `DocumentModel`
  edits only fields it knows and carries the rest raw.
- `DocumentModel.UnsupportedEdits` names `"masked selections"` when `masks` is
  non-empty, so an export that cannot render them is confirmed, not silent.
- Windows does not create masks and does not resolve `faceId`.

## 8. Migration

| From | Behaviour |
|---|---|
| v1/v2 | decode through the v3 model with defaults; save as the file's version; a document that gains masks saves as v5 |
| v3 | stays v3 unless masks/face identities are present → v5 |
| v4 | stays v4 unless masks/face identities are present → v5 |
| v5 | stays v5 |

There is no in-place rewriting of a file on open. The upgrade happens at save
and only when the document carries data the older version cannot express.

## 9. The twelve required checks

| # | Check | Where | Status |
|---|---|---|---|
| 1 | Save/reopen with masks | `StudioCoreTests` M8 (in-memory and `Tests/Fixtures/ProjectV5/project-v5-full.retouch`) | LOCAL PASS |
| 2 | Face identity + mask association | same: `faceId` resolves to a stored identity; Windows `Interchange`; `[v5]` model checks for minting, re-attach by overlap and one-id-one-face | LOCAL PASS (codec and macOS model) |
| 3 | Multiple masks | M8: two masks keep ids and order | LOCAL PASS |
| 4 | Mask parameters | M8: strokes, erase, box, inversion, feather/opacity | LOCAL PASS |
| 5 | Unknown fields | M8: top-level and inside a mask, reattached by id after reorder; removed mask drops its data; ABI fixture carries both | LOCAL PASS |
| 6 | Migrations from every older version | M8: v3/v4 fixtures stay their version; masks raise to v5 | LOCAL PASS |
| 7 | macOS/Windows interpretation | `Tests/ABI/Fixtures/project-v5.json` through the C ABI; Windows `Interchange` v5 block | ABI LOCAL PASS; Windows CI PENDING |
| 8 | Crop keeps coordinates | M8: crop + quarter turn leave masks identical; `[v5]` model check maps canvas points through the crop and back | LOCAL PASS (codec and canvas mapping) |
| 9 | Replaced image must not reuse masks | `MaskRecord.applies(toWidth:height:)` refuses a different frame, and the open path only restores a mask whose frame matches the installed pixels | LOCAL PASS (rule and open path) |
| 10 | Cache delete + regenerate | M8: a mask is complete without `refined`; `[v5]` model check adopts, reloads, refuses changed bytes and removes the folder | LOCAL PASS (contract and store) |
| 11 | Deterministic serialization | M8: encode-twice and read-modify-write byte identity; fixture byte identity | LOCAL PASS |
| 12 | Backward compatibility | M8: v4 fixture resaves byte for byte; v6 refused as `tooNew` | LOCAL PASS |

Recovery is a second save path: the `[v5]` model check
`testRecoverySnapshotCarriesMasks` proves a crash copy carries masks and face
identities beside the frozen v3 body, a restore hands them back, an unchanged v3
snapshot keeps its shape, and a bare project still decodes as a legacy copy.

## 10. Limitations and open work

- Face identities are persisted and re-attachable by box overlap; the runtime
  tracker's ids are still Ints and the project still stores `selectedFace` as an
  index. Stable selection ids remain WS-2 work.
- A mask attaches to a person only when the chosen face's box contains the
  mask's centre. A brush that spans two people is stored without a `faceId`
  rather than guessed.
- Same-size image replacement is not detected.
- Windows cannot render masks; it confirms and preserves them.
- Undo restores both the edit and its mask; removing the last edit leaves the
  mask record in place, because the mask is a separate drawing the owner made.
- The restored mask is shown in the AI selection; the raster is trusted only
  when its digest matches, and its geometry is used otherwise.
- The retouch worker's `feather` and `dilate` are passed in the worker's own
  pixel units, so `parameters` is not written yet: storing a number whose unit
  is not verified would invent meaning.
