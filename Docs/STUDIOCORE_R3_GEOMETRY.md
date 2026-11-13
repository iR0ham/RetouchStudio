# StudioCore R3 — Portable Geometry Foundation

**Status:** Implemented in R3, uncommitted, awaiting review.
**Baseline:** `main` / `deaaf37e1a1e9996fac417ebbe9341f0cc36b3bc` (R2 committed).
**Scope:** a Foundation-only geometry value layer plus macOS CoreGraphics
adapters. No document-model migration, no renderer change, no v3 format change.

Related documents:

- `Docs/STUDIOCORE_CANONICAL_JSON.md` — keyed canonical geometry and number rules.
- `Docs/STUDIOCORE_INTERFACE_DESIGN.md` — §2.4–2.5 units and coordinate spaces.
- `Docs/STUDIOCORE_ARCHITECTURE.md` — engine boundary and pipeline.
- `Docs/STUDIOCORE_R2_EXTRACTION.md` — the first StudioCore extraction.

---

## 1. Purpose

R2 extracted pure value types (`Adjustments`, makeup types, `UserPreset`).
Every geometry record in the app still uses `CGPoint`, `CGSize`, `CGRect` and
`CGFloat`. This milestone adds portable replacements and documents the exact
semantics those replacements must preserve, without touching stored data.

The constraint that shaped the design: **v3 project files encode Apple
geometry as unkeyed nested arrays**, while the R1 canonical JSON contract uses
keyed objects. The two shapes are not interchangeable, and the v3 bytes are
part of the shipped contract. Therefore R3 is additive. No existing serialized
field changes type.

---

## 2. Verified inventory (Phase 1)

### 2.1 Stored geometry

| Declaration | Location | Stored fields | Space and unit | Serialized in v3 |
|---|---|---|---|---|
| `HealSpot` | `Sources/RetouchStudio/Models/Heal.swift:10` | `center: CGPoint`, `radius: CGFloat` | `center` normalized top-left against the original photo; `radius` fraction of the short side | Yes, inside `healSpots` |
| `Sticker` | `Sources/RetouchStudio/Models/Sticker.swift:20` | `center: CGPoint`, `size: Double` (plus `rotation`, `opacity`, color) | `center` normalized top-left; `size` fraction of the original photo's short side | Yes, inside `stickers` |
| `AIEdit` | `Sources/RetouchStudio/Models/AIEdit.swift:11` | `box: CGRect`, `imagePixels: CGSize` | `box` normalized top-left against the original photo; `imagePixels` pixel dimensions of the job image | Yes, inside `aiEdits` |
| `AnalysisSettings` | `Sources/RetouchStudio/Models/Analysis.swift:68` | `endpoints: [String: CGPoint]`, `anchors: [String: CGPoint]` | **Normalized bottom-left**; the overlay and renderer flip y when drawing | Yes, inside `analysis` |
| `RetouchProject.crop` | `Sources/RetouchStudio/Models/Project.swift:39` | `CGRect?` | Normalized top-left | Yes |
| `AIMaskStroke` | `Sources/RetouchStudio/Models/AIMask.swift:33` | `points: [CGPoint]`, `width: CGFloat` | Normalized top-left; `width` fraction of photo width | No (transient selection state) |
| `AIMaskSelection` | `Sources/RetouchStudio/Models/AIMask.swift:41` | `box: CGRect?` | Normalized top-left | No (transient) |

Project decoding is tolerant: `crop`, `healSpots`, `stickers`, `aiEdits` and
`analysis` are all read with `decodeIfPresent`
(`Sources/RetouchStudio/Models/Project.swift:107-112`), so older files open
unchanged. `AnalysisSettings` has a hand-written decoder with per-key defaults
(`Sources/RetouchStudio/Models/Analysis.swift:120-142`).

### 2.2 Derived, transient geometry

