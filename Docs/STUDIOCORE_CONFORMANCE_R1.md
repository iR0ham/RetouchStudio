# StudioCore R1 conformance foundation

**Status: R1 draft — infrastructure only.** R1 prepares contracts and fixtures
for a future StudioCore. It does not create a production module, move Swift
types, refactor `EditorModel`, change the v3 project format, implement v4,
alter Recovery or the AI runtime, or change the macOS UI.

Every file described here lives under `Tests/Conformance/` except this document
and `Docs/STUDIOCORE_CANONICAL_JSON.md`. The existing application sources,
build scripts, default tests, corpus fixtures, baselines, references, and export
files are unchanged.

Read with:

- `Docs/STUDIOCORE_CANONICAL_JSON.md` — byte-level serialization.
- `Docs/STUDIOCORE_INTERFACE_DESIGN.md` — the proposed document model and ABI.
- `Docs/STUDIOCORE_ARCHITECTURE.md` — engine boundary and pipeline.
- `Docs/STUDIOCORE_EXTRACTION_ROADMAP.md` — R0/R1/R2 sequencing.

---

## 1. What R1 freezes, and what it does not

Frozen for the R1 gate:

- the canonical JSON byte form and hash rule,
- the fixture envelope and schema integers,
- the document, render-plan, export, error, and progress shapes used by the
  fixtures,
- the 17-stage render order and its stage-to-operation mapping,
- the domain error code names,
- the draft C ABI declarations and their ownership rules,
- the identity of the existing golden corpus (hashes and counts).

Not frozen, and explicitly **provisional**:

- the operation storage order in documents,
- lowercase UUID text as the only accepted spelling,
- the exact fixture envelope (a production format may wrap differently),
- the C ABI layout, which is a draft and has no implementation,
- cross-language byte equality, which has not been tested,
- the relationship between these fixtures and the v3 file format.

Not claimed:

- no new renderer exists or was executed,
- no Rust, C++, or Qt code exists,
- the app does not use any of this at runtime,
- the golden corpus was not regenerated or re-baselined,
- no native Intel, Windows, or Linux validation was performed.

---

## 2. Contracts

### 2.1 Document

A document fixture is `{"schema": 1, "document": {...}}`. Required document
members:

| Member | Shape | Notes |
|---|---|---|
| `id` | lowercase UUID | Stable document identity |
| `revision` | unsigned integer | Increases on committed edits; `0` for a new document |
| `selectedFace` | integer or `null` | Index into analysis faces |
| `capabilities` | string array | Features the writer used |
| `requires` | string array | Features a reader must support |
| `source` | object | See below |
| `assets` | `{schema, assets[]}` | Package asset table |
| `operations` | `{schema, coordinateSpace, operations[]}` | `coordinateSpace` is `source_normalized` |
| `metadata` | object | Title, timestamps, writer versions, `unknown` bag |

`source` records `assetId`, `fileName`, nullable portable `relativePath`,
`external`, `embedded`, `orientationNormalized`, `bytes`, `quickIdentity`
(`size`, nullable `modifiedAt`), nullable `contentHash`
(`algorithm: "sha256"`, `hex`), `pixelWidth`, `pixelHeight`, and `colorSpace`
(`name`, nullable `iccHash`). A source whose file name matches a golden-corpus
fixture must carry that fixture's SHA-256; the runner enforces this.

An asset entry records `assetId`, `kind`, `mediaType`, portable `path`,
`bytes`, and lowercase SHA-256. Paths are relative, use `/`, and must not
escape the package.

Operation types and their payloads:

| `type` | Payload | Singleton |
|---|---|---|
| `orientation` | `quarterTurns` 0...3, `flipped`, `angle` | yes |
| `heal` | `spots[]` of `{center{x,y}, radius}` | no |
| `aiPatch` | `editId`, `box`, `orientation`, `imagePixels`, `patch`, `alpha`, `provenance` | no |
| `retouchParameters` | `params` object | yes |
| `stickers` | `items[]` of `{id, kind, center, size, rotation, opacity, color{h,s,v}}` | no |
| `crop` | `rect{x,y,width,height}` | yes |
| `analysis` | `settings`, `snapshot: null` in R1 | yes |

`aiPatch.patch` and `aiPatch.alpha` reference asset-table entries by
`assetId` and repeat the SHA-256; a missing entry is `ASSET_MISSING`, a
mismatched hash is `ASSET_HASH_MISMATCH`. Provenance records engine, model ID
and version, preset, prompt, seed, worker protocol, start time, and seconds.
R1 fixtures keep analysis snapshots `null`; embedded snapshots are a later
decision.

