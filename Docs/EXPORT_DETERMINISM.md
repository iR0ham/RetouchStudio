# Export determinism

**Project:** Retouch Studio
**Repository:** `/Users/roham/RetouchStudio`
**Document date:** 2026-11-22
**Branch base:** `main` at `90d70bf` (all `file:line` references below were read in that tree)
**Scope:** what RetouchStudio actually guarantees about the bytes an export writes,
where the guarantee breaks, and why it was not repaired for 2.0.0.

This document exists because earlier wording in this repository could be read as a
blanket "exports are byte-identical" claim. It is not one. The statement below
replaces any such reading.

---

## 1. Evidence rules

Same vocabulary as `Docs/IMAGE_ENGINE_CHARACTERIZATION.md` §1:

- **VERIFIED** — read in this tree at the stated line.
- **MEASURED** — reproduced on the host named in §3 with the stated parameters; a measurement, not a general proof.
- **INFERRED** — the most economical explanation of the measurement plus the code; not isolated by an instrumented experiment.
- **NOT VERIFIED** — plausible, but nothing here establishes it. Do not repeat it as fact.

---

## 2. The guarantee, stated precisely

What holds:

1. **Within one app session, after the first render has happened, the same
   document with the same edits exports the same pixels.** Repeating an export
   produces identical rendered pixels, so repeated exports of the same
   document are comparable and re-runnable. *(MEASURED on the §3 host; see §3
   item 4.)*
