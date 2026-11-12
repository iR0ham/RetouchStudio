# StudioCore — Interface Design

**Status:** Interface draft, not implemented
**Milestone:** 4 — StudioCore Architecture & Extraction Design
**Baseline:** `main` / `7cfc8594f416c987386e0abe103cc75121de073a`
**Date:** 2026-11-11
**Companion:** [STUDIOCORE_ARCHITECTURE.md](STUDIOCORE_ARCHITECTURE.md)

---

## 1. Purpose and status

This document specifies the contracts that a portable `StudioCore`, the image engine, the AI engine, and platform adapters must satisfy. It is an interface draft. It does not create source code, dependencies, or projects.

Every schema, type, and function signature below is **PROPOSED** unless it is explicitly marked **VERIFIED** against the current repository. The current macOS behavior remains authoritative until the corpus and the owner approve a change.

---

## 2. Conventions

### 2.1 Identifiers

**PROPOSED.**

| ID | Form | Notes |
|---|---|---|
| `DocumentId` | UUID text | Stable for the life of the document; survives Save As. |
| `AssetId` | UUID text | Immutable content-addressed asset record. |
| `OperationId` | UUID text | Stable across edits, undo, and project writes. |
| `EditId` | UUID text | One AI edit; the artifact set is immutable. |
| `PresetId` | UUID text | User preset identity. |

Existing projects contain UUIDs created by Swift's `UUID` (`Sources/RetouchStudio/Models/AIEdit.swift:12`, `Sources/RetouchStudio/Models/Sticker.swift:20`). The codec accepts any valid UUID text and preserves it. New IDs may use UUIDv7 for rough time ordering, but ordering must never depend on the ID alone.

### 2.2 Versions and capabilities

**PROPOSED.**

- `formatVersion` is the project container version (4).
- Each JSON document has its own `schema` integer.
- `capabilities` lists features the writer used, for example `operations.v1`, `masks.v1`, `ai.provenance.v1`.
- `requires` lists capabilities a reader must understand. A reader that does not understand a required capability refuses to open the document read-write. It may offer a read-only summary.
- Unknown **optional** fields are preserved. Unknown **required** capabilities are not guessed.

### 2.3 Canonical JSON

**PROPOSED.** All shared JSON is UTF-8 with these rules:

- Object keys sorted lexicographically by Unicode scalar value.
- Two-space indentation for human-readable project files; compact form for hashing and IPC.
- No `NaN`, `Infinity`, or `-Infinity`.
- Numbers use the shortest representation that round-trips to the same IEEE-754 double or integer.
- Strings are NFC-normalized for names and paths; binary data is base64 only where explicitly allowed.
- Arrays preserve order; the order is semantic where the schema says so.
- Every parser rejects duplicate object keys.
- Every record preserves unknown fields in a raw map and re-emits them on write.

The canonical form is what `contentHash` and `documentHash` cover. Hash algorithm: SHA-256, for continuity with the current code (`CryptoKit` usage recorded in the audit) and broad tool availability. BLAKE3 is a possible future option, not a requirement.

### 2.4 Units and geometry

**PROPOSED.**

- Lengths in the document are normalized `[0,1]` relative to the declared coordinate space, unless a field name says pixels.
- Fractions of the short side keep the current healing/sticker semantics (`Sources/RetouchStudio/Models/Heal.swift:10-13`, `Sources/RetouchStudio/Models/Sticker.swift:19-30`).
- Angles are degrees, clockwise positive.
- Points have `x` right and `y` down in document data.
- Rectangles are half-open: `[minX, maxX) × [minY, maxY)`.
- A normalized point maps to a pixel coordinate as `x * width`, `y * height`.
- Every geometric record declares a `space` from §2.5.

### 2.5 Coordinate spaces

**PROPOSED.**

| Space | Definition | Stored in document? |
|---|---|---|
| `source_normalized` | Normalized top-left relative to the decoded source after EXIF normalization and before user orientation. | Yes, canonical |
| `source_pixel` | Integer pixels in the same source frame. | Yes, when pixel data is needed |
| `mask_raster` | Row-major raster with explicit width, height, origin, and stride. | Yes, as asset metadata |
| `preview_normalized` | Normalized top-left relative to a preview target. | No |
| `export_pixel` | Pixels in the final export. | No |

**VERIFIED inconsistency in the current code:** healing, stickers, crop, and AI boxes use top-left normalized (`Sources/RetouchStudio/Models/Heal.swift:5-8`, `Sources/RetouchStudio/Models/Crop.swift:4-5`, `Sources/RetouchStudio/Models/Sticker.swift:15-18`, `Sources/RetouchStudio/Models/QuickEdit.swift:197-219`), while `FaceGeometry` and `MaskShape` use bottom-left normalized (`Sources/RetouchStudio/Core/FaceAnalyzer.swift:7-11`, `Sources/RetouchStudio/Core/MaskBuilder.swift:5-6`).

**RECOMMENDATION.** The adapter converts bottom-left Vision/mask values to `source_normalized` at the boundary. The engine converts back for Core Image. This conversion is a parity risk and must be covered by the corpus before the document model changes.

### 2.6 Color

**PROPOSED.**

```text
ColorSpaceDescriptor {
  name: string                 // "sRGB", "Display P3", "Adobe RGB", ...
  iccBytes: bytes | null       // optional embedded profile
  iccHash: "sha256:..." | null
  whitePoint: "D65" | ...      // informational
}
```

- The document stores the source color-space descriptor and the export target descriptor.
- The engine receives input and output descriptors explicitly. It must not infer a working space silently.
- The current canonical comparison unit is premultiplied RGBA8 in the image's own color space (`Docs/IMAGE_COMPARISON_METHODOLOGY.md:25-45`). The portable engine must reproduce that canonical unit before it claims parity.
- Wide-gamut sources must keep their profile; converting to sRGB for preview must not alter the stored source or the export unless the user chose an sRGB export.

### 2.7 Pixels and alpha

**PROPOSED.**

| Format | Use |
|---|---|
| `rgba8_premultiplied` | Canonical validation and 8-bit output |
| `rgba16` | 16-bit PNG/TIFF export |
| `rgba16_float` | Engine working format, if the implementation needs it |
| `gray8` | Masks, single channel, no alpha |

- Alpha is premultiplied at every API boundary. A straight-alpha input is converted before use.
- The source photo is treated as opaque unless a format explicitly carries alpha.
- Export flattening onto white happens in the encoder/exporter policy, not in the engine.

### 2.8 Time and progress

**PROPOSED.**

- Timestamps are RFC 3339 UTC with milliseconds.
- Core does not read the wall clock directly; a `Clock` port supplies time for provenance and recovery ordering.
- Progress is a monotonically non-decreasing fraction in `[0,1]` with a stage identifier and optional `unitsDone`/`unitsTotal`.
- Progress is advisory. A cancelled or failed job may stop without reaching 1.0.

### 2.9 Errors

**PROPOSED.** Errors have a stable code, a message key for localization, and a structured detail object:

```json
{
  "code": "SOURCE_CHANGED",
  "messageKey": "error.source.changed",
  "detail": { "expectedBytes": 812345, "actualBytes": 812400 }
}
```

The shell localizes `messageKey`. The core never returns English prose as the only error. A debug string may accompany the error, but it is not user-facing copy.

---

## 3. Document model

### 3.1 Document

**PROPOSED.**

```text
Document {
  id: DocumentId
  source: SourceRef
  operations: OperationList
  selectedFace: integer | null
  metadata: DocumentMetadata
  assets: AssetTable
  revision: uint64
  capabilities: [string]
  requires: [string]
}
```

`revision` increments on each committed transaction and on each source/asset change. It is monotonic for the life of the session. It is persisted so a reader can detect stale recovery candidates.