Storage order is non-decreasing rank: `orientation` 0, `heal` 1, `aiPatch` 2,
`retouchParameters` 3, `stickers` 16, `crop` 17, `analysis` 18. This order is
provisional and is not the current v3 on-disk order.

Validation failures use `VALIDATION_FAILED`; an unknown entry in `requires`
uses `UNSUPPORTED_FEATURE`. Invalid fixtures pin both.

### 2.2 Render plan

A render plan is a top-level object with `schema: 1`. It is the payload a shell
would send to a core. Required members:

- `documentRevision` — must equal the linked document's `revision`.
- `source` — `width`, `height`, `colorSpace.name`; must equal the document's
  source pixels and color space.
- `orientation`, `crop`, `parameters` — must equal the document's effective
  values. `parameters` contains only the enabled retouch values plus `schema`.
- `heal[]`, `aiPatches[]`, `stickers[]` — flattened from the document; AI patch
  IDs and asset references must match the document.
- `masks[]` — raster descriptors: `name`, `asset`, `sha256`, `format`
  (`gray8`), `space` (`mask_raster`), `width`, `height`, `bytesPerRow`,
  `origin`, `gate`, `feather`, `coverage`.
- `analysis` — nullable; R1 fixtures keep it `null`.
- `determinism` — `heal`, `color`, `vision`, `ai`, each in
  `exact | tolerance | platform | nondeterministic`.
- `engine` — `name`, `version`; the fixture value is `coreimage` /
  `macos-27`, marking the reference engine rather than a target.
- `target` — `kind` (`preview` or `export`), `maxLongEdge`, `scale`.
- `stages` — exactly 17 entries in canonical order.

`stages` is an ordered array, not a reorderable DAG. Each entry has `stage`,
`index` (`1...17`), `enabled`, and `operationIds`. The pipeline is:

| Index | Stage | Operation type |
|---:|---|---|
| 1 | `heal` | `heal` |
| 2 | `aiPatch` | `aiPatch` |
| 3 | `bodySkin` | `retouchParameters` |
| 4 | `localSkin` | `retouchParameters` |
| 5 | `underEye` | `retouchParameters` |
| 6 | `teeth` | `retouchParameters` |
| 7 | `eyes` | `retouchParameters` |
| 8 | `makeup` | `retouchParameters` |
| 9 | `hair` | `retouchParameters` |
| 10 | `featureReshape` | `retouchParameters` |
| 11 | `silhouetteReshape` | `retouchParameters` |
| 12 | `bodySlim` | `retouchParameters` |
| 13 | `pose` | `retouchParameters` |
| 14 | `globalColor` | `retouchParameters` |
| 15 | `background` | `retouchParameters` |
| 16 | `art` | `stickers` |
| 17 | `finalCrop` | `crop` |

The runner checks stage names, contiguous indexes, enabled/disabled
consistency, operation-ID existence, and operation-type compatibility. A
disabled stage must have no operation IDs; an enabled stage that needs an
operation must reference one. `finalCrop` must agree with the document crop.

This order reflects the current pipeline characterization. R1 does not execute
it and does not prove that a future engine reproduces it.

### 2.3 Export configuration

An export fixture is `{"schema": 1, "exportPlan": {...}}` with:

- `documentRevision`,
- `intent`: `format` in `jpeg | png | tiff | heic`, `quality` 0...1,
  `maxLongEdge` null or unsigned (0/null keeps source size), `aiUpscale`,
  `analysisMode` in `none | onPhoto | poster | overlayOnly`,
  `backgroundColor` nullable, `watermark` nullable, `stripLocationMetadata`,
- `metadataPolicy`: `mode: "privacyStrip"` and an `allow` array drawn from
  `dpi | tiffResolution | orientationNormalized`, sorted,
- `outputName`, portable `proposedURL`,
- `sourceProtection.refuseIfDestinationIsSource`,
- `requiresEngine`: feature list and minimum version.

The allowlist matches the current export behavior: resolution and normalized
orientation may survive, identity and location do not.

### 2.4 Domain errors

An error fixture is `{"schema": 1, "error": {...}}` with `code` from the R1
taxonomy, `messageKey` matching `error.<segment>[.<segment>]*`, and a
kind-specific `detail` object. The R1 codes are:

