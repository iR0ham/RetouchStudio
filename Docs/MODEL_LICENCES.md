<!-- Imported evidence record. The body below is the researcher's dossier,
     transcribed without change except for the two scratch-directory paths
     named in Appendix C, which are described rather than spelled out so no
     tracked file points at a temporary location as an evidence source. -->

> **Import record (2026-11-22).** This is the repository-owned copy of the
> model-licence dossier that previously lived only in a temporary directory.
> Source file: `MODEL_LICENSES.md`, original date **2026-11-21** (file mtime
> 2026-11-21 21:55:18 local).
> Original byte size: **39361** bytes. Original SHA-256:
> `2b2815d5e8359bff9e542d18c8ef362831a20ba496d564cdac01d2d683dd5b7c`.
> The digest and size describe the imported original; this copy differs from
> it only by this preamble and the Appendix C redaction above.

# Model Licence & Provenance Dossier — RetouchStudio

Status: research deliverable for the post-release AI roadmap (owner directive §3 D/E/F).
Date of all web reads: **2026-11-21** (UTC timestamps in Appendix A). Local reads: same day.
Author: Researcher. No implementation, no pins changed, no download, no app launch, no writes to the repository.

Evidence labels used throughout:

- **MEASURED** — read from a file/API/URL that is cited, or from the disk on this Mac.
- **INFERRED** — a conclusion drawn from cited material, not stated verbatim there.
- **NOT CONFIRMED** — could not be verified; never to be treated as a licence position.

---

## 0. Recommendations (read this first)

### 0.1 Verdict summary

| Feature | Recommended model | Verdict | One-sentence reason |
|---|---|---|---|
| Upscale ×4 (installed) | `swin2sr-x4` (caidas) | **USABLE-WITH-CONDITIONS** | Apache-2.0 covers code *and* the checkpoint on the HF repo, but the training data is research-only (dataset risk) and the download must carry the licence text + evidence URL. |
| Mask / segmentation (installed) | `sam2.1-hiera-tiny` (Meta) | **USABLE** | Apache-2.0 covers the checkpoints explicitly ("The SAM 2 model checkpoints … are licensed under Apache 2.0"); blocked by *metadata*, not licence. |
| Enhancer (P3) | Real-ESRGAN `x4plus` or `realesr-general-x4v3` | **USABLE-WITH-CONDITIONS** | BSD-3-Clause code, weights only under the repo licence (no separate weights grant), 67 MB, GitHub-release hosted. |
| Enhancer (P3) alternative | SwinIR-L realSR GAN / colour-DN | **USABLE-WITH-CONDITIONS** | Apache-2.0 code + stable GitHub release assets; weights grant is the repo licence (not separately stated). |
| Enhancer (P3) alternative | Restormer / NAFNet / SCUNet | **USABLE-WITH-CONDITIONS** | permissive code licences (MIT / MIT / Apache-2.0), but weights sit on Google Drive — no catalogue-grade artefact. |
| Portrait: face restore | RestoreFormer++ | **USABLE-WITH-CONDITIONS** (do not ship yet) | Apache-2.0 code, but trained on FFHQ (CC BY-NC-SA 4.0) and no explicit weights grant on an artefact host. |
| Portrait: face restore | GFPGAN | **EXCLUDED** | Its LICENSE embeds the NVIDIA licence §3.3 (non-commercial only) and DFDNet CC BY-NC-SA 4.0. |
| Portrait: face restore | CodeFormer | **EXCLUDED** | S-Lab License 1.0: redistribution/use for non-commercial purpose only. |
| Portrait: matting/selection | BiRefNet | **USABLE** | MIT for code *and* weights (HF `license: mit` on the repo holding `model.safetensors`). |
| Portrait: matting | MODNet | **USABLE-WITH-CONDITIONS** | Apache-2.0 code; weights only on Google Drive, no explicit weights grant verified. |
| Heal / inpaint (small) | `migan` (installed) | **USABLE** | MIT code **and** an explicit MIT `LICENSE-WEIGHTS`; ONNX is the author's own export. |
| Heal / inpaint (large) | LaMa `big-lama` | **USABLE-WITH-CONDITIONS** | Apache-2.0 code; the checkpoint's own licence is not stated by the authors and the file we would download is a third-party re-export. |
| Generative edit (installed) | `flux2-klein-4b-q4` | **USABLE** (licence) / **EXCLUDED on this hardware** | Apache-2.0 weights explicitly "for commercial use"; measured 16.7 GB peak on M3 16 GB. |

### 0.2 What I recommend the project do

1. **Keep `swin2sr-x4`.** It is the right compromise: Apache-2.0 weight grant explicitly attached to the file's own repository, 48 MB, and the model card is the licence evidence. Add the licence text and evidence URL to the model store (see §8a) instead of replacing it.
2. **Unblock `sam2` by recording metadata, not by re-licensing.** The checkpoint is Apache-2.0; the app's own DR-5 rule is what refuses it. Record `sizeBytes = 156008466` and `sha256 = 7402e0d8…` (measured today), then separately add the `sam2` runtime package. Do not represent this as "licence cleared" — it already is.
3. **For the Enhancer, prefer Real-ESRGAN `realesr-general-x4v3` (67 MB class) or SwinIR-L realSR.** Both live on GitHub releases with stable URLs and permissive code licences. Restormer/NAFNet/SCUNet are licence-clean but only distributable from Google Drive, which our catalogue validation and DR-5 verifiability cannot consume reliably.
4. **Never ship GFPGAN or CodeFormer.** They are the canonical trap in this area. Their marketing pages say "Apache" (GFPGAN) or omit the restriction (CodeFormer README); their licence files say otherwise. Also treat DFDNet as excluded (CC BY-NC-SA).
5. **Treat "trained on FFHQ" as a standing yellow flag.** FFHQ is CC BY-NC-SA 4.0 at the dataset level (images individually CC BY/BY-NC/PDM/CC0/US-Gov). Any face model trained on it inherits a residual non-commercial argument even when the weights licence is permissive. This is the second-most-common trap after the "research-only" code licence.
6. **Make the weights licence a first-class manifest field with a date and URL** (§8a). Today the app stores three licence strings and never shows the evidence URL; nothing records *when* the licence was read, so a stale claim cannot be detected.
7. **Do not conflate the two notice surfaces.** `worker/THIRD_PARTY_NOTICES.md` covers bundled Python wheels only and says so; weights are covered by nothing (they are not shipped). A model licence must never be discharged by pointing at the worker notices.