`DocumentMetadata` holds non-edit fields: title, created/modified timestamps, app/core versions, and a free-form `unknown` map. It does not hold OS paths.

### 3.2 Source reference

**PROPOSED.**

```text
SourceRef {
  assetId: AssetId
  fileName: string
  relativePath: string | null       // portable, relative to the project package
  external: bool                    // true when the source is not inside the package
  bytes: uint64
  quickIdentity: { size: uint64, modifiedAt: string | null }
  contentHash: { algorithm: "sha256", hex: string } | null
  pixelWidth: uint32
  pixelHeight: uint32
  colorSpace: ColorSpaceDescriptor
  orientationNormalized: bool       // EXIF orientation has been applied at decode
  embedded: bool
}
```

Rules:

- `relativePath` is preferred. It must use `/` separators and must not escape the package root with `..` unless `external` is true.
- No absolute path appears in shared JSON.
- `contentHash` is computed when the source is first attached or when the user asks to verify. It may be absent for a newly imported source until the first save.
- `quickIdentity` is a fast check, not proof of identity.
- If the file is missing or the hash differs, the document enters `sourceMissing` or `sourceChanged`. It never silently renders a different photo.

### 3.3 Operation list and stages

**PROPOSED.**

```text
OperationList {
  schema: 1
  coordinateSpace: "source_normalized"
  operations: [Operation]
}

Operation =
  | RetouchParameters { id, schema, params }
  | Heal              { id, schema, spots: [HealSpot] }
  | AiPatch           { id, schema, editId, patch: AssetRef, alpha: AssetRef,
                        box: SourceRect, orientation: OrientationValue,
                        imagePixels: {width,height}, provenance: AiProvenance }
  | Stickers          { id, schema, items: [Sticker] }
  | Analysis          { id, schema, settings: AnalysisSettings, snapshot: AnalysisSnapshot? }
  | Crop              { id, schema, rect: SourceRect }
  | Orientation       { id, schema, quarterTurns, flipped, angle }
```

The canonical evaluation order is fixed:

| # | Stage | Operation |
|---:|---|---|
| 1 | `heal` | `Heal` |
| 2 | `aiPatch` | `AiPatch` records in document order |
| 3 | `bodySkin` | `RetouchParameters` |
| 4 | `localSkin` | `RetouchParameters` |
| 5 | `underEye` | `RetouchParameters` |
| 6 | `teeth` | `RetouchParameters` |
| 7 | `eyes` | `RetouchParameters` |
| 8 | `makeup` | `RetouchParameters` |
| 9 | `hair` | `RetouchParameters` |
| 10 | `featureReshape` | `RetouchParameters` |
| 11 | `silhouetteReshape` | `RetouchParameters` |
| 12 | `bodySlim` | `RetouchParameters` |
| 13 | `pose` | `RetouchParameters` |
| 14 | `globalColor` | `RetouchParameters` |
| 15 | `background` | `RetouchParameters` |
| 16 | `art` | `Stickers` |
| 17 | `finalCrop` | `Crop` |

This order matches the characterized pipeline (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md:43-69`). `Orientation` is applied at decode/render time and is not a pixel stage in the list. `Analysis` is an output overlay, not a retouch stage; it is applied after the 17 stages by the export policy. `AiPatch` records are ordered by their creation sequence and keep that order across undo/redo.

Validation rules:

- At most one `RetouchParameters`, `Analysis`, `Crop`, and `Orientation`.
- Multiple `Heal`, `AiPatch`, and `Stickers` are allowed; their internal order is semantic.
- Every operation has a unique `id`.
- Every operation declares a known `schema`; unknown required operation types fail validation.
- Unknown optional operation types are preserved but skipped, and the document is marked read-only unless the user explicitly accepts the degradation.
- A crop or orientation record with invalid values is rejected, not clamped silently. Clamping is a shell interaction policy that calls a valid setter.

### 3.4 Retouch parameters

**PROPOSED.** `RetouchParameters.params` keeps the current field names so v3 migration is mechanical. The fields are the same groups as `Adjustments` (`Sources/RetouchStudio/Models/Adjustments.swift:14-200`):

| Group | Fields |
|---|---|
| Skin | `smooth`, `blemish`, `wrinkle`, `skinToneEvens`, `darkCircles`, `skinBrighten`, `texturePreserve`, `teethWhiten`, `eyeBrighten`, `eyeSharpen` |
| Reshape | `eyeSize`, `noseSize`, `noseTip`, `lipSize`, `cheekSize`, `jawWidth`, `chinLength`, `faceWidth`, `faceLength` |
| Color/light | `exposure`, `contrast`, `blacks`, `whites`, `saturation`, `vibrance`, `warmth`, `clarity`, `vignette` |
| Look | `lookID`, `lookStrength`, `grain` |
| Makeup | `lipTint`, `lipColor`, `blush`, `blushColor`, `browDefine`, `browColor`, `eyeshadow`, `shadowColor`, `eyeliner`, `linerColor` |
| Finish/detail | `skinFinish`, `shine`, `irisEnhance`, `lashDarken`, `lipGloss`, `splitTone` |
| Body/background | `bodySmooth`, `bodyTone`, `bodySlim`, `backgroundBlur`, `backgroundTone`, `backgroundSaturation` |
| Pose | `bodyWaist`, `bodyArms`, `bodyLegs` |
| Hair | `hairColor`, `hairTint`, `hairShine`, `hairVolume` |
| Contour | `contour`, `contourColor` |
| Tone curve | `curveShadows`, `curveMidtones`, `curveHighlights` |
| HSL | `hslHue[12]`, `hslSaturation[12]`, `hslLuminance[12]` |
| Iris/teeth | `lensTint`, `lensColor`, `teethAlign` |
| Background replacement | `backgroundFill`, `backgroundFillColor`, `backgroundRemove`, `backgroundImage`, `backgroundImageName`, `backgroundImageAmount` |

Rules:

- Every amount is `-100…100` or `0…100` exactly as the current model documents; zero is a no-op.
- `lookID` is an open string; an unknown look is a validation warning, not a crash.
- HSL arrays must have exactly the band count for the schema. A wrong length is a validation error.
- Color values are plain HSV (`h`, `s`, `v`), not SwiftUI `Color`. The current `MakeupColor`/`MakeupShade` decode compatibility must be preserved.
- The decoder fills missing fields with the current defaults so older projects and presets open unchanged.

### 3.5 Geometry records

**PROPOSED.**

```text
Point { x: f64, y: f64, space: CoordinateSpace }
Rect  { x: f64, y: f64, width: f64, height: f64, space: CoordinateSpace }

HealSpot {
  center: Point                  // source_normalized
  radius: f64                    // fraction of the source short side
}

Sticker {
  id: UUID
  kind: "star" | "heart" | "sparkle" | "flower" | "butterfly" | "lightning"
  center: Point
  size: f64                      // fraction of the short side
  rotation: f64                  // degrees clockwise
  opacity: f64                   // 0…1
  color: HsvColor
}

OrientationValue {
  quarterTurns: 0…3
  flipped: bool
  angle: f64                     // degrees, clockwise
}

Crop.rect                       // source_normalized
```

The current helpers remain the behavioral reference: `HealGeometry` (`Sources/RetouchStudio/Models/Heal.swift:15`), `ArtGeometry` (`Sources/RetouchStudio/Models/Sticker.swift:32`), `CropGeometry` (`Sources/RetouchStudio/Models/Crop.swift:31`), and `DocumentOrientation` (`Sources/RetouchStudio/Models/Orientation.swift:13`).

### 3.6 Analysis and face data

**PROPOSED.**

```text
AnalysisSettings {
  isEnabled, showsMesh, showsFaceOutline: bool
  regions: [string]              // stable region names
  endpoints: map<string, Point>  // source_normalized
  anchors: map<string, Point>    // source_normalized
  lineOpacity, lineWeight: f64
  tint: string
  glow: bool
  marginPercent: f64
  exportMode: "onPhoto" | "poster" | "overlayOnly"
}
```

`AnalysisSnapshot` optionally stores the detector output used at edit time:

```text
AnalysisSnapshot {
  detector: { name, version, provider }
  faces: [FaceLandmarks]
  personMask: AssetRef | null
  capturedAt: string
}
```

`FaceLandmarks` is a plain schema, not `Vision`/`VNFaceObservation`:

```text
FaceLandmarks {
  index: int
  boundingBox: Rect              // source_normalized
  contour: [Point]
  leftEye, rightEye: [Point]
  leftPupil, rightPupil: Point | null
  leftBrow, rightBrow: [Point]
  outerLip, innerLip: [Point]
  nose: [Point]
  noseCrest: [Point]
  medianLine: [Point]
  confidence: f64
  detector: { name, version }
}
```

**RECOMMENDATION.** Storing the snapshot is optional but valuable: the current pipeline re-runs Vision on every load, and Vision output can change across OS versions (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md:265`). A snapshot makes a project reproducible; a version mismatch can invalidate it explicitly. The macOS adapter may regenerate it. This is a design proposal, not current behavior.