| Operation | Location | Notes |
|---|---|---|
| `HealGeometry.workingRadius/workingCenter/originalCenter/originalRadius/workingSpots/indexed` | `Sources/RetouchStudio/Models/Heal.swift:21-67` | Maps a spot between the original normalized frame and the cropped working frame; discards stamps fully outside the crop |
| `HealGeometry.shortSideDistance` | `Sources/RetouchStudio/Models/Heal.swift:69` | Distance in short-side units; accounts for pixel aspect |
| `HealGeometry.shapes` | `Sources/RetouchStudio/Models/Heal.swift:83` | Builds bottom-left `MaskShape.ellipse` records; `y = 1 - center.y - ry` |
| `CropGeometry` | `Sources/RetouchStudio/Models/Crop.swift:31-92` | `full`, minimum size, view/normalized conversion, crop composition, clamping, aspect fit |
| `ArtGeometry` | `Sources/RetouchStudio/Models/Sticker.swift:33-86` | Sticker center/size between original and working frames with pixel-aspect correction |
| `DocumentOrientation` | `Sources/RetouchStudio/Models/Orientation.swift` | Quarter turns, mirror, straighten; maps normalized points, rects and short-side fractions between frames; renders via Core Image |
| `MaskShape` | `Sources/RetouchStudio/Core/MaskBuilder.swift:6-16` | Polygon/ellipse/rounded-rect masks with a bottom-left origin |
| `AnalysisRenderer` / `AnalysisOverlay` | `Sources/RetouchStudio/Core/AnalysisRenderer.swift`, `Sources/RetouchStudio/Views/AnalysisOverlay.swift:120,132-134` | Bottom-left canvas math; stored pins are flipped on draw |
| `AIMaskRenderer` | `Sources/RetouchStudio/Models/AIMask.swift` (renderer) | Flips top-left strokes/box into a bottom-left bitmap context |
| `WatermarkSettings` | `Sources/RetouchStudio/Models/Watermark.swift` | Only scalar settings are stored; layout uses CG at render time |

### 2.3 Coordinate conventions actually in force

1. **Canonical document space is normalized top-left**, y down. Crop, heal
   centers, sticker centers, AI boxes and mask strokes all follow it
   (`Heal.swift:5-6`, `Crop.swift:4-5`, `Sticker.swift:15-18`,
   `AIEdit.swift:21-23`). This matches R1 `coordinateSpace: "source_normalized"`
   (`Tests/Conformance/Fixtures/canonical/document-crop-orientation.json:20`).
2. **Analysis pins are normalized bottom-left.** `AnalysisOverlay.normalized`
   computes `y: 1 - point.y / height` (`AnalysisOverlay.swift:132-134`) and
   draws at `(1 - end.y) * height` (`:120`). `AnalysisRenderer` keeps the same
   bottom-left math. This is a verified inconsistency with the canonical space.
3. **Vision, masks and Core Image are bottom-left**, in normalized or pixel
   units depending on the stage (`FaceAnalyzer.swift:306`,
   `MaskBuilder.swift:6`, `Heal.swift:77-79`).
4. **Sizes that must survive a crop are stored as fractions of the short
   side**: heal radius and sticker size. Sticker conversion additionally needs
   the photo's pixel aspect ratio (`Sticker.swift:35-43`).
5. **Orientation is baked into working pixels**, so stored coordinates are
   remapped through `DocumentOrientation.mapPoint/mapRect`; a straighten is
   bounded rather than exact for axis-aligned rectangles.

### 2.4 v3 serialization evidence

A Foundation-only probe encoded the Apple values with `JSONEncoder`
(sorted keys) and produced:

```text
rect:  [[0.1,0.2],[0.3,0.4]]
point: [0.1,0.2]
size:  [0.3,0.4]
```

That is `CGRect` as an unkeyed pair of origin/size pairs and `CGPoint`/`CGSize`
as unkeyed pairs. Corresponding project keys are `crop`, `healSpots[].center`,
`stickers[].center`, `aiEdits[].box`, `aiEdits[].imagePixels`,
`analysis.endpoints` and `analysis.anchors`.

The R1 canonical fixtures use keyed objects instead:

```json
"rect":   { "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8 }
"center": { "x": 0.42, "y": 0.37 }
"box":    { "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.25 }
```

Consequences, all verified from the fixtures:

- Swapping a stored `CGRect`/`CGPoint`/`CGSize` for a keyed portable type
  changes the bytes of every project that contains that field.
- `JSONDecoder` will not read a keyed object into `CGRect`, and a synthesized
  keyed decoder will not read the legacy unkeyed arrays. There is no implicit
  migration.
- Changing the wire shape needs an explicit format-version decision, a
  read-old/write-new policy, and corpus/conformance evidence. None of that is
  part of R3.

### 2.5 CoreGraphics-dependent operations

The following cannot move into StudioCore unchanged: `CGRect.minX/midX/maxX`
conveniences, `CGRect.standardized/contains/union/intersection`, geometry
rendering (`CGContext`, `CIImage`, `CGAffineTransform`), Vision point
conversion, and every draw/layout path. R3 therefore adds value types and
leaves the operations in the app until an engine milestone supplies portable
implementations.