---

## 1. How a verdict was reached

Three questions were answered separately for every candidate, in this order:

1. **Code licence** — the repository the loader code / architecture comes from.
2. **Weights licence** — the grant attached to the checkpoint artefact itself (HF model card licence tag, `LICENSE-WEIGHTS`, or an explicit sentence in the README covering checkpoints). A repo licence is *not* automatically a weights licence; where only the repo licence exists, this dossier says so and marks the weights grant INFERRED rather than quoting it as a grant.
3. **Training-data provenance** — recorded because a restrictive dataset is a residual risk that the publisher's weight grant may not cure, and because the project has already been bitten by exactly this kind of conflation (opencv GPL x264/x265).

Verdicts:

- **USABLE** — permissive grant on the weights themselves (explicit), commercial use allowed, redistribution allowed with a notice obligation.
- **USABLE-WITH-CONDITIONS** — permissive but one grant is implicit (repo licence only), or the artefact host is not catalogue-grade (Google Drive), or the dataset provenance is restrictive/adverse. Conditions are stated per row.
- **EXCLUDED** — the licence text forbids commercial use or forbids redistribution.

Two facts about the licence landscape that shape every row below (both MEASURED today):

- **DIV2K is "made available for academic research purpose only"** — https://data.vision.ee.ethz.ch/cvl/DIV2K/ (2026-11-21T18:19:22Z). Almost every super-resolution/restoration model in this space is trained on DIV2K or DF2K (DIV2K+Flickr2K). Strictly read as a derivative-work restriction, that would exclude the entire SR field; no publisher in this space states that position. We therefore rely on the publisher's weight grant and record the dataset as a residual risk.
- **FFHQ is CC BY-NC-SA 4.0 at the dataset level** — https://raw.githubusercontent.com/NVlabs/ffhq-dataset/master/README.md (2026-11-21T18:19:22Z): "The dataset itself … is made available under Creative Commons BY-NC-SA 4.0 … You can use, redistribute, and adapt it for non-commercial purposes." FFHQ is the standard training set for portrait restoration, so this risk is concentrated exactly where the roadmap wants face features.

Neither statement is a legal opinion. Both are the reason the same "Apache-2.0" label means different things in different rows.

---

## 2. Upscale ×4 — the installed model

### 2.1 `swin2sr-x4` — USABLE-WITH-CONDITIONS

| Field | Value | Evidence |
|---|---|---|
| Artefact in use | `caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr`, 3 files, 48,461,065 B total | MEASURED: `Resources/model-catalog.json`; on-disk `~/Library/Application Support/RetouchStudio/AI/models/swin2sr-x4/1.0.0/` |
| Exact file set | `config.json` 772 B (sha `1e986f…6365`), `preprocessor_config.json` 152 B (sha `cbc362…cc4d`), `pytorch_model.bin` 48,460,141 B (sha `4a5f52a20932085557ed115f87c0ee8385e12f2719108c0dfd38c64aedea4710`) | MEASURED: catalog + `manifest.json` + hashed on disk (matches) |
| Source URL | https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr | MEASURED |
| Licence read at | Same URL, HF API `cardData.license = "apache-2.0"`, tag `license:apache-2.0` (2026-11-21T18:23:05Z) | MEASURED |
| Upstream code repo | https://github.com/mv-lab/swin2sr | MEASURED |
| Code licence | Apache-2.0, `LICENSE` with appendix "Copyright [2021] [SwinIR Authors]" | MEASURED (read 2026-11-21) |
| Weights licence | **Apache-2.0, same HF repo that holds `pytorch_model.bin`** — the licence tag is repository-level and the repository's only payload is the checkpoint | MEASURED (tag) + INFERRED (that the tag is the author's grant for the weights) |
| SPDX | `Apache-2.0` | — |
| Commercial use | Permitted (§2 of Apache-2.0) | MEASURED: standard text |
| Redistribution of weights | Permitted. If we ever mirror the file we owe: a copy of the licence, retained notices, a statement of changes, and any NOTICE text (§4(a)–(d)) | MEASURED: Apache-2.0 §4 |
| Patent clause | Yes — Apache-2.0 §3, with termination on patent litigation | MEASURED |
| Attribution | Retain copyright/notice; today delivered by download, so strictly no §4(a) obligation on us unless we redistribute. Recommended anyway (see §8a) | INFERRED |
| Dataset provenance | Model card names the degradation ("realworld-sr-x4-64-bsrgan-psnr") but **does not state the training set**. Companion SwinIR paper uses DF2K+OST; Swin2SR's own training set NOT CONFIRMED | NOT CONFIRMED |
| Residual risk | DIV2K is research-only (§1). This is a dataset-level argument, not a licence term of the checkpoint | MEASURED (dataset page) |
| Size / memory | 48.5 MB f32 weights, 12.05 M params. Project measurement: 6.2 s per 256² tile on MPS (M3 16 GB); shipped banded path recorded at 26.4 B/px, RSS ≈ 0.558 + 0.01842·px GB (not re-measured here) | MEASURED (catalog notes) / recorded project measurement |
| MIT-app compatibility | Yes — Apache-2.0 is compatible with an MIT application; the app's own MIT terms are unaffected | MEASURED |
| Verdict | **USABLE-WITH-CONDITIONS** — ship it, but disclose code + weights licence and the evidence URL at consent time, and record the dataset caveat internally | — |

Why not "USABLE": the licence tag is on the model repository, which is the correct place for a weights grant, but the tag is the *only* statement. There is no sentence such as SAM 2's ("the model checkpoints … are licensed under …"). The distinction matters for auditability, not for the outcome.

Why not "replace it": every alternative in this class has the same or a weaker weights grant and a larger artefact. The one alternative with a *stronger* grant (SAM-style explicit sentence) does not exist for x4 SR.