### 3.7 Export intent and plan

**PROPOSED.**

```text
ExportIntent {
  format: "jpeg" | "png" | "tiff" | "heic"
  quality: 0…1                  // used where the format supports it
  maxLongEdge: uint32 | null    // 0 or null keeps the source size
  aiUpscale: bool
  stripLocationMetadata: bool
  watermark: WatermarkSettings | null
  analysisMode: "none" | "onPhoto" | "poster" | "overlayOnly"
  backgroundColor: ColorValue | null
}

ExportPlan {
  intent: ExportIntent
  documentRevision: uint64
  outputName: string
  proposedURL: string            // portable, shell resolves
  metadataPolicy: MetadataPolicy
  sourceProtection: { refuseIfDestinationIsSource: true }
  requiresEngine: { minVersion: string, features: [string] }
}
```

Rules:

- Output naming preserves the current conventions: `name.format`, `name-analysis.format`, `name-analysis-poster.format` where applicable (`Sources/RetouchStudio/Models/EditorModel.swift:2998-3004`).
- A destination that resolves to the source is refused before rendering. The identity check is a platform port; the policy is core.
- Metadata is stripped by an allowlist (DPI, TIFF resolution, orientation normalization) when privacy stripping is enabled. The current behavior lives in `ImageProcessor.write` and `strippedPrivacyMetadata`; the policy is extracted, the ImageIO implementation stays.
- The exporter receives pixels and a metadata policy; it does not decide policy.
- Alpha is flattened onto white for formats that do not carry it.

### 3.8 Batch job

**PROPOSED.**

```text
BatchJob {
  id: UUID
  items: [BatchItem]
  outputDirectory: string        // shell-provided
  naming: { baseSuffix: "-retouched", conflict: "suffixCounter" }
  includeStamps: bool
  includeAnalysis: bool
  concurrency: uint32            // shell may clamp
}

BatchItem {
  source: SourceRef
  document: DocumentSnapshot     // portable, no pixels
  outputName: string
}
```

Per-file policy is a pure function, implemented as
`BatchRenderPolicy.request(_:fileURL:documentURL:documentAspect:fileAspect:)`
in `Sources/StudioCore/BatchRenderPolicy.swift` (M8):

- The item's own file keeps the document's crop.
- Another file keeps its crop only when orientation is identity and the aspect matches; otherwise the crop is removed.
- AI edits are cleared.
- Orientation is reset to identity for a different frame.
- Selected face is cleared.
- Analysis endpoints and anchors are reset.
- Output names are unique per batch.

### 3.9 Preset

**PROPOSED.**

```text
Preset {
  id: PresetId
  name: string
  schema: 1
  params: RetouchParameters.params
  createdAt, modifiedAt: string
  unknown: map
}
```

Presets belong to the person, not the document (`Sources/RetouchStudio/Models/UserPreset.swift:10-12`). The file store is a port.

### 3.10 Recovery candidate

**PROPOSED.**

```text
RecoveryCandidate {
  id: UUID
  state: "working" | "candidate" | "quarantined"
  savedAt: string
  document: DocumentSnapshot
  sourceIdentity: { size, modifiedAt, contentHash? }
  appVersion, coreVersion: string
  integrity: { algorithm: "sha256", hex }
}
```

Policy rules, grounded in the current store:

- A working slot is the latest autosave for the active document.
- A candidate is immutable and independent; it is never overwritten.
- Candidates are ordered by `savedAt`, then by file name for a stable tie-break (`Sources/RetouchStudio/Models/Recovery.swift:279`).
- A candidate whose source is missing or changed is still offered; the user chooses Locate, Discard, or Restore.
- Unreadable candidates are quarantined, never deleted.
- A recovery epoch invalidates stale writes after discard or document replacement.
- Durability is reported by the file store; a store that cannot `fsync` must not be described as crash-safe.

### 3.11 Render port (implemented in M8)

**VERIFIED — `Sources/StudioCore/RenderContract.swift`, `RenderPolicy.swift`,
`BatchRenderPolicy.swift`; used by `Sources/RetouchStudio/Core/MacDocumentRenderer.swift`.**

The 3.7/3.8 schemas describe a future multi-language boundary. M8 implements
the Swift-level subset that both macOS entry points now use:

```text
ExportFormat     jpeg | png | tiff | heic       extension, type name, depth, alpha
RenderRequest    adjustments, healSpots, stickers, aiEdits, analysis, crop,
                 orientation, selectedFaceIndex, format, quality, longEdge,
                 stripsPrivacyMetadata, includeStamps, includeAnalysis,
                 aiUpscale, watermark
RenderSourceDescription   pixelSize, photoAspect, faceCount, profileName
RenderPlan       format, pixelSize, upscales, appliesAnalysis, appliesWatermark,
                 flattensAlpha, bitsPerChannel, colorSpace, carriesSourceMetadata
RenderProgress   stage(preparing|rendering|upscaling|writing), completed, total
RenderError      cancelled | sourceIsDestination | imageTooLarge |
                 upscaleFailed | renderFailed | writeFailed
RenderResult     destination, pixelSize, format, colorSpace, profileName,
                 carriedSourceMetadata

DocumentRenderPipeline<Source, Output>
  render(request, source, progress) -> Output
  write(output, request, source, to:, protecting:) -> RenderResult
  renderAndWrite(...)  // provided
```

Rules proven by the core suite:

- A request with analysis overlays and a detected face forces PNG and
  transparent output; without a face the chosen format stays.
- The 4x pass is offered only inside the 40 MP output ceiling, caps at the
  requested long edge, and writes sRGB because the upscaler returns untagged
  pixels; a downscale never enables it.
- `-analysis` / `-analysis-poster` naming follows the same predicate as the
  plan, so a name never promises analysis the file cannot carry.
- A batch keeps the document's crop only for the document itself or a
  same-aspect upright file; otherwise it clears crop, AI edits, orientation,
  face selection and analysis anchors.
- Unique output names gain a counter without overwriting an earlier file.
- The port receives the same request and source through `renderAndWrite`, and
  the write step sees the rendered output; a recording conformer checks it.

`ExportSource` (CIImage, masks, faces, CGColorSpace, ImageIO metadata) and
`RenderedExport` stay in the app target. Core Image, CoreGraphics, `UTType`,
`CGImage` and Vision types never appear in the shared API.

