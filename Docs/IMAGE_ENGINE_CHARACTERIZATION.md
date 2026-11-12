# Image Engine Characterization

**Project:** Retouch Studio
**Repository:** `/Users/roham/RetouchStudio`
**Baseline commit:** `main` at `01da9005663127a513dae704785243f5b5ec8fab`
**Document date:** 2026-11-11
**Scope:** Milestone 3 — describe what the current macOS image engine does, which of it is captured by the golden corpus, and which parts are **not** characterized. No engine code was modified for this document.

The corpus itself is described in `Docs/GOLDEN_IMAGE_CORPUS.md`. The comparison rules are in `Docs/IMAGE_COMPARISON_METHODOLOGY.md`.

---

## 1. Evidence rules

Every statement below is one of:

- **VERIFIED** — read in this tree at the stated line, or reproduced by the harness at the stated commit.
- **OBSERVED** — measured on this host with the stated parameters; not a general guarantee.
- **NOT CAPTURED** — the code path exists (or may exist) but no corpus case exercises it.
- **NOT VERIFIED** — plausible from the code but not measured here.

Line numbers refer to `01da900`.

---

## 2. Method

The corpus harness calls the production engine directly. It does **not** drive the UI and does not reimplement any pixel operation.

For each fixture, `Tests/CorpusSupport.swift:1074` (`prepare`) performs:

1. `ImageProcessor.load(from:previewMaxDimension:)` at [ImageProcessor.swift:150](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L150) with `previewMaxDimension: 4096`.
2. Builds a `FaceGeometry` from known fixture geometry (`faceGeometry(box:)`), then runs `AutoAnalyzer.annotateTeeth` and `AutoAnalyzer.annotateEyes`.
3. Calls `ImageProcessor.buildMasks(extent:faces:image:maskDimension:)` at [ImageProcessor.swift:290](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L290) with `MaskBuilder.exportMaskDimension` (4096).
4. For body/background cases, replaces the `person` mask with a synthetic head-and-torso ellipse whose coordinates are known to the generator.

Each case then calls `ImageProcessor.process(...)` at [ImageProcessor.swift:731](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L731), renders the result to canonical premultiplied RGBA8, and records a SHA-256 digest. Every case is rendered **twice from separately built inputs**; the harness requires the two digests to match.

**Important consequence:** the corpus characterizes everything **downstream** of landmark detection, but it does **not** exercise Vision's face, landmark, person or pose detectors. A real photograph enters the engine through Vision; the corpus supplies the geometry directly so that measurements are reproducible. This is a deliberate boundary, not a hidden assumption.

---

## 3. Pipeline order under test

`process` applies work in this order. The order is part of the contract: a future implementation that reorders these passes will change the result even if every individual pass is identical.

| # | Stage | Code | Captured by |
|---|---|---|---|
| 1 | Manual spot healing | [ImageProcessor.swift:749](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L749) | `X01_HEAL` |
| 2 | AI result patches | [ImageProcessor.swift:759](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L759) | **NOT CAPTURED** (no AI runtime) |
| 3 | Body skin (smooth, tone) on `person ∩ skin` | [ImageProcessor.swift:808](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L808) | `S17`, `S18` |
| 4 | Local skin: blemish, wrinkle, tone-even, smooth, brighten, finish, shine | [ImageProcessor.swift:773](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L773) | `S01`–`S08` |
| 5 | Under-eye correction | [ImageProcessor.swift:821](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L821) | `S09` |
| 6 | Teeth alignment and whitening | [ImageProcessor.swift:829](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L829) | `S10`, `S11` |
| 7 | Eye brighten, sharpen, iris, lash, lens | [ImageProcessor.swift:856](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L856) | `S12`–`S16` |
| 8 | Makeup: shadow, liner, lips, gloss, blush, brows, contour | [ImageProcessor.swift:878](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L878) | `M01`–`M06`, `M10` |
| 9 | Hair: dye, shine, volume (geometry ∩ person) | [ImageProcessor.swift:906](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L906) | `M07`–`M09` |
| 10 | Feature reshape (brows protected) | [ImageProcessor.swift:944](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L944) | `R01`–`R10` |
| 11 | Silhouette reshape (eyes, lips, brows protected) | [ImageProcessor.swift:950](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L950) | `R06`–`R10` |
| 12 | Body slim | [ImageProcessor.swift:957](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L957) | `B01` |
| 13 | Pose shaping (waist, arms, legs) | [ImageProcessor.swift:964](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L964) | **NOT CAPTURED** (no pose) |
| 14 | Global colour and light | [ImageProcessor.swift:972](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L972), body at [1025](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1025) | `G01`–`G18`, `A01`, `A02` |
| 15 | Background blur, tone, saturation, fill, image, remove | [ImageProcessor.swift:977](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L977) | `BG01`–`BG06`; image replacement **NOT CAPTURED** |
| 16 | Art stickers | [ImageProcessor.swift:1006](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1006) | `X02` |
| 17 | Final crop to extent | [ImageProcessor.swift:1010](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1010) | all cases |

