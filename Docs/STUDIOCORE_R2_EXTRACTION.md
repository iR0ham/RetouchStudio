# StudioCore R2 — first production extraction

R2 moves a small, coherent set of Foundation-only domain types out of the app
target and into a real module that compiles on its own: `Sources/StudioCore`.
It is the first extraction step, not a refactor. The macOS app remains the
reference implementation and behaves exactly as before.

- Baseline: `main` at `7cfc8594f416c987386e0abe103cc75121de073a`
- Project format: still v3, unchanged
- Golden Image Corpus: untouched (fixtures, references and baselines unchanged)
- Build system: unchanged (flat `swiftc` + `bash`, no SwiftPM, no Xcode)

## 1. Types moved into `Sources/StudioCore`

| Type | File | Notes |
| --- | --- | --- |
| `MakeupColor` | `MakeupColor.swift` | HSV value type; hue wrap, 0...1 clamping, RGB conversion, `with(hue:)`/`with(saturation:)`. Hashable + Codable. |
| `MakeupFamily` | `Makeup.swift` | Skin-tone family and the unchanged luminance thresholds. |
| `MakeupRegion` | `Makeup.swift` | Cosmetic region, per-region default amount, and the `WritableKeyPath<Adjustments, …>` addressing the colour and amount fields. |
| `MakeupShade` | `Makeup.swift` | The 58-entry catalogue. Stable `id`/`rawValue`, identity initialiser, region/family queries, `Shade.all` in the original order. |
| `Adjustments` | `Adjustments.swift` | All 77 stored settings, the computed `blackLevel`/`whiteLevel`, `RetouchField`/`ColorField` option sets, group views, applying/scaling helpers, and the hand-written `Codable` conformance. |
| `HSLBand` | `Adjustments.swift` | Eight hue bands with their center hues and half widths. |
| `AdjustmentGroup` | `Adjustments.swift` | Inspector group identity and order. |
| `UserPreset` | `UserPreset.swift` | Saved look: stable id, name, adjustments. |

`RetouchField` and `ColorField` are nested in `Adjustments` and are part of the
same extraction.

## 2. Types deliberately left in the app

| Type | Why it was not moved |
| --- | --- |
| `DocumentOrientation`, `HealSpot`, `HealGeometry`, `CropAspect`, `CropGeometry`, `Sticker`, `ArtGeometry`, `AnalysisSettings` | They are defined in `CoreGraphics` geometry (`CGRect`/`CGPoint`) or are inseparable from the image editor's coordinate space. Moving them needs a geometry/coordinate abstraction first, which is not part of R2. |
| `RetouchProject` | Uses `CGRect`, `UTType` and security-scoped bookmarks. The document codec belongs to a later, explicitly approved step. |
| `ExportSnapshot`, `BatchExportPolicy` | Tied to editor/export settings and image sizes; they depend on the extraction of the document/export model first. |
| `FilmLook`, `LookGrade` | `Adjustments.look` is now an app-side extension over the extracted `lookID`; the look catalogue stays with its rendering engine. |
| `PresetGroup`, `PresetID`, `Preset` | The built-in preset library and its localized titles are app content, not portable domain values. |
| `UserPresetStore` | File-system I/O and Application Support paths; stays in the app. |
| `HSLBand.title`, makeup enum titles, `Preset.title` | Localization (`L10n`) is a presentation concern. |
| `MakeupColor.color` | `SwiftUI.Color`; moved into an app-side extension. |

No duplicate competing definition remains anywhere. The removed app-side
declarations were deleted, not copied as fallbacks.

## 3. Module and build integration

`Sources/StudioCore` contains four files and imports `Foundation` only.
`Tests/build-studiocore.sh` compiles it as an independent module:

```
swiftc -O -target <arch>-apple-macosx14.0 -sdk <sdk> \
  -module-name StudioCore \
  -emit-module -emit-module-path build/studiocore/<arch>/StudioCore.swiftmodule \
  -emit-library -static -o build/studiocore/<arch>/libStudioCore.a \
  Sources/StudioCore/*.swift
```