---

## 4. History and transactions

**PROPOSED.**

```text
History {
  limit: 100
  entries: [Snapshot]
  cursor: integer
  cleanSnapshot: SnapshotId | null
}

Transaction {
  id: UUID
  label: string
  coalesceKey: string | null
  baseRevision: uint64
}
```

Operations:

```text
begin_transaction(label, coalesceKey) -> Transaction
commit_transaction(tx) -> CommitResult { revision, undoAvailable, redoAvailable, dirty }
cancel_transaction(tx)
undo() -> StateChange
redo() -> StateChange
mark_clean()
```

Behavioral contract, matching the current model:

- A snapshot covers every document edit: parameters, heal spots, stickers, AI edits, analysis, crop, orientation, selected face (`Sources/RetouchStudio/Models/EditorModel.swift:313-322`).
- The undo limit is 100 (`Sources/RetouchStudio/Models/EditorModel.swift:361-362`).
- A commit that does not change state adds no entry.
- A new commit clears the redo stack.
- Undo after save re-dirties the document only when the current state differs from the clean snapshot. This matches the current `cleanState` behavior.
- Coalescing is explicit: the shell decides when a gesture ends. Core may merge consecutive transactions with the same `coalesceKey` and no intervening commit. Core does not run a 350 ms timer; the current timer is UI policy (`Sources/RetouchStudio/Models/EditorModel.swift:343-350`).
- History is not serialized. Opening a project starts with an empty history and the current state as clean, matching current behavior.
- Undo/redo must not mutate shared assets. AI assets are immutable; an undone AI edit leaves its files available for redo until the document is closed or the asset GC runs.

**Open question — NOT VERIFIED.** Whether to keep full snapshots or structural deltas after the 100-entry limit. Full snapshots are simpler and bounded by document size; deltas risk subtle divergence. The recommendation is full snapshots with shared immutable assets until measurement shows a memory problem.

---

## 5. Project format v4

### 5.1 Container

**PROPOSED.** A directory package with the layout in `STUDIOCORE_ARCHITECTURE.md` §9.1. The audit already recommends this shape (`Docs/PHASE0_CROSSPLATFORM_AUDIT.md:350-361`).

A v4 package is recognized by `manifest.json` with `"format": "retouch-project"` and `"formatVersion": 4`. A v3 file is recognized by the existing `.retouch` JSON with `"version": 3` (`Sources/RetouchStudio/Models/Project.swift:8-11`).

### 5.2 `manifest.json`

**PROPOSED.**

```json
{
  "format": "retouch-project",
  "formatVersion": 4,
  "schemaVersions": {
    "manifest": 1,
    "source": 1,
    "operations": 1,
    "export": 1,
    "assets": 1
  },
  "documentId": "018f2c9e-...",
  "createdAt": "2026-11-11T12:00:00.000Z",
  "modifiedAt": "2026-11-11T12:34:56.789Z",
  "appVersion": "1.1.0",
  "coreVersion": "0.1.0",
  "revision": 42,
  "capabilities": ["operations.v1", "masks.v1", "ai.provenance.v1"],
  "requires": [],
  "files": {
    "source": "source.json",
    "operations": "operations.json",
    "export": "export.json",
    "assets": "assets/index.json"
  },
  "platform": {
    "macos": "platform/macos.json"
  },
  "unknown": {}
}
```

Rules:

- `files` paths are relative and must not escape the package.
- `platform` entries are optional and never required to open the document.
- `requires` is enforced before any edit is accepted.
- `revision` is the document revision at write time.
- The manifest is written last in the staging directory so a partially written package has no valid manifest.

### 5.3 `source.json`

**PROPOSED.**

```json
{
  "schema": 1,
  "assetId": "018f2ca0-...",
  "fileName": "portrait.jpg",
  "relativePath": "../Photos/portrait.jpg",
  "external": true,
  "bytes": 8123456,
  "quickIdentity": {
    "size": 8123456,
    "modifiedAt": "2026-11-10T18:02:11.000Z"
  },
  "contentHash": {
    "algorithm": "sha256",
    "hex": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  },
  "pixelWidth": 6000,
  "pixelHeight": 4000,
  "colorSpace": {
    "name": "Display P3",
    "iccHash": "sha256:..."
  },
  "orientationNormalized": true,
  "embedded": false
}
```

- `relativePath` is used only when `external` is false or when the relative location is still meaningful. A path outside the package is allowed only for external sources and must be resolved against the project location first.
- `contentHash` is optional until computed.
- `embedded` is true only for an explicit self-contained handoff; the original is not embedded by default.

### 5.4 `operations.json`

**PROPOSED.**

```json
{
  "schema": 1,
  "coordinateSpace": "source_normalized",
  "operations": [
    {
      "id": "018f2cb1-...",
      "type": "retouchParameters",
      "schema": 1,
      "params": { "exposure": 12, "smooth": 34 }
    },
    {
      "id": "018f2cb2-...",
      "type": "heal",
      "schema": 1,
      "spots": [
        { "center": { "x": 0.42, "y": 0.37 }, "radius": 0.018 }
      ]
    },
    {
      "id": "018f2cb3-...",
      "type": "aiPatch",
      "schema": 1,
      "editId": "018f2cb4-...",
      "patch": { "assetId": "018f2cb5-...", "sha256": "..." },
      "alpha": { "assetId": "018f2cb6-...", "sha256": "..." },
      "box": { "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.25 },
      "orientation": { "quarterTurns": 0, "flipped": false, "angle": 0 },
      "imagePixels": { "width": 1600, "height": 1067 },
      "provenance": {
        "modelId": "flux2-klein-4b-q4",
        "modelVersion": "catalog-2026-11",
        "engine": "patch",
        "prompt": "...",
        "seed": 42,
        "preset": "removeObject",
        "startedAt": "2026-11-11T12:00:00.000Z",
        "seconds": 24.1,
        "workerProtocol": 2
      }
    },
    {
      "id": "018f2cb7-...",
      "type": "crop",
      "schema": 1,
      "rect": { "x": 0.05, "y": 0.1, "width": 0.8, "height": 0.7 }
    },
    {
      "id": "018f2cb8-...",
      "type": "orientation",
      "schema": 1,
      "quarterTurns": 1,
      "flipped": false,
      "angle": 1.5
    }
  ]
}
```

The exact property names may change during implementation, but the semantics above are the contract.

### 5.5 `export.json`

**PROPOSED.**

```json
{
  "schema": 1,
  "export": {
    "format": "jpeg",
    "quality": 0.92,
    "maxLongEdge": 0,
    "aiUpscale": false,
    "stripLocationMetadata": true,
    "analysisMode": "none",
    "watermark": null
  },
  "toolDefaults": {
    "autoRetouchStrength": 70,
    "autoColorStrength": 100
  }
}
```

This carries the current project fields `exportFormat`, `exportQuality`, `exportLongEdge`, `autoRetouchStrength`, and `autoColorStrength`, separated into export defaults and tool defaults.

### 5.6 `assets/index.json`

**PROPOSED.**

```json
{
  "schema": 1,
  "assets": [
    {
      "assetId": "018f2cb5-...",
      "kind": "aiPatch",
      "mediaType": "image/png",
      "bytes": 482113,
      "sha256": "…",
      "path": "sha256/9f/9f86d081…"
    }
  ]
}
```

- Paths are relative to `assets/`.
- The hash is computed over the exact bytes.
- A missing asset is an explicit `ASSET_MISSING` error on open or render, never a silent transparent patch.
- A hash mismatch is `ASSET_HASH_MISMATCH` and the document becomes read-only until the asset is relinked.
- Identical bytes are stored once.
- The asset table is the only place that knows file names; operations refer to `assetId` plus hash for verification.