Global colour order inside `applyGlobal` is: levels → exposure → contrast → saturation → vibrance → warmth → tone curve → split tone → HSL → clarity → vignette → look → grain. Levels are always evaluated first because exposure and contrast are tuned around the endpoints ([ImageProcessor.swift:1031](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1031)–[1041](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1041)). Grain is last because it belongs on the finished picture ([ImageProcessor.swift:1098](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1098)).

---

## 4. Mask construction and gating

`buildMasks` produces the `MaskSet` at [ImageProcessor.swift:532](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L532). Masks are opaque grayscale rasters built by `MaskBuilder.makeMask` at [MaskBuilder.swift:59](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/MaskBuilder.swift#L59), at up to 1600 px (`maxMaskDimension`) or 1024 px (`previewMaskDimension`) and upscaled to the working extent. The corpus explicitly requests 4096 px (`MaskBuilder.exportMaskDimension`) so that mask rasterization is not the limiting factor in a baseline.

### 4.1 Annotation gates

Two mask families depend on pixel measurements, not geometry:

- **Teeth:** available only when `face.hasVisibleTeeth` and the enamel rectangle passes a bright, low-saturation gate. `AutoAnalyzer.annotateTeeth` sets the flag when mouth openness exceeds a threshold and more than 32% of the inner mouth is bright and low-saturation ([AutoAnalyzer.swift:212](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/AutoAnalyzer.swift#L212)–[221](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/AutoAnalyzer.swift#L221)). `buildMasks` additionally gates the enamel geometry at [ImageProcessor.swift:403](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L403) and [467](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L467).
- **Eye parts:** `sclera` is gated at or above a measured split luminance, `iris` below it, and `lashes` below 95% of it ([ImageProcessor.swift:420](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L420)–[457](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L457)). The split is clamped to 0.30–0.82 and comes from the eye opening's luminance percentiles ([AutoAnalyzer.swift:261](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/AutoAnalyzer.swift#L261)).

For F01 the annotated values are:

```
teeth=true  openness=0.783  visibleTeethFraction=0.948  eyeSplit=0.389  usableEyes=true
```

and every `MaskSet` member is available (skin, face, eyes, sclera, iris, lashes, eyeDetail, lips, teeth, brows, cheeks, underEyes, skinTexture, lids, liners, hair, contours, nose).

### 4.2 Gate-coverage round-off (OBSERVED)

`gatedMask` rejects a gated mask when the gated mean falls below 2% of the geometry mean ([ImageProcessor.swift:560](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L560)–[578](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L578)). Both means are read through `CIAreaAverage` rendered to **8-bit RGBA with `colorSpace: nil`**, i.e. in the linear working space ([ImageProcessor.swift:602](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L602)–[611](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L611)).

During corpus construction, two small regions initially fell below that floor and their masks were dropped:

- a thin single lash line, where the passing pixels rounded to zero at portrait scale;
- the enamel region of a small mouth, where the linear-light mean rounded below the floor.

Enlarging the fixture's lash lines and open-mouth geometry made both masks available. **No engine code was changed.** This is a real characterization of the current engine: mask availability is sensitive to the size of the gated region and to 8-bit rounding in linear light. An implementation that reads the means in a different space or at higher precision will produce different mask decisions on borderline faces.

### 4.3 Mask fallbacks used by `process`

- Eye brightening uses `masks.sclera ?? masks.eyes` ([ImageProcessor.swift:856](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L856)).
- Eye sharpening uses `masks.eyeDetail ?? masks.eyes` ([ImageProcessor.swift:859](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L859)).
- Hair dye and shine intersect the geometric head band with the person mask ([ImageProcessor.swift:909](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L909)).
- Feature reshape protects the brows; silhouette reshape protects the union of eyes, lips and brows ([ImageProcessor.swift:1015](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1015)).
- A missing mask generally means the pass is skipped, not approximated.

---

## 5. Captured operation matrix

78 cases across 11 categories. All 78 were **CAPTURED** and **VALIDATED** on the capture host. "Reference" means a PNG is kept for human inspection; every case has a digest regardless.

| Category | Cases | Captured | Reference PNGs | Notes |
|---|---:|---:|---:|---|
| colour-light | 18 | 18 | 7 | Levels, exposure, contrast, saturation, vibrance, warmth, curve, split tone, HSL, clarity ±, vignette, two looks, grain, a four-control combo |
| skin | 9 | 9 | 3 | Blemish, wrinkle, tone-even, smooth ± preserve, brighten, finish, shine, dark circles |
| eyes-teeth | 7 | 7 | 1 | Teeth whiten/align, eye brighten/sharpen, iris, lash, lens |
| makeup | 7 | 7 | 2 | Lips, blush, brows, eyeshadow, liner, contour, gloss |
| hair | 3 | 3 | 0 | Dye, shine, volume |
| reshape | 10 | 10 | 2 | Eye, nose size/tip, lip, cheek, jaw, chin, face width/length, combo |
| body | 3 | 3 | 0 | Body smooth, body tone, body slim |
| background | 6 | 6 | 2 | Blur, tone, saturation, fill, remove, three-way combo |
| extras | 6 | 6 | 4 | Manual healing, sticker, three analysis modes, watermark |
| auto | 3 | 3 | 0 | Auto colour on two frames, Auto Retouch |
| load | 6 | 6 | 0 | EXIF upright, 16-bit P3, alpha, zero-adjustment no-op, crop, quarter-turn |
| **Total** | **78** | **78** | **21** | |

Reference PNGs (21):

```
G01 G04 G09 G11 G12 G15 G17
S01 S04 S09 S10
M01 M02
R01 R06
BG01 BG05
X01 X02 X03 X06
```

---

## 6. Captured baseline table

`baselines.json` is authoritative. This table is a compact index; metrics compare each case against the same fixture's zero-adjustment render (lower MAE often means a smaller mask area, not a weaker edit).

| Case | Fixture | Parameters | MAE | Max err | Changed | ΔE76 mean | SSIM | Digest prefix |
|---|---|---|---|---:|---:|---:|---:|---|
| `G01_EXPOSURE_UP` | F05 | exposure +40 | 5.032 | 9 | 1.000 | 2.055 | 0.9990 | `1b7eb1b33faf` |
| `G02_EXPOSURE_DOWN` | F06 | exposure -40 | 4.518 | 9 | 0.986 | 1.783 | 0.9984 | `bbaa66133d10` |
| `G03_CONTRAST` | F04 | contrast +45 | 14.967 | 81 | 1.000 | 5.841 | 0.9204 | `afe16d494630` |
| `G04_BLACKS` | F06 | blacks +60 | 8.202 | 45 | 0.496 | 2.832 | 0.6100 | `28228ed69c37` |
| `G05_WHITES` | F06 | whites +50 | 9.099 | 41 | 0.407 | 3.399 | 0.9813 | `57adcf70cf3a` |
| `G06_SATURATION` | F04 | saturation +50 | 0.907 | 77 | 0.045 | 0.567 | 0.9976 | `b2e493cd4d81` |
| `G07_VIBRANCE` | F04 | vibrance +60 | 0.743 | 38 | 0.225 | 0.572 | 0.9983 | `ef609dbe866e` |
| `G08_WARMTH` | F01 | warmth +45 | 2.736 | 14 | 1.000 | 3.550 | 1.0000 | `52b8d5e1316d` |
| `G09_CLARITY_UP` | F04 | clarity +55 | 12.089 | 88 | 0.892 | 4.474 | 0.9170 | `0127cb4642d7` |
| `G10_CLARITY_DOWN` | F04 | clarity −60 | 11.862 | 93 | 0.640 | 5.025 | 0.8605 | `24449fb9ae8d` |
| `G11_VIGNETTE` | F01 | vignette +55 | 9.942 | 38 | 0.988 | 4.431 | 0.9802 | `219edd265cc5` |
| `G12_CURVE` | F06 | shadows +30, midtones −25, highlights +20 | 13.009 | 34 | 0.926 | 5.881 | 0.8602 | `12d473d04586` |
| `G13_SPLIT_TONE` | F06 | split tone 60 | 3.718 | 10 | 0.977 | 4.487 | 0.9979 | `27fce5e51761` |
| `G14_HSL` | F04 | red hue +20, green sat −60, blue lum −30 | 2.389 | 36 | 0.211 | 0.932 | 0.9555 | `dd198dc4ce6c` |
| `G15_LOOK_WARM_GOLD` | F01 | warm gold, 70 | 6.336 | 28 | 1.000 | 4.652 | 0.9944 | `af89e5d4f54d` |
| `G16_LOOK_CROSS` | F03 | cross process, 60 | 6.444 | 22 | 1.000 | 4.120 | 0.9949 | `4adcc1b54e59` |
| `G18_TONE_COMBO` | F03 | exposure +20, contrast +20, saturation +10, warmth +15 | 19.962 | 57 | 1.000 | 10.007 | 0.8385 | `45ed841c65f3` |
| `G17_GRAIN` | F01 | grain 60 | 5.783 | 35 | 0.944 | 2.454 | 0.7357 | `84d293818f6c` |
| `S01_BLEMISH` | F01 | blemish 70 | 0.660 | 150 | 0.046 | 0.302 | 0.9880 | `de61c04d4308` |
| `S02_WRINKLE` | F01 | wrinkle 60 | 0.699 | 70 | 0.221 | 0.320 | 0.9857 | `122ef840470b` |
| `S03_TONE_EVEN` | F01 | tone even 60 | 0.771 | 15 | 0.319 | 0.714 | 0.9999 | `f128e13841ee` |
| `S04_SMOOTH` | F01 | smooth 60, preserve 40 | 0.432 | 57 | 0.181 | 0.198 | 0.9921 | `92c15444a046` |
| `S05_SMOOTH_PRESERVE` | F01 | smooth 70, preserve 100 | 0.191 | 34 | 0.090 | 0.092 | 0.9979 | `c98fd5900213` |
| `S06_SKIN_BRIGHTEN` | F02 | skin brighten 40 | 2.955 | 27 | 0.329 | 1.449 | 0.9760 | `c6d397f72e61` |
| `S07_SKIN_FINISH` | F01 | skin finish 50 | 3.530 | 55 | 0.327 | 1.472 | 0.9867 | `a10260bf2c5e` |
| `S08_SHINE` | F01 | shine 50 | 0.855 | 6 | 0.244 | 0.355 | 0.9994 | `b0cd7fa65db6` |
| `S09_DARK_CIRCLES` | F01 | dark circles 60 | 0.006 | 2 | 0.010 | 0.005 | 1.0000 | `6516fe5661ef` |
| `S10_TEETH_WHITEN` | F01 | teeth whiten 70 | 0.007 | 5 | 0.005 | 0.011 | 1.0000 | `dc55d65112d4` |
| `S11_TEETH_ALIGN` | F01 | teeth align 60 | 0.148 | 72 | 0.005 | 0.076 | 0.9985 | `0a0039898b8a` |
| `S12_EYE_BRIGHTEN` | F01 | eye brighten 60 | 0.032 | 11 | 0.008 | 0.012 | 1.0000 | `47f723ed6757` |
| `S13_EYE_SHARPEN` | F01 | eye sharpen 60 | 0.046 | 34 | 0.007 | 0.023 | 0.9999 | `e32a75a05884` |
| `S14_IRIS` | F01 | iris 60 | 0.059 | 39 | 0.007 | 0.026 | 0.9998 | `f6d2d0df290e` |
| `S15_LASH` | F01 | lash 60 | 0.192 | 64 | 0.009 | 0.088 | 0.9985 | `49e828fb4330` |
| `S16_LENS` | F01 | lens 60 | 0.091 | 26 | 0.007 | 0.045 | 0.9997 | `7150bef1b86f` |
| `M01_LIPS` | F01 | lip tint 60 | 0.311 | 55 | 0.017 | 0.218 | 0.9980 | `0a0c399fa05a` |
| `M02_BLUSH` | F01 | blush 60 | 0.275 | 18 | 0.048 | 0.221 | 0.9998 | `e57873bb8bfe` |
| `M03_BROWS` | F01 | brow define 60 | 0.107 | 15 | 0.022 | 0.056 | 0.9994 | `9d131b90bb9b` |
| `M04_EYESHADOW` | F01 | eyeshadow 60 | 0.014 | 6 | 0.007 | 0.006 | 1.0000 | `2920d712c986` |
| `M05_EYELINER` | F01 | eyeliner 60 | 0.038 | 23 | 0.007 | 0.020 | 0.9998 | `26d72634ec01` |
| `M06_CONTOUR` | F01 | contour 60 | 1.532 | 39 | 0.092 | 0.590 | 0.9950 | `590138e6681a` |
| `M07_HAIR_DYE` | F01 | hair colour 60 | 2.313 | 47 | 0.128 | 0.948 | 0.9915 | `1ea5821dfec5` |
| `M08_HAIR_SHINE` | F01 | hair shine 60 | 0.834 | 17 | 0.119 | 0.357 | 0.9986 | `14109b0430dc` |
| `M09_HAIR_VOLUME` | F01 | hair volume 60 | 1.620 | 133 | 0.161 | 0.719 | 0.9766 | `85f7526a1b18` |
| `M10_LIP_GLOSS` | F01 | lip gloss 60 | 0.196 | 73 | 0.016 | 0.091 | 0.9987 | `364b78caadc8` |
| `R01_EYE_SIZE` | F01 | eye size 60 | 1.006 | 221 | 0.103 | 0.414 | 0.9671 | `b17bc8dcb9d9` |
| `R02_NOSE_SIZE` | F01 | nose size 60 | 0.043 | 64 | 0.016 | 0.017 | 0.9981 | `cfeba65ba894` |
| `R03_NOSE_TIP` | F01 | nose tip 60 | 0.016 | 28 | 0.008 | 0.006 | 0.9997 | `85eac73d911b` |
| `R04_LIP_SIZE` | F01 | lip size 60 | 0.282 | 182 | 0.031 | 0.128 | 0.9936 | `7fd131821abc` |
| `R05_CHEEK` | F01 | cheek size 60 | 0.249 | 107 | 0.072 | 0.099 | 0.9861 | `9f5693d2020c` |
| `R06_JAW` | F01 | jaw width 60 | 0.231 | 148 | 0.068 | 0.105 | 0.9901 | `1f046e35c212` |
| `R07_CHIN` | F01 | chin length 60 | 0.155 | 170 | 0.048 | 0.069 | 0.9949 | `c5592f5e41bc` |
| `R08_FACE_WIDTH` | F01 | face width 60 | 2.112 | 187 | 0.425 | 0.938 | 0.9094 | `ef9c78effefc` |
| `R09_FACE_LENGTH` | F01 | face length 60 | 2.396 | 193 | 0.428 | 1.050 | 0.9056 | `867d2e51d94d` |
| `R10_COMBO` | F01 | eye 40, jaw 40, face width 30 | 1.911 | 203 | 0.372 | 0.830 | 0.9320 | `6abba560bd7a` |
| `S17_BODY_SMOOTH` | F03 | body smooth 50 | 0.340 | 54 | 0.091 | 0.164 | 0.9971 | `82bf9076610b` |
| `S18_BODY_TONE` | F02 | body tone 40 | 3.557 | 22 | 0.618 | 1.832 | 0.9883 | `83f4ecc94670` |
| `B01_BODY_SLIM` | F03 | body slim 60 | 4.415 | 240 | 0.367 | 1.978 | 0.8734 | `dddbe9358e3c` |
| `BG01_BLUR` | F03 | background blur 60 | 0.643 | 47 | 0.507 | 0.426 | 0.9818 | `72f8eaed8313` |
| `BG02_TONE` | F03 | background tone −50 | 40.237 | 93 | 0.608 | 18.663 | 0.4573 | `97171a4271ee` |
| `BG03_SATURATION` | F03 | background saturation −60 | 2.284 | 17 | 0.592 | 2.714 | 0.9996 | `2ec105ddc5b3` |
| `BG04_FILL` | F03 | background fill 70 | 71.301 | 177 | 0.612 | 28.546 | 0.7501 | `8c3dd2d19e74` |
| `BG05_REMOVE` | F03 | background remove | 44.737 | 122 | 0.597 | 19.160 | 0.4174 | `bf80d5b29f7f` |
| `BG06_COMBO` | F03 | blur 40, tone −20, saturation −30 | 16.931 | 77 | 0.603 | 7.675 | 0.8428 | `693f59ba1f8a` |
| `X01_HEAL` | F01 | 3 stamps, radius 0.018 | 0.164 | 154 | 0.009 | 0.076 | 0.9976 | `70001c1da7f7` |
| `X02_STICKER` | F01 | star at (0.72, 0.28), size 0.16, rotation 12 | 0.747 | 210 | 0.009 | 0.631 | 0.9912 | `1d418244cdbf` |
| `X03_ANALYSIS_PHOTO` | F01 | analysis on photo | 1.419 | 203 | 0.116 | 0.661 | 0.9290 | `762bb4a818aa` |
| `X04_ANALYSIS_POSTER` | F01 | analysis poster | — | — | — | — | — | `d4cfb1e72ecc` |
| `X05_ANALYSIS_OVERLAY` | F01 | analysis overlay only | — | — | — | — | — | `b3c5235dd32f` |
| `X06_WATERMARK` | F01 | "Retouch Studio", bottom-right | 0.371 | 164 | 0.005 | 0.151 | 0.9931 | `d598aa4111d6` |
| `A01_AUTO_COLOR_PORTRAIT` | F01 | exposure 1.98, blacks 36.60, whites 13.07, vibrance 2.65 | 12.363 | 31 | 0.999 | 5.452 | 0.8754 | `ef6fe508923d` |
| `A02_AUTO_COLOR_CLIPPED` | F06 | vibrance 8.85, warmth −7.37, clarity 4.65 | 0.642 | 28 | 0.711 | 0.596 | 0.9948 | `556c506083c2` |
| `A03_AUTO_RETOUCH` | F01 | smooth 6.00, preserve 90.10, blemish 12.52, wrinkle 16.00, tone 6.00, eye brighten 16.00, eye sharpen 6.00 | 0.333 | 61 | 0.118 | 0.172 | 0.9960 | `89a6bb7b3b56` |
| `L01_F10_UPRIGHT` | F10 | load EXIF orientation 6 | — | — | — | — | — | `2e296528edb1` |
| `L02_F11_P3` | F11 | load 16-bit Display P3 | — | — | — | — | — | `cd56c6989bd4` |
| `L04_F09_ALPHA` | F09 | load RGBA | — | — | — | — | — | `5decb9feffa8` |
| `L05_F08_NOOP` | F08 | zero adjustments at 1600×1067 | — | — | — | — | — | `30bcac352aed` |
| `L06_F03_CROP` | F03 | crop x0 y0 w0.5 h1 | — | — | — | — | — | `d5662c964021` |
| `L07_F01_ROTATE` | F01 | load quarter-turn 1 | — | — | — | — | — | `2ccb55691e83` |

Load cases have no `vsNoop` because their output is the loaded/rotated/cropped source, not an edit of it.

---

## 7. Export and file-handling characterization

These are captured in `baselines.json` under `exports`, with artifacts under `Tests/Corpus/Exports/`:

| Behaviour | Observation |
|---|---|
| 16-bit PNG export | 256 px long edge, 16 bits per component |
| TIFF export | written |
| JPEG export | 256 px, 8 bits per component |
| HEIC export | written on this host (encoder available); still treated as optional |
| Display P3 PNG export | 16 bits, profile preserved as Display P3 |
| Alpha PNG export (F09) | alpha preserved |
| JPEG alpha flatten (F09) | transparent regions flattened |
| F08 large-source export | 256 px long edge from 1600×1067 |
| F10 oriented export | 480×720, orientation tag 1, blue quadrant at (0.20, 0.10) |
| Privacy allowlist | GPS removed, resolution/orientation kept ([ImageProcessor.swift:1204](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ImageProcessor.swift#L1204)) |
| Source protection | symlink, hardlink and case-only alias refused; unrelated path allowed; original unchanged ([ExportService.swift:404](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ExportService.swift#L404)) |

The export cases call `ExportService.render` at [ExportService.swift:184](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ExportService.swift#L184) and `renderFinal` at [238](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/ExportService.swift#L238) directly. They do not exercise the save panel, overwrite prompts or batch orchestration.

---

## 8. Determinism observations

- **78/78** cases produced identical digests from two independently constructed pipelines on this host. `baselines.json` records `deterministic: true` for every case.
- **21/21** reference PNGs decode back to the exact captured pixels.
- Two consecutive verify runs matched all 78 digests and all 21 references.
- **Grain:** `G17_GRAIN` uses `CIRandomGenerator` ([LookEngine.swift](file:///Users/roham/RetouchStudio/Sources/RetouchStudio/Core/LookEngine.swift)). It repeated exactly on this host and across runs. This is **OBSERVED**, not a cross-version guarantee.
- **No-op:** a zero-adjustment render is required to equal the loaded source exactly; `L05_F08_NOOP` checks this at full 1600×1067 size.
- **Cross-architecture:** under `RETOUCH_ARCH=x86_64` (Rosetta on Apple silicon), 72 of 78 case digests matched the arm64 baseline. The six exceptions were `X02_STICKER`, `X03_ANALYSIS_PHOTO`, `X04_ANALYSIS_POSTER`, `X05_ANALYSIS_OVERLAY`, `X06_WATERMARK` and `L01_F10_UPRIGHT`; nine lossless fixture regeneration checks also differed by 1–4 levels. This is evidence that vector/text/analysis/EXIF-upright paths are not bit-identical across code generation, not a compatibility claim. See the methodology document.

---

## 9. Explicitly NOT CAPTURED

This list is part of the deliverable. None of these should be inferred from the baselines.

| Area | Why it is not captured |
|---|---|
| Vision face and landmark detection | The corpus supplies `FaceGeometry` directly; no real face was analyzed |
| Vision person segmentation | Body/background cases use a synthetic head-and-torso person mask |
| Vision body pose | `bodyWaist`, `bodyArms`, `bodyLegs` have no case; there is no pose input |
| AI runtime patches | `AIRuntime.package` is `nil`; no model was installed or run |
| AI upscale, AI segmentation, AI compositing | Same; the AI worker was not started |
| Background image replacement (`backgroundImage`) | No backdrop asset was loaded in the harness; only blur/tone/saturation/fill/remove are captured |
| RAW/DNG decoding | No RAW fixture; depends on the macOS RAW decoder |
| Grayscale load | F12 decodes but `load` returns `nil`; the limitation is recorded, not fixed |
| 16-bit internal pipeline | F11 is decoded and exported at 16 bits, but no face/mask case processes it |
| HEIC source decoding | Only HEIC export is attempted |
| UI, sliders, preview latency, drag/drop | Harness calls the engine, not the app |
| Project save/load, Recovery, autosave | Out of scope and explicitly untouched |
| Batch export policy and cancellation | Separate subsystem, not part of this corpus |
| Error paths (missing masks, failed load, failed encode) | Only the grayscale `nil` load is recorded |
| Non-deterministic rendering | No case is marked non-deterministic; no such case was observed |
| GPU/Metal vs CPU rendering differences | Not varied or measured |
| Windows, Linux, native Intel | No such hardware or build was used |

---

## 10. Reproducing and interpreting

```bash
./Tests/run-corpus.sh                 # verify on this host
RETOUCH_ARCH=x86_64 ./Tests/run-corpus.sh
RETOUCH_CORPUS_RECAPTURE=1 ./Tests/run-corpus.sh
```

Interpreting a failure:

- **Digest mismatch on the capture host** means the engine or a dependency changed, the fixture changed, or the graphics stack changed. Investigate before recapturing.
- **Reference PNG mismatch with a matching digest** is impossible unless the PNG writer changed; the harness decodes and compares pixels, not bytes.
- **A fixture manifest mismatch** is a corpus problem, not an engine result.
- **A cross-architecture or cross-platform mismatch** is expected at some level and must be judged with the methodology document; it is not automatically a defect.

---

## 11. Precision, colour-space and XMP decisions (2026-11-13)

This section records engine changes made after the baseline table above and
what they do and do not prove. The corpus baselines were not regenerated.

**16-bit sources survive the upright bake.** `ImageProcessor.load` bakes an
EXIF orientation by rendering the turned image through Core Image. That render
used to request an RGBA8 intermediate unconditionally, so a 16-bit PNG or TIFF
reached analysis and export with 8-bit values inside a 16-bit container. The
intermediate format now follows the source's own depth
(`renderFormat(for:)`: RGBA8 up to 8 bpc, RGBA16 up to 16, RGBAf above).
`EngineTests` writes a 48×32 16-bit PNG tagged orientation 6 and compares its
load against a pre-upright RGBA16 reference: the observed channel delta is 1
LSB, while an 8-bit bake misses by about 127. This is a fix, not new behaviour
to recapture — F10 is an 8-bit rotated fixture and F11 is 16-bit but not
rotated, so no baseline depends on the old path.

**The working colour space is named and wide.** An unconfigured `CIContext`
on this toolchain reports `kCGColorSpaceExtendedLinearSRGB` as its working
space (`CIContext.workingColorSpace`, measured). The context now names that
space instead of inheriting it. Naming plain sRGB was tried and rejected: it
is a narrower space, it clipped wide-gamut intermediates, and it shifted
existing effect results (`reshape` and `teethWhiten` regressions in
`EngineTests`). Source profiles still tag exports, so a Display P3 photo
keeps its P3 profile. What is *not* proven: the preview surface, the PDF/print
path, and any wide-gamut display path beyond the encoded file.

**XMP survives when the owner keeps metadata.** `load` reads the XMP packet
with `CGImageSourceCopyMetadataAtIndex` and carries it as `CGImageMetadata`
(`LoadResult.xmp` → `ExportSource.xmp` → `ExportService.write`). When
`stripPrivacyMetadata` is false, the writer uses
`CGImageDestinationAddImageAndMetadata`, so `dc:`, `photoshop:` and other
XMP namespaces the engine does not interpret travel with the export; when it
is true, the previous property-dictionary path runs and XMP is not written.
The EXIF/XMP orientation tags are removed from the carried graph because the
pixels were already baked upright and a surviving tag would turn the photo a
second time. The regression covers a JPEG round trip only; PNG, TIFF and HEIC
XMP preservation is **NOT VERIFIED**.

These changes do not characterize GPU-versus-CPU rendering, RAW decoding, or
any Windows/Linux renderer. There is no Windows renderer in this repository
yet.