---

## 3. Portable design (Phase 2)

All types are Foundation-only, `Double`-based, `Hashable`, `Codable` and
`Sendable`. CoreGraphics appears only in an app-side adapter file.

### 3.1 `StudioPoint`

- Stored `x: Double`, `y: Double`; `zero`; `isFinite`; `distance(to:)`.
- Synthesized Codable: `{"x":…,"y":…}`. Keys are the R1 canonical names.
- No implicit conversion between spaces. A bare point has no origin: the
  caller must know its `StudioCoordinateSpace`.

### 3.2 `StudioSize`

- Stored `width`, `height`; `zero`; `isFinite`; `isValid` (finite and
  non-negative); `isEmpty` (`width <= 0 || height <= 0`).
- Zero is explicitly **valid**: an empty crop or an empty mask box is a real
  state. Negative dimensions are representable but invalid; nothing clamps
  them, because legacy values and UI drafts must round-trip unchanged.

### 3.3 `StudioRect`

- Stored `x`, `y`, `width`, `height`, matching the R1 keys exactly.
- `origin`/`size` accessors; `minX`, `midX`, `maxX`, `minY`, `midY`, `maxY`;
  `isFinite`, `isValid`, `isEmpty`.
- `contains(_:)` is **half-open**: `minX <= x < maxX` and `minY <= y < maxY`.
  This matches the interface design (§2.4) and avoids double-counting shared
  edges.
- `standardized()` flips negative extents explicitly. It is never applied
  automatically, so a draft rectangle keeps the values the user produced.
- Synthesized Codable: `{"height":…,"width":…,"x":…,"y":…}` when sorted.

### 3.4 `StudioCoordinateSpace`

| Case | Raw value | Origin | Unit |
|---|---|---|---|
| `sourceNormalizedTopLeft` | `source_normalized` | top-left | normalized |
| `sourceNormalizedBottomLeft` | `source_normalized_bottom_left` | bottom-left | normalized |
| `sourcePixelTopLeft` | `source_pixel` | top-left | pixels |
| `sourcePixelBottomLeft` | `source_pixel_bottom_left` | bottom-left | pixels |

- `source_normalized` is the only raw value already pinned by R1 fixtures;
  the other three are StudioCore names, not new canonical contract.
- `isNormalized`, `hasTopLeftOrigin`, `sameUnit(as:)`.
- `convert(_ point:to:frameHeight:)` and
  `convert(_ rect:to:frameHeight:)`:
  - conversion happens only within one unit (normalized ↔ normalized, pixel ↔
    pixel); crossing units returns `nil`,
  - `frameHeight` is the frame height in pixels, ignored for normalized
    spaces, and must be finite and positive for pixel spaces,
  - a rect is converted as `y' = height - (y + height)`; its `y` is the min
    edge in the source space, which is how mask and Vision rectangles are
    defined,
  - an actual flip requires finite input; a negative-extent rect returns
    `nil` and must be standardized explicitly by the caller,
  - nothing is clamped or normalized automatically,
  - converting to the same space is identity and returns the value unchanged,
    including a value that would fail validation.

### 3.5 Serialization policy

- Keyed objects only. The synthesized decoder **rejects the legacy unkeyed v3
  shape**; a test pins that so a future migration cannot happen by accident.
- Unknown keys are ignored by the synthesized decoder. These value types are
  not document records, so they do not implement unknown-field preservation;
  a future document codec must do that at the record level.
- Non-finite values fail `JSONEncoder` by default (non-conforming float
  strategy `.throw`), and a JSON `NaN`/`Infinity` literal fails the decoder.
  That matches the canonical JSON rule that these values are invalid.
- Float text formatting remains Swift's shortest round-trip form. Agreement
  with the Python reference encoder on every double is **NOT VERIFIED**; only
  the keyed shape and exact Swift round-trip are tests here.
- Negative zero: `Double(-0.0) == Double(0.0)`, and Swift may emit `-0`.
  Canonical JSON rejects negative zero. StudioCore does not rewrite it; a
  future canonical encoder must handle this explicitly.

---

## 4. Implementation (Phase 3)

| File | Contents |
|---|---|
| `Sources/StudioCore/StudioGeometry.swift` | `StudioPoint`, `StudioSize`, `StudioRect`, `StudioCoordinateSpace` |
| `Sources/RetouchStudio/Models/StudioGeometry+CoreGraphics.swift` | App-boundary `init(CGPoint/CGSize/CGRect)` and `cgPoint/cgSize/cgRect` |
| `Tests/StudioCoreTests.swift` | Pure geometry and Codable checks |
| `Tests/ModelTests.swift` | CoreGraphics bridge checks |