### 5.7 Platform state

**PROPOSED.**

`platform/macos.json`:

```json
{
  "schema": 1,
  "lastKnownPath": "/Users/owner/Photos/portrait.jpg",
  "bookmark": {
    "data": "base64…",
    "createdAt": "2026-11-11T12:00:00.000Z",
    "stale": false
  },
  "securityScoped": true
}
```

`platform/windows.json` and `platform/linux.json` contain only path hints and identity hints. No shell reads another shell's file. A missing platform file is normal, not an error.

**RECOMMENDATION.** The bookmark is refreshed on successful open when it is stale. It is never copied into `source.json`.

### 5.8 Unknown fields

**PROPOSED.**

- Every object decoder keeps a map of keys it does not understand.
- On write, known fields are written first, then unknown fields that do not collide.
- Unknown fields are recorded at the object level, not flattened into a global blob, so a future reader can preserve them through multiple edits.
- A writer that cannot preserve an unknown field must fail the save rather than drop it.

### 5.9 v3 → v4 migration map

**PROPOSED.**

| v3 field (`Sources/RetouchStudio/Models/Project.swift:8-28`) | v4 destination |
|---|---|
| `version` | `manifest.formatVersion = 4` |
| `imagePath` | `source.relativePath` when under the project directory; otherwise external plus `platform/<os>.lastKnownPath` |
| `imageBookmark` | `platform/macos.json.bookmark.data` |
| `adjustments` | `operations[type=retouchParameters].params` |
| `exportFormat`, `exportQuality`, `exportLongEdge` | `export.json.export` |
| `autoRetouchStrength`, `autoColorStrength` | `export.json.toolDefaults` |
| `crop` | `Crop` operation |
| `orientation` | `Orientation` operation |
| `healSpots` | `Heal` operation |
| `stickers` | `Stickers` operation |
| `aiEdits` | `AiPatch` operations plus copied assets, when the source files are readable |
| `analysis` | `Analysis` operation |
| `selectedFace` | `Document.selectedFace` |
| unknown top-level keys | `manifest.unknown` |

Migration rules:

- Migration is pure and never writes until the user saves.
- A source path that cannot be made relative stays external; an absolute path is stored only in platform state.
- An AI patch or alpha file that cannot be read becomes a missing-asset reference with the original path recorded in platform state. The document opens with a clear warning; it is not silently rendered without the edit.
- Coordinates are already source-frame normalized for heal, sticker, AI, crop, and analysis; migration must verify this per record and convert only where the current code used a different space.
- Unknown v3 keys are preserved in `manifest.unknown`, but a later v3 projection cannot re-emit them because v3 has no place for them. The UI must not claim lossless v3 round-trip in that case.

### 5.10 v4 → v3 projection

**RECOMMENDATION.** Support a best-effort v3 writer for compatibility with 1.0-era builds:

- Allowed only when the document contains no v4-only state: no embedded source, no analysis snapshot, no unknown required capability, and all assets are externally resolvable.
- Writes the current v3 JSON fields with an absolute path and a macOS bookmark obtained by the platform adapter.
- Drops v4-only fields; the UI explains that the compatibility copy is lossy.
- Never overwrites the only v4 copy with a v3 projection. It writes to a user-chosen path.

This is the only way to keep old builds useful without making v4 unrepresentable. It is a compatibility bridge, not the primary format.

### 5.11 Save and recovery protocol

**PROPOSED.**

```text
save(document, target):
  1. Validate document and capabilities.
  2. Resolve or copy external assets as required by policy.
  3. Create staging directory beside target.
  4. Write assets, source metadata, operations, export, platform state.
  5. Write manifest last.
  6. fsync every file; fsync every directory.
  7. Verify stage by reading manifest and hashes back.
  8. Write save journal in parent.
  9. Swap previous and staging directories.
 10. fsync parent.
 11. Re-read target manifest; remove journal and previous generation.
```

Failure handling:

- Any failure before step 9 leaves the target untouched. The staging directory is removed or quarantined.
- A crash between steps 9 and 11 leaves a journal and at least one complete generation. Startup recovery chooses the newest valid manifest and never deletes the previous one until verification.
- A store that cannot provide durable flushes returns `DURABILITY_FAILURE`; the UI must not say "saved" without qualification.

**Windows — HYPOTHESIS — NOT VERIFIED.** The adapter must define the equivalent of step 9 using `ReplaceFileW`/directory rename rules and prove it with crash injection. POSIX rename behavior is not portable to Windows open-handle semantics.

### 5.12 Missing and relocated sources

Resolution order:

1. Portable `relativePath` against the project package.
2. Platform state `lastKnownPath`.
3. Platform bookmark/security scope (macOS only).
4. User search list.
5. Ask the user to locate the file.

After resolution:

- If `contentHash` exists and differs, the document is `sourceChanged`.
- If only `quickIdentity` exists and differs, the user is asked to verify; the file is not silently accepted.
- If the user relinks a different file, the source reference is updated, the hash is recomputed, and the document is marked dirty.
- Rendering is blocked until a source is resolved. A placeholder preview may be shown, but export is blocked.

---

## 6. Image engine C ABI

### 6.1 Design choice

**RECOMMENDATION.** Use a C ABI because it is the most stable common denominator for Swift, C++, and Qt. The document API uses JSON payloads for evolvability; the render API uses fixed C structs because it is on the hot path.

### 6.2 Header draft

**PROPOSED.**

```c
#ifndef STUDIOCORE_IMAGE_ENGINE_H
#define STUDIOCORE_IMAGE_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#define SC_IMAGE_ENGINE_ABI 1u

typedef struct ScEngine ScEngine;
typedef struct ScCancelToken ScCancelToken;

typedef struct ScSlice {
  const uint8_t *ptr;
  size_t len;
} ScSlice;

typedef struct ScOwnedBuffer {
  uint8_t *ptr;
  size_t len;
  void (*release)(uint8_t *ptr, size_t len, void *user);
  void *user;
} ScOwnedBuffer;

typedef enum ScPixelFormat {
  SC_PIXEL_RGBA8_PREMULTIPLIED = 1,
  SC_PIXEL_RGBA16 = 2,
  SC_PIXEL_RGBA16F = 3,
  SC_PIXEL_GRAY8 = 4
} ScPixelFormat;

typedef enum ScColorEncoding {
  SC_COLOR_SRGB = 1,
  SC_COLOR_DISPLAY_P3 = 2,
  SC_COLOR_ADOBE_RGB = 3,
  SC_COLOR_ICC = 4
} ScColorEncoding;

typedef struct ScImageBuffer {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  ScPixelFormat format;
  ScColorEncoding color_encoding;
  ScSlice icc_profile;          /* optional */
  ScOwnedBuffer pixels;
} ScImageBuffer;

typedef struct ScProgress {
  uint32_t stage;
  double fraction;
  uint64_t units_done;
  uint64_t units_total;
} ScProgress;

typedef void (*ScProgressCallback)(const ScProgress *progress, void *user);

typedef struct ScRenderTarget {
  uint32_t kind;                /* 1 = preview, 2 = export */
  uint32_t max_long_edge;       /* 0 = full source */
  double scale;                 /* 1.0 = target size; ignored when max_long_edge > 0 */
} ScRenderTarget;

typedef struct ScRenderRequest {
  uint32_t struct_size;
  uint32_t abi_version;
  ScImageBuffer source;
  ScSlice render_plan_json;     /* canonical JSON, versioned */
  ScSlice mask_planes;          /* optional packed descriptors, see 6.4 */
  ScCancelToken *cancel;
  ScProgressCallback progress;
  void *progress_user;
  ScRenderTarget target;
} ScRenderRequest;

typedef struct ScError {
  int32_t code;
  const char *message_key;
  ScOwnedBuffer detail_json;
  ScOwnedBuffer debug;
} ScError;

int32_t sc_engine_create(uint32_t abi_version, ScEngine **out, ScError **error);
void    sc_engine_destroy(ScEngine *engine);
int32_t sc_engine_capabilities(ScEngine *engine, ScOwnedBuffer *out_json, ScError **error);
int32_t sc_engine_render(ScEngine *engine, const ScRenderRequest *request,
                         ScImageBuffer *out_image, ScError **error);
void    sc_engine_cancel(ScEngine *engine, ScCancelToken *token);
void    sc_buffer_release(ScImageBuffer *image);
void    sc_error_release(ScError *error);

#endif
```