`OK`, `INVALID_ARGUMENT`, `INVALID_STATE`, `UNSUPPORTED_VERSION`,
`UNSUPPORTED_FEATURE`, `DECODE_FAILED`, `UNSUPPORTED_FORMAT`,
`SOURCE_MISSING`, `SOURCE_CHANGED`, `SOURCE_ACCESS_DENIED`, `ASSET_MISSING`,
`ASSET_HASH_MISMATCH`, `VALIDATION_FAILED`, `CANCELLED`, `BUSY`,
`ENGINE_FAILURE`, `AI_UNAVAILABLE`, `IO_FAILURE`, `DURABILITY_FAILURE`,
`INTERNAL`.

`ERROR-SOURCE-CHANGED` pins `SOURCE_CHANGED` with expected and actual byte
counts.

### 2.5 Progress and cancellation

A progress fixture is `{"schema": 1, "progress": {...}}` with `stage`,
`stageIndex`, optional `operationId`, `fraction` 0...1, `unitsDone`,
`unitsTotal`, `state` in `running | cancelling | cancelled | completed |
failed`, and a `cancellation` object with `requestedAt`, `acknowledgedAt`, and
`state`. Stage indexes use the orchestration sequence: `0` decode, `1...17`
canonical stages, `18` encode, `19` write.

`PROGRESS-CANCELLATION` pins cancellation during `globalColor` (index 14) at
fraction 0.62, acknowledged 250 ms after the request.

---

## 3. Canonical serialization

See `Docs/STUDIOCORE_CANONICAL_JSON.md`. In short: UTF-8 without BOM, NFC
strings, sorted object keys, two-space pretty form plus one final LF, duplicate
keys and non-finite/exponent/negative-zero numbers rejected, SHA-256 over the
compact sorted form with no trailing newline.

---

## 4. Fixture inventory (schema 1)

All paths are relative to `Tests/Conformance/Fixtures/`. Every file is listed
in `index.json` with its kind, schema version, expected outcome, SHA-256, and
corpus references.

### 4.1 Valid fixtures (15)

| ID | Kind | File | Content |
|---|---|---|---|
| `DOC-EMPTY` | document | `canonical/document-empty.json` | One source, no operations, revision 0 |
| `DOC-BASIC` | document | `canonical/document-basic.json` | Exposure 12, smooth 34, revision 42 |
| `DOC-MULTI-OPERATION` | document | `canonical/document-multi-operation.json` | Orientation, 2 heal spots, 2 AI patches, parameters, 2 stickers, crop, analysis; revision 43 |
| `DOC-ASSETS-MASKS` | document | `canonical/document-assets-masks.json` | Display P3 source, one AI patch, parameters, crop, 3 assets; revision 44 |
| `DOC-CROP-ORIENTATION` | document | `canonical/document-crop-orientation.json` | Quarter turn plus crop; revision 7 |
| `DOC-UNKNOWN-FIELDS` | document | `canonical/document-unknown-fields.json` | Unknown optional document and metadata fields |
| `RP-BASIC` | render plan | `canonical/render-plan-basic.json` | Enabled: bodySkin, localSkin, globalColor; preview |
| `RP-MULTIPLE` | render plan | `canonical/render-plan-multiple.json` | Enabled: heal, aiPatch, bodySkin, localSkin, eyes, makeup, globalColor, background, art, finalCrop |
| `RP-DISABLED` | render plan | `canonical/render-plan-disabled.json` | All 17 stages disabled |
| `RP-MASKS` | render plan | `canonical/render-plan-masks.json` | AI patch, 512×512 gray8 mask, coverage 0.18, gate 0.02 |
| `RP-CROP-ORIENTATION` | render plan | `canonical/render-plan-crop-orientation.json` | Only finalCrop enabled; quarter turn |
| `RP-EXPORT` | render plan | `canonical/render-plan-export.json` | Export target, max long edge 2048 |
| `EXPORT-CONFIG` | export | `canonical/export-config.json` | JPEG q0.92, max edge 2048, privacy allowlist |
| `ERROR-SOURCE-CHANGED` | error | `canonical/error-source-changed.json` | `SOURCE_CHANGED` with byte counts |
| `PROGRESS-CANCELLATION` | progress | `canonical/progress-cancellation.json` | Cancelled at globalColor, fraction 0.62 |

### 4.2 Expected-invalid fixtures (6)

