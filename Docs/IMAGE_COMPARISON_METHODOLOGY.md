# Image Comparison Methodology

**Project:** Retouch Studio
**Repository:** `/Users/roham/RetouchStudio`
**Baseline commit:** `main` at `01da9005663127a513dae704785243f5b5ec8fab`
**Document date:** 2026-11-11
**Scope:** how to compare a future image-engine implementation, or a different build of this one, against the golden corpus. This document does not authorize a port and does not claim that any non-macOS platform has been tested.

---

## 1. What is validated today

| Comparison | Status | Evidence |
|---|---|---|
| Same host, same build, same graphics stack | **VALIDATED** | 78/78 digests and 21/21 reference PNGs matched on two consecutive runs |
| Same host after a source change | **VALIDATED as a gate** | any digest change fails the harness |
| arm64 vs x86_64 slice under Rosetta | **OBSERVED only** | 72/78 digests matched; six paths differed |
| Windows / Linux / native Intel | **NOT TESTED** | no such hardware or build was used |
| Numeric tolerance for an unseen platform | **NOT VERIFIED** | no numeric gate is approved in this document |

The only automatic pass rule that has been validated is **exact equality on the capture host**. Everything else below is a documented procedure for gathering evidence, not an approved threshold.

---

## 2. Canonical comparison unit

The harness never compares encoded file bytes for case outputs. It compares decoded pixels in a canonical form.

### 2.1 Pixel buffer

`Tests/CorpusSupport.swift:134` (`pixels(of:)`) draws a `CGImage` into:

- **RGBA8**, 4 bytes per pixel;
- **premultipliedLast** alpha;
- the image's **own colour space** (`image.colorSpace ?? sRGB`), not a forced sRGB conversion;
- `interpolationQuality = .none`, so no resampling is introduced by the comparison itself.

Case outputs are produced by `ImageProcessor.renderCGImage(..., format: .RGBA8)` at [ImageProcessor.swift:1113](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1113), using the fixture's colour space, then copied into the canonical buffer above.

Consequences:

- A Display P3 output is compared in P3 encoding, not in sRGB. Its ΔE values are therefore **not colorimetric** (see §2.4).
- Alpha is premultiplied. A difference in straight vs premultiplied alpha handling changes the digest even when the visible colour is unchanged.
- Dimensions are part of the comparison; a one-pixel extent change fails.

### 2.2 Digest

`pixelDigest` (`Tests/CorpusSupport.swift:154`) hashes:

```
"<width>x<height>|<colorSpace name>|<bits>|" || RGBA8 bytes
```

with SHA-256. The digest is therefore sensitive to size, colour space, bit depth and every pixel byte. It is an exact-match identifier, not a perceptual metric.

The fixture `decodedKey` uses a closely related form:

```
"<width>x<height>|bpc=<n>|bpp=<n>|cs=<name>|sha256(RGBA8)"
```

### 2.3 Reference PNGs

21 curated cases also write a PNG of the rendered output. Verify mode decodes the PNG and requires **max error 0** against the freshly rendered pixels. These files exist for human review and for cross-platform comparison where a digest is not portable; they are not a separate source of truth.

### 2.4 Metrics

`comparePixels` (`Tests/CorpusSupport.swift:200`) computes:

| Metric | Definition | Caveat |
|---|---|---|
| `mae` | Mean absolute error over R, G, B channels, 0–255 scale | Not alpha-aware; a masked edit over a small area can have a low MAE |
| `rmse` | Root mean square of the same channel errors | Dominated by large edge errors |
| `maxError` | Largest absolute channel error in any pixel | A single resampled edge pixel can produce a large value; do not use alone |
| `psnr` | `10·log10(255²/mse)`, capped at 99 dB | Misleading for small, localized edits |
| `ssim` | Mean SSIM over non-overlapping 8×8 windows on Rec.709 luma | Global average; a small broken region is diluted by unchanged pixels |
| `changedFraction` | Fraction of pixels with any channel differing by ≥ 1 | Sensitive to quantization; 0.005 can be a correct eyeliner |
| `alphaMAE` | Mean absolute alpha difference, 0–255 | Must be exact for cutout/removal cases |
| `deltaE76Mean` | CIE76 ΔE on every third pixel, computed from sRGB-encoded values | Colorimetric only for sRGB fixtures; P3 and grayscale are compared as encoded RGB |
| `deltaE76Max` | Largest of those ΔE samples | Same caveat |