Notes:

- The header is illustrative. Field order and names must be frozen only after the prototype and an ABI review.
- `struct_size` and `abi_version` on every extensible struct allow a newer caller to pass a larger struct to an older engine. The engine must read only fields covered by the declared size.
- `ScOwnedBuffer.release` is mandatory. The engine and host may use different allocators; the producer releases.
- `ScError` is allocated by the engine and released by the host. `message_key` points into static storage or into `detail_json`; the release function is the only safe way to free.

### 6.3 Render plan

**PROPOSED.** The render plan is canonical JSON produced by StudioCore:

```json
{
  "schema": 1,
  "documentRevision": 42,
  "source": {
    "width": 6000,
    "height": 4000,
    "colorSpace": { "name": "Display P3", "iccHash": "sha256:..." }
  },
  "orientation": { "quarterTurns": 1, "flipped": false, "angle": 1.5 },
  "crop": { "x": 0.05, "y": 0.1, "width": 0.8, "height": 0.7 },
  "parameters": { "schema": 1, "exposure": 12, "smooth": 34 },
  "heal": [{ "x": 0.42, "y": 0.37, "radius": 0.018 }],
  "aiPatches": [
    {
      "patchAsset": "018f2cb5-...",
      "alphaAsset": "018f2cb6-...",
      "box": { "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.25 },
      "orientation": { "quarterTurns": 0, "flipped": false, "angle": 0 }
    }
  ],
  "stickers": [],
  "analysis": null,
  "target": { "kind": "preview", "maxLongEdge": 2048 },
  "masks": [
    { "name": "skin", "asset": "018f...", "space": "mask_raster", "gate": 0.02 }
  ],
  "determinism": {
    "heal": "exact",
    "color": "exact",
    "vision": "platform",
    "ai": "nondeterministic"
  },
  "engine": { "name": "coreimage", "version": "macos-27" }
}
```

The plan is immutable and self-contained except for asset bytes, which are passed separately or resolved by the engine from the asset store. The engine must not reach into the project itself; the shell/core supplies all bytes.

### 6.4 Masks

**PROPOSED.**

A mask descriptor passed to the engine contains:

```text
MaskPlane {
  name: string
  width: uint32
  height: uint32
  bytesPerRow: uint32
  format: gray8
  space: "mask_raster"
  origin: { x: f64, y: f64 }       // source-normalized position of the raster
  coverage: f64 | null             // optional precomputed coverage
  gate: f64 | null                 // coverage floor, e.g. 0.02
  feather: f64
  sha256: string | null
}
```

Rules:

- `gray8`, 0 = excluded, 255 = fully included.
- The raster origin and size define the mapping to `source_normalized`. No implicit stretching.
- The gate is part of the plan, not a hidden engine default. The current 2% floor is a policy value (`Sources/RetouchStudio/Core/ImageProcessor.swift:560`), so it must be visible and versioned.
- A mask with coverage below the gate resolves to empty. A mask that is absent resolves to empty, not to "whole image".
- Mask construction (shapes, feather, rasterization) is a separate portable module in the target design. Until it exists, the macOS adapter supplies rasters.

### 6.5 Render behavior

**PROPOSED.**

- The engine applies stages in the canonical order, after orientation and before final crop, exactly as the plan says. It does not reorder.
- The engine returns a zero-origin image of the requested target size.
- The output color space is explicit. If the requested output profile is unavailable, the render fails with `COLOR_SPACE_UNAVAILABLE`; it does not silently fall back to sRGB.
- The engine does not write metadata. It returns pixels; metadata policy is applied by the exporter.
- The engine does not touch the source file.
- The engine checks cancellation before each stage and inside long loops. It returns `CANCELLED` promptly.
- Progress stage identifiers match the stage table in §3.3 plus `decode`, `encode`, and `write` for orchestration.
- A stage that is unsupported by the implementation is `UNSUPPORTED_FEATURE`; it is never silently skipped.

### 6.6 Determinism contract

**PROPOSED.** Every render plan labels each stage:

| Label | Meaning | Comparison |
|---|---|---|
| `exact` | Same input and implementation version produce the same canonical pixels on the same host. | Exact digest |
| `tolerance` | Deterministic math, but platform floating-point/GPU differences are expected. | MAE/RMSE/max/SSIM/ΔE gates |
| `platform` | Output depends on an OS detector/model version. | Store a snapshot or compare with an explicit version boundary |
| `nondeterministic` | Output depends on sampling/AI inference. | Never compared pixel-for-pixel; compare masks, boxes, and user-visible quality |

The current same-host gate is exact (`Docs/GOLDEN_IMAGE_CORPUS.md:95`; `Docs/IMAGE_COMPARISON_METHODOLOGY.md:86`). Cross-platform tolerance gates are provisional and unverified (`Docs/IMAGE_COMPARISON_METHODOLOGY.md:127`).

### 6.7 Threading and ownership

**PROPOSED.**

- An engine handle is safe to use from multiple threads only if `capabilities` says `concurrent_renders > 1`; otherwise the host serializes.
- The engine may block the calling thread. Shells call it from a worker queue, never the main thread for full-resolution export.
- The engine owns decoded caches with a byte budget. The host can request `sc_engine_trim_cache`.
- The host owns the input buffers for the duration of the call. It must not free them until the call returns.
- The engine owns the output until `sc_buffer_release`.
- No callback may call back into the same engine handle synchronously. A progress callback must be non-blocking or enqueue work elsewhere.

---

## 7. AI engine interface

### 7.1 Current boundary

**VERIFIED.** The current app submits JSON-RPC jobs to a Python helper, waits for progress, and receives file paths for a patch and alpha (`Sources/RetouchStudio/Models/QuickEdit.swift:89-222`, `Sources/RetouchStudio/Core/WorkerClient.swift:17`). The runtime installer is disabled (`Sources/RetouchStudio/Core/AIRuntime.swift:40`).

### 7.2 Portable contract

**PROPOSED.**

```text
AiEngine {
  capabilities() -> AiCapabilities
  status() -> RuntimeStatus
  ensureReady(cancel) -> RuntimeStatus
  submit(job: AiJob, idempotencyKey: string) -> JobId
  poll(jobId) -> JobStatus
  cancel(jobId)
  adopt(jobId) -> AiArtifacts
}
```

```text
AiCapabilities {
  jobs: ["patchEdit", "segment", "upscale", "modelCatalog"]
  models: [{ id, task, license, bytes, installed, hash? }]
  devices: ["cpu", "metal"]        // per platform
  maxWorkingLongEdge: 1600
  protocolVersion: 2
  deterministic: false
}

AiJob =
  | PatchEdit {
      source: WorkingImageRef,     // temporary copy, not the original
      mask: MaskAssetRef | null,
      points: [Point] | null,
      prompt: string,
      preset: "removeObject" | "healArea" | "reimagine",
      seed: int64,
      engine: "patch" | "inpaint",
      fullFrame: bool,
      patchSize: 512,
      context: 0.25,
      steps: 4,
      dilate: int,
      feather: int
    }
  | Segment { source: WorkingImageRef, box: SourceRect }
  | Upscale { source: WorkingImageRef, factor: float }
  | ModelCatalog
```

