# Master product completion status

**Basis:** `main` at `5ce61ca` (merge of PR #27, 2026-11-14). PR #21 (16-bit
export) is verified by CI run
[43557855311](https://github.com/iR0ham/RetouchStudio/actions/runs/43557855311)
and merged as `18d4e46`; PR #22 (Windows MSI) is verified by run
[43561151628](https://github.com/iR0ham/RetouchStudio/actions/runs/43561151628)
and merged as `950636d`; PR #23 (in-place MSI upgrade) by run
[43563787267](https://github.com/iR0ham/RetouchStudio/actions/runs/43563787267),
merged as `1199210`; PR #24 (Windows batch export) by run
[43566124482](https://github.com/iR0ham/RetouchStudio/actions/runs/43566124482)
and its documentation head by run 43567380416. PR #26 (vignette parity) is
verified by run
[43573329343](https://github.com/iR0ham/RetouchStudio/actions/runs/43573329343),
merged as `a7d478e6`, and post-merge `main` is green in run 43575818731. PR #27
(clarity parity) is verified by run
[43576450870](https://github.com/iR0ham/RetouchStudio/actions/runs/43576450870)
and its documentation head by run 43577351736, merged as `5ce61ca`, with
post-merge `main` green in run 43578692160. PR #29 (colour-managed P3 decode) is
verified by run
[43582087464](https://github.com/iR0ham/RetouchStudio/actions/runs/43582087464)
(attempt 2; attempt 1 was cancelled at the job timeout during toolchain setup)
and its documentation head by run 43586982825, merged as `413363f`, with
post-merge `main` green in run 43588258162.
The original audit ran on `1d32842` (CI run 43531081160, also green).
**Updated:** 2026-11-14.

This is the single progress and evidence record for the cross-platform
completion mission. A row may only say VERIFIED when a reproducible result is
linked from [§5](#5-verification-ledger). Everything else is IMPLEMENTED,
NOT VERIFIED, BLOCKED, or ABSENT, and says which one.

## 1. Execution model

The mission asks for a Lead Orchestrator plus specialist agents. In this
environment the specialist agent runtime was unavailable (`Model 'sonnet' is
unavailable`), so the lead performed the discovery and implementation directly.
No work is attributed to an agent that did not run. The ownership column below
therefore names the role the work belongs to, and the implementation column
names the real commit.

Repository safety rules in force: no force-push, no reset/rebase, no rewriting
published history, no deletion of user work, no merge of a pull request without
explicit owner authorization, no golden-corpus regeneration, no private photos,
no secrets, no authentication or branch-protection bypass.

## 2. Capability matrix

`Shared core` = `Sources/StudioCore` behind the C ABI v1. `macOS` = the SwiftUI
app. `Windows` = the WPF host in `Windows/`. Evidence is in §5.

| Capability | Shared core | macOS | Windows | Tests | Status |
|---|---|---|---|---|---|
| v3 project read/write | codec | yes | via C ABI | v3 fixture byte identity, conformance | VERIFIED |
| v4 project read/write, keyed geometry | codec | yes | via C ABI | v4 fixture byte identity, ModelTests | VERIFIED |
| Unknown top-level keys across a save | context | yes | via C ABI | fixture `futureFlag`, Windows host test | VERIFIED |
| Nested unknown fields | capture/apply | yes | via C ABI | R4.8 tests | VERIFIED (top-level and modelled records; unmodelled nested records are dropped by design) |
| Cross-platform project interchange | codec | macOS fixtures | opens the same fixtures, saves structurally identical JSON | 14 host checks, CI run 43534410772 | VERIFIED |
| Edits a host cannot render are named, not dropped | `DocumentModel.UnsupportedEdits` | renders heal/stickers/AI/analysis | keeps the records, names them in the status bar and asks before an export writes without them | 5 host checks | TESTED (headless; the confirmation dialog is UI, NOT VERIFIED) |
| Undo/redo, 100-step history | `DocumentHistory` | yes | yes | StudioCore suite, 55 host checks | VERIFIED |
| Nine global adjustments | `Adjustments` | full engine | 9-slider pipeline | host checks; G-case metrics vs macOS references | VERIFIED per host; exposure/levels aligned (MAE 0.01 / 0.007), vignette aligned (MAE 0.47, gated at 1), clarity aligned (MAE 0.06, gated at 1); negative vignette is a no-op on both hosts and negative clarity blurs instead of inverting; cross-host parity NOT VERIFIED |
| Crop, quarter turns, mirror, straighten | values + policy | full freeform | 4 presets and a freeform overlay (corner handles, Apply/Cancel), turns, mirror, straighten | host checks of the crop arithmetic; window smoke run | VERIFIED (unit); Windows overlay IMPLEMENTED, drag wiring NOT VERIFIED by CI |
| Face detection, landmarks, multi-face, confidence | — | Vision, biggest-first | ABSENT | engine suite, `--selftest` | VERIFIED macOS |
| Face line mesh | — | ~76 Vision points + forehead/cheek rows, drawn as a web | ABSENT | self-check draws-mesh probe | VERIFIED macOS; no dense/3D mesh exists |
| Semantic segmentation of skin/regions | — | geometric regions + YCbCr/luma gates | ABSENT | engine suite | VERIFIED macOS; not a learned segmentation model |
| Masks (preview 1024 px, export 4096 px) | — | Core Image, feather + gates | ABSENT | engine suite, corpus | VERIFIED macOS |
| Heal stamps, stickers, watermarks | values | yes | ABSENT | corpus references | VERIFIED macOS |
| AI edits (composite, patch lifecycle) | values | yes, needs worker | ABSENT | engine/model suites | VERIFIED macOS; worker source outside repo |
| Export JPEG/PNG | contract | 8-bit | 8-bit JPEG; 16-bit PNG | host checks, run 43557855311 | VERIFIED per host; Windows PNG depth VERIFIED |
| Export TIFF | contract | 16-bit | 16-bit pixels, header-read | host checks, run 43557855311 | macOS VERIFIED; Windows VERIFIED per host |
| Export HEIC | contract | 8-bit, alpha flattened | explicit refusal | corpus `F01_export_256.heic` | macOS VERIFIED; Windows ABSENT by design |
| Orientation and alpha on load | — | EXIF baked, premultiplied compare | EXIF baked, straight alpha, white flatten for JPEG | corpus checks F10/F09 | Windows TESTED, no-op export pixel-identical |
| 16-bit pixels | — | PNG/TIFF source and output | PNG/TIFF export decodes and writes 16 bits; a 16-bit source previews through the 16-bit pipeline (header probe); JPEG stays 8-bit | host checks, runs 43557855311 and 43593470894 | macOS VERIFIED; Windows VERIFIED for PNG/TIFF export; 16-bit preview TESTED (at rest within one level of the 8-bit preview, 8 levels apart under strong adjustments, gated at 10) |
| HEIC decode | — | ImageIO | no decoder on `windows-2025` (probe fails `0x88982F8B`) | format probe, run 43549524897 | macOS VERIFIED; Windows NOT AVAILABLE on CI |
| Metadata keep/strip | — | EXIF/TIFF/IPTC/GPS + XMP | camera model + ISO when kept in JPEG, TIFF and 16-bit PNG; resolution always; no XMP/IPTC | Windows host tests, runs 43545230075, 43557855311 | macOS VERIFIED; Windows TESTED (measured allowlist) |
| ICC handling | — | source profile carried to render/write | source profile converted to sRGB on decode (WIC colour management), write always sRGB | corpus F11 P3, host checks, run 43582087464 | macOS VERIFIED; Windows decode TESTED (four in-gamut points within one level of ColorSync, wide-gamut colours clipped to sRGB; the P3 profile is not preserved on write) |
| Batch export | planner | yes | several sources rendered with one document through the single-export path, 16-bit PNG | host checks, run 43566124482 | macOS VERIFIED; Windows TESTED (output sample-exact against a single export, collision-safe names, per-file failure isolation; the WPF dialogs are not driven by CI) |
| AI runtime install | `AIRuntime` | disabled (`package == nil`) | ABSENT | runtime v2 suites | BLOCKED — no approved package |
| Signed update feed | `UpdatePolicy` | prepared, no feed shipped | ABSENT | update tests | IMPLEMENTED, not published |
| macOS packaging + DMG | — | per-arch, ad-hoc signed | — | `Tools/make-dmg.sh` | VERIFIED locally; clean-machine install NOT VERIFIED |
| Windows packaging | — | — | zip + SHA-256, built and re-checked on CI | zip manifest check, extracted-app smoke | VERIFIED |
| Windows installer | — | — | WiX v3 MSI, per-machine, Start menu, fixed `UpgradeCode` | silent install → window from `Program Files` → uninstall, runs 43561151628 and 43563787267 | VERIFIED per host, including an upgrade to a higher version in place |
| Windows updater | — | — | ABSENT | — | NOT STARTED |
| Notarization | — | pipeline ready | — | — | BLOCKED — no Apple Developer membership |
| CI matrix | — | 3 required + Windows core | `windows-2025` app job | §5 | VERIFIED |

## 3. Phase status

| Phase | Scope | Status | Evidence / gap |
|---|---|---|---|
| 0 | Baseline and gap analysis | VERIFIED | This document; `main` `1d32842`; run 43531081160 |
| 1 | Shared core and portable project architecture | VERIFIED | StudioCore boundary suite, conformance gate, R2–R4.8 docs |
| 2 | W3 face analysis and masking | macOS VERIFIED; Windows BLOCKED | Vision landmarks and masks exist and are tested on macOS; the Windows host has no face path, and its only in-box detector returns boxes without landmarks, so a distributable landmark model must be chosen |
| 3 | W4 image engine and rendering parity | PARTIAL | macOS pipeline characterised (16-bit PNG/TIFF, ICC, metadata, corpus references); Windows exports 16-bit PNG/TIFF sample-exactly (run 43557855311), previews 16-bit PNG/TIFF sources through the 16-bit pipeline (run 43593470894) and keeps 8-bit sRGB for other previews and JPEG exports, with tested metadata keep/strip, upright orientation, alpha, an exact no-op and exposure/levels that match the macOS references (MAE 0.01 / 0.007); the vignette follows CIVignette's measured shape in linear light and lands at MAE 0.47, gated at one level (run 43573329343); clarity reproduces CIUnsharpMask's Gaussian and the keepLuminance rebuild in linear light, landing at MAE 0.06, gated at one level (run 43576450870); Windows batch export shares the single-export path and its output is sample-exact against one-off exports (run 43566124482); the source profile is converted to sRGB on decode, proven against ColorSync at four in-gamut points (run 43582087464), but wide-gamut colours are clipped and ICC preservation on write is absent; HEIC read is absent, the missing HEIF decoder measured; full cross-host parity NOT VERIFIED |
| 4 | W5 AI runtime and model management | BLOCKED | Runtime installer disabled by design (`AIRuntime.package` nil); model weights and official package unavailable |
| 5 | Performance, stability, reliability | PARTIAL | macOS benchmarks recorded in `Docs/PERFORMANCE_BENCHMARKS.md`; the Windows host now prints a photo-sized preview (median 1187 ms, five runs, run 43598349755) and a 16-bit PNG export (1594 ms), gated at deliberately loose 3 s / 30 s ceilings so only a pathological regression fails a noisy runner; a 40-document loop renders varied crops, quarter turns, flips, straighten angles and both clarity signs without a failure and requires pixel-identical repeats; no Windows memory, startup or AI timing exists, and long-session stability is NOT VERIFIED |
| 6 | macOS product completion | PARTIAL | Native app builds, self-tests, corpus and engine suites pass; signing is ad-hoc and notarization is BLOCKED |
| 7 | Windows product completion | PARTIAL | Light native editor builds, runs 152 headless checks and opens a window on `windows-2025`, with verified 16-bit PNG/TIFF export, a 16-bit preview, a freeform crop overlay, batch export through the same path as a single export, an export guard for project edits the host cannot render, and an MSI that installs into `Program Files` and uninstalls cleanly on CI; no updater, face analysis or AI; interactive Windows behaviour NOT VERIFIED (CI-only) |
| 8 | Cross-platform project interchange | VERIFIED | macOS v3 and v4 fixtures open on Windows, round-trip with structurally identical JSON, keep the unknown key and required feature, and a v3 save stays v3 (CI run 43534410772) |
| 9 | Distribution, installers, updates | PARTIAL | macOS DMGs exist; Windows ships a zip and an unsigned per-machine MSI whose silent install, start from `Program Files`, in-place upgrade and clean uninstall are proved on CI (runs 43561151628, 43563787267); no updater, no update feed, no signing |
| 10 | CI/CD and release engineering | VERIFIED (CI) / NOT VERIFIED (release) | Five jobs green; the dormant release `windows-app` job has never executed |
| 11 | Documentation and product definition | IN PROGRESS | This record plus the existing Windows, CI, release and StudioCore documents |

## 4. W3 gap analysis (face analysis and masks)

This is the next implementation wave, so its exact starting point is recorded
here.

**Verified on macOS** (`Sources/RetouchStudio/Core/FaceAnalyzer.swift`):

- `VNDetectFaceLandmarksRequest` on a reused BGRA pixel buffer; results are
  filtered by confidence `>= 0.35` and area `>= 0.2%` of the frame, then sorted
  largest-first (`FaceAnalyzer.swift:439-459`).
- Landmarks: face contour, eyes, pupils, brows, outer/inner lips, nose, nose
  crest, median line, converted to absolute normalized bottom-left coordinates
  (`:541-577`).
- Derived regions for every tool: eye/lip shields, lids, lash line, iris,
  forehead, cheeks, blush, jaw, chin, under-eye, teeth/enamel
  (`:55-366`).
- Multiple faces exist as an ordered array; the document stores only
  `selectedFace` (an index). There is no stable per-face identity or mask
  persistence beyond the chosen index and the analysis pins.
- Masks are built geometrically and refined by kernels
  (`Sources/RetouchStudio/Core/MaskBuilder.swift`): opaque grayscale coverage,
  1024 px preview, 4096 px export, feather/softness, subtract/union/intersect,
  and luminance/saturation/YCbCr gates.
- Orientation: analysis runs on the oriented working image; stored pins are
  normalized bottom-left and flipped on draw (`AnalysisOverlay.swift:120-134`),
  which is a documented inconsistency with the canonical top-left space.

**Absent on Windows:** no face detection, landmarks, masks, analysis overlay,
or corresponding host tests. The shared v4 schema can already carry
`analysis`, `selectedFace`, `crop`, `healSpots`, `stickers` and `aiEdits`, so a
Windows face path must consume the same records rather than invent a second
format.

**Windows options, assessed 2026-11-14:** `Windows.Media.FaceAnalysis` detects
and tracks faces as boxes and exposes no landmarks. Masks need landmark
regions, so a box-only detector would be the fake feature this plan forbids.
The only route to real Windows landmarks is a distributable landmark model
(for example ONNX) with approved weights; none is in the repository and no
download is approved. W3 on Windows is therefore BLOCKED on an owner decision
about the detector and its weights, not on missing code structure.

**Not implemented anywhere:** dense 3D face mesh, learned semantic
segmentation, per-face identities, and standalone mask layers. The product
must not claim them.

## 5. Verification ledger

| Date | Commit | Workflow / job | Result |
|---|---|---|---|
| 2026-11-13 | `ef27d15` | CI, all five jobs | success; PR #14 merged as `1d32842` |
| 2026-11-13 | `1d32842` | CI run 43531081160, all five jobs | success |
| 2026-11-13 | `28f8462` | Windows App job 132239473907 | 13 exports, 142 runtime DLLs, 55 host checks, window `Retouch Studio` loaded, `WINDOWS APP BUILD: PASS` |
| 2026-11-14 | `983fb21` | local macOS codec probe | v3 fixture re-encodes byte-identically and stays v3; v4 stays v4 with `futureFlag`, `requiredFeatures`, keyed crop |
| 2026-11-14 | `d0673d8` | CI run 43534410772, all five jobs | success; Windows App job `WINDOWS HOST TESTS: PASS (69 checks)` including the 14 interchange checks |
| 2026-11-14 | `2c50802` | CI run 43535723386, all five jobs | success (documentation only; PR #15 head, mergeable) |
| 2026-11-14 | `a43bdeb` | PR #15 checks, all five jobs | success; merged with a merge commit as `223063c` |
| 2026-11-14 | `e36fd94` | PR #16 checks, all five jobs | success; merged with a merge commit as `de96fd6` |
| 2026-11-14 | `c32d344` | CI run 43545230075, Windows App job | `WINDOWS HOST TESTS: PASS (79 checks)`; probe: only camera model and ISO survive, GPS/date/make/exposure/aperture/flash/white-balance/comment dropped, `DateTaken` throws |
| 2026-11-14 | `44a2869` | PR #17 checks, all five jobs | success; merged with a merge commit as `9278d65` |
| 2026-11-14 | `0afcce5` | CI run 43547671904, Windows App job | `WINDOWS HOST TESTS: PASS (86 checks)`; F10 upright 480x720 at luma 115.442 / sd 61.798 against macOS 115.746 / 61.530, identical on the next run; F01 no-op export pixel-identical; merged as `27028d1` |
| 2026-11-14 | `432e443` | CI run 43549524897, Windows App job | probe: F11 decodes as Rgba16 (512x512, 2 097 152 bytes); 16-bit PNG and TIFF encode store 16 bits (IHDR, TIFF `BitsPerSample`); HEIC decode unavailable `0x88982F8B` |
| 2026-11-14 | `bc0514e` | PR #19 checks, all five jobs | success; merged with a merge commit |
| 2026-11-14 | `516f549` | CI run 43553381673, Windows App job | `WINDOWS HOST TESTS: PASS (91 checks)`; against the macOS references: G01 MAE 0.01, G04 MAE 0.007, G09 MAE 5.80, G11 MAE 5.22 |
| 2026-11-14 | `3824b80` | PR #20 checks, all five jobs | success; merged as `1d2673c`; adjustments follow the shared scales |
| 2026-11-14 | `20d3a8c` | CI run 43557855311, Windows App job | `WINDOWS HOST TESTS: PASS (108 checks)`; PNG IHDR and TIFF `BitsPerSample` read back 16; 8-bit source promotes exactly; 16-bit no-op export sample-exact and 8-bit re-decode byte-identical; the 16-bit P3 fixture exports sample-exact; 766 310 of 786 432 colour samples off the 8-bit grid after an adjustment; pipelines drift 1 level (tone/colour) and 2 (clarity, 8-bit blur truncation); a kept 16-bit PNG carries the camera model and nothing outside the allowlist, a stripped one carries neither |
| 2026-11-14 | `20d3a8c` | PR #21 checks, all five jobs | success; merged with a merge commit as `18d4e46` |
| 2026-11-14 | `18d4e46` | CI run 43560222549 (post-merge `main`) | all five jobs green |
| 2026-11-14 | `2488ae4` | CI run 43561151628, Windows App job | MSI 398 086 490 bytes, msi version 0.0.0.0; silent install registered in Programs and Features; the installed copy in `Program Files\Retouch Studio` loaded a window; uninstall left no folder, shortcut or entry |
| 2026-11-14 | `657781b` | CI run 43563787267, Windows App job | 0.0.1.0 installed over an installed 0.0.0.0; one Programs and Features entry with the new version; the upgraded copy loaded a window; the final uninstall left nothing behind |
| 2026-11-14 | `49c3798` | CI run 43566124482, Windows App job | `WINDOWS HOST TESTS: PASS (116 checks)`; a three-file batch exports one result per source as 16-bit PNG, leaves the sources byte-identical, decodes sample-exactly like a single export of the same file, writes `one-retouched-2.png` instead of overwriting a pre-existing `one-retouched.png`, and reports a missing input while the next file still exports; MSI install/upgrade/uninstall path unchanged |
| 2026-11-14 | `93ad90a` | CI run 43567380416 (PR #24 documentation head) | five jobs green on the exact merge head; merged with a merge commit as `42a3b65` |
| 2026-11-14 | `1199210` | CI run 43565828542 (post-merge `main`) | all five jobs green |
| 2026-11-14 | `42a3b65` | CI run 43568795622 (post-merge `main`) | all five jobs green |
| 2026-11-14 | `04defe0` | CI run 43573329343, Windows App job | `WINDOWS HOST TESTS: PASS (118 checks)`; `G11_VIGNETTE: mae 0.473` (was 5.2), rmse 0.688, luma delta −0.4, now gated at one level; a negative vignette leaves every pixel unchanged; the committed oracle reproduces `G11_VIGNETTE.png` byte-for-byte (SHA-256 `af9bebfd…`) |
| 2026-11-14 | `a7d478e6` | CI run 43575818731 (post-merge `main`) | all five jobs green |
| 2026-11-14 | `528c597` | CI run 43576450870, Windows App job | `WINDOWS HOST TESTS: PASS (122 checks)`; `G09_CLARITY_UP: mae 0.06` (was 5.8), rmse 0.246, psnr 60.33 dB, changed 6.5%, luma delta −0.04, now gated at one level; a flat field is untouched by positive clarity, a step edge gains contrast at +100 and loses it at −100; `G11_VIGNETTE` still 0.473; both depths drift 3 levels with clarity on (8-bit pass quantises the pre-clarity picture) |
| 2026-11-14 | `cb9937d` | CI run 43577351736 (PR #27 documentation head) | five jobs green on the exact merge head; merged with a merge commit as `5ce61ca` |
| 2026-11-14 | `5ce61ca` | CI run 43578692160 (post-merge `main`) | all five jobs green |
| 2026-11-14 | `c66cf38` | CI run 43582087464 (attempt 2), Windows App job | `WINDOWS HOST TESTS: PASS (124 checks)`; a Display P3 photo decodes colour-managed to sRGB — four in-gamut points within one level of ColorSync, the saturated cyan within 8 levels (rendering-intent difference) and more than 10 levels from the raw P3 numbers; the 16-bit path agrees within four levels (attempt 1 was cancelled at the 45-minute job timeout while installing the Swift toolchain; nothing failed) |
| 2026-11-14 | `1adafa0` | CI run 43586982825 (PR #29 documentation head) | five jobs green on the exact merge head; merged with a merge commit as `413363f` |
| 2026-11-14 | `413363f` | CI run 43588258162 (post-merge `main`) | all five jobs green |
| 2026-11-14 | `48b8b75` | CI run 43593470894, Windows App job | `WINDOWS HOST TESTS: PASS (131 checks)`; the depth probe reads PNG IHDR and TIFF BitsPerSample (16-bit fixture 16, 8-bit PNG 8, JPEG 8, an exported 16-bit TIFF 16); the 16-bit preview matches the 8-bit preview within one level at rest and 8 levels under a strong adjustment set, gated at 10; an exact-level reduction check pins the BGRA order |
| 2026-11-14 | `6307c09` | CI run 43596432866, all five jobs | success; `Windows App` `PASS (139 checks)`; the crop box fit/resize/move/clamp arithmetic is tested in photo coordinates; merged as `cf3acf9` (PR #33); the overlay drag wiring is not driven by CI |
| 2026-11-14 | `249f4c1` | CI run 43596513201, all five jobs | success; `Windows App` `PASS (133 checks)`; the Swift installer is cached and the job budget raised to 60 minutes (PR #32) |
| 2026-11-14 | `d57aa78` | CI run 43599028784 (post-merge `main`) | all five jobs green |
| 2026-11-14 | `6f65650` | CI run 43598349755, Windows App job | `WINDOWS HOST TESTS: PASS (145 checks)`; a 1600×1067 preview with all nine sliders renders at a median 1187 ms over five runs (1189 1187 1189 1166 1137) and a 16-bit PNG export takes 1594 ms, both under deliberately loose 3 s / 30 s ceilings; forty documents differing by crop, quarter turn, flip, straighten and clarity sign all render, repeat pixel-identically, and never exceed the source area (PR #36) |
| 2026-11-14 | `dd7177f` | CI run 43599860760 (PR #34 head) | five jobs green; `Windows App` `PASS (146 checks)`; a v4 and a v3 project each name all six edits this host cannot render, empty lists and disabled tools name none, and one sticker is enough to warn; the export and batch dialogs ask before writing pixels that lack them, a dialog no CI run drives |
| 2026-11-14 | `dd14310` | CI run 43600764519 (post-merge `main`, PR #34) | all five jobs green |
| 2026-11-14 | `1c3bae1` | CI run 43600876917 (PR #36 head) | five jobs green; `Windows App` `PASS (152 checks)`, the merged count; the measurement printed again at median 1056 ms (1092 1085 1056 1027 1033) and 1368 ms for the 16-bit export, meeting the budgets on a second runner; merged as `3fa6883` |
| 2026-11-14 | `0ab9a4d` | Release run 43598113385 (`workflow_dispatch`) | the four build jobs succeed and publish is skipped because the ref is not a tag; both DMGs, the Windows zip and MSI were downloaded and their checksums, `hdiutil verify`, bundle layout and ad-hoc signature re-verified locally (PR #35) |

That run is the Windows leg of PR #15: all five jobs green on the exact head
commit `d0673d8`, including the macOS Integration and Platform-neutral
Conformance gates. The unknown-key check is proved on the save *after* a reopen,
because the C ABI returns the typed record and carries unknown top-level keys in
the write context (`Sources/StudioCoreABI/ProjectABI.swift`).

## 6. Blockers

| Blocker | Affects | Needed |
|---|---|---|
| No Apple Developer Program membership / Developer ID | notarization, warning-free macOS distribution | owner-provided certificate and notarytool profile |
| No official protocol-v2 AI runtime package | AI install, model download, inference | approved package with URL, size and SHA256 |
| Model weights not in the repository | AI feature verification | owner-approved download |
| Worker source lives outside this repository | helper builds from a fresh clone | keep the external checkout or publish the source |
| No physical Windows machine | interactive Windows verification | CI-only evidence remains the standard |
| No approved face landmark model | W3 on Windows | owner-approved, distributable model and weights |
| WIC exposes no XMP/IPTC write path | metadata parity | a separate XMP packet writer, if the owner wants it |
| WinRT metadata writer drops most EXIF keys | metadata parity | an EXIF rewrite outside WIC, if the owner wants it |
| No HEIF decoder on `windows-2025` | HEIC read on CI | install the HEIF extension or accept the measured gap |
| Windows output is always sRGB, with wide-gamut colours clipped at decode | ICC preservation and wide-gamut rendering | carry the source profile into the render and write, a scoped project of its own |
| Branch protection on `main` requires only `StudioCore Boundary`, `Platform-neutral Conformance` and `macOS Integration` | a Windows regression can merge while `Windows App` or `Windows StudioCore` is red or still running | owner decision: add the Windows contexts to the required set (changing protection needs owner approval) |

## 7. Next actions

1. W4 remaining: ICC preservation on write, wide-gamut rendering and HEIC
   read on CI (no decoder). The decode now converts the source profile to sRGB
   and is proven against ColorSync; a 16-bit source previews at 16-bit
   precision. The vignette (MAE 0.47) and clarity (MAE 0.06) now follow measured
   Core Image behaviour in both depths. None of the remaining items is claimed
   until tested.
2. W3 on Windows is BLOCKED on an approved, distributable landmark model.
   The in-box detector gives boxes only, which cannot drive masks.
3. W5: only after an approved runtime package exists.
4. W6: the Windows MSI exists and CI proves install, start, in-place upgrade
   and uninstall; what remains is an updater, which needs a signed feed first.
5. Notarization stays BLOCKED until credentials exist; never simulate it.

## 8. Execution rules (owner directive, 2026-11-14)

These govern how this plan is carried out; they supersede any habit of idling
on CI.

1. CI never blocks the workstream. While a run is in flight, the next
   independent task starts; status checks are quick reads (30–60 s), never
   multi-minute sleeps.
2. Documentation rides in the active workstream. No documentation-only pull
   requests are opened just to record a merge; the record is updated in the
   workstream's own changes before its final validation run.
3. No CI run is started for documentation-only or intermediate commits when an
   existing run already validates the change. CI is the hard gate at the merge
   boundary, and required checks are never bypassed.
4. A prioritized queue of independent tasks is kept; when a task waits on an
   external process, the queue moves.
5. Slow jobs are fixed, not endured: the Windows Swift toolchain download now
   runs with the setup action's cache enabled and the app job has a 60-minute
   budget, after one run was cancelled at the old 45-minute timeout during
   installation.
6. Green checks are a checkpoint, not a stopping point; implementation
   continues automatically.