**If it ever fails** (e.g. the owner wants a stricter dataset position): replacement order is SwinIR-L realSR ×4 GAN (Apache-2.0, 142,473,939 B) → Real-ESRGAN `x4plus` (BSD-3-Clause, 67,040,989 B). Both are §4 below.

---

## 3. Mask / segmentation — the installed model

### 3.1 `sam2.1-hiera-tiny` — USABLE

| Field | Value | Evidence |
|---|---|---|
| Artefact | `sam2.1_hiera_tiny.pt`, 156,008,466 B on disk | MEASURED: store listing; SHA-256 `7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69` (first recording, this task) |
| Source URL (as catalogued) | https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_tiny.pt | MEASURED: `Resources/model-catalog.json` |
| Licence evidence URL (as catalogued) | https://huggingface.co/facebook/sam2.1-hiera-tiny (licence tag `apache-2.0`) | MEASURED 2026-11-21 |
| Code repo | https://github.com/facebookresearch/sam2 | MEASURED |
| Code licence | Apache-2.0, recorded pin `@2b90b9f` in `Docs/AI_RUNTIME.md` §6 | MEASURED |
| **Checkpoint licence** | Apache-2.0, stated explicitly in the repo README: "The SAM 2 model checkpoints, SAM 2 demo code … and training code are licensed under Apache 2.0" | MEASURED (read 2026-11-21) |
| SPDX | `Apache-2.0` (both) | — |
| Commercial use | Permitted | MEASURED |
| Redistribution | Permitted with Apache §4 obligations | MEASURED |
| Patent clause | Yes, Apache §3 | MEASURED |
| Dataset provenance | Not stated on the model card; SAM 2 training data is described in the paper, not as a licence term | NOT CONFIRMED (irrelevant to the grant here) |
| Size / memory | 156 MB on disk. Peak memory **NOT MEASURED**. Worker catalogue note claims "21 ms warm at 1024²" (latency, not memory) | MEASURED size / NOT MEASURED memory |
| MIT-app compatibility | Yes | MEASURED |
| Verdict | **USABLE** — the strongest licence position of any candidate in this dossier; both grants are explicit | — |

Note the distinction the PM asked for: the *repository* licence (Apache-2.0) and the *checkpoint* licence (Apache-2.0) are separate grants here, and the project is lucky that Meta stated the second one explicitly. Most repos do not.

**Blockers are not licence blockers — see §8c.**

---

## 4. Enhancer (roadmap phase 3)

The owner directive requires the Enhancer to stay separate from the Upscaler (§3 D). These candidates are therefore evaluated for *enhancement* duty (detail/denoise/deblur/realism), not as a replacement upscaler.

