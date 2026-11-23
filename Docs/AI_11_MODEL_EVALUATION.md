# AI-01 — Model evaluation for a local AI editing system

**Status:** Research record for review. No weight was downloaded, converted,
quantized or run for this document; no model is adopted by it.
**Milestone:** AI-01 under the RetouchStudio Master Execution Plan V4.
**Base:** `main` at `a559a0e` (2026-11-16), after the Windows runtime
payload-size fix (PR #63); no model-evaluation finding changed.
**Companions:** [AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md),
[AI_11_ROADMAP.md](AI_11_ROADMAP.md), [AI_RUNTIME.md](AI_RUNTIME.md).

> **Addendum 2026-11-16 (owner decision).** Windows is a first-class AI
> platform from W5. The Windows rows in §12–§14 stay accurate as current
> state (no runtime, no models, nothing supported); they are no longer a
> statement that Windows AI is out of scope. The planned path and its gates
> are in [W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
> §3–4 and [W5_ROADMAP.md](W5_ROADMAP.md) §3. §13's "before a Windows
> landmark decision" now scopes to face/mask capabilities only; upscaling does
> not depend on F1.

> **Addendum 2026-11-23 (licence re-adjudication).** This stays the dated research record it
> is — its `Base:` line pins it to `main` at `a559a0e` (2026-11-16) and nothing below is
> rewritten. One entry is no longer current shipped state: `flux2-klein-4b-q4`, listed "Ships
> today (opt-in download)" in §2 and "Apache-2.0" in the §6 and §8 tables, is **not**
> downloadable. Its catalogue `permitted_use` record now reads `unknown` with
> `statedBy: not-established` and `admitted: false`, and the capabilities it was the only
> answer for — `generative.edit`, `generative.reimagine`, `inpaint.object` — report `blocked`.
> The grant itself is real; it belongs to `black-forest-labs/FLUX.2-klein-4B`, while the pinned
> bytes come from a third-party conversion repository that ships no licence copy and names no
> upstream revision, so the link between the two is unestablished. Evidence and the corrections
> to that re-reading: [MODEL_LICENCES.md](MODEL_LICENCES.md) §12 and
> [MODEL_LICENCE_EVIDENCE.md](MODEL_LICENCE_EVIDENCE.md) §11. The same re-adjudication changes
> the question this document asks: under the 2026-11-22 gate, admission is measured against
> public **non-commercial** use and distribution, so "explicitly allows commercial use" is
> neither a rejection reason when absent nor a sufficient approval reason when asserted by
> someone other than the rights holder.

## 1. Method and labels

- **VERIFIED** — read from the official repository, release asset, model card
  or licence file, or from this repository's source.
- **MEASURED** — a number from a recorded run, with its context cited.
- **ESTIMATE** — a projection; its basis is stated. Never a result.
- **NOT VERIFIED** — could not be established from an official source here.

Sizes are the weight files as published where a listing was read; `(arith.)`
means parameters × dtype. Feasibility classes follow AI-01: **comfortable**,
**usable with compromises**, **aggressive quantization or tiled only**, **not
practical** on a 16 GB M3.

**The licence rule.** A repository licence covers code. Weights are a separate
grant. A candidate ships only when both are established for commercial use.
Code licences do not launder weight terms: several otherwise-excellent models
are research-only or non-commercial.

## 2. Licence and shipping status

| Model family | Code licence | Weights / commercial use | Shipping status |
|---|---|---|---|
| Apple Vision (face landmarks, person segmentation) | OS framework | OS terms | Ships today (macOS only) |
| FLUX.2 klein 4B (q4) | Apache-2.0 | Apache-2.0 | Ships today (opt-in download) |
| SAM 2.1 tiny | Apache-2.0 | Apache-2.0 | Ships today; integrity metadata recorded 2026-11-18, download still refused (`sam2` not a worker dependency) |
| Swin2SR x4 | Apache-2.0 | Apache-2.0 | Ships today |
| MI-GAN (512, Places2) | MIT (weights MIT) | MIT | Ships today |
| MediaPipe Face Landmarker | Apache-2.0 | model-card terms **NOT VERIFIED** | Candidate; needs a written read |
| BiRefNet | MIT declared | No `LICENSE` file in the repo — grant **unconfirmed** | Candidate after the grant is written |
| MODNet | Apache-2.0 | Apache-2.0 (repo states code, models and demos) | Candidate |
| SCUNet | Apache-2.0 (KAIR MIT) | Apache-2.0 per repo | Candidate |
| NAFNet / Restormer | MIT / Apache-2.0 | per repo | Candidate |
| RestoreFormer++ | Apache-2.0 | Apache-2.0 | Candidate |
| Real-ESRGAN family | BSD-3-Clause | BSD-3-Clause | Candidate (sharper, invents more) |
| GFPGAN v1.4 | Apache-2.0 **except** NVIDIA StyleGAN2 terms and DFDNet CC BY-NC-SA | Mixed; needs a legal read | Candidate with a licence risk flag |
| LaMa | Apache-2.0 | Re-hosted weights **NOT VERIFIED** | Candidate only after a grant |
| InsightFace (SCRFD/ArcFace) | MIT | **Non-commercial research only** | Blocked |
| CodeFormer | S-Lab 1.0 | **Non-commercial** | Blocked |
| RMBG-2.0 | Source-available | **CC BY-NC 4.0** | Blocked |
| MAT | — | CC BY-NC 4.0 | Blocked |
| FLUX.1 Fill dev | Apache-2.0 | **FLUX.1 [dev] non-commercial** | Blocked |
| SUPIR / HYPIR | — | Non-commercial | Blocked |
| SAM 3 | Apache-2.0 repo | Meta **SAM License**, gated | Blocked for shipping today |
| FLUX 3 Image Klein | Apache-2.0 | FLUX Kommunity (revenue-gated) | Blocked for this product |
| OSEDiff / PiSA-SR | No licence file | — | Not redistributable |

## 3. Face analysis (capability A)

### 3.1 Detection, landmarks, parsing, identity

| Model | Source | Format · size | M3 16 GB | Windows | Notes |
|---|---|---|---|---|---|
| Apple Vision `VNDetectFaceLandmarksRequest` | developer.apple.com/documentation/vision | OS framework | comfortable | none | ~76 points in 13 region groups, 2-D, normalized to the face box; what the app uses |
| Apple Vision `VNGeneratePersonSegmentationRequest` | developer.apple.com/documentation/vision | OS framework | comfortable | none | Learned person matte, `.balanced`, 1600 px working copy; already used (`SceneEngine.swift:146-174`) |
| MediaPipe Face Landmarker | developers.google.com/edge/mediapipe | `.task` float16 bundle; size **NOT VERIFIED** | comfortable | Python wheel only, unverified | 478 3-D landmarks, 52 blendshapes, 4×4 pose; different topology from Vision |
| InsightFace (SCRFD + ArcFace) | github.com/deepinsight/insightface | ONNX pack; size not stated | comfortable | ONNX possible | Best identity embeddings; weights non-commercial → blocked |
| BiSeNet face parsing (zllrunning) | github.com/zllrunning/face-parsing.PyTorch | PyTorch, 224² | comfortable | ONNX export needed | No `LICENSE` file; CelebAMask-HQ classes |
| SegFormer face parsing (jonathandinu) | huggingface.co/jonathandinu/face-parsing | ONNX + quantized ONNX; 84.6 M ≈ 339 MB fp32 | usable | ONNX Runtime | No licence declared; best parser if terms are cleared |
| SAM 2.1 tiny | github.com/facebookresearch/sam2 | 39 M params; 148.8 MB (156,008,466 bytes) measured 2026-11-18, against the ~298 MB an unrecorded catalog had been quoted as | comfortable | ORT possible; official ONNX **NOT VERIFIED** | Box prompts ship today; point prompts absent |
| SAM 3 / 3.1 | github.com/facebookresearch/sam3 | ≈0.85–0.9 B; F32 ≈3.4–3.6 GB | aggressive → impractical | CUDA 12.6+ per repo | Text+box+point; gated custom licence |

### 3.2 Picks

| Role | Best quality | Best lightweight | Best on M3 16 GB | Best cross-platform |
|---|---|---|---|---|
| Landmarks | MediaPipe (478 + blendshapes) | Apple Vision | Vision for pins/regions; MediaPipe only if a mesh is sold | MediaPipe *if* Windows Python is proven — unverified |
| Face identity | InsightFace ArcFace (blocked) | Vision + IoU tracker (current) | current | none verified |
| Face parsing | SegFormer mit-b5 | BiSeNet | SegFormer small/medium class | licence unresolved on both |
| Person matte | BiRefNet | MODNet | BiRefNet lite | BiRefNet lite / MODNet via ONNX |
| Click-to-mask | SAM 3 | SAM 2.1 tiny | SAM 2.1 tiny + point prompts | SAM 2.1 tiny ONNX (unverified export) |

**Reading.** The current macOS pipeline needs no new model for face detection,
landmarks or person segmentation. A learned parser or a 478-point mesh is a
deliberate upgrade with its own detector, index map and quality corpus, not a
swap. Windows cannot use Vision, so its landmark backend is an owner decision
([AI_11_ROADMAP.md](AI_11_ROADMAP.md) F1).

## 4. Segmentation, masking and matting (capability B)

| Model | Format · size | Licence | M3 16 GB | Windows | Role |
|---|---|---|---|---|---|
| Apple Vision person segmentation | OS framework | OS terms | comfortable | none | Person matte today; coarse edges |
| SAM 2.1 tiny | see §3 | Apache-2.0 | comfortable | ORT possible | Box/point masks |
| BiRefNet full / lite | 220.7 M ≈ 883 MB / 44.4 M ≈ 177 MB fp32 | MIT declared, grant unconfirmed | lite: usable; full: tiled/quantized | ONNX export notebooks exist | Best hair among segmenters; still a mask, not a true matte |
| MODNet | 6.5 M ≈ 25 MB | Apache-2.0 | comfortable | ONNX ports | Portrait alpha; weak on non-portrait subjects |
| ViTMatte | ~0.5 GB (NOT VERIFIED) | MIT | comfortable | PyTorch only | Finest hair with a correct trimap |
| RMBG-2.0 | 0.2 B ≈ 0.9 GB fp32 (EST.) | CC BY-NC 4.0 | comfortable | ONNX | Blocked |
| U-2 Net | PyTorch checkpoint | Apache-2.0 code; weights unverified | usable | community ONNX | Superseded by BiRefNet |

**Picks.** Best quality: BiRefNet (after the grant). Best lightweight: MODNet
for portraits. Best on M3: BiRefNet lite. Best cross-platform: MODNet ONNX.
Fine matting remains unsolved by any shippable candidate until a written
licence exists; do not call a segmentation mask a matte.

## 5. Portrait retouching (capability C)

The evidence supports a blunt conclusion: **for portrait retouching the best
model is no model.** The shipped deterministic engine preserves texture and
imposes nothing on clean input; generative and restoration models plasticize
skin, invent pores and drift identity.

| Operation | Candidate | Verdict |
|---|---|---|
| Skin smoothing + texture | Classical frequency separation (shipped) | Keep |
| Eye (sclera/iris/lash) | Classical masked passes (shipped) | Keep |
| Teeth/enamel | Classical enamel mask (shipped) | Keep |
| Lip/brow | Classical luminance-preserving tint (shipped) | Keep |
| Blemish removal | MI-GAN (shipped) | Keep for spots |
| AI augmentation | Face restorers (**GFPGAN, CodeFormer, RestoreFormer++**) | Not for clean skin; CodeFormer blocked (non-commercial) |
| AI skin/detail models | No open weights with a clear commercial grant found | None recommended |

| Role | Best quality | Best lightweight | Best on M3 16 GB | Best cross-platform |
|---|---|---|---|---|
| Skin, eye, teeth, lip, brow | Classical (shipped) | Classical | Classical | Classical |
| Spot/blemish repair | MI-GAN | MI-GAN | MI-GAN | MI-GAN (ONNX unproven) |
| Damaged-face restoration | RestoreFormer++ | GFPGAN | RestoreFormer++ (512 crops) | PyTorch only |
| AI skin smoothing | none verified | none | none | none |

A future AI portrait path must be opt-in, A/B measured on a texture-and-identity
corpus, and reversible; the classical path stays the default.

## 6. Healing and object removal (capability D)

### 6.1 Repair by scale

| Scale | Fits | Avoid |
|---|---|---|
| Small spot, dust, acne | MI-GAN 512 (28.1 MB, shipped) | Diffusion: cost without benefit |
| Irregular brush stroke | LaMa-class (Fourier convolutions) | MI-GAN alone above ~150 px strokes |
| Large object | FLUX.2 klein 4B q4 (shipped) | LaMa: blurry semantics |
| Complex background | FLUX.2 klein 4B q4 | MI-GAN, LaMa |
| Face region | MI-GAN for spots; restorers only on damaged faces | Global face restoration on clean skin |

### 6.2 Candidates

| Model | Weights | Licence | M3 16 GB | Windows | Notes |
|---|---|---|---|---|---|
| MI-GAN | 28.1 MB | MIT (weights) | comfortable | no verified ONNX port | Prompt-free small-hole fill; shipped |
| LaMa / simple-lama-inpainting | weights size **NOT VERIFIED** | code Apache-2.0; weights unverified | comfortable | ONNX/Core ML conversion unverified | Medium fill; needs a written weight grant |
| FLUX.2 klein 4B (q4) | 4.6 GB | Apache-2.0 | aggressive but viable | not practical on CPU | Semantic rebuild; no native mask inpaint — the app composites patch+alpha |
| FLUX.1 Fill dev | 12 B BF16 ≈ 24 GB (arith.) | Non-commercial | not practical | no | Only verified native inpaint+outpaint; blocked |
| GFPGAN 1.4 / RestoreFormer++ | 348.6 MB / **NOT VERIFIED** | Apache-2.0 (GFPGAN: mixed third-party terms) | usable | community ONNX | Damaged-face repair only |

**Picks.** Spot: MI-GAN. Medium brush: LaMa (post-licence). Large
object/complex background: FLUX.2 klein. Best cross-platform: MI-GAN if an
ONNX export is proven; none otherwise.

**Layer contract.** Every engine must honour patch + alpha + authorized box,
with pixels outside the box identical. MI-GAN tiling and LaMa edge blending
need per-engine dilate/feather verification.

| Role | Best quality | Best lightweight | Best on M3 16 GB | Best cross-platform |
|---|---|---|---|---|
| Spot | MI-GAN | MI-GAN | MI-GAN | MI-GAN (ONNX unproven) |
| Medium brush | LaMa (after licence) | LaMa | LaMa | LaMa ONNX (unverified) |
| Large object | FLUX.2 klein | FLUX.2 klein | FLUX.2 klein | none (CPU impractical) |
| Complex background | FLUX.2 klein | FLUX.2 klein | FLUX.2 klein | none |
| Face-region repair | MI-GAN; restorer only on damage | MI-GAN | MI-GAN | MI-GAN |

## 7. Background (capability E)

| Approach | Needs | Status |
|---|---|---|
| Replace background behind a person | Person matte (Vision today) + classical composite | Available now on macOS; edges are coarse |
| Clean cutout with hair detail | Fine matte (BiRefNet/ViTMatte class) | Candidate; licence/test gaps |
| Generated background | Generative engine (FLUX.2 klein) | Separate generative job; memory-heavy |
| Background detection (subject type) | No model adopted | Not planned before measurement |

No new matte model is required to ship a background replacement; the gap is
edge quality and hair. A generated background is never part of the matte job.

| Role | Best quality | Best lightweight | Best on M3 16 GB | Best cross-platform |
|---|---|---|---|---|
| Person matte | BiRefNet (after grant) | MODNet | BiRefNet lite | MODNet ONNX |
| Fine hair matte | ViTMatte (needs trimap) | none | BiRefNet full (tiled) | none verified |
| Generated background | FLUX.2 klein | FLUX.2 klein | FLUX.2 klein | none |
| Composite/edge blend | Classical | Classical | Classical | Classical |

## 8. Generative editing and outpainting (capability F)

| Model | Weights | Licence | M3 16 GB | Windows | Notes |
|---|---|---|---|---|---|
| FLUX.2 klein 4B q4 | 4.6 GB | Apache-2.0 | aggressive but viable | not practical | Shipped; 4-step distilled; reference edit + T2I; no native mask inpaint |
| FLUX 3 Image Klein | 5.6 B + 4 B encoder ≈ 19 GB BF16 (arith.) | FLUX Kommunity (revenue-gated) | not practical | no | Refs + boxes, not hard masks |
| FLUX.1 Fill dev | 12 B ≈ 24 GB BF16 (arith.) | Non-commercial | not practical | no | Native inpaint + outpaint; blocked |
| SD 3.5 Medium / Large | 2.5 B ≈ 5 GB / 8 B ≈ 16 GB | Stability Community (<$1 M free) | Medium usable / Large no | no | Inpaint only via community finetunes |
| SDXL inpainting 0.1 | UNet ≈ 2.6 B ≈ 5 GB fp16 | CreativeML OpenRAIL++-M | comfortable | no | Older quality; superseded |
| Z-Image-Turbo | 6 B ≈ 12 GB BF16 | Apache-2.0 | vendor claims 16 GB class — **UNVERIFIED** | no | T2I only; Edit checkpoint unreleased |

**Picks.** Best quality on this hardware and the only shippable option:
FLUX.2 klein 4B q4. Outpainting: no shippable engine today; FLUX.1 Fill is
licence- and memory-blocked, so outpainting is a refusal, not a promise.

| Role | Best quality | Best lightweight | Best on M3 16 GB | Best cross-platform |
|---|---|---|---|---|
| Local prompt edit | FLUX.2 klein | FLUX.2 klein | FLUX.2 klein | none (CPU impractical) |
| Whole-frame reimagine | FLUX.2 klein | FLUX.2 klein | FLUX.2 klein | none |
| Outpainting | FLUX.1 Fill dev (blocked) | none verified | none practical | none |

### 8.1 What 16 GB allows

- **Memory.** 4.6 GB of weights plus text encoder and 1024² activations:
  expect 8–12 GB peak (ESTIMATE), leaving thin headroom beside the app.
- **Latency.** The measured 24–47 s masked patch is the only evidence; it is
  single-machine and not a benchmark. Larger contexts and more steps grow
  superlinearly.
- **Tiling.** 512 px patches with 0.25 context are how seams are avoided
  today; full-frame 1024 is at the edge.
- **Quantization.** q4/q8 MLX works for klein; FP8/NVFP4 are NVIDIA-only.
- **Thermal.** A fanless Air throttles on sustained work; one job at a time.

## 9. Upscaling (capability G)

### 9.1 What ships today

Export-time only, fixed 4×: the export plan enables the job when the requested
long edge exceeds the photo and the output stays under the 40 MP ceiling
(`Sources/StudioCore/RenderPolicy.swift:9-52`); the base is rendered at source
size, upscaled, then callouts and watermark are applied
(`ExportService.swift:133-165`); the job has a 1500 s timeout and tile progress
(`:201-242`).

| Evidence | Value |
|---|---|
| 64×64 → 256×256, `mps` | 0.46–2.37 s compute, 5–7 s whole job (MEASURED, [PHASE5_ACCEPTANCE.md](PHASE5_ACCEPTANCE.md) §4) |
| 900×1600 photo, 256 px tiles | 28 tiles, ~150 s, 23 MP output (MEASURED, recorded in `RenderPolicy.swift:27-31`; also the basis of the 6.5 s/MP UI estimate — **superseded 2026-11-19:** the sheet's estimate is now a fitted 12.0 s base plus 9.0 s per output mega-pixel; see `Docs/W5_UPSCALER_ACCEPTANCE.md` §12.9) |
| 256×256 job, `mps` | 0.55 s compute (MEASURED, [PRIVACY_AUDIT.md](PRIVACY_AUDIT.md) §3) |
| Swin2SR x4 weights | 48.5 MB, 12.2 M params, Apache-2.0 (VERIFIED, catalog and HF listing agree) |

**Contract.** Upscaling changes dimensions and reconstructs detail; it must
not be sold as denoise, deblur or restoration, even when a model does some of
each. Input size is capped by the 40 MP output ceiling (≈2.5 MP input at 4×).

**Colour and bit depth are an open decision.** The 1.0 plan writes every
export in sRGB (`RenderPolicy.swift:130`), and the upscale source is an sRGB
PNG written at native size (a 16-bit container). Wide-gamut is therefore
already converted before the job; whether more than 8 bits survives the model
round trip is **NOT VERIFIED**, and a photo product must answer this before
advertising 16-bit upscaling. An ESTIMATE of the working set: a 40 MP RGBA16
buffer is ≈320 MB, several live at once, plus ≈1 GB of runtime.

### 9.2 2× candidates

| Model | Weights | Code licence | M3 16 GB | Notes |
|---|---|---|---|---|
| Swin2SR classical x2-64 | 48.46 MB | Apache-2.0 | comfortable | Same family as the measured x4 |
| Swin2SR lightweight x2 | **4.08 MB** | Apache-2.0 | comfortable | Fastest credible option |
| SwinIR-S / M x2 | 17.1 MB / 67.3 MB | Apache-2.0 | comfortable / tiled | M is the quality step |
| Real-ESRGAN x2plus | 67.0 MB; MLX 33.47 MB | BSD-3-Clause | comfortable | Best Apple-native path; sharper, invents more |
| BSRGAN x2 | 66.9 MB | Apache-2.0 code; weights **NOT VERIFIED** | comfortable | Over-smooths |
| HAT-S x2 | 9.6 M; size **NOT VERIFIED** | Apache-2.0 | compromises | Dense attention |

### 9.3 4× candidates

| Model | Weights | Code licence | M3 16 GB | Notes |
|---|---|---|---|---|
| Swin2SR x4 (current) | 48.5 MB | Apache-2.0 | **measured 150 s / 23 MP** | Classical checkpoint |
| Swin2SR realworld x4 | 48.46 MB | Apache-2.0 | comfortable | Better prior for camera/JPEG sources |
| Real-ESRGAN x4plus | 67.0 MB; MLX 33.46 MB | BSD-3-Clause | comfortable | Sharper, higher invention risk |
| realesr-general-x4v3 (+wdn) | **4.9 MB**; MLX 2.43 MB | BSD-3-Clause | comfortable, fastest | Denoise strength knob |
| SwinIR realSR x4 GAN | 67.1 MB (M) / 142.5 MB (L) | Apache-2.0 | M tiled; L compromises | |
| HAT-S / HAT x4 | 9.6 / 20.8 M; Drive-only weights, size **NOT VERIFIED** | Apache-2.0 | HAT-S compromises; HAT aggressive | Highest PSNR class here |
| SeedVR2-3B | 13.57 GB + 1.0 GB VAE | Apache-2.0 | not practical | Diffusion, video-oriented |

### 9.4 Picks

| Role | Best quality | Best lightweight | Best on M3 16 GB | Best cross-platform |
|---|---|---|---|---|
| 2× | HAT-S (if weights are obtainable) | Swin2SR lightweight x2 | Real-ESRGAN x2plus via MLX | Swin2SR x2 (unapproved community ONNX conversions exist) |
| 4× | HAT / SwinIR-L (compromises) | realesr-general-x4v3 | Swin2SR x4 (already measured) | Swin2SR x4 (no approved ONNX artifact — W5-4 BLOCKED) |

**Corrected 2026-11-17.** The last column of both rows read "(ONNX
available)". Available is not approved: what exists are third-party
conversions whose conversion procedure, tool versions, opset, producer, size,
SHA-256 and licence terms this project does not hold — see
[W5_ROADMAP.md](W5_ROADMAP.md) §W5-4 and decision 6 of
[W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md).
A filename that says Swin2SR is not evidence that it is Swin2SR. The finding
that Swin2SR is the cross-platform pick stands; the gate it must pass first is
unchanged and still open.

**Face-aware upscaling.** No shippable face-restoration stage is recommended
inside upscaling: a restorer on clean faces plasticizes identity, and the
quality corpus to prove otherwise does not exist. Treat face restoration as an
explicit restore tool (§10), not an automatic upscale step.

## 10. Enhancement and restoration (capability H)

Enhancement is a first-class capability distinct from upscaling: same
dimensions, visible operation, strength control. The **AI Enhancer** is the
product surface for it — general, portrait, face, low-light and old-photo
presets over an ordered stage pipeline — while denoise, deblur, detail,
sharpen and face restoration are the stages and sliders it may use. Calling
all of them "enhancer" would hide what changed; the individual contracts stay
visible. Restoration is a separate contract for old or damaged photos.

| Operation | Input → output | What changes | Default today |
|---|---|---|---|
| Upscale | photo → larger photo | Dimensions + reconstructed detail | Off; export toggle only |
| Enhance | photo → same-size photo | Local contrast/detail/light | Classical sliders only |
| Denoise | photo → same-size photo | Noise reduction | No AI path; no slider |
| Sharpen | photo → same-size photo | Edge acuity | Clarity (luminance unsharp mask) |
| Deblur | photo → same-size photo | Blur recovery | None |
| Restore | photo → same-size photo | Scratches, noise, blur, tone | None |
| Face restoration | face crop/region → repaired region | Face detail | None |

| Model | Weights | Licence | M3 16 GB | Windows | Role |
|---|---|---|---|---|---|
| GFPGAN v1.4 | 348.6 MB | Apache-2.0 except NVIDIA StyleGAN2 and DFDNet CC BY-NC-SA | usable | community ONNX | Face restoration, licence risk |
| CodeFormer | 376.6 MB + parser/detector | S-Lab 1.0, non-commercial | usable | — | Blocked |
| RestoreFormer++ | size **NOT VERIFIED** | Apache-2.0 | usable (512 px crops) | community ONNX? | Face restoration candidate |
| Restormer | 104.7 MB per task | MIT | compromises (attention-heavy, tiled) | ONNX? | Best-quality denoise/deblur class |
| SCUNet (colour) | 72.0 MB | Apache-2.0 / KAIR MIT | comfortable, tiled | ONNX? | Denoise candidate |
| SwinIR colour-DN | 122.9 MB per σ (15/25/50) | Apache-2.0 | compromises | ONNX? | Denoise only |
| NAFNet | deblur ONNX 91.7 MB | MIT | comfortable-ish, tiled | ONNX Runtime | Deblur (GoPro/REDS) |
| DRUNet (KAIR) | 130.6 MB | MIT | compromises | ONNX? | Blind denoise/deblock |
| DNCNN (KAIR) | 2.2–2.7 MB | MIT | comfortable | — | Tiny baseline |
| Retinexformer | 6.48 MB | MIT | comfortable | — | Low-light (LOL/SID/FiveK) |
| realesr-general-x4v3 (+wdn) | 4.9 MB | BSD-3-Clause | comfortable | MLX 2.43 MB | Weakest denoise, fastest |

Old/degraded photo restoration, verified artifacts only: Swin2SR realworld x4
(48.46 MB, Apache-2.0) is the best drop-in today; SwinIR realSR x4 GAN
(67.1 MB M / 142.5 MB L, Apache-2.0) and Real-ESRGAN x4plus (67 MB, BSD-3)
are alternatives with a sharper, more inventive character. A face pass on top
is RestoreFormer++ (Apache-2.0) or GFPGAN (licence risk); CodeFormer is
blocked. Holes and tears belong to inpainting (MI-GAN), not restoration.

Denoise/deblur/low-light picks: best quality Restormer; best lightweight
DNCNN; best on M3 SCUNet (denoise) and NAFNet (deblur); best cross-platform
NAFNet ONNX. None of these is recommended for 1.1 until the enhancement
contract and a quality corpus exist.

No enhancement or restoration model is adopted for 1.1. The classical pipeline
covers exposure, contrast, saturation, vibrance, warmth, tone curve, split
tone, HSL, clarity (luminance-only unsharp mask), vignette, look and grain
(`ImageProcessor.swift:1046-1112`); there is no global denoise or deblur
slider today (`Adjustments.swift:38-52`). "Denoising" in Quick Edit refers to
diffusion steps, not image noise (`QuickEdit.swift:70`) and must not be reused
as a feature name.

## 11. Resource envelope on the M3 16 GB target

| Class | Examples | Expected peak | Rule |
|---|---|---|---|
| Comfortable | Vision requests, MI-GAN, MODNet, SAM 2.1 tiny, Swin2SR | well under 2 GB (ESTIMATE) | May stay resident or load per job |
| Usable with compromises | Swin2SR on 23 MP output, BiRefNet full, face restorers | several GB (ESTIMATE) | Tiled, one at a time |
| Aggressive / tiled only | FLUX.2 klein q4 | 8–12 GB (ESTIMATE) | Opt-in, unload after use |
| Not practical | FLUX.1 Fill 12 B, FLUX 3 Klein, SeedVR2, SAM 3 | weights alone exceed budget | Do not offer |

No model here has a measured peak-memory figure; the recorded upscale numbers
are the only measured AI timings in the repository. Resource measurement is
roadmap item R3.

## 12. Recommended model dossier

For each shipped or near-term recommended model: what it is, what it costs, how
it accelerates, and what it cannot do. "Architecture" is stated only where the
official source establishes it; the external worker's exact checkpoint and
preprocessing remain **NOT VERIFIED**.

### 12.1 Shipped models

| | FLUX.2 klein 4B (q4) | SAM 2.1 tiny | Swin2SR x4 | MI-GAN 512 |
|---|---|---|---|---|
| Task | Prompt-guided local/whole-frame edit | Promptable segmentation | 4× super-resolution | Small-hole inpainting |
| Architecture | Flow/diffusion-class transformer, 4-step distilled as shipped; exact graph NOT VERIFIED | Promptable segmentation transformer with memory attention | SwinV2-based restoration transformer, 12.2 M params | GAN trained on Places2, 512² |
| Format | q4 weights (safetensors/MLX class) | PyTorch checkpoint (ONNX unofficial) | safetensors | PyTorch/ONNX class (worker NOT VERIFIED) |
| Download size | 4.6 GB | 148.8 MB (156,008,466 bytes) recorded 2026-11-18; the ≈298 MB this row quoted from [AI_RUNTIME.md](AI_RUNTIME.md) §1 came from a catalog with no size field, which is also why download progress used to be indeterminate | 48.5 MB | 28.1 MB |
| Code / weights licence | Apache-2.0 / Apache-2.0 | Apache-2.0 / Apache-2.0 | Apache-2.0 / Apache-2.0 | MIT / MIT |
| Acceleration | PyTorch MPS; MLX/mflux wheels bundled | PyTorch MPS | PyTorch MPS; ONNX exports in the community | PyTorch MPS |
| Quantization | q4 (shipped) | none applied | none applied | none applied |
| Offline | Yes after consented download | Yes | Yes | Yes |
| M3 16 GB | Aggressive; 8–12 GB peak (ESTIMATE) | Comfortable | Comfortable; 150 s / 23 MP measured | Comfortable, sub-second claimed but **NOT VERIFIED** |
| Windows | Not practical (no path) | ORT conversion unverified | No AI path in the host | No verified ONNX port |
| Quality limits | Strong semantic fill; identity/colour drift on faces; no native mask inpaint; 512 px patch contract | Box prompt only today; coarse on hair; not a matte | Invents detail at high zoom; face detail not specialised | Blurs semantics above ~150 px strokes; 512² prior |
| Integration | `generative_edit` / `patch_edit`; patch+alpha layer | `mask`; mask geometry stored in v5 | `upscale`; export-only | `inpaint`; patch+alpha layer |
| Maintenance | External catalog + runtime; largest download | Small; point prompts still to add | Stable; checkpoint choice unverified | Stable; weight hash present |

### 12.2 Near-term candidates

| | MODNet | BiRefNet lite | Real-ESRGAN x4plus | RestoreFormer++ | NAFNet | LaMa |
|---|---|---|---|---|---|---|
| Task | Portrait matte | Subject matte | 2×/4× SR | Face restoration | Deblur | Medium fill |
| Weights | ~25 MB | ~177 MB (44.4 M) | 67 MB (MLX 33.46 MB) | size NOT VERIFIED | 91.7 MB ONNX (deblur) | size NOT VERIFIED |
| Licence | Apache-2.0 code+weights | MIT declared, no licence file | BSD-3-Clause | Apache-2.0 | MIT | code Apache-2.0, weights unverified |
| M3 16 GB | Comfortable | Usable | Comfortable | Usable (512 crops) | Comfortable-ish, tiled | Comfortable |
| Windows | ONNX port | ONNX export notebooks | No AI path | Community ONNX only | ONNX Runtime | Conversion unverified |
| Limit | Portrait subjects only | Segmentation mask, not a true matte | Invents texture and faces | Identity drift if applied to clean faces | Needs tile overlap | Blurry semantics on large removals |
| Gate | Licence clear | Written grant | Quality corpus vs Swin2SR | Licence read + corpus | ONNX parity | Weight grant |

All candidates are offline once installed. On macOS they would run through
PyTorch MPS (or a converted Core ML path after a measured gate); on Windows
through ONNX Runtime/WinML CPU. None has a measured latency, peak memory or
quality figure on either platform; every class in the tables is an ESTIMATE.

## 13. Windows summary

| Capability | Windows path today | Blocking fact |
|---|---|---|
| Face detection/landmarks | None | `Windows.Media.FaceAnalysis` returns boxes without landmarks |
| Masks | Preserved in v5, not rendered | No pixel/mask path in the C ABI or host renderer |
| Upscale | No AI upscale option | No inference runtime or Swin2SR model on Windows |
| Enhance/heal/generative | Not rendered; export warns and omits them | 19 guard categories name unsupported edits, with a confirm dialog before writing |
| Model inference | None | No ORT integration; no ONNX assets; CPU-only CI |

No Windows AI path is recommended before a Windows landmark decision exists
([AI_11_ROADMAP.md](AI_11_ROADMAP.md) N1). CPU-only CI can prove correctness,
never GPU quality or speed.

## 14. Best picks across capabilities

| Capability | Ship for 1.1 | Defer |
|---|---|---|
| Face analysis | Vision (macOS) | Windows landmarks; learned parsing; mesh |
| Masks | SAM 2.1 box (+ point after R1) | Semantic classes; fine matte |
| Portrait | Classical engine | AI skin/eye/teeth |
| Healing | MI-GAN + FLUX.2 klein | LaMa (licence) |
| Background | Person matte + composite | Fine matte; generated backgrounds |
| Generative | FLUX.2 klein 512 px patch | Outpainting |
| Upscale | Swin2SR 4×; 2× option | Face-aware upscale |
| Enhance/restore | Classical sliders | All AI enhancement and restoration |

## 15. NOT VERIFIED register

- Every worker-internal detail: checkpoint choice, preprocessing, tiling,
  dtype, job routing. The worker source is outside this repository.
  *(Corrected 2026-11-18: the source is tracked under `worker/` and its 124 tests
  run in CI, so these are verifiable as implemented behavior. What stays open is
  the separate claim — that a real weight file reproduces that behavior — which
  no amount of reading answers, and `sam2.1-hiera-tiny` has no size or hash to
  check at all. See `AI_11_ARCHITECTURE.md` §17.)*
- MediaPipe model-card terms, bundle size and Windows behavior.
- BiSeNet and SegFormer-parser weight licences; U-2 Net weight terms;
  CelebAMask-HQ dataset terms.
- BiRefNet's written grant (MIT is declared but no licence file is present).
- LaMa's re-hosted weight licence and conversion quality.
- SAM 2.1 official ONNX export; SAM 3.1 deltas; SAM 3 commercial terms.
- RMBG-2.0 exact file size; ViTMatte weight size.
- GFPGAN's third-party exclusions as applied to its weights.
- RestoreFormer++ weight size; HAT and BSRGAN weight sizes and BSRGAN weight
  licence; SCUNet/NAFNet denoise ONNX exports; any official Core ML
  super-resolution model (conversions found are third-party).
- 16-bit preservation through the upscale round trip; the 1.0 plan forces sRGB
  output, so wide-gamut is already converted at the source.
- Z-Image-Turbo's 16 GB claim; any unreleased Edit checkpoint.
- All M3 feasibility classes beyond Swin2SR 4×; no latency, peak-memory or
  thermal measurement exists for any other candidate.
- Windows CPU/GPU latency and quality for every model above.

## 16. Official sources

Only sources opened during this research are listed; a model absent here has no
verified source link and is not recommended.

| Model / topic | Official source |
|---|---|
| Apple Vision face landmarks | developer.apple.com/documentation/vision/vnfacelandmarks2d |
| Apple Vision person segmentation | developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest |
| MediaPipe Face Landmarker | developers.google.com/edge/mediapipe/solutions/vision/face_landmarker |
| InsightFace | github.com/deepinsight/insightface |
| BiSeNet face parsing | github.com/zllrunning/face-parsing.PyTorch |
| SegFormer face parsing | huggingface.co/jonathandinu/face-parsing |
| SAM 2 | github.com/facebookresearch/sam2 |
| SAM 3 | github.com/facebookresearch/sam3 · huggingface.co/facebook/sam3 |
| BiRefNet | github.com/ZhengPeng7/BiRefNet |
| MODNet | github.com/ZHKKKe/MODNet |
| U-2 Net | github.com/xuebinqin/U-2-Net |
| ViTMatte | github.com/hqztrue/ViTMatte |
| RMBG-2.0 | huggingface.co/briaai/RMBG-2.0 |
| FLUX.2 klein | huggingface.co/black-forest-labs/FLUX.2-klein-4B · bfl.ai/blog/flux-2-klein |
| FLUX 3 Image Klein | huggingface.co/black-forest-labs/FLUX.3-Image-Klein · bfl.ai/blog/flux-3 |
| FLUX.1 Fill dev | huggingface.co/black-forest-labs/FLUX.1-Fill-dev |
| SD 3.5 | huggingface.co/stabilityai/stable-diffusion-3.5-large |
| SDXL inpainting | huggingface.co/diffusers/stable-diffusion-xl-1.0-inpainting-0.1 |
| Z-Image-Turbo | huggingface.co/Tongyi-MAI/Z-Image-Turbo |
| Swin2SR | github.com/mv-lab/swin2sr |
| Real-ESRGAN (incl. general-x4v3, MLX port) | github.com/xinntao/Real-ESRGAN · huggingface.co/mlx-community/Real-ESRGAN-x4plus |
| HAT | github.com/XPixelGroup/HAT |
| Restormer | github.com/swz30/Restormer |
| Retinexformer | github.com/caiyuanhao1998/Retinexformer |
| NAFNet | github.com/megvii-research/NAFNet |
| RestoreFormer++ | github.com/wzhouxiff/RestoreFormerPlusPlus |
| GFPGAN | github.com/TencentARC/GFPGAN |
| CodeFormer | github.com/sczhou/CodeFormer |
| mflux | github.com/filipstrand/mflux |

MI-GAN, SwinIR, BSRGAN, SCUNet, DRUNet/DNCNN, LaMa and SeedVR2 appear in the
tables as researched candidates; their official pages were not re-opened in
this pass, so their licences keep the **NOT VERIFIED** flags above.

## 17. What this evaluation does not do

It does not download weights, convert formats, benchmark models, alter the
catalog or enable any download. It recommends no new language or runtime
change; runtime and language conclusions live in
[AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §7. A model enters the product
only through the licence, integrity and measurement gates in
[AI_11_ROADMAP.md](AI_11_ROADMAP.md) §7.