| ID | Kind | File | Expected code | Defect |
|---|---|---|---|---|
| `DOC-DUPLICATE-SINGLETON` | document | `invalid/document-duplicate-singleton.json` | `VALIDATION_FAILED` | Two `retouchParameters` operations |
| `DOC-BAD-CROP` | document | `invalid/document-bad-crop.json` | `VALIDATION_FAILED` | Crop rectangle outside 0...1 |
| `DOC-BAD-HSL` | document | `invalid/document-bad-hsl.json` | `VALIDATION_FAILED` | HSL band array of the wrong length |
| `DOC-UNKNOWN-REQUIRED` | document | `invalid/document-unknown-required.json` | `UNSUPPORTED_FEATURE` | Unknown required capability |
| `RP-BAD-ORDER` | render plan | `invalid/render-plan-stage-order.json` | `VALIDATION_FAILED` | `bodySkin` and `localSkin` swapped |
| `RP-MISSING-STAGES` | render plan | `invalid/render-plan-missing-stages.json` | `INVALID_ARGUMENT` | 16 stages instead of 17 |

The expected-invalid fixtures prove that the contract rejects a defect for the
intended reason, not merely that parsing fails.

### 4.3 Corpus references

Document fixtures reference the real golden corpus by source file name and
pixel size. The runner checks the recorded content hash against
`Tests/Corpus/Fixtures/MANIFEST.json`:

- `F01_PORTRAIT_SRGB_8` — 512×512 sRGB 8-bit.
- `F11_P3_16BIT` — Display P3 16-bit source used by `DOC-ASSETS-MASKS`.

No fixture copies corpus pixels or depends on the corpus harness at runtime.

### 4.4 Corpus lock

`corpus-lock.json` pins:

- `manifestSha256`: `84f4b81cb994627ad501a677526a833cc501116f8aad6eaa10b17180f902d254`
- `baselinesSha256`: `aea08d46c116b303c2766797f5b31e603d2f6ecf5d3cbc33c9e2cb363c411ed1`
- counts: 12 fixtures, 78 baseline cases, 21 reference PNGs, 11 export files
- the SHA-256 of every reference PNG
- the set of 11 export file names

The runner recomputes all of these. If anyone regenerates a baseline, changes
an image algorithm, or adds/removes an export, the lock fails until the change
is reviewed and the lock is updated deliberately.

Export bytes are deliberately **not** pinned. During R1 validation the corpus
harness rewrote four export files with different bytes while all 376 corpus
checks still passed; `baselines.json` records export structure, dimensions,
bit depth, and profile, not hashes. Pinning bytes would make the gate fail
after every normal corpus run without indicating a real regression.

---

## 5. C ABI draft

Header: `Tests/Conformance/ABI/studioscore_image_engine.h`.

**This is a contract draft with no implementation.** It is not linked into the
app and must not be treated as final. It is compiled only by the standalone
smoke test.

### 5.1 Types and versioning

- `SC_IMAGE_ENGINE_ABI` and `SC_IMAGE_ENGINE_ABI_MIN` are `1`.
- `ScStatus` is `int32_t`; status values are `0...19`, matching the twenty
  domain codes including `OK`.
- Status, pixel format, color encoding, and target kind are fixed-width
  integer typedefs, not C enums, so layout does not depend on compiler enum
  size.
- Extensible structs start with `struct_size` and `abi_version`. A caller may
  pass a smaller struct; the engine reads only the declared prefix. Adding
  fields at the end is allowed within ABI 1. Renaming, removing, or changing a
  field requires a new ABI version.
- Opaque handles: `ScEngine`, `ScCancelToken`.
- No AppKit, CoreGraphics, CoreImage, Foundation, or Swift types appear in the
  header.

### 5.2 Functions

| Function | Purpose |
|---|---|
| `sc_engine_create(abi_version, out_engine, out_error)` | Create an engine after an ABI check |
| `sc_engine_destroy(engine)` | Destroy the handle |
| `sc_engine_capabilities(engine, out_json, out_error)` | Return a JSON capability object |
| `sc_engine_render(engine, request, out_image, out_error)` | Render one immutable plan |
| `sc_engine_trim_cache(engine)` | Release disposable caches |
| `sc_cancel_token_create(abi_version, out_token, out_error)` | Create a cancellation token |
| `sc_cancel_token_destroy(token)` | Destroy the token |
| `sc_engine_cancel(engine, token)` | Request cancellation from any thread |
| `sc_buffer_release(image)` | Release engine-owned image bytes |
| `sc_error_release(error)` | Release an error and its detail |