No single metric is sufficient. In particular, the mask-local cases in the baseline have very small global MAE and changed fractions by design (for example `S10_TEETH_WHITEN`: MAE 0.007, changed 0.005). A global SSIM near 1.0 or a tiny MAE does **not** prove the mask landed in the right place.

---

## 3. Comparison order

A comparison is only meaningful if each step passes before the next is attempted.

1. **Identity of inputs.** Confirm the fixture files are the intended ones. On the capture host, compare file SHA-256 and decoded key with `MANIFEST.json`. On another host, do not expect the same file hash from a regenerated fixture; use the stored fixture files as the input set and compare decoded pixels against the manifest, recording any decode delta.
2. **Identity of dimensions and colour space.** Width, height, colour space name and bit depth must match. A mismatch here invalidates every downstream metric.
3. **Identity of the case matrix.** The same case ids must exist. The harness refuses a baseline whose id set differs (`Tests/CorpusTests.swift:879`).
4. **Determinism.** Render each case twice from independently built inputs. If two runs on the same host disagree, the result is not comparable to anything; fix the non-determinism first.
5. **No-op preservation.** A zero-adjustment render must equal the loaded source exactly. This catches colour-management, orientation and alpha mistakes before any edit is judged.
6. **Digest equality.** On the capture host, this is the pass/fail gate.
7. **Metric comparison and human review.** Only when digests differ and the target is a different platform/build. Use the procedure in §4.

---

## 4. Comparing an unseen platform or a new implementation

### 4.1 Principle

Do not import a numeric tolerance from another project or invent one. Derive it from measurements on the target. Until that is done, a digest mismatch is **review evidence**, not an automatic failure and not an automatic pass.

### 4.2 Required inputs

- The **same fixture files** (or their decoded pixels) used for the reference. Inputs must be identical before outputs can be compared.
- The **same case parameters** from `baselines.json`.
- The **same canonical pixel format** (§2.1).
- A recorded host description: CPU architecture, OS build, graphics device, Core Image/CI version or equivalent, and renderer (CPU/GPU).

### 4.3 Procedure

1. **Input check.** Decode each fixture on the target and compare with the manifest decoded key. Lossless PNG/TIFF should decode identically; if not, record the delta and stop — the platform's colour management or decoder differs and no output comparison is valid. JPEG may differ by a small amount; record it.
2. **No-op check.** Run the zero-adjustment path. It must be exact. If it is not, the platform differs in colour management, orientation, alpha or pixel format, and output comparisons would be measuring that difference rather than the engine.
3. **Run all 78 cases twice.** Require repeat equality on the target. If a case is non-deterministic there, classify it separately; do not average it into a pass.
4. **Compare digests.** Record exact matches. The arm64/Rosetta experiment shows that a large majority can be exact even across code generation, but this is not a guarantee.
5. **Compare reference pixels** for the 21 reference cases. Compute the metrics in §2.4 and save a side-by-side difference image.
6. **Localize the comparison.** For mask-local operations, compute metrics inside the region the reference actually changed (reference vs no-op), not only over the whole frame. Report:
   - the changed-region bounding box and area;
   - MAE, RMSE, ΔE mean and SSIM inside that region;
   - the sign of the mean change per channel, to confirm the edit moved in the intended direction.
7. **Structural review.** For geometry, vector, text, sticker, analysis and watermark cases, inspect the reference PNG at full size. Pixel metrics alone do not establish that a jaw moved instead of the mouth, or that a glyph is the intended glyph.
8. **Record the evidence** in the format of §6.

### 4.4 Provisional review gates (HYPOTHESIS — NOT VERIFIED)

The following are proposed review thresholds, not validated gates. They are included so that a future evaluation is consistent; they must be revised after at least three independent runs on the target.

| Family | Primary evidence | Proposed review threshold | Status |
|---|---|---|---|
| Identity, no-op, alpha, orientation | digest and pixels | exact | validated on this host |
| Global tone/colour (`G*`) | global MAE, ΔE mean, SSIM | MAE ≤ 1.0, ΔE76 mean ≤ 1.0, SSIM ≥ 0.995 | **NOT VERIFIED** |
| Local skin/eye/makeup/hair (`S*`, `M*`) | changed-region MAE and ΔE, mask placement | region MAE ≤ 1.0, region ΔE ≤ 1.0, changed-region overlap ≥ 95% | **NOT VERIFIED** |
| Reshape/body (`R*`, `B01`) | region SSIM and feature displacement | SSIM ≥ 0.99 in the warped region; landmark/edge displacement within 1 px | **NOT VERIFIED** |
| Background (`BG*`) | person-mask boundary and region metrics | boundary displacement ≤ 1 px; region MAE ≤ 1.0 | **NOT VERIFIED** |
| Vector/text/analysis (`X02`–`X06`) | human review of reference PNG | no automatic gate | **NOT VERIFIED** |
| Load/decode (`L*`) | dimensions, orientation, colour space, pixels | exact for lossless; JPEG decode delta recorded | **NOT VERIFIED** |