```text
AiArtifacts {
  patch: AssetRef
  alpha: AssetRef
  box: SourceRect
  imagePixels: { width, height }
  outsidePixelsIdentical: bool
  provenance: AiProvenance
}

AiProvenance {
  modelId: string
  modelVersion: string | null
  modelHash: string | null
  engine: string
  prompt: string
  seed: int64
  maskHash: string | null
  preset: string | null
  startedAt: string
  seconds: double
  workerProtocol: int
  host: string
}
```

### 7.3 Data crossing the boundary

**PROPOSED.**

- The worker receives a temporary working copy, never the original path.
- The copy is capped at the working long edge (currently 1600; `Sources/RetouchStudio/Core/AIWorker.swift`).
- The copy strips location and camera metadata. **RECOMMENDATION** — verify the current temp-copy path before relying on this as existing behavior.
- The mask is an opaque 8-bit grayscale PNG, white = may change.
- Prompts, preset identifiers, model IDs, seed, patch/context/steps, and mask options cross the boundary.
- The worker returns patch and alpha files, a box, image size, an `outside_pixels_identical` flag, and provenance.
- The app copies returned artifacts into its own content-addressed store before the document learns about the edit. A failure leaves no half-edit, matching the current adoption rule (`Sources/RetouchStudio/Models/AIEdit.swift:11`; `Sources/RetouchStudio/Models/QuickEdit.swift:205-221`).

### 7.4 Transport portability

**PROPOSED.**

- Transport is a `LocalIpc` port with length-prefixed UTF-8 JSON frames.
- macOS/Linux: Unix domain socket.
- Windows: named pipe or loopback socket, chosen by prototype. The framing and JSON-RPC semantics stay identical.
- The handshake carries protocol version, helper generation, launch nonce, and process identity.
- Requests are idempotent by `idempotencyKey`; a retry after a timeout must not create a duplicate paid/generative job.
- Cancellation sends a cancel request and then stops polling. The worker owns cleanup.
- The app never opens a network listener. The AI process is local-only. Model downloads are a separate, consented process (`Sources/RetouchStudio/Models/ModelManager.swift`).

### 7.5 Runtime status

**PROPOSED.**

```text
RuntimeStatus =
  | unavailable { reason: "notInstalled" | "unsupportedPlatform" | "disabled" }
  | installing { fraction }
  | ready { protocolVersion, generation }
  | busy { reason }
  | failed { code, detail }
```

**VERIFIED.** Today `AIRuntime.package` is `nil`, so the downloaded runtime path is disabled (`Sources/RetouchStudio/Core/AIRuntime.swift:40`). The interface must represent "AI unavailable" as a normal state, not an error that blocks the editor. Intel builds have no AI path (the audit records this).

### 7.6 ONNX Runtime

**HYPOTHESIS — NOT VERIFIED.** ONNX Runtime could implement segmentation and upscaling behind the same `AiEngine` contract, with Core ML/DirectML/CUDA/TensorRT/CPU execution providers. It is not approved for implementation because:

- Model conversion parity for Flux/MIGAN is unmeasured.
- Licensing and redistribution of converted weights are unverified.
- Memory on 16 GB machines is unmeasured.
- Execution-provider output can differ from the Python path.

The audit classifies ONNX as "needs more research" (`Docs/PHASE0_CROSSPLATFORM_AUDIT.md:329`). This document keeps that classification.

---

## 8. Platform port contracts

**PROPOSED.** Ports are small and testable. A fake implementation must be enough to run the core suite headlessly.

### 8.1 `SourceAccess`

```text
SourceAccess {
  resolve(ref: SourceRef, platformState: PlatformState) -> ResolvedSource
  readRange(resolved, offset, length) -> bytes
  identity(resolved) -> { size, modifiedAt, contentHash? }
  locate(ref: SourceRef, startDirectory: string) -> ResolvedSource | null
}

ResolvedSource {
  handle: opaque
  readablePathHint: string | null
  size: uint64
  modifiedAt: string | null
  securityScoped: bool
}
```

- `handle` is opaque to core. It may be a POSIX file descriptor, a Windows `HANDLE`, or a platform object.
- The adapter acquires and releases security scope on macOS. Core never sees a bookmark.
- A resolved source must be readable until the operation completes; the adapter documents its lifetime.

### 8.2 `FileStore`

```text
FileStore {
  read(path) -> bytes
  writeAtomic(path, bytes, durability) -> WriteResult
  createDirectory(path)
  list(path) -> [Entry]
  remove(path)
  rename(from, to)
  syncFile(path)
  syncDirectory(path)
  lock(path, exclusive, timeout) -> LockHandle
  fileIdentity(path) -> { device, inodeOrFileId, resolvedPath }
}
```

- `durability` is `bestEffort` or `durable`. `durable` requires file and directory flush semantics.
- `fileIdentity` is how source protection compares destination and source without relying on string equality. The current macOS code already uses resolved paths and device/inode (`Sources/RetouchStudio/Core/ExportService.swift:404`).
- Lock semantics differ on Windows; the adapter owns them. Core asks for a lock, not for `flock`.

### 8.3 Decoder and encoder

```text
Decoder {
  probe(path) -> { format, width, height, colorSpace, hasAlpha, orientation }
  decode(path, options) -> DecodedSource { pixels, width, height, colorSpace, metadata }
}

Encoder {
  encode(pixels, colorSpace, intent, metadataPolicy, destination) -> WriteResult
  supportedFormats() -> [format]
}
```

- Decode applies EXIF orientation exactly once and reports `orientationNormalized`.
- Encode applies the metadata allowlist and normalizes orientation to 1.
- HEIC/RAW support is reported, not assumed. The corpus has no RAW or HEIC source coverage (`Docs/GOLDEN_IMAGE_CORPUS.md:139`).

### 8.4 `LocalIpc`, `ProcessRegistry`, `Clock`

```text
LocalIpc { connect(endpoint), call(frame), close() }
ProcessRegistry { identity(pid), isAlive(identity), terminate(identity) }
Clock { now() }
```

- The current registry and lease code is POSIX-specific (`Sources/RetouchStudio/Core/HelperRegistry.swift:11`, `Sources/RetouchStudio/Core/LockFile.swift:16`). The port must be implemented per OS, not compiled conditionally inside core.

### 8.5 Dialog port

**PROPOSED.** Dialogs are shell code, not a core port. The shell produces a `ResolvedSource` or a destination URL and passes it to the session. This keeps `NSOpenPanel` out of the core and avoids designing a lowest-common-denominator dialog API.

---

## 9. StudioCore FFI

### 9.1 Handle model

**PROPOSED.**

```c
typedef struct ScCore ScCore;
typedef struct ScSession ScSession;

int32_t sc_core_create(uint32_t abi_version, ScCore **out, ScError **error);
void    sc_core_destroy(ScCore *core);
int32_t sc_core_version(ScOwnedBuffer *out_json, ScError **error);

int32_t sc_session_open(ScCore *core, ScSlice request_json,
                        ScSession **out, ScError **error);
int32_t sc_session_call(ScSession *session, ScSlice request_json,
                        ScOwnedBuffer *out_json, ScError **error);
void    sc_session_close(ScSession *session);
```

Every `sc_session_call` takes a command envelope and returns a result envelope. This keeps the ABI stable while operation schemas evolve.

### 9.2 Command envelope

**PROPOSED.**

```json
{
  "command": "apply_operation",
  "requestId": "018f2cc0-...",
  "payload": {
    "operation": { "type": "heal", "id": "018f2cb2-...", "spots": [] }
  }
}
```