2. **The edit graph itself is deterministic.** Two independently constructed
   pipelines over the same fixture produced identical digests for 78/78 corpus
   cases, and two consecutive verify runs matched all of them
   (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md` §8).
3. **Project files are canonical bytes.** `.json` writers use sorted keys and a
   stable region order, so both hosts write identical files for the same
   document (`Docs/PROJECT_SCHEMA_V5.md` §5). That is *project* serialization;
   it says nothing about exported image bytes.

What does **not** hold:

- **Byte-for-byte reproducibility of exported image files across processes is
  not guaranteed.** Specifically, the **first export after app launch** can
  differ from every later export of the same document (§3).
- This is now a documented property of the product, not a defect to be
  rediscovered. Any acceptance test, golden-corpus comparison or user-facing
  claim must treat "exported file hashes match a run from a different process"
  as outside the contract unless a per-export tolerance is applied.

---

## 3. Measured evidence

Host: **MacBook Air, Apple M3, macOS 27.2**. Reproduces at
`44647b0` ("Merge pull request #96 from iR0ham/w5-11/runtime-install-phase"),
i.e. it pre-dates the recent W5 work.

Numbers in this section come from an experiment run by the Product Owner on that
host. **I did not re-run it** — re-running needs a launched app, which is barred
on this machine — so I verified the code premises in §4 instead and report the
figures as given:

| Observation | Status |
|---|---|
| First export after launch vs. every later export: max deviation **1 LSB**, affecting **41 pixels** on the probe image | MEASURED (owner's experiment; NOT VERIFIED by me) |
| The same divergence occurs with the watermark **disabled** | MEASURED (owner's experiment; NOT VERIFIED by me) |
| Probe image identity, exact diff metric, and the precise revision the probe ran on | **NOT VERIFIED** — not recoverable from the repository; do not cite a specific fixture name for this |
| Later exports within the same session agree exactly | MEASURED indirectly: the corpus harness renders each case twice from separately built inputs and requires equal digests, and reports 78/78 equal plus two matching consecutive verify runs (`Docs/IMAGE_ENGINE_CHARACTERIZATION.md` §8). Whether every one of those double renders straddled the first-use boundary is **NOT VERIFIED**. |

Magnitude in plain terms: 1 LSB of a 16-bit channel is 1/65535 of a channel
range; 41 pixels out of a full-resolution photograph is far below anything a
human eye, a print, or a colour-managed comparison can register.

---

## 4. Where the variance comes from

### 4.1 One shared `CIContext`, GPU-backed (VERIFIED)

`ImageProcessor` is a singleton holding exactly one Core Image context:

- `Sources/RetouchStudio/Core/ImageProcessor.swift:104` — `static let shared = ImageProcessor()`
- `Sources/RetouchStudio/Core/ImageProcessor.swift:106` — `let context: CIContext`
- `Sources/RetouchStudio/Core/ImageProcessor.swift:117-121` — created once in `private init()` with
  `.cacheIntermediates: true`, **`.useSoftwareRenderer: false`**, working space extended linear sRGB.

Every render funnels through `renderCGImage`
(`Sources/RetouchStudio/Core/ImageProcessor.swift:1124`), which calls
`context.createCGImage(...)` at `Sources/RetouchStudio/Core/ImageProcessor.swift:1136`.

### 4.2 The localised cause (INFERRED)

A Metal-backed `CIContext` compiles and caches its kernels lazily. On the first
use the shader cache is cold; afterwards it is warm. The inference — which the
owner's experiment supports and which no instrumented run in this repository
proves — is that the cold path resolves to a slightly different kernel/precision
selection than the warm one, and that the warm GPU result agrees with a software
render. Label remains **INFERRED**: I found no code in this tree that selects a
renderer at runtime, and no measurement that toggles
`.useSoftwareRenderer` to confirm the agreement.

Note that `Docs/IMAGE_ENGINE_CHARACTERIZATION.md` §9 lists *"GPU/Metal vs CPU
rendering differences — Not varied or measured"* under explicitly NOT CAPTURED.
This document records the first measurement of that gap; it does not retroactively
characterize the corpus.

### 4.3 Which export paths are affected (VERIFIED)

All formats go through the same single choke point. There is **no bypass**.

`ExportFormat` offers exactly four cases — `jpeg`, `png`, `tiff`, `heic`
(`Sources/StudioCore/RenderContract.swift:7`). **There is no WebP export** in this
product; an earlier draft of this ticket assumed WebP, and that assumption is wrong.

Chain, single export and batch alike:

1. `Sources/RetouchStudio/Core/MacDocumentRenderer.swift:62` `write` →
2. `Sources/RetouchStudio/Core/ExportService.swift:295-303` `processor.write(...)` into a
   sibling temp file →
3. `Sources/RetouchStudio/Core/ImageProcessor.swift:1152` `write` →
4. `renderCGImage` at `ImageProcessor.swift:1179` → `context.createCGImage` at `:1136` →
5. `CGImageDestinationCreateWithURL` / `AddImage(AndMetadata)` / `Finalize` at
   `ImageProcessor.swift:1182`, `:1209-1213`, `:1214`.

So PNG, JPEG, TIFF and HEIC are **all** exposed to the cold-context effect, via
step 4. Step 5 (the ImageIO encoder) is downstream of the render and contributes
no pixel decision of its own; whether it is itself byte-stable run to run is
**NOT VERIFIED** here — `Docs/STUDIOCORE_CONFORMANCE_R1.md` §9 flatly states
*"Export file bytes are not reproducible across encoder runs."*

Adjacent uses of the same context, listed so nobody assumes they are exempt:

- AI upscale input: `Sources/RetouchStudio/Core/AIWorker.swift:1737`
  `writeUpscaleSource` writes a PNG through the shared processor before the
  helper enlarges it, so an upscaled export inherits the effect at its base layer.
- Previews, load-time normalization and analysis all render through the same
  context (`ImageProcessor.swift:173`, `:188`, `:225`, `:660`, `:664`), which is
  why "first export" really means "first render after launch" — loading a photo
  usually warms the context before any export is attempted. An export attempted
  before any document load is the case that can hit the cold path.
- The one renderer **outside** the shared context is
  `Sources/RetouchStudio/Models/AIMask.swift:102`, which builds a throwaway
  `CIContext(options: nil)` per call. It is a mask visualization, not an export
  path, so it is unaffected by (and does not affect) this finding.

### 4.4 What is NOT affected

- **Repeat exports inside one session** — identical pixels (§2 item 1).
- **Perceptual quality** — a 1 LSB change on tens of pixels is invisible and
  unmeasurable by any consumer toolchain that matters.
- **Colour management** — untouched. Working space, sRGB output policy, profile
  embedding and clipping behaviour are exactly as `Docs/OUTPUT_COLOR_POLICY.md`
  describes; the variance is a rounding-level difference inside an already-agreed
  colour space, not a profile or gamut change.
- **The watermark decision** — whether the signature appears, its text, position,
  opacity and size are unaffected; the experiment reproduces with the watermark off
  (§3). Related: `Docs/IMAGE_ENGINE_CHARACTERIZATION.md` §8 already records that
  `X06_WATERMARK` is one of the six cases whose digest moves between arm64 and
  Rosetta code generation, so text/sticker paths have their own separate,
  already-documented cross-architecture caveat.
- **Crop, geometry, metadata allowlisting, source-file protection, cancel
  semantics, temp-file commit** — all pure logic upstream/downstream of the
  render; none of them is precision-sensitive.

---

## 5. Why this was not fixed for 2.0.0

Deliberate decision, taken as the DOCUMENTATION resolution of the ticket rather
than a code change:

- The risk asymmetry is unfavourable. Touching the shared render context — its
  options, its lifetime, or where it is created — changes the pixel output of
  **every** export on **every** platform, days before a release candidate. The
  bug being avoided is a sub-LSB variance; the bug that could be introduced is a
  visible engine shift or a broken golden corpus.
- Existing docs already carry hash-pinned artifacts (`Tests/Corpus/Exports/*`,
  renewed only under explicit Product Owner authorisation per
  `Docs/OUTPUT_COLOR_POLICY.md` "Evidence"). Any pipeline change forces a
  re-capture sweep that a release window is the wrong place to approve.
- No user-visible harm: the affected quantity is 1 LSB on a handful of pixels.

---

## 6. What a real fix looks like (next maintainer)

Pick one; do not leave it implicit.

1. **Warm the shared context once at launch.** After `ImageProcessor.init`
   (`ImageProcessor.swift:109-122`), render a tiny throwaway graph — e.g. a
   1×1 `CIImage` through the existing `renderCGImage` with the same
   `format`/`colorSpace` arguments exports use — on a background queue during
   app start. Cheapest option, no behavioural change after the first frame.
   Caveat to check when implementing: a 1×1 render may not compile the kernels a
   real photograph needs, so warming may have to use a representative filter
   chain (scale + composite + a colour-adjusted pass) rather than a blank rect.
   Whether one small render is sufficient is **NOT VERIFIED**.
2. **Declare a tolerance instead of demanding equality.** Keep the pipeline and
   state a documented bound: ≤1 LSB per channel, ≤0.01% of pixels, between any
   two exports of the same document. Then make the corpus and any release
   acceptance check compare with that tolerance rather than SHA-256.
3. **Force the software renderer for exports** (`.useSoftwareRenderer: true`,
   `ImageProcessor.swift:119`) — correctness floor, but a measured preview/export
   speed cost is required first, and it would move every baseline. Not recommended
   without a benchmark.

Whichever is chosen, also:

- Measure it properly: same document, same edits, exported as the *first* render
  after launch versus the *second*, for each of PNG/JPEG/TIFF/HEIC, with the
  watermark off, on Apple silicon and Intel, and record max-abs-difference and
  differing-pixel-count rather than a hash equality.
- Close the corresponding `Docs/IMAGE_ENGINE_CHARACTERIZATION.md` §9 row
  ("GPU/Metal vs CPU rendering differences") instead of leaving a new doc orphaned.

---

## 7. Claims elsewhere in these docs that are too strong

Audited on `main` @ `90d70bf`. None of them asserts image-export byte equality
outright, so none needed correcting in place; the ones marked ⚠ are worded so
that readers routinely over-read them, which is why this document exists.

| Location | What it says | Verdict |
|---|---|---|
| `Docs/TECHNICAL_AUDIT.md:40` | "the preview/export pipeline is a single deterministic Core Image graph" | ⚠ Too strong as written. True of the *graph*; false of the *first rendered bytes*. Read together with §2 here. |
| `Docs/TECHNICAL_AUDIT.md:1350`, `:1461` | "the pixel work is deterministic"; colour "is a deterministic chain" | ⚠ Same qualification: deterministic ordering/logic, not bit-stable across a cold-to-warm context transition. |
| `Docs/TECHNICAL_AUDIT.md:1754` | "the pipeline is resolution-scaled and deterministic" | ⚠ Same. |
| `Docs/IMAGE_ENGINE_CHARACTERIZATION.md:256` | 78/78 identical digests, `deterministic: true` per case | Accurate **as measured** — in-process, same host, two renders per case. It is not a cross-process export-bytes claim; §8 already labels grain "OBSERVED, not a cross-version guarantee". |
| `Docs/PROJECT_SCHEMA_V5.md:93-99` | "both hosts produce **identical files** for the same document" | Accurate but narrow: it is about the **project JSON** codec, not exports. |
| `Docs/OUTPUT_COLOR_POLICY.md:40` with `Sources/RetouchStudio/Core/MacDocumentRenderer.swift:94-95` | an sRGB source "keeps its own sRGB space … leaves its exported bytes exactly as before"; the Swift doc comment reads "its bytes stay exactly as before" | Accurate in context: a comparison against the previous colour-space choice, not a first-vs-later export claim. Worth knowing that this comment is where the nearest thing to a byte-identity assertion in Swift lives — and it is about *which colour space*, not *which bits*. |
| `Docs/STUDIOCORE_CONFORMANCE_R1.md:441` | "Export file bytes are not reproducible across encoder runs" | Already conservative, and consistent with this document. |
| Swift sources | searched for `byte-identical` / `bit-exact` / `deterministic` claims about exports | No export byte-determinism claim found. Hits are `ProjectCodec.swift:559` (v3 snapshot JSON), `FaceIdentity.swift:46,80` (ordering), `ModelCatalog.swift:113` (AI model flag), `Recovery.swift:125` (test hooks). Nothing there needed correcting. |

---

## 8. Open items

- Independent re-measurement of §3 by someone other than the original experimenter,
  including the Intel/Rosetta axis. Blocked here by the standing ban on launching
  the app.
- Whether the ImageIO encode step (as opposed to the Core Image render) is itself
  byte-stable run to run. **NOT VERIFIED**; §4.3 explains why it matters for any
  hash-based acceptance test.
- The exact probe revision used for the 41-pixel measurement. **NOT VERIFIED** —
  `44647b0` is the revision the variance is reported to reproduce at, not
  necessarily the one the probe image was captured on.