Changed build files:

- `build.sh` — app sources are scoped to `Sources/RetouchStudio`; one module is
  built per architecture, then the app is compiled with `-I` and linked against
  `libStudioCore.a`. The flat `swiftc` build is preserved.
- `Tests/run.sh`, `Tests/run-corpus.sh` — build the module once per run and link
  the four suites and the corpus harness against it.
- `Tests/build-studiocore.sh` (new) — module builder shared by all harnesses.
- `Tests/run-studiocore.sh` (new) — boundary check + standalone tests.

`build/studiocore/` is under the ignored `build/` tree and is disposable.

## 4. Architectural checks

`./Tests/run-studiocore.sh` fails if any of these is violated:

1. StudioCore source imports anything other than `Foundation` (the forbidden
   list includes AppKit, SwiftUI, Core Image, Vision, ImageIO, CoreGraphics,
   UIKit, UniformTypeIdentifiers, CoreVideo, Metal, AVFoundation, Cocoa and
   `RetouchStudio`).
2. A source line mentions a platform type such as `NSColor`, `CIImage`, `CGRect`,
   `CGFloat`, `UTType`, `Color`, `Image` or `View`.
3. The test binary links a platform framework (verified with `otool -L`).
4. The module and its tests do not compile without the app target (the test
   compile passes no `-framework` flags and no app sources).

The independent compile is the strongest proof: the module cannot reference
app-only types and still build.

## 5. v3 serialization compatibility