Response:

```json
{
  "ok": true,
  "requestId": "018f2cc0-...",
  "documentRevision": 43,
  "result": {}
}
```

Error:

```json
{
  "ok": false,
  "requestId": "018f2cc0-...",
  "error": {
    "code": "VALIDATION_FAILED",
    "messageKey": "error.operation.duplicateCrop",
    "detail": { "operationId": "..." }
  }
}
```

### 9.3 Commands

**PROPOSED.**

| Command | Purpose |
|---|---|
| `document_snapshot` | Return the portable document, revision, dirty flag, history availability |
| `begin_transaction` | Start a transaction with a label and coalesce key |
| `apply_operation` | Add, replace, or remove an operation inside the transaction |
| `commit_transaction` | Commit and return the new revision |
| `cancel_transaction` | Discard uncommitted changes |
| `undo` / `redo` | Move the history cursor |
| `mark_clean` | Mark the saved revision after a successful save |
| `set_source` | Attach or relink a source reference |
| `validate` | Return capability and schema diagnostics |
| `plan_export` | Validate an export intent and return a plan |
| `plan_batch` | Return per-file snapshots and output names |
| `project_encode` | Encode a v4 package (or a v3 projection) to a staged file store |
| `project_decode` | Decode v3/v4 bytes into a document |
| `preset_list` / `preset_save` / `preset_delete` | Preset operations |
| `recovery_classify` | Classify candidates into restore/locate/discard/quarantine |
| `recovery_snapshot` | Produce a portable candidate |

Commands are synchronous. Expensive work (decode, render, AI) happens in the shell or engine, not inside `sc_session_call`.

### 9.4 Session thread safety

**PROPOSED.**

- One `ScSession` belongs to one document. Calls are serialized by the core with a mutex.
- The shell must not call a session from two threads simultaneously. If it does, the calls serialize, but ordering is not guaranteed.
- Rendering is not done inside a session call. The shell obtains an immutable snapshot and a render plan, then calls the engine.
- A session handle must not be used after `sc_session_close`.

### 9.5 Version negotiation

**PROPOSED.**

- `sc_core_version` returns `{abi, coreVersion, maxProjectFormat, capabilities}`.
- The shell checks the ABI before opening a session.
- The core checks the project `requires` before accepting edits.
- A newer shell can open an older core only if the shell can operate without the newer commands; otherwise it refuses.
- No function pointer table is exposed in the first version. A stable set of exported functions plus JSON is easier to audit.

---

## 10. Error taxonomy

**PROPOSED.**

| Code | Retryable | Meaning | User action |
|---|---:|---|---|
| `OK` | — | Success | — |
| `INVALID_ARGUMENT` | No | Malformed request or value | Fix the call |
| `INVALID_STATE` | No | Operation not allowed in the current session state | Refresh state |
| `UNSUPPORTED_VERSION` | No | Project or operation version is too new | Update the app |
| `UNSUPPORTED_FEATURE` | No | Engine/AI capability missing | Use a supported path |
| `DECODE_FAILED` | Maybe | Source could not be decoded | Choose another file |
| `UNSUPPORTED_FORMAT` | No | Format not supported by this build | Choose another format |
| `SOURCE_MISSING` | Maybe | Source file not found | Locate the file |
| `SOURCE_CHANGED` | Maybe | Source identity differs | Locate or accept the new file |
| `SOURCE_ACCESS_DENIED` | Maybe | Permission or security scope denied | Grant access |
| `ASSET_MISSING` | Maybe | Project asset missing | Locate or discard the edit |
| `ASSET_HASH_MISMATCH` | No | Asset bytes differ from the recorded hash | Do not use; relink or discard |
| `VALIDATION_FAILED` | No | Document invariant violated | Fix the document |
| `CANCELLED` | — | Caller cancelled | None |
| `BUSY` | Yes | Another operation holds the resource | Retry |
| `ENGINE_FAILURE` | Maybe | Renderer failed | Retry or report |
| `AI_UNAVAILABLE` | Yes | Runtime not installed/ready | Install or disable AI |
| `IO_FAILURE` | Maybe | File operation failed | Check disk/permissions |
| `DURABILITY_FAILURE` | Maybe | Write could not be confirmed durable | Check disk; do not claim saved |
| `INTERNAL` | Maybe | Unexpected failure | Report with debug detail |

The current app has UI status tokens and localized strings for many of these conditions; the extraction maps them to stable codes without changing the visible wording.

---

## 11. Conformance vectors

**PROPOSED.** The implementation is not accepted on prose alone. These fixtures must exist before a language switch:

### 11.1 Document fixtures

- Minimal document: one source, no operations.
- Every operation type present.
- Multiple heal spots, AI edits, and stickers in a defined order.
- Duplicate singleton operations rejected.
- Unknown optional field round-trip.
- Unknown required capability refused.
- HSL array of the wrong length rejected.
- Out-of-range crop rejected.
- Orientation values normalized to 0…3.
- A v3 fixture with absolute path and bookmark.
- A v3 fixture with missing AI patch files.
- A v4 fixture with a missing asset and a hash mismatch.
- A v4 fixture with a relocated source and a matching hash.
- A v4 fixture with a mismatched source hash.
- A preset written by an older build opens with defaults.

### 11.2 History fixtures

- Commit, undo, redo, redo cleared by a new commit.
- No-op commit adds no entry.
- Limit 100 discards the oldest entry.
- Commit after save and undo returns to the clean state exactly.
- Coalesced transactions merge only with the same key.
- Cancelled transaction changes nothing.

### 11.3 Render fixtures

- The existing 78-case corpus, unchanged, against the macOS adapter.
- The same corpus against a future Rust engine, with the methodology's comparison order.
- Preview and export of the same plan agree on geometry and masks.
- Cancellation at each stage returns `CANCELLED` and no partial output.
- Missing mask resolves to empty, never full coverage.
- Color profile unavailable fails explicitly.
- Alpha premultiplication is consistent between preview and export.

### 11.4 ABI fixtures

- A C program compiled by the macOS, Windows, and Linux toolchains creates an engine, renders a 1×1 image, and releases every buffer.
- A struct with `struct_size` smaller than the current struct is accepted and only declared fields are read.
- A panic path returns `INTERNAL` and does not unwind.
- Double release is either idempotent or detected; it never corrupts the heap.
- Unicode paths and long paths are accepted by the platform adapter.

### 11.5 AI fixtures

- Fake worker over the real framing: submit, progress, result, adopt.
- Worker crash mid-job returns a typed failure and leaves no document edit.
- Cancellation stops polling and does not create a duplicate job.
- A missing runtime reports `AI_UNAVAILABLE` and the editor remains usable.
- Provenance records model ID, prompt, seed, mask hash, and protocol version.

---

## 12. Open questions

**NOT VERIFIED / OWNER DECISION REQUIRED.**

1. Whether stored analysis snapshots are optional or required for cross-platform fidelity.
2. Whether the source may be embedded in a v4 package at all, and under what warning.
3. Whether v3 compatibility projection is a shipping feature or a one-release bridge.
4. The exact Windows directory-swap sequence and durability guarantee.
5. Whether full snapshot history stays within the memory budget on 16 GB machines for large documents.
6. The exact color working space and whether it can match Core Image closely enough without changing baseline pixels.
7. The Qt 6 feasibility for color-managed canvas, RTL, IME, and tablet input.
8. Whether ONNX Runtime can reproduce the current AI quality for any model.
9. Whether face detection can become portable without changing downstream masks.
10. The minimum OS versions for Windows and Linux, which affect filesystem, color, and IPC choices.

These are design inputs, not implementation approvals.