### 5.3 Ownership and lifetime

- Input image bytes and slices are host-owned and must remain valid until
  `sc_engine_render` returns. Host input descriptors have `release == NULL`.
- Output image bytes, the capability JSON, and error details are engine-owned.
  The host releases them exactly once through `sc_buffer_release` or
  `sc_error_release`. Release functions are producer-supplied callbacks.
- `ScImageBuffer` success output is zero-origin. On failure it is untouched.
- `ScError.message_key` is a static NUL-terminated UTF-8 string; `detail_json`
  and `debug` are length-delimited UTF-8 slices owned by the error.
- Strings in slices are UTF-8 and are not NUL-terminated unless stated.

### 5.4 Threading, cancellation, progress

- No C++ exception or foreign unwind may cross the ABI.
- The progress callback runs on the render thread, must return promptly, and
  must not synchronously call back into the same engine handle.
- `sc_engine_cancel` is safe from another thread. The engine does not destroy
  the token; the host owns its lifetime.
- Progress `stage` uses `0` decode, `1...17` stages, `18` encode, `19` write;
  `fraction` is monotonic and advisory and may stop below 1.0 on failure or
  cancellation.

---

## 6. Standalone C smoke test

`Tests/Conformance/ABI/abi_smoke.c` is C11 and header-only. It asserts:

- ABI and minimum ABI values,
- status count and code ordering,
- fixed-width sizes of the status and enum-like typedefs,
- prefix offsets and member types of `ScImageBuffer`,
- pixel, color, and target constants,
- function signatures through `_Generic` compile-time checks.

It takes no function addresses, so it links without an implementation. It does
not call the engine, load the app, or link AppKit, SwiftUI, Core Image, Vision,
or Foundation.

Build and run (performed by `run-conformance.sh`):

```bash
clang -std=c11 -Wall -Wextra -Werror -pedantic \
  -I Tests/Conformance/ABI Tests/Conformance/ABI/abi_smoke.c -o /tmp/abi_smoke
/tmp/abi_smoke
```

Expected output: `studioscore abi=1 status_count=20 error_codes=20`.

---

## 7. Conformance runner

`Tests/Conformance/conformance.py` is a Python 3 standard-library script; there
is no new dependency and no build-system change. It:

1. Rejects malformed JSON: BOM, invalid UTF-8, duplicate keys, non-finite
   numbers, exponent notation, negative zero, non-NFC strings.
2. Compares every fixture's raw bytes to canonical pretty form plus one LF.
3. Recomputes every fixture hash and compares it to `index.json`.
4. Loads documents first, then render plans, and cross-checks revisions,
   source dimensions and color, orientation, crop, parameters, operation IDs,
   operation types, AI patch asset references, and masks.
5. Validates expected-invalid fixtures against their pinned error code.
6. Recomputes the corpus lock and refuses drift.

`run-conformance.sh` then compiles and runs the C smoke test. Exit status is
non-zero on any failure, with a specific message on stderr.

Run:

```bash
./Tests/Conformance/run-conformance.sh
```

---

## 8. Validation commands

| Check | Command |
|---|---|
| R1 gate and C smoke | `./Tests/Conformance/run-conformance.sh` |
| Existing Swift suites (arm64) | `./Tests/run.sh` |
| Existing Swift suites (Rosetta) | `RETOUCH_ARCH=x86_64 ./Tests/run.sh` |
| Golden corpus (read-only verify) | `./Tests/run-corpus.sh` |
| Whitespace | `git diff --check` |

---

## 9. Limitations and unverified claims

- Only the Python reference implementation was executed. Cross-language
  canonical byte equality is **NOT VERIFIED**.
- The C header is compiled, not implemented. No render, capability, error, or
  cancellation path was exercised at runtime.
- No native Intel, Windows, or Linux build was produced. Any `x86_64` result
  is Rosetta on Apple silicon and is labeled as such.
- The corpus lock proves file identity, not image correctness. Image
  comparison remains governed by `Docs/IMAGE_COMPARISON_METHODOLOGY.md` and the
  existing corpus harness.
- Export file bytes are not reproducible across encoder runs. The lock pins
  their names and count only. The corpus harness rewrites
  `Tests/Corpus/Exports/*` on every run; the committed copies must be restored
  if the working tree is expected to stay clean.