Rationale for the shape of these proposals:

- **1.0 level** is the smallest non-zero signed error in 8-bit data and the natural quantization scale for a cross-implementation comparison.
- **SSIM 0.995 / 0.99** are round values above the observed same-host values for all but the deliberately destructive global edits; they are proposals, not measurements.
- **maxError is deliberately absent as a gate.** Same-host baselines already contain max errors from 2 to 240 because a one-pixel resampling or text-edge difference can be large without being wrong.
- **Local cases need local metrics.** A global gate would pass a mask placed on the wrong cheek as long as the mask is small.

These numbers must not be quoted as validated. If a future run adopts them, this table must be replaced with measured values and the date and host of the derivation.

---

## 5. What the cross-architecture experiment did and did not show

**Setup:** the same corpus, same fixtures, same cases, run with `RETOUCH_ARCH=x86_64` under Rosetta on Apple silicon, compared with the arm64 baseline.

**Observed:**

- **72 of 78** case digests matched exactly.
- Six cases differed: `X02_STICKER`, `X03_ANALYSIS_PHOTO`, `X04_ANALYSIS_POSTER`, `X05_ANALYSIS_OVERLAY`, `X06_WATERMARK`, `L01_F10_UPRIGHT`. These are the vector, text, analysis-composition and EXIF-upright paths.
- Nine lossless 8-bit RGB fixture regeneration checks differed by 1–4 levels out of 255; F10, F11 and F12 regeneration checks passed.
- Fixtures on disk were confirmed unchanged after the experiment.

**Not shown:**

- That an x86_64 Mac, Windows or Linux build behaves the same. Rosetta is a translation layer on the same OS and graphics stack.
- That any of the six differing paths is wrong. They are evidence that rasterization/composition is not bit-identical across code generation.
- That the tolerance table in §4.4 is correct. No candidate output was scored against it.

**Conclusion:** exact digests are a same-host gate. Cross-platform work needs the stored fixtures, the reference PNGs, localized metrics and human review. No Windows, Linux or native Intel compatibility is claimed.

---

## 6. What invalidates a comparison

A result must be rejected, not reinterpreted, when any of these is true:

- Fixture pixels differ from the input set used for the reference.
- Dimensions, colour space, bit depth or alpha convention differ.
- Orientation was baked or tagged differently.
- The target is non-deterministic across two runs.
- The zero-adjustment path is not exact.
- A case ran with different parameters or a different mask set (for example the synthetic `person` mask was replaced by Vision output).
- Metrics were computed over the whole frame for a mask-local operation and used as the sole pass criterion.
- A different colour space was converted to sRGB before comparison without recording that conversion.

Record the output as **INVALID** with the failed precondition, not as a low score.

---

## 7. Reporting template

For each future platform/build, record:

```text
Platform:            <OS, version, build, CPU arch>
Renderer:            <GPU/CPU, API, Core Image or equivalent version>
Fixture inputs:      <files, decoded-key match yes/no, delta if any>
No-op:               <exact / delta>
Determinism:         <all repeatable / list of exceptions>
Case matrix:         <78 cases present / differences>
Exact digests:       <n>/78
Reference PNGs:      <n>/21 exact; list of differences with metrics>
Localized metrics:   <per differing case: region, MAE, ΔE, SSIM, direction>
Structural review:   <cases inspected, reviewer, verdict>
Known differences:   <paths expected to differ, with reason>
Verdict:             <compatible / compatible with review / not comparable>
```

A verdict of "compatible" must cite the exact rule used. Until §4.4 is replaced with measured tolerances, only exact matches and documented human review can support it.

---

## 8. Non-claims

- This methodology does not establish or imply Windows, Linux or native Intel compatibility.
- It does not establish that Rosetta results represent an Intel Mac.
- It does not establish that pixel equality implies visual equality for vector, text or analysis overlays; those need review.
- It does not authorize changing the engine to make a comparison pass.