| Candidate | Code licence (URL, read 2026-11-21) | Weights grant | Artefact host | Size | Verdict |
|---|---|---|---|---|---|
| **Real-ESRGAN `x4plus`** | BSD-3-Clause, "Copyright (c) 2021, Xintao Wang" — https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/LICENSE | Repo licence only; no sentence about weights. INFERRED, not granted | GitHub release `v0.1.0`: `RealESRGAN_x4plus.pth`, **67,040,989 B** | 67 MB | **USABLE-WITH-CONDITIONS** |
| **Real-ESRGAN `realesr-general-x4v3`** | same repo/licence | same (INFERRED) | GitHub release `v0.2.5.0`: https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth — size NOT RECORDED | tiny model (author's description) | **USABLE-WITH-CONDITIONS** — best size/quality trade for "Enhance" |
| **SwinIR-L realSR ×4 GAN** | Apache-2.0, Jingyun Liang — https://raw.githubusercontent.com/JingyunLiang/SwinIR/main/LICENSE | Repo licence only (INFERRED) | GitHub release `v0.0`: `003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_GAN.pth`, **142,473,939 B** | 142 MB | **USABLE-WITH-CONDITIONS** |
| **SwinIR colour-DN** | Apache-2.0 (same) | Repo licence only (INFERRED) | same release: `005_colorDN_DFWB_s128w8_SwinIR-M_noise{15,25,50}.pth`, **122,905,743 B** each | 123 MB | **USABLE-WITH-CONDITIONS** (denoise-only prior) |
| **NAFNet** | MIT, "Copyright (c) 2022 megvii-model" + BasicSR Apache-2.0 appendix — https://raw.githubusercontent.com/megvii-research/NAFNet/main/LICENSE | Not stated; weights on Google Drive per README | **No GitHub releases** (API returns `[]`) | — | **USABLE-WITH-CONDITIONS**; artefact blocker |
| **SCUNet** | Apache-2.0, "Copyright 2022 Kai Zhang" — https://raw.githubusercontent.com/cszn/SCUNet/main/LICENSE | Not stated | **No GitHub releases** (API `[]`); README weight host NOT VERIFIED | — | **USABLE-WITH-CONDITIONS**; artefact blocker |
| **Restormer** | MIT, "Copyright (c) 2022 Syed Waqas Zamir and contributors" — https://raw.githubusercontent.com/swz30/Restormer/main/LICENSE.md | Not stated; all checkpoints on Google Drive folders per README | Google Drive only | — | **USABLE-WITH-CONDITIONS**; artefact blocker, and transformer cost at high res |
| **Retinexformer** | MIT, "Copyright (c) 2023 Yuanhao Cai" — https://raw.githubusercontent.com/caiyuanhao1998/Retinexformer/master/LICENSE.txt | **Weights repo has no licence tag** (`cardData` has no `license`) — https://huggingface.co/api/models/CaiYuanhao/Retinexformer | HF, small (~70 MB total) | — | **USABLE-WITH-CONDITIONS** at best; weights grant NOT CONFIRMED. Also low-light-specific |
| **KAIR DRUNet / DNCNN** | MIT, "Copyright (c) 2019 Kai Zhang" — https://raw.githubusercontent.com/cszn/KAIR/master/LICENSE | Not stated | In-repo `model_zoo` (NOT VERIFIED) | small | **USABLE-WITH-CONDITIONS**; classic baseline |

**Recommendation:** `realesr-general-x4v3` for the "Enhance" slider (small, fast, GitHub-hosted), with `x4plus` as the higher-quality tier. If a dedicated denoiser is needed, SwinIR colour-DN has the best artefact story; NAFNet is the quality leader but its distribution path needs a mirror before it could enter the catalogue.

Why no enhancement model reaches plain "USABLE": none of them (except SAM 2 and MI-GAN) ships a sentence that grants the *weights* rather than the *repository*. That is the normal state of this field, and the catalogue should encode the distinction rather than flatten it.

---

## 5. Portrait / face

| Candidate | Licence facts (URLs read 2026-11-21) | Dataset | Verdict |
|---|---|---|---|
| **GFPGAN** | LICENSE says "Apache License Version 2.0 **except for the third-party components listed below**"; embeds **NVIDIA licence §3.3** ("The Work and any derivative works thereof only may be used or intended for use non-commercially… non-commercially means for research or evaluation purposes only") for the StyleGAN2-derived component, and **DFDNet under CC BY-NC-SA 4.0**. https://raw.githubusercontent.com/TencentARC/GFPGAN/master/LICENSE | FFHQ (CC BY-NC-SA 4.0) + CelebA-HQ | **EXCLUDED** — a commercial product cannot ship a bundle carrying NVIDIA-NC and DFDNet-NC-SA components, whatever the top-level badge says |
| **CodeFormer** | "S-Lab License 1.0, Copyright 2022 S-Lab … Redistribution and use for non-commercial purpose…"; commercial requires contacting S-Lab. https://raw.githubusercontent.com/sczhou/CodeFormer/master/LICENSE | FFHQ + CelebA-HQ | **EXCLUDED** — non-commercial by construction |
| **DFDNet** | CC BY-NC-SA 4.0 (as recorded inside GFPGAN's LICENSE; standalone repo not re-read) | FFHQ | **EXCLUDED** |
| **RestoreFormer++** | Apache-2.0, copyright placeholder "[yyyy] [name of copyright owner]" unedited. https://raw.githubusercontent.com/wzhangzz/RestoreFormer/master/LICENSE | FFHQ | **USABLE-WITH-CONDITIONS, do not ship yet** — no explicit weights grant on an artefact host, and FFHQ provenance is adverse |
| **BiRefNet** | Code MIT (github.com/ZhengPeng7/BiRefNet); **weights MIT** — HF API `cardData.license = "mit"` on the repo containing `model.safetensors`. https://huggingface.co/api/models/ZhengPeng7/BiRefNet | DIS5K etc. (stated in card, not a licence term) | **USABLE** — best-positioned portrait/object matting model; ~220.7 M params, f16 safetensors ≈ 441 MB (estimate) |
| **MODNet** | Apache-2.0, copyright placeholder unedited. https://raw.githubusercontent.com/ZHKKKe/MODNet/master/LICENSE | unknown | **USABLE-WITH-CONDITIONS** — weights only on Google Drive; **no GitHub release assets** (API `[]`) |
| **MediaPipe Face Landmarker** | Repo Apache-2.0 (plus a Lucent notice for a UTF util). https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/LICENSE | — | **USABLE-WITH-CONDITIONS on code; model NOT CONFIRMED** — the `.task` model card licence was not read. (The app already has a Vision-based face path, so this is only relevant if we want a second provider.) |

**Recommendation:** for skin/blemish/wrinkle work, the project already has a non-AI path (frequency separation, measured and shipped). Do not add a face-restoration network just to get "AI" in the label: the only two popular ones are non-commercial, and the clean one (RestoreFormer++) is trained on a non-commercial dataset. Use BiRefNet for select-subject/hair/background, and keep face restoration off the roadmap until either (a) a model trained on a permissive face dataset appears, or (b) the owner accepts the FFHQ residual risk in writing.

---

## 6. Generative / inpainting (heal)

| Candidate | Licence facts (URLs read 2026-11-21) | Weights grant | Size | Verdict |
|---|---|---|---|---|
| **MI-GAN** (installed) | MIT code (Picsart AI Research, 2024) https://raw.githubusercontent.com/Picsart-AI-Research/MI-GAN/main/LICENSE **and** MIT `LICENSE-WEIGHTS` https://raw.githubusercontent.com/Picsart-AI-Research/MI-GAN/main/LICENSE-WEIGHTS. HF `andraniksargsyan/migan` tagged `mit`; the ONNX is the author's own pipeline export | **Explicit weights grant** | 28,079,181 B ONNX, sha `6f1f35…c40b` (matches disk) | **USABLE** |
| **LaMa `big-lama`** | Code Apache-2.0, "Copyright [2021] Samsung Research". https://raw.githubusercontent.com/advimman/lama/main/LICENSE. README distributes models via Google Drive/Yandex, with no weights licence sentence. The file our worker would use is `simple-lama-inpainting`'s **third-party torchscript re-export**, 205,803,670 B, https://github.com/enesmsahin/simple-lama-inpainting/releases/download/v0.1.0/big-lama.pt | **NOT CONFIRMED** from the authors; a third-party HF mirror (`smartywu/big-lama`) tags it `apache-2.0`, which is a mirror's assertion, not the authors' | 196 MiB | **USABLE-WITH-CONDITIONS** — Apache-2.0 code is clear; the checkpoint grant rests on a mirror |
| **FLUX.2 klein 4B q4** (installed) | HF `mflux-community/flux2-klein-4b-mflux-q4` Apache-2.0; FLUX.2-klein-4B card: "Open weights available for commercial use under the Apache 2.0 license"; out-of-scope-use list is not a licence restriction | Explicit, quoted | 4.61 GB q4 | **USABLE** (licence) — **EXCLUDED on M3 16 GB**: measured 16.7 GB peak, KV cache rejected |

Dataset note: MI-GAN and the LaMa family train on **Places2**. The Places2 terms page could not be fetched (two attempts, both failed today); **Places2 licence = NOT CONFIRMED**. The MI-GAN authors nonetheless attached an explicit MIT grant to the weights, which is the operative document.

**Recommendation:** MI-GAN stays the default heal model (small, MIT code *and* weights, runs under 30 MB). Use LaMa only if large-hole quality demands it, and if so record the third-party artefact explicitly in the manifest with `weightsLicense: "NOT CONFIRMED (third-party re-export of big-lama)"` rather than "Apache-2.0". Do not promote FLUX generation on this hardware.

---

## 7. Cross-cutting findings

### 7.1 Notice obligations by licence (what would have to be shipped if we mirrored weights)

| Licence | Commercial | Redistribute weights | Text to ship | Patent |
|---|---|---|---|---|
| Apache-2.0 | yes | yes | licence copy (§4a), notices (§4c), change notices (§4b), NOTICE text if any (§4d) | yes (§3) |
| MIT | yes | yes | copyright + permission notice (in full) | none stated |
| BSD-3-Clause | yes | yes | copyright notice + three conditions (binary form) | none stated |
| S-Lab 1.0 | **no** | non-commercial only | n/a — excluded | none |
| NVIDIA (embedded) | **no** | non-commercial only | n/a — excluded | none |
| CC BY-NC-SA 4.0 | **no** | non-commercial + share-alike | n/a — excluded | none |

Today we download at runtime and do not redistribute weight files, so the Apache §4 text-shipping duty is not triggered by the download itself. Two things still matter:

1. Our **consent sheet** already shows `codeLicense / weightsLicense / host / SHA-256 prefix` (`Sources/RetouchStudio/Views/ModelManagerView.swift:607-611`), in both English and Persian (`Localization.swift:708-713`, `PersianL10n.swift:735-739`). That is a disclosure, not a licence delivery.
2. `licenseEvidenceUrl` is stored and validated (`ModelCatalog.swift:108`, `Tests/ModelStoreTests.swift:546` requires https) but **is never displayed anywhere**. A user cannot reach the URL that justifies the claim. MEASURED (grep over `Sources/`).

### 7.2 The two notice surfaces, precisely

- `Resources/THIRD_PARTY_NOTICES.txt` (to be added by PR #111, still unmerged — MEASURED: the file does not exist in the owner tree) is the **application bundle** notice file: the app's own third-party code, and the audit script that prevents drift.
- `worker/THIRD_PARTY_NOTICES.md` (in the repo today) is the **worker/runtime** notice file: it lists the Python packages actually bundled, states that `requirements.lock` is SHA-256 pinned, and says the authoritative licence text is the `.dist-info` METADATA copied into the bundle.
- Neither covers model weights, and the worker file says so: "Model weights are not part of this repository or the app bundle. They are downloaded separately … each model carries its own license and attribution requirements."

### 7.3 Where the model store records licence — and what is missing

`retouchstudio.model-manifest/1` (in `…/AI/models/<id>/<version>/manifest.json`) records per-file `sha256` + `sizeBytes` + `manifestSha256` + `installedAt`. **No licence field, no provenance URL, no install-time notice.** The installed store contains no licence sidecar for any model (MEASURED: directory listing of `…/AI/models/{migan,sam2.1-hiera-tiny,swin2sr-x4}`). This is why the dossier has to exist as a separate document.

---

## 8. The three brief questions

### (a) What the runtime download manifest must carry so this dossier cannot rot

The app catalog (`Resources/model-catalog.json`, decoded strictly by `JSONDecoder().decode` at `ModelCatalog.swift:37`) currently has per entry: `codeLicense`, `weightsLicense`, `licenseEvidenceUrl` — three strings, no date, no attribution, no verdict. Add these fields (all optional in the Codable struct so old catalogues still decode; required by `validate()` for entries with a version ≥ a new catalogue version):

```json
"licenses": {
  "code":        { "spdx": "Apache-2.0", "url": "https://…", "readOn": "2026-11-21" },
  "weights":     { "spdx": "Apache-2.0", "url": "https://…", "readOn": "2026-11-21",
                   "explicit": true, "commercial": true, "redistribute": true,
                   "noticeRequired": true, "attribution": "Copyright …" },
  "dataset":     { "name": "FFHQ", "url": "https://…", "commercial": false, "note": "residual risk" },
  "patentGrant": true,
  "verdict":     "usable-with-conditions",
  "verdictReason": "one sentence",
  "dossier":     "https://…/MODEL_LICENSES.md#swin2sr-x4"
}
```

Minimum viable delta, if the full object is too heavy: **`weightsLicenseUrl`, `weightsLicenseReadOn`, `commercialOk`, `noticeText`**, plus the existing `codeLicense`/`weightsLicense`. Rationale:

- **A URL without a date cannot rot-detect.** Licences change (BiRefNet added an MIT `LICENSE` after early releases; GFPGAN's top-level claim contradicts its own file). `readOn` is the only way a future audit can know whether a claim is stale.
- **`explicit` distinguishes "the author granted the weights" from "we inferred it from the repo licence."** That is the exact failure mode this project already hit once.
- **`noticeText`** is what would have to be reproduced if the file is ever mirrored or bundled; without it, a redistribution decision cannot be executed without re-reading the web.
- **`verdict` + `verdictReason`** keep the policy decision next to the data, not in a separate document that drifts.
- The consent UI should render the `weights.url` (and the verdict) — today it renders only the SPDX names.

The worker catalog (`worker/retouch_ai_worker/catalog.py`) already has `license_id` + `commercial_ok` per model, and refuses without the flag unless `RETOUCH_AI_EVAL_MODELS=1`. It should gain `license_url` so the two surfaces can be checked against each other.

### (b) What `worker/THIRD_PARTY_NOTICES.md` covers that weights do not

It covers **code shipped inside the worker bundle**: the MIT worker itself, every Python distribution actually bundled (direct and transitive), pinned by SHA-256 in `requirements.lock`, with the authoritative text taken from each package's `.dist-info/METADATA` in the bundle. It explicitly excludes weights in its closing paragraph. So:

- a clean worker notices file says nothing about whether a checkpoint may be used commercially;
- a model's Apache-2.0 weights do not appear in it and must not be satisfied by it;
- the two files answer different questions: "what code is in the bundle?" vs "what may we download and run?".

### (c) sam2 pin decision — lock file, manifest, or licence?

**Not the lock file, not the licence. It is the manifest, plus one missing runtime package.**

| Candidate cause | Verdict | Evidence |
|---|---|---|
| Lock file (`.locks/sam2.1-hiera-tiny@…`) | **No** | The lock is a runtime lease (`Catalog._lease`, `catalog.py:225-252`). The only failure it produces is `BUSY` (transient). Nothing prevents first acquisition; the model is already on disk |
| Licence | **No** | Apache-2.0 for code and checkpoints (SAM 2 README); worker entry `license_id="Apache-2.0", commercial_ok=True` (`catalog.py:152-153`); worker's `require()` would load it |
| App manifest | **Yes** | `Resources/model-catalog.json` sets `sizeBytes: null`, `sha256: null` and `unverifiableReason: "No recorded SHA-256 or size; DR-5 forbids downloading or installing it until both are recorded."` → `isVerifiable == false` (`ModelCatalog.swift:117-135`) |
| Runtime package | **Yes, second gap** | `engine.py:589-595` lazily imports `sam2` via `build_sam2(...)`; `sam2` is not in `worker/requirements.lock` and is recorded only as a git checkout `@2b90b9f` in `Docs/AI_RUNTIME.md` §6. A verified checkpoint still cannot run |

Two numeric facts measured today close the manifest half: **size 156,008,466 B**, **SHA-256 `7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69`**. Recording them requires an owner-authorised data change (the catalogue is a pin), but no new licence decision.

Latent integrity gap worth a ticket: both the worker `require()` (`if spec.bytes is not None`) and `verify()` (`if spec.sha256 is None: continue`) skip enforcement when a field is absent. A checkpoint with no recorded hash therefore loads silently and can never fail verification. The same is true in the app entry today. Making `sizeBytes`/`sha256` mandatory for every catalogued model — rather than tolerated — is what prevents this class of "unpinned but working" model.

---

## 9. NOT CONFIRMED register (and how to close each)

| # | Item | Why it matters | How to close |
|---|---|---|---|
| 1 | **Places2 dataset terms** (MI-GAN, LaMa) | MI-GAN's MIT weight grant is explicit, so this is residual only | Fetch the Places2 terms from a reachable mirror or archive; two attempts failed today (csail.mit.edu unreachable) |
| 2 | **Swin2SR training set** | Dataset risk for the shipped upscaler | Read §4/§5 of arXiv 2209.11345 (Swin2SR paper) for the real-world-SR training set |
| 3 | **LaMa checkpoint licence from the authors** | We download a third-party re-export | Ask the LaMa authors, or pin `big-lama.zip` from the authors' Drive and record its hash; current position: Apache-2.0 code, weights grant unstated |
| 4 | **MediaPipe Face Landmarker model licence** | Only if a second face provider is ever added | Read the model card PDF referenced from ai.google.dev/edge |
| 5 | **RestoreFormer++ / MODNet weight artefact + licence** | Portrait roadmap | Locate the released checkpoint URL and any licence sentence; today both are Drive-hosted with no explicit grant |
| 6 | **SCUNet / NAFNet / Restormer weight hosts** | Enhancer shortlist | All three are licence-clean; only the artefact host is unresolved (Drive). A mirror decision is an owner decision |
| 7 | **`realesr-general-x4v3` size + hash** | Enhancer recommendation | Download-metadata read of the release asset (not done: no downloads permitted) |
| 8 | **Peak memory for sam2 / BiRefNet / enhancer candidates on 16 GB** | Selection criterion | Needs a measured run — a later, owner-authorised task; cannot be done by reading |

---

## 10. Size / memory table (this Mac, M3 16 GB)

| Model | On disk | Peak memory | Basis |
|---|---|---|---|
| swin2sr-x4 | 48.5 MB | small; shipped banded path 26.4 B/px (≈1.06 GB at 40 MP) | MEASURED size, recorded project measurement |
| sam2.1-hiera-tiny | 156 MB | NOT MEASURED | MEASURED size |
| migan (ONNX) | 28.1 MB | NOT MEASURED | MEASURED size |
| flux2-klein-4b-q4 | 4.61 GB | **16.7 GB — rejected** | MEASURED (catalog note) |
| Real-ESRGAN x4plus | 67.0 MB | RRDB ×4 — not measured | MEASURED size |
| SwinIR-L realSR ×4 GAN | 142.5 MB | not measured | MEASURED size |
| BiRefNet | ≈441 MB (f16, 220.7 M params) | not measured | INFERRED from HF parameter counts |

The only model known to *fail* the 16 GB budget is FLUX.2 klein with KV cache. Everything recommended above is an order of magnitude smaller than that ceiling.

---

## Appendix A — Evidence log (all reads 2026-11-21)

| # | URL | What it establishes | Time (UTC) |
|---|---|---|---|
| A1 | https://raw.githubusercontent.com/NVlabs/ffhq-dataset/master/README.md | FFHQ dataset CC BY-NC-SA 4.0; per-image CC BY/BY-NC/PDM/CC0/US-Gov; not for face-recognition development | 18:19:22 |
| A2 | https://data.vision.ee.ethz.ch/cvl/DIV2K/ | DIV2K "made available for academic research purpose only" | 18:19:22 |
| A3 | https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/LICENSE | Apache-2.0 + Lucent notice | 18:19:22 |
| A4 | https://api.github.com/repos/swz30/Restormer/license | MIT (`LICENSE.md`), Syed Waqas Zamir and contributors | 18:20:59 |
| A5 | https://api.github.com/repos/caiyuanhao1998/Retinexformer/license | MIT (`LICENSE.txt`), Yuanhao Cai 2023 | 18:21:00 |
| A6 | https://raw.githubusercontent.com/megvii-research/NAFNet/main/LICENSE | MIT (megvii-model 2022) + BasicSR Apache-2.0 | 18:20:34 |
| A7 | https://raw.githubusercontent.com/cszn/SCUNet/main/LICENSE | Apache-2.0, Kai Zhang 2022 | 18:20:34 |
| A8 | https://raw.githubusercontent.com/cszn/KAIR/master/LICENSE | MIT, Kai Zhang 2019 | 18:20:34 |
| A9 | https://raw.githubusercontent.com/swz30/Restormer/main/README.md | All checkpoints on Google Drive; no licence section | 18:20:41 |
| A10 | https://raw.githubusercontent.com/caiyuanhao1998/Retinexformer/master/README.md | weights hosted on HF, `hf download`; no licence statement | 18:20:41 |
| A11 | https://api.github.com/repos/xinntao/Real-ESRGAN/releases/latest | v0.3.0; `realesr-general-x4v3` at v0.2.5.0 | 18:21:14 |
| A12 | https://raw.githubusercontent.com/enesmsahin/simple-lama-inpainting/main/README.md + `…/models/model.py` | weight URL `…/v0.1.0/big-lama.pt`; no weights licence | 18:20:59 |
| A13 | https://raw.githubusercontent.com/advimman/lama/main/README.md | models via Drive/Yandex; no weights licence sentence | 18:20:59 |
| A14 | https://huggingface.co/api/models/ZhengPeng7/BiRefNet | `cardData.license = "mit"`; `model.safetensors` 220.7 M params | 18:20:59 |
| A15 | https://api.github.com/repos/megvii-research/NAFNet/releases ; …/cszn/SCUNet/releases ; …/ZHKKKe/MODNet/releases | all `[]` — no GitHub-hosted weights | 18:21:13 |
| A16 | https://api.github.com/repos/JingyunLiang/SwinIR/releases | v0.0 assets incl. 142,473,939 B realSR GAN, 122,905,743 B colour-DN | 18:21:23 |
| A17 | https://huggingface.co/api/models/CaiYuanhao/Retinexformer | no `license` in cardData; 70 MB total | 18:21:23 |
| A18 | https://huggingface.co/api/models/smartywu/big-lama | third-party mirror tagged `license:apache-2.0` | 18:21:23 |
| A19 | https://api.github.com/repos/enesmsahin/simple-lama-inpainting/releases | `big-lama.pt` 205,803,670 B | 18:21:23 |
| A20 | https://api.github.com/repos/xinntao/Real-ESRGAN/releases/tags/v0.1.0 | `RealESRGAN_x4plus.pth` 67,040,989 B | 18:23:05 |
| A21 | https://huggingface.co/api/models/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr | `cardData.license = "apache-2.0"`, 3 files, repo sha `bb13f02e…` | 18:23:05 |
| A22 | https://raw.githubusercontent.com/TencentARC/GFPGAN/master/LICENSE | Apache-2.0 "except for third-party components"; NVIDIA §3.3 non-commercial; DFDNet CC BY-NC-SA 4.0 | earlier today |
| A23 | https://raw.githubusercontent.com/sczhou/CodeFormer/master/LICENSE | S-Lab License 1.0, non-commercial | earlier today |
| A24 | https://raw.githubusercontent.com/wzhangzz/RestoreFormer/master/LICENSE | Apache-2.0, placeholder copyright | earlier today |
| A25 | https://raw.githubusercontent.com/advimman/lama/main/LICENSE | Apache-2.0, Samsung Research 2021 | earlier today |
| A26 | https://raw.githubusercontent.com/Picsart-AI-Research/MI-GAN/main/LICENSE and `/LICENSE-WEIGHTS` | MIT + MIT weights (Picsart AI Research 2024) | earlier today |
| A27 | https://raw.githubusercontent.com/mv-lab/swin2sr/main/LICENSE | Apache-2.0, SwinIR Authors 2021 | earlier today |
| A28 | https://github.com/facebookresearch/sam2 (README) | "The SAM 2 model checkpoints … are licensed under Apache 2.0" | earlier today |
| A29 | https://huggingface.co/facebook/sam2.1-hiera-tiny | licence tag `apache-2.0` | earlier today |
| A30 | https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/LICENSE | BSD-3-Clause, Xintao Wang 2021 | earlier today |
| A31 | https://raw.githubusercontent.com/JingyunLiang/SwinIR/main/LICENSE | Apache-2.0 | earlier today |
| A32 | https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4 ; FLUX.2-klein-4B card | Apache-2.0; "open weights available for commercial use" | earlier today |

Failed fetches: `https://places2.csail.mit.edu/download.html` and `https://places2.csail.mit.edu/` (twice each, today). Recorded in §9 #1.

## Appendix B — Repository-state facts measured for this dossier

| Fact | Location |
|---|---|
| Catalog entry fields: `codeLicense`, `weightsLicense`, `licenseEvidenceUrl` (no date, no notice text) | `Sources/RetouchStudio/Models/ModelCatalog.swift:96-115` |
| Strict decode; optional-field additions are safe, required ones are not | `ModelCatalog.swift:37` |
| `isVerifiable` / `verificationProblem` (DR-5 refusal) | `ModelCatalog.swift:117-135` |
| Consent sheet shows `host · code / weights · SHA-256 <16 chars>…` | `Views/ModelManagerView.swift:607-611` |
| `licenseEvidenceUrl` never rendered | grep over `Sources/` — only `ModelCatalog.swift:108` |
| Worker entries: `license_id` + `commercial_ok`; refusal text "not cleared for commercial use" | `worker/retouch_ai_worker/catalog.py:12-16, 152-153, 254-262` |
| Worker `require()` skips size check when `bytes` is None; `verify()` skips hash when `sha256` is None | `catalog.py:312-320, 348-360` (sha skip at 357) |
| SAM2 loader lazily imports `sam2` | `worker/retouch_ai_worker/engine.py:589-595` |
| `sam2` absent from `worker/requirements.lock` | grep — no match |
| Store manifest has no licence field | `…/AI/models/swin2sr-x4/1.0.0/manifest.json` |
| No licence sidecar in any installed model folder | listing of `…/AI/models/{migan,sam2.1-hiera-tiny,swin2sr-x4}` |
| `Resources/THIRD_PARTY_NOTICES.txt` does not exist yet (PR #111 unmerged) | `ls` → not found; PR #111 file list |

## Appendix C — Constraints honoured

No model was downloaded; no application was launched; no file outside a temporary scratch directory was written; `~/Library/Application Support/RetouchStudio/AI` was read only; the repository working tree was not modified. Prior scratch artefacts (the earlier updater-design, updater-feasibility and round-6 folders, held outside the repository) untouched.

---

## 11. Addendum, 2026-11-22 — `swin2sr-x4` weights: the `unknown` row is superseded

This addendum appends; nothing above is rewritten. Every §0.1, §2.1 and Appendix A
row written on 2026-11-21 stays exactly as it was filed, including the
`MEASURED (tag) + INFERRED (that the tag is the author's grant for the weights)`
cell in §2.1 and the "Whether the dossier should upgrade it is the owner's
decision" note in `Docs/MODEL_LICENCE_EVIDENCE.md` §9. This is that decision —
taken by the release manager on 2026-11-22 under the owner's standing execution
authority, which directs the team to decide on evidence rather than ask the owner
to choose between candidates, so it is not an owner ruling — recorded with the
evidence it rests on.

### 11.1 What changed in the shipped record

| Field | Before (PR #114 as first written) | After (this decision) |
|---|---|---|
| `permitted_use.weights.verdict` | `unknown` | **`approved-with-conditions`** |
| `permitted_use.weights.statedBy` | `inferred` | **`rights-holder`** |
| `canAcquire` / `canRedistribute` / `canUse` | `null` / `null` / `null` | **`true` / `true` / `true`** |
| `readOn` | `2026-11-21` | **`2026-11-22`** |
| `conditions` | *(none — an unknown record may not carry a grant)* | **four, all `met: true`** |
| `PermittedUse.admitted` | `false` | **`true`** |
| `capability.list` → `upscale.4x` | `blocked` ("no established permission …") | **`requires_model`** when uninstalled |

`trainingData` was **not** upgraded: it stays `unknown` / `not-established` with all
three axes blank. Its note gained the dataset quote below and no permission.

### 11.2 The evidence, read 2026-11-22 at primary sources

Three statements, each quoted from the source named with its URL. All three were
re-read from the network on 2026-11-23 while this branch was being prepared, and
each still reads as quoted: the organisation endpoint returns the verified flag and
full name below, the README (14,822 bytes) contains both sentences word for word
under the sections named, and `LICENSE` is still 11,348 bytes opening with the
Apache text and carrying the SwinIR appendix. One quotation is normalised rather
than byte-exact — the README writes `for testing:` with two trailing spaces, printed
here with one, which is how the rendered page shows it anyway.

1. **The uploader is the rights holder, not a mirror.**
   `https://huggingface.co/api/organizations/caidas/overview` returns
   `"isVerified": true` and `"fullname": "Computer Vision Lab, CAIDAS, University of Würzburg"`
   — the same lab the Swin2SR paper is authored from (README affiliation line:
   "Computer Vision Lab, CAIDAS, University of Würzburg"). A repository published by
   the verified account of the paper's own lab is the author's publication of their
   checkpoint, so its licence statement is a statement *by* the rights holder about
   the weights rather than our inference about a third-party upload.
2. **The project states its own licence in a sentence.**
   `https://github.com/mv-lab/swin2sr` (README, "Citation and Acknowledgement"):
   > "This project is released under the Apache 2.0 license."
   The repository also carries an `Apache-2.0` `LICENSE` file
   (`https://raw.githubusercontent.com/mv-lab/swin2sr/main/LICENSE`, 11,348 B, whose
   text begins "Apache License / Version 2.0, January 2004"), appendix
   "Copyright [2021] [SwinIR Authors]" — already logged as A27 on 2026-11-21.
3. **The training-data provenance the project itself reports.**
   Same README, "Results":
   > "We use mainly the DIV2K Dataset and Flickr2K datasets for training, and for
   > testing: RealSRSet, 5images/Classic5/Set5, Set14, BSD100, Urban100 and Manga109"
   DIV2K is distributed "made available for academic research purpose only"
   (Appendix A2, read 2026-11-21). This product is a free, non-commercial
   application under the owner's standing mandate, so a research-only *training
   corpus* does not refuse the recorded use class `public-non-commercial-use-and-distribution`.
   The constraint is therefore recorded, not ignored, and not treated as a term of
   the Apache grant either.

### 11.3 The four conditions now carried by the record

Each is stored in `worker/retouch_ai_worker/catalog.py` with `met: true`, mirrored
verbatim into `Resources/model-catalog.json` by `Docs/licence-evidence-apply.py`,
and pinned by `Tests/ModelStoreTests.swift` [19] and `worker/tests/test_catalog.py`:

1. Rights-holder identity documented with evidence URL and read date (the
   `caidas` verified-organisation overview, §11.2 item 1).
2. The Apache grant documented with evidence URL and read date (§11.2 item 2).
3. Training-data provenance recorded in this register and in the dossier rather
   than ignored (§11.2 item 3), including the open item in §11.4.
4. The artefact stays download-only at release — no bytes mirrored or bundled —
   and the recorded Apache notice is preserved wherever the checkpoint is
   redistributed.

An `approved-with-conditions` record may not stand with an unmet condition: both
validators refuse it, so these four are checked, not decorative.

### 11.4 NOT VERIFIED, stated plainly

- **The per-checkpoint training mix beyond DIV2K/Flickr2K is NOT VERIFIED.** The
  quote names the corpora the project says it used "mainly"; it does not state what
  `swin2SR-realworld-sr-x4-64-bsrgan-psnr` specifically saw, nor whether the
  BSRGAN degradation pipeline's source images carry their own terms. §9 item 2
  ("Swin2SR training set … Read §4/§5 of arXiv 2209.11345") remains **open**; this
  addendum does not close it, and the `trainingData` record stays `unknown`.
- The Hugging Face model card for this repo was re-checked for a licence sentence
  about the checkpoint. What is recorded is the repository-level `license:apache-2.0`
  tag plus the organisation's verified identity plus the upstream README sentence;
  there is still no HF-card paragraph naming the `.bin` file the way SAM 2's README
  names its checkpoints (A28). The upgrade rests on the README sentence and the
  authorship of the uploading account, not on a file-level statement.
- Nothing was measured against a downloaded model for this decision: no weights
  were fetched, no run was performed. It is a documentary decision on primary
  sources, read on 2026-11-22 and re-read 2026-11-23.

### 11.5 What this decision deliberately did not touch

`sam2.1-hiera-tiny`, `migan` and `flux2-klein-4b-q4` keep the records PR #114
wrote for them. `mask.click` still reports `blocked` because the `sam2` Python
package is not in `worker/requirements.lock` — that is a missing runtime, correctly
reported, and out of scope here. No other verdict moved in either direction.