- The runner does not enforce JSON nesting or size limits. A hostile-input
  policy is a later decision.
- The runner does not prove that unknown optional fields survive a rewrite; it
  only accepts them.
- The fixture envelope, operation storage order, and lowercase UUID rule are
  provisional.
- R1 fixtures do not cover every operation field combination. They cover the
  cases named in the R1 brief and interface-design §11; missing cases are
  listed as future work, not silently assumed.

---

## 10. Provisional decisions

| Decision | R1 choice | Why provisional |
|---|---|---|
| Fixture envelope | One object per file with a `schema` and a kind key | A production package may need a different container |
| Operation storage order | orientation 0 … analysis 18 | Preserves pipeline intent without claiming v3 order |
| UUID spelling | Lowercase canonical text | Matches common JSON encoders; not yet a format rule |
| Render stage shape | Array of `{stage, index, enabled, operationIds}` | Keeps order explicit and non-reorderable |
| C ABI release | Producer-supplied callback in the descriptor | Allows engine allocators without exposing a global free |
| Progress stages | Decode 0, stages 1...17, encode 18, write 19 | Aligns UI progress with engine work |
| Analysis snapshots | `null` only | Cross-platform snapshot fidelity is an open question |
| AI determinism | `nondeterministic` | Model output is not reproducible across machines |

---

## 11. Acceptance checklist against the R1 brief

| Requirement | Status |
|---|---|
| Repository state verified before edits | Done; branch `main`, HEAD `7cfc8594…`, four untracked design docs |
| Four Milestone 4 documents preserved | Done; hashes unchanged, not staged |
| Conformance scope defined | Done; §2 |
| Canonical fixtures with stable hashing | Done; 15 valid fixtures plus index |
| Render-plan fixtures for 17 stages | Done; 6 valid plans, 2 invalid |
| C ABI header draft | Done; header only, no implementation |
| Standalone C smoke test | Done; compiles and runs |
| Standalone conformance runner | Done; stdlib only, nonzero exit on failure |
| Golden corpus IDs, hashes, and baselines unchanged | Done; corpus lock added and verified |
| Existing tests | See §12; no production source changed |
| `git diff --check` | See §12 |
| No production extraction, no format change, no commit/push/PR | Done |
| R2 not started | Done |

---

## 12. Verification results

Recorded on 2026-11-11 on the owner's Apple-silicon machine, macOS 27.2.

| Command | Result |
|---|---|
| `./Tests/Conformance/run-conformance.sh` | PASS, exit 0: 21 fixtures (15 valid, 6 invalid); corpus lock 12 fixtures / 78 cases / 21 references / 11 exports; C smoke prints `studioscore abi=1 status_count=20 error_codes=20` |
| `./Tests/run.sh` (arm64) | PASS, exit 0: four suites, 840 checks |
| `RETOUCH_ARCH=x86_64 ./Tests/run.sh` | PASS, exit 0: four suites, 840 checks; **Rosetta on Apple silicon**, not native Intel |
| `./Tests/run-corpus.sh` | PASS, exit 0: "Verified against baselines.json. 376 checks, 0 failures" |
| Negative runner check (temporary copy) | Corrupted fixture produced `R1 conformance: FAIL`, `sha256 differs from index`, exit 1 |
| `git diff --check` | Clean, exit 0 |
| Whitespace / CRLF scan of new files | No trailing whitespace or CR characters |

Corpus side effect: the harness rewrote four export files
(`F01_export_256.png`, `F01_export_256.tif`, `F08_export_256.png`,
`F11_export_256.png`) with different bytes. All corpus checks passed, which
confirmed that export bytes are not the contract. The four files were restored
byte-for-byte to their committed content and the corpus lock now pins only the
export file set.

The four Milestone 4 documents were re-hashed after validation; all four SHA-256
values match the values recorded before R1 work began.

---

## 13. Recommendation for R2

Do not begin R2 until the owner approves the provisional decisions in §10 and
the fixture envelope in §2. R2 should be limited to pure Swift value types in a
new target, with:

1. a byte-equality test against the R1 canonical fixtures before any type move,
2. a forbidden-import check for AppKit, SwiftUI, CoreImage, and ImageIO,
3. unchanged v3 encoder output for existing projects,
4. no change to `EditorModel`, renderers, views, Recovery, or the AI runtime.

If the owner prefers a different container or operation order, change R1
fixtures and hashes first; do not let R2 encode an unreviewed contract.
