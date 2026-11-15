# Golden Image Corpus

**Project:** Retouch Studio
**Repository:** `/Users/roham/RetouchStudio`
**Baseline commit:** `main` at `01da9005663127a513dae704785243f5b5ec8fab`
**Document date:** 2026-11-11
**Scope:** Milestone 3 — corpus creation and engine characterization. No engine algorithm, project format, Recovery/autosave path, runtime installer or dependency was changed.

This document describes what the corpus **actually contains**, how it was produced, and what it does **not** cover. It is deliberately separate from the engine characterization (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md`) and the comparison rules (`Docs/IMAGE_COMPARISON_METHODOLOGY.md`).

---

## 1. Status vocabulary

| Label | Meaning in this document |
|---|---|
| **PLANNED** | Designed in the fixture table below but not generated. Nothing in this row exists on disk. |
| **CREATED** | A fixture file exists under `Tests/Corpus/Fixtures/` and its SHA-256 is recorded in `MANIFEST.json`. |
| **CAPTURED** | A reference output exists under `Tests/Corpus/References/` and/or a digest exists in `baselines.json`, produced by the current engine on this host. |
| **VALIDATED** | Re-running the harness reproduced the captured digest/reference exactly on this host. |
| **NOT CAPTURED** | The operation exists in the engine but no corpus case exercises it, or it cannot run in this environment. |

Captured baselines are **not** a claim of cross-platform correctness. They are exact only on the machine, OS build and graphics stack that produced them. See `Docs/IMAGE_COMPARISON_METHODOLOGY.md`.

---

## 2. What exists now

| Item | Count | Location | State |
|---|---|---|---|
| Planned fixtures | 13 | `Tests/CorpusSupport.swift` (`FixtureSpec`) | **CREATED** 13/13 |
| Fixture files | 13 | `Tests/Corpus/Fixtures/` | **CREATED** |
| Manifest | 1 | `Tests/Corpus/Fixtures/MANIFEST.json` | **CREATED** |
| Operation cases | 85 | `Tests/CorpusTests.swift` (`buildCases`) | **CAPTURED** 85/85 |
| Reference PNGs | 28 | `Tests/Corpus/References/` | **CAPTURED** |
| Baselines | 2 | `Tests/Corpus/baselines.json` + `baselines.geometry.v1.json` | **CAPTURED** |
| Export artifacts | 11 | `Tests/Corpus/Exports/` | **CAPTURED** |
| Harness | 2 scripts | `Tests/run-corpus.sh`, `Tests/CorpusTests.swift` + `Tests/CorpusSupport.swift` | **CREATED** |
| Reference comparison | 85 digest checks + 28 PNG checks | verify mode of the harness | **VALIDATED** on this host |

Final verification on the capture host (2026-11-11): **376 checks, 0 failures**, including 78 digest matches, 21 exact reference-PNG matches, fixture integrity and export checks.

After the additive geometry extension (2026-11-15): **428 checks, 0 failures** on the same host — the original 376 results are unchanged, plus 7 geometry cases with dimension, digest and exact reference checks. The capture was run in a scratch directory (`RETOUCH_CORPUS_DIR=/tmp/geo-capture`), and only the new fixture, the seven `Q*` references and the new baseline file were copied in; `baselines.json`, every existing fixture and every existing reference kept their bytes.

Baseline host recorded in `baselines.json`:

```json
{"arch": "arm64", "languageMode": "swift5", "os": "Version 27.2 (Build 26B123)"}
```

Approximate on-disk size: fixtures 4.3 MB, references 6.0 MB, exports 2.4 MB, `baselines.json` 80 KB. The corpus is opt-in and is **untracked** at the time of writing; it was not committed.

---

## 3. Fixture inventory

Every fixture is generated procedurally from code in `Tests/CorpusSupport.swift`. No fixture is a photograph, an AI-generated image, or a downloaded asset.

| ID | File | Size / format | Purpose | Why it is necessary | Operations covered |
|---|---|---|---|---|---|
| `F01_PORTRAIT_SRGB_8` | `F01_portrait_srgb_8.png` | 512×512, 8-bit sRGB | Baseline portrait for local retouch and global colour | Every face-masked operation needs one shared, reproducible subject | skin, eyes, teeth, makeup, hair, reshape, healing, global colour, stickers, analysis overlay, auto |
| `F02_PORTRAIT_DEEP_LOWKEY` | `F02_portrait_deep_lowkey.png` | 512×512, 8-bit sRGB | Deep skin tone under low-key light | Tone controls must not be calibrated on light skin only | skin brightening, tone evening, under-eye, exposure, body tone |
| `F03_PORTRAIT_LANDSCAPE` | `F03_portrait_landscape.png` | 768×432, 8-bit sRGB | Off-centre subject in a wide frame | Background and batch behaviour depends on an off-centre subject in a non-square frame | background blur/tone/saturation/fill/remove, person tools, crop/aspect mapping |
| `F04_DETAIL_CHART` | `F04_detail_chart.png` | 512×512, 8-bit sRGB | High-frequency structure and colour patches | Texture-preserving operations need measurable fine detail, not only skin | clarity, contrast, saturation, vibrance, HSL |
| `F05_GRADIENT_SKY` | `F05_gradient_sky.png` | 768×384, 8-bit sRGB | Smooth gradients and a highlight | Tonal operations are judged on smooth ramps where banding is visible | exposure, levels, contrast, curves, split tone |
| `F06_HIGHLIGHTS_SHADOWS` | `F06_highlights_shadows.png` | 640×480, 8-bit sRGB | Clipped highlights, deep shadows and a grey ramp | Endpoint recovery and clipping behaviour need known clipped and near-black regions | highlights/shadows, whites, blacks, vignette, curve, split tone, auto colour |
| `F07_LOWLIGHT_NOISE` | `F07_lowlight_noise.png` | 512×384, 8-bit sRGB | Low light with deterministic luminance noise | Noise handling must be visible in a controlled, repeatable frame | (fixture only; no case currently uses it — see §7) |
| `F08_HIGHRES_PORTRAIT` | `F08_highres_portrait.png` | 1600×1067, 8-bit sRGB | Full-resolution behaviour | Radius scaling and preview/export parity require an image well above 1400 px | load dimensions, 256 px export; hash-only no-op |
| `F09_ALPHA_CUTOUT` | `F09_alpha_cutout.png` | 512×512, 8-bit sRGB + alpha | Transparency and alpha export | Alpha handling and JPEG flattening cannot be verified on opaque photos | load alpha, PNG alpha export, JPEG flatten |
| `F10_EXIF_ORIENT6` | `F10_exif_orient6.jpg` | stored 720×480, 8-bit JPEG, orientation 6 | EXIF orientation handling | Camera files are commonly stored rotated; the corpus must prove the mapping | decode, upright baking (480×720), quadrant mapping, oriented export |
| `F11_P3_16BIT` | `F11_p3_16bit.png` | 512×512, 16-bit Display P3 | Wide gamut and deep storage | Colour management and bit-depth behaviour need a non-sRGB, non-8-bit source | 16-bit decode, P3 source profile, 16-bit PNG export (converted to sRGB since 2026-11-15, W4-4) |
| `F12_GRAY_8` | `F12_gray_8.png` | 640×480, 8-bit Gray Gamma 2.2 | Grayscale source | A grayscale source exercises a colour model the RGB fixtures cannot | decode only; the current loader refuses it (see §6) |
| `F13_GEOMETRY_GRID` | `F13_geometry_grid.png` | 512×384, 8-bit sRGB | Crop and straighten geometry (added 2026-11-15, W4-8 Option A) | Geometry needs a frame with exact pixel edges, orientation markers and measurable resampling; the portrait fixtures do not provide it | crop fractions, straighten angles, quarter turn, mirror, coordinate mapping, interpolation, edge behaviour |

The manifest records for each fixture: `id`, `file`, `width`, `height`, `bitsPerComponent`, `bitsPerPixel`, `colorSpace`, `sha256`, `decodedKey`, `purpose`, `characteristics`, `operations`, `necessity`.

`decodedKey` is a decoded-pixel fingerprint of the form:

```
widthxheight|bpc=<n>|bpp=<n>|cs=<name>|sha256(<premultiplied RGBA8 pixels>)
```

It exists because encoded PNG bytes are not guaranteed to be stable across encoders or architectures, while decoded pixels are what the engine consumes. Verify mode checks both the manifest fingerprint and the decoded key.

---

## 4. Provenance and licensing

- **Source:** all 12 fixtures are drawn at runtime by `Tests/CorpusSupport.swift` using CoreGraphics. The random elements (noise, pores, blemishes, grain) use a SplitMix64 `SeededRNG` with explicit per-fixture seeds.
- **No third-party pixels:** no stock image, icon, font, texture or model output is embedded. The only file formats used are standard CoreGraphics encoders.
- **No personal data:** the private portraits in `~/Documents/image test` were never loaded, copied, hashed into the corpus, or referenced by the harness. This was re-checked after capture; those files are unmodified.
- **No network:** generation and comparison are offline.
- **Licence:** the generated fixtures are part of this repository's source artifacts and are covered by the project's MIT licence. They contain no identifiable person and no copyrighted third-party content.
- **Generated, not curated:** editing a fixture by hand would silently invalidate `MANIFEST.json`. Regenerate instead of patching.

---

## 5. Determinism and host dependence

What was observed on the capture host (arm64, macOS 27.2 build 26B123):

| Property | Observation |
|---|---|
| Fixture generation, same host | Stable; PNG encoding of the rebuilt image matched the stored file exactly for all lossless fixtures |
| F10 JPEG re-encode | In-memory re-encode and decode matched the stored file exactly (max error 0) |
| Case renders, same host | 78/78 cases produced two independently built pipelines with identical digests |
| Reference PNG round-trip | 21/21 decoded back to the exact captured pixels |
| Verify run after capture | 78/78 digests matched `baselines.json`; 21/21 reference PNGs matched exactly |
| Cross-architecture fixture rasterization | Under `RETOUCH_ARCH=x86_64` (Rosetta), nine lossless regeneration checks (the 8-bit RGB fixtures) differed by 1–4 levels out of 255; F10, F11 and F12 regeneration checks passed |

Consequences:

1. **Same-host comparison may use exact digests.** The harness does, and that is how the references are validated.
2. **Fixture SHA-256 is host-specific.** A different OS, GPU or CoreGraphics build may rasterize the same drawing differently by a few levels. A future platform must regenerate fixtures from the same source and record its own manifest, or accept a pixel tolerance on decoded fixtures. Do not treat `MANIFEST.json` hashes as portable.
3. **Grain is deterministic only as observed.** `G17_GRAIN` uses `CIRandomGenerator`; it repeated exactly on this host and across two runs. That is an observation, not a guarantee for other Core Image versions or GPUs.

---

## 6. Known fixture limitation: F12 grayscale

`F12_GRAY_8.png` decodes correctly as `kCGColorSpaceGenericGrayGamma2_2` (640×480, centre sample 146/146/146). The engine's loader nevertheless returns `nil` for it because the preview render at [ImageProcessor.swift:193](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L193) requests `.RGBA8` with the source's gray colour space.

This is recorded as an **observed engine limitation**, not as grayscale support and not as a corpus failure. The harness stores the observation in `baselines.json`:

```json
"grayscale": {
  "source": "F12_GRAY_8",
  "load": "nil",
  "observedReason": "preview render uses .RGBA8 with the source gray colour space",
  "codePath": "ImageProcessor.load line 193 -> renderCGImage(colorSpace: GenericGrayGamma2_2)",
  "decoded": {"width": 640, "height": 480,
              "colorSpace": "kCGColorSpaceGenericGrayGamma2_2",
              "centerSample": {"r": 146, "g": 146, "b": 146}},
  "explicitSRGBDigest": "ba4efc28c7711985c97c684f9e2f72201643699f8e96b7aa7999a36babd21229"
}
```

The explicit sRGB digest proves the decoded pixels are stable even though the normal load path refuses them. No case was added that would have required changing the loader.

---

## 7. Coverage gaps in the fixture set

**Planned and created:** all 13 fixtures listed above exist.

**Created but not exercised by a case:** `F07_LOWLIGHT_NOISE` is generated and manifested but no current case consumes it. `F12_GRAY_8` has no processing case because the loader refuses it; only the load observation is captured.

**Deliberately excluded from the corpus:**

- Real camera photographs and any portrait of a real person (privacy and reproducibility).
- RAW/DNG sources; the runtime's RAW path is a macOS decoder dependency and was not exercised.
- Images larger than 1600 px on the long edge; the corpus tests scaling, not production-size memory behaviour.
- AI runtime outputs (upscale, segmentation, compositing): `AIRuntime.package` is `nil` in this tree, so no AI model was installed or run.
- Video, Live Photos, HEIC **sources** (HEIC is only an export check, and it is optional in the harness).
- UI-only behaviour: drag/drop, sliders, preview latency, animation, Recovery dialogs.

These exclusions are intentional. They keep the corpus small enough to regenerate and review, and they avoid claiming coverage that was not measured.

---

## 7a. Additive geometry set (W4-8 Option A)

**Approved:** 2026-11-15 by the Product Owner (W4-8 Option A). The approval explicitly requires that existing fixtures stay untouched, that new fixtures be added incrementally and versioned, and that any unresolved tolerance be presented to the owner instead of invented. The approval and its date are recorded inside `Tests/Corpus/baselines.geometry.v1.json`.

**What was added:**

| Case | Operation | Parameters | Output |
|---|---|---|---|
| `Q01_CROP_CENTER` | crop | x 0.25, y 0.25, w 0.5, h 0.5 | 256×192 |
| `Q02_CROP_EDGE` | crop anchored at the origin | x 0, y 0, w 0.375, h 0.5 | 192×192 |
| `Q03_STRAIGHTEN_CW` | clockwise straighten | angle +5° | 512×384 |
| `Q04_STRAIGHTEN_CCW` | counter-clockwise straighten | angle −7.5° | 512×384 |
| `Q05_STRAIGHTEN_CROP` | straighten then crop | angle +4°, crop 0.125/0.125/0.5/0.5 | 256×192 |
| `Q06_TURN_STRAIGHTEN_CROP` | quarter turn, straighten, crop | turn 1, angle +3°, crop 0.125/0.25/0.5/0.5 | 192×256 |
| `Q07_MIRROR_CROP` | mirror then crop | flipped, crop 0.25/0.125/0.5/0.75 | 256×288 |

`F13_GEOMETRY_GRID` is 512×384 with four colour quadrants, a 2 px grid every 64 px, a 16 px checkerboard in the centre, a crisp diagonal and a distinct 6 px bar on each edge. Every crop parameter lands on an exact integer pixel boundary (128/256 etc.), so a failing crop case measures a real coordinate error rather than fractional-pixel rounding. The fixture's own property checks assert all four quadrants and all four edge bars at known points.

**What the macOS harness records:** expected dimensions for every case (asserted directly), a pixel digest in `baselines.geometry.v1.json`, and an exact reference PNG. The harness also proved, with a separate CoreGraphics-only script, that the `Q01`, `Q02` and `Q07` references are byte-exact crops/mirrors of `F13_GEOMETRY_GRID` (max error 0), so those three are pure coordinate transforms with no resampling.

**Windows comparison:** `GeometryEvidence()` in `Windows/RetouchStudio.Tests/Program.cs` decodes the same fixture, renders `orientation → crop → adjustments` through `ExportRunner.RenderDocument`, and compares against the macOS references:

- `Q01`, `Q02`, `Q07` are **parity gates**: they must match the macOS reference with MAE 0, because neither host resamples for these transforms.
- `Q03`–`Q06` resample with different filters (Core Image affine versus the Windows bilinear rotation), and no numeric cross-host tolerance has been approved. They gate the dimensions and the rotation direction (the opposite-signed angle must be measurably further from the reference) and print MAE/PSNR as measurement. A numeric tolerance for the interpolation cases is **NOT APPROVED** and must be decided by the Product Owner if one is wanted.

`baselines.geometry.v1.json` has schema version 1 and its own `fixture` + `cases` arrays. `baselines.json` is not modified by this set; verify mode merges the two case lists for the ID-matrix and digest checks. A fixture may be added to `MANIFEST.json` without a recapture only when an approved versioned baseline names it first.

---

## 8. Layout and schema

```
Tests/
  CorpusSupport.swift          fixture generation, pixel/digest/metric helpers
  CorpusTests.swift            cases, capture/verify logic, export checks
  run-corpus.sh                opt-in harness (same SDK probe as Tests/run.sh)
  Corpus/
    Fixtures/
      F01…F13.<ext>
      MANIFEST.json
    References/
      <CASE_ID>.png            one per reference case (28, including Q01–Q07)
    Exports/
      F01_export_256.<png|jpg|tif|heic>
      F01_stripped.png
      F01_metadata_kept.png
      F08_export_256.png
      F09_alpha_export.<png|jpg>
      F10_upright.png
      F11_export_256.png
    baselines.json
    baselines.geometry.v1.json   additive Crop/Straighten set (W4-8)
```

`baselines.json` top-level keys:

| Key | Contents |
|---|---|
| `schemaVersion` | corpus schema version |
| `createdBy`, `captureNote` | provenance and the exact cross-platform warning |
| `host` | `arch`, `languageMode`, `os` of the capture |
| `fixtures` | one object per fixture (same fields as the manifest) |
| `masks` | per-fixture availability of every `MaskSet` member |
| `noop` | per-fixture source and no-op digests |
| `cases` | one object per case: id, fixture, category, note, params, reference flag, determinism, digest, dimensions, luma stats, optional no-op metrics |
| `exports` | output dimensions/bit depths and source-protection results |
| `grayscale` | the F12 load observation above |

`baselines.geometry.v1.json`:

| Key | Contents |
|---|---|
| `schemaVersion` | `1` |
| `approved`, `approval`, `additive` | approval date (2026-11-15), the approved decision, and `true` |
| `createdBy`, `captureNote` | provenance and the cross-platform measurement warning |
| `host` | `arch`, `languageMode`, `os` of the capture |
| `fixture` | the `F13_GEOMETRY_GRID` manifest object (same fields as `MANIFEST.json`) |
| `cases` | `Q01`–`Q07`: id, category, note, params, dimensions, digest, reference flag, luma stats |

Case metrics (`vsNoop`) are defined in `Docs/IMAGE_COMPARISON_METHODOLOGY.md`.

---

## 9. Reproduction

From the repository root:

```bash
# Capture on the current host (writes fixtures, references, exports, baselines)
RETOUCH_CORPUS_RECAPTURE=1 ./Tests/run-corpus.sh

# Verify against the captured baselines (normal rerun; this is the gate)
./Tests/run-corpus.sh

# Verify the x86_64 slice under Rosetta (evidence only; see methodology)
RETOUCH_ARCH=x86_64 ./Tests/run-corpus.sh

# Write artifacts somewhere else
RETOUCH_CORPUS_DIR=/tmp/retouch-corpus ./Tests/run-corpus.sh
```

The harness is opt-in and is **not** part of the default 840-check gate (`Tests/run.sh`). It compiles the same production sources with the same SDK probe, excluding only `App.swift` and `SelfCheck.swift`.

Behaviour:

- No `baselines.json` present → capture mode.
- `RETOUCH_CORPUS_RECAPTURE=1` → force capture/overwrite; capture also writes `baselines.geometry.v1.json`.
- Otherwise → verify mode: fixtures are checked against the manifest and decoded key, every case is rendered twice, every digest is compared (merging `baselines.json` with the geometry baseline), every reference PNG is decoded and compared, and export checks are rerun.
- A manifest that lacks a fixture declared by the geometry baseline is extended with that one entry; an undeclared missing fixture is a failing check.
- Exit status is non-zero if any check fails.

---

## 10. Integrity rules

1. **Do not hand-edit fixtures, references or `baselines.json`.** They are outputs.
2. **Recapture deliberately.** A recapture replaces the references for the current host; it is a new baseline, not a fix for a failing comparison. Record the host and reason in the commit that updates the corpus.
3. **Regenerate, do not patch.** If a fixture must change, change its generator, recapture, and review the new manifest and references as a whole.
4. **Never mix hosts.** A baseline captured on arm64 must not be compared against a run on another architecture as if it were expected to match exactly. Use the methodology document.
5. **Keep private photos out.** The corpus has no mechanism to ingest user images and must not gain one for this purpose.
6. **One authorised export renewal.** On 2026-11-15 the Product Owner approved the sRGB output policy (W4-4 Option A) and authorised renewing exactly one tracked artifact, `Exports/F11_export_256.png`, because its source is Display P3. No fixture, reference PNG or baseline digest changed, and every other export kept its hash; see `Docs/OUTPUT_COLOR_POLICY.md`.
7. **Additive fixtures are declared first.** A new fixture may join `MANIFEST.json` without a recapture only when an approved, versioned baseline (`baselines.geometry.v1.json`) names its ID and fingerprints. The harness refuses to extend the manifest for an undeclared fixture, and verify mode requires every manifest entry except the declared addition to keep its SHA-256 and decoded key.