Before the move, the original app code was used to capture four JSON documents
(pretty-printed, sorted keys, the app's encoder settings). They are stored as
permanent fixtures and compared byte for byte:

| Fixture | SHA-256 |
| --- | --- |
| `Tests/StudioCoreFixtures/v3-adjustments-defaults.json` | `d3924d840ad1b300ad2a403eec2a67795aefc16a5000487521cc0041651d6145` |
| `Tests/StudioCoreFixtures/v3-adjustments-full.json` | `62823f377e78a00fe6c031d09d50987d40084015a0bb968409e290e4fcb2d02a` |
| `Tests/StudioCoreFixtures/v3-adjustments-legacy-decoded.json` | `4721fe0f219613df4a43d8ff200d77462db1c23570e59b26e37e6d0e56a1a6da` |
| `Tests/StudioCoreFixtures/v3-user-preset.json` | `f266426f710b135d15024c87f46f3ef8cd71df3075051d01af1905efe610affb` |

Compatibility-sensitive details that are preserved and asserted:

- identical key names and encode order;
- the decode-only legacy keys `lipShadeID`/`blushShadeID`;
- missing keys fall back to the same values the old decoder used;
- HSL arrays are padded, trimmed and clamped to eight bands;
- an empty object still decodes `backgroundImageAmount` as 0 (the declared
  default is 100; that asymmetry predates R2 and is intentionally unchanged);
- stable shade identifiers, catalogue order and the 58-entry count.

The project version stays 3. No encoder, C ABI or operation-ordering change was
made; UUID conventions remain provisional.

## 6. Verification

Same-host arm64 results:

| Check | Result |
| --- | --- |
| Independent StudioCore compile | pass (arm64 and x86_64) |
| `./Tests/run-studiocore.sh` | 52/52 checks, boundary clean |
| Platform boundary check | pass: Foundation only, no platform types, no platform linkage |
| Engine suite | 131 checks pass |
| Model suite | 609 checks pass |
| Runtime process suite | 55 checks pass |
| Runtime v2 suite | 46 checks pass |
| `./Tests/run.sh` total | 841 checks, 0 failures |
| `./Tests/run-corpus.sh` | 376 checks, 0 failures; corpus files unchanged |
| R1 conformance | pass: 21 fixtures, lock 12/78/21/11 |
| C ABI header smoke | `studioscore abi=1 status_count=20 error_codes=20` |
| `RETOUCH_ARCH=arm64 ./build.sh` | bundle built, engine self-test passed |
| `git diff --check` | clean |

Rosetta x86_64 slice on Apple silicon (evidence only, no native Intel claim):

- StudioCore compile and tests: 52/52;
- `RETOUCH_ARCH=x86_64 ./Tests/run.sh`: 841 checks, 0 failures;
- `RETOUCH_ARCH=x86_64 ./Tests/run-corpus.sh`: 376 checks, 18 failures — the
  nine 8-bit fixture regeneration checks and the six paths
  `X02_STICKER`, `X03_ANALYSIS_PHOTO`, `X04_ANALYSIS_POSTER`,
  `X05_ANALYSIS_OVERLAY`, `X06_WATERMARK`, `L01_F10_UPRIGHT`. This matches, in
  the same set and magnitude, the cross-architecture behavior already recorded
  in `Docs/GOLDEN_IMAGE_CORPUS.md` and `Docs/IMAGE_COMPARISON_METHODOLOGY.md`.
  It is not an R2 regression; the arm64 run is the gate.

The five export files the x86_64 corpus run rewrites were restored afterwards;
all tracked corpus files match their pre-run hashes.

## 7. Remaining dependencies and risks

- The extracted module is architecture-specific; each build produces its own
  `.swiftmodule`/`.a` pair.
- Geometry-bearing types and the document codec still depend on CoreGraphics
  and cannot move until a portable geometry layer exists.
- The module's public interface is not a frozen ABI. R3 and later steps decide
  the JSON/codec surface.
- Byte-identical encoding depends on JSON encoder settings (sorted keys,
  pretty printing); the fixtures pin the current contract.
- No cross-language JSON compatibility, Windows, Linux or native Intel support
  is claimed.

## 8. Rollback

R2 is reversible without touching project data.

1. Restore the tracked files that R2 modified:

   ```
   git checkout -- build.sh Tests/run.sh Tests/run-corpus.sh \
     Sources/RetouchStudio/Core/AutoAnalyzer.swift \
     Sources/RetouchStudio/Core/ExportService.swift \
     Sources/RetouchStudio/Core/FeatureReshaper.swift \
     Sources/RetouchStudio/Core/ImageProcessor.swift \
     Sources/RetouchStudio/Core/LookEngine.swift \
     Sources/RetouchStudio/Core/MakeupEngine.swift \
     Sources/RetouchStudio/Core/SceneEngine.swift \
     Sources/RetouchStudio/Core/SelfCheck.swift \
     Sources/RetouchStudio/Core/SmartAnalyzer.swift \
     Sources/RetouchStudio/Models/Adjustments.swift \
     Sources/RetouchStudio/Models/EditorModel.swift \
     Sources/RetouchStudio/Models/Localization.swift \
     Sources/RetouchStudio/Models/Makeup.swift \
     Sources/RetouchStudio/Models/PersianL10n.swift \
     Sources/RetouchStudio/Models/Project.swift \
     Sources/RetouchStudio/Models/Sticker.swift \
     Sources/RetouchStudio/Models/TutorialCopy.swift \
     Sources/RetouchStudio/Models/UserPreset.swift \
     Sources/RetouchStudio/Views/Components.swift \
     Sources/RetouchStudio/Views/InspectorView.swift \
     Tests/CorpusSupport.swift Tests/CorpusTests.swift \
     Tests/EngineTests.swift Tests/ModelTests.swift
   ```

2. Remove R2-only untracked paths (this keeps the R1 conformance work):

   ```
   rm -rf Sources/StudioCore Tests/StudioCoreFixtures \
     Tests/StudioCoreTests.swift Tests/run-studiocore.sh \
     Tests/build-studiocore.sh build/studiocore
   ```

3. Rebuild and rerun the suites exactly as before R2.

Project files, recovery data and the corpus need no migration: R2 never
changed any on-disk format.