No stored model was migrated. R3 keeps every project byte and every engine
calculation identical; the models still hold `CGPoint`/`CGSize`/`CGRect`.

**Why no migration:** each candidate field is serialized with the unkeyed
Apple shape. Replacing the type changes the bytes and needs a versioned
migration plus corpus evidence. The optional “at most one low-risk type” in
the brief does not apply: no serialized geometry field is low-risk, and the
transient `AIMaskStroke`/`AIMaskSelection` types are intermediate UI state
whose migration would only add churn without proving portability.

---

## 5. Compatibility and risks

| Risk | Status in R3 |
|---|---|
| v3 wire shape | Untouched. No stored field changed. |
| Defaults for missing fields | Untouched (`decodeIfPresent` and analysis decoder unchanged). |
| Clamping/normalization of legacy values | Not introduced. |
| Golden fixtures/baselines | Not regenerated. |
| `CGFloat` ↔ `Double` precision | Exact on arm64 and x86_64 (64-bit `CGFloat`); tests check bit patterns. 32-bit platforms are out of scope. |
| Bottom-left analysis pins | Documented; not migrated. A future adapter must flip at the boundary. |
| Straighten mapping | Unchanged; it remains pixel-space and bounded for rects. |
| Canonical number formatting | **NOT VERIFIED** across languages; only shape and Swift round-trip tested. |
| Windows behavior | Swift build and fixture tests pass on `windows-2025` (2026-11-13); a light C# host exists in `Windows/` and is tested there; no parity claim. |
| Linux behavior | **NOT VERIFIED**; no Linux build is claimed. |

---

## 6. Tests (Phase 5)

`Tests/StudioCoreTests.swift` adds:

1. Construction, defaults, equality and hashing for all three value types.
2. Positive, zero and negative dimensions; zero-valid/empty distinction.
3. Non-finite values: `isFinite`/`isValid` false, conversions return `nil`,
   encoding throws.
4. Rectangle edges: origin edges contained, max edges excluded, outside
   points rejected; mutating `origin`/`size` keeps the rectangle coherent.
5. Point/size accessors and `standardized()`.
6. Coordinate-space semantics: top-left ↔ bottom-left points and rects,
   exact unit edges, out-of-range values that are flipped rather than
   clamped, pixel height, unit mismatch, invalid frame height, round trip.
7. Codable: exact keyed JSON, round trip, unknown keys ignored, legacy
   unkeyed arrays rejected, non-finite JSON rejected, bit-exact double round
   trip.

`Tests/ModelTests.swift` adds a bridge check that `CGPoint`, `CGSize` and
`CGRect` convert in both directions with identical bit patterns, that a
negative-extent rect survives unchanged, and that the adapter does not
standardize or clamp.

---

## 7. Migration candidates for a later milestone

Ordered by risk, lowest first. Each needs its own compatibility decision.

1. **Transient only:** `AIMaskStroke.points`, `AIMaskSelection.box` (not
   serialized). Safe to type as `[StudioPoint]` / `StudioRect?` once the mask
   renderer has a portable transform.
2. **Canonical-shaped candidates:** `AIEdit.box`/`imagePixels` and
   `RetouchProject.crop`. These already match canonical keyed geometry
   semantically, but the on-disk bytes are unkeyed, so a writer/reader
   migration is required.
3. **Fraction-of-short-side candidates:** `HealSpot.center/radius` and
   `Sticker.center/size`. The values need a documented unit tag before they
   can be portable; radius/size are not plain normalized coordinates.
4. **Bottom-left pins:** `AnalysisSettings.endpoints/anchors`. Migrating them
   requires an explicit space change or a boundary flip, plus corpus proof.
5. **Operations, not values:** `HealGeometry`, `CropGeometry`, `ArtGeometry`,
   `DocumentOrientation`. These require portable rect math, transform
   composition, and pixel/aspect helpers. They belong to an engine milestone,
   not R3.

---

## 8. Explicitly out of scope

- `EditorModel` refactor or extraction.
- Whole document model extraction.
- Any image-pipeline, algorithm or 17-stage render-order change.
- AI worker/protocol changes, Recovery/autosave changes.
- Any v3 serialization change, format version bump or fixture regeneration.
- Rust, Qt, a new UI framework, new dependencies, SwiftPM conversion.
- macOS UI behavior changes.
