# Master product completion status

**Basis:** `main` at PR #20 (`1d2673c`, merged 2026-11-14). PR #21 (16-bit
export) is verified by CI run
[43557855311](https://github.com/iR0ham/RetouchStudio/actions/runs/43557855311),
green across all five jobs. The original audit ran on `1d32842` (CI run
43531081160, also green).
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
| Undo/redo, 100-step history | `DocumentHistory` | yes | yes | StudioCore suite, 55 host checks | VERIFIED |
| Nine global adjustments | `Adjustments` | full engine | 9-slider pipeline | host checks; G-case metrics vs macOS references | VERIFIED per host; exposure/levels aligned (MAE 0.01 / 0.007), clarity and vignette still differ (MAE 5.8 / 5.2); cross-host parity NOT VERIFIED |
| Crop, quarter turns, mirror, straighten | values + policy | full freeform | 4 aspect presets, turns, mirror, straighten | host checks | VERIFIED (unit); Windows UI is preset-only |
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
| 16-bit pixels | — | PNG/TIFF source and output | PNG/TIFF export decodes and writes 16 bits; preview and JPEG stay 8-bit | host checks, run 43557855311 | macOS VERIFIED; Windows VERIFIED for PNG/TIFF export; 16-bit preview NOT IMPLEMENTED |
| HEIC decode | — | ImageIO | no decoder on `windows-2025` (probe fails `0x88982F8B`) | format probe, run 43549524897 | macOS VERIFIED; Windows NOT AVAILABLE on CI |
| Metadata keep/strip | — | EXIF/TIFF/IPTC/GPS + XMP | camera model + ISO when kept in JPEG, TIFF and 16-bit PNG; resolution always; no XMP/IPTC | Windows host tests, runs 43545230075, 43557855311 | macOS VERIFIED; Windows TESTED (measured allowlist) |
| ICC handling | — | source profile carried to render/write | always sRGB | corpus F11 P3 | macOS VERIFIED; Windows simplified to sRGB |
| Batch export | planner | yes | ABSENT | planner suite | VERIFIED macOS |
| AI runtime install | `AIRuntime` | disabled (`package == nil`) | ABSENT | runtime v2 suites | BLOCKED — no approved package |
| Signed update feed | `UpdatePolicy` | prepared, no feed shipped | ABSENT | update tests | IMPLEMENTED, not published |
| macOS packaging + DMG | — | per-arch, ad-hoc signed | — | `Tools/make-dmg.sh` | VERIFIED locally; clean-machine install NOT VERIFIED |
| Windows packaging | — | — | `Tools/package-windows.ps1` | none | NOT VERIFIED |
| Windows installer/updater | — | — | ABSENT | — | NOT STARTED |
| Notarization | — | pipeline ready | — | — | BLOCKED — no Apple Developer membership |
| CI matrix | — | 3 required + Windows core | `windows-2025` app job | §5 | VERIFIED |

## 3. Phase status

| Phase | Scope | Status | Evidence / gap |
|---|---|---|---|
| 0 | Baseline and gap analysis | VERIFIED | This document; `main` `1d32842`; run 43531081160 |
| 1 | Shared core and portable project architecture | VERIFIED | StudioCore boundary suite, conformance gate, R2–R4.8 docs |
| 2 | W3 face analysis and masking | macOS VERIFIED; Windows BLOCKED | Vision landmarks and masks exist and are tested on macOS; the Windows host has no face path, and its only in-box detector returns boxes without landmarks, so a distributable landmark model must be chosen |
| 3 | W4 image engine and rendering parity | PARTIAL | macOS pipeline characterised (16-bit PNG/TIFF, ICC, metadata, corpus references); Windows exports 16-bit PNG/TIFF sample-exactly (run 43557855311) but previews and JPEG exports in 8-bit sRGB, with tested metadata keep/strip, upright orientation, alpha, an exact no-op and exposure/levels that match the macOS references (MAE 0.01 / 0.007); clarity and vignette still differ (MAE 5.8 / 5.2); ICC preservation and HEIC read are absent, the missing HEIF decoder measured; full cross-host parity NOT VERIFIED |
| 4 | W5 AI runtime and model management | BLOCKED | Runtime installer disabled by design (`AIRuntime.package` nil); model weights and official package unavailable |
| 5 | Performance, stability, reliability | PARTIAL | macOS benchmarks recorded in `Docs/PERFORMANCE_BENCHMARKS.md`; no Windows benchmark; no stress suite |
| 6 | macOS product completion | PARTIAL | Native app builds, self-tests, corpus and engine suites pass; signing is ad-hoc and notarization is BLOCKED |
| 7 | Windows product completion | PARTIAL | Light native editor builds, runs 108 headless checks and opens a window on `windows-2025`, with verified 16-bit PNG/TIFF export; no installer, face analysis, AI, batch or packaging proof |
| 8 | Cross-platform project interchange | VERIFIED | macOS v3 and v4 fixtures open on Windows, round-trip with structurally identical JSON, keep the unknown key and required feature, and a v3 save stays v3 (CI run 43534410772) |
| 9 | Distribution, installers, updates | NOT STARTED | macOS DMGs exist; Windows installer absent; no update feed published |
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
| 2026-11-14 | `20d3a8c` | PR #21 checks, all five jobs | success; merge pending owner-authorized merge commit |

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
| Windows output is always sRGB | ICC preservation | carry the source profile into the render and write, a scoped project of its own |

## 7. Next actions

1. W4 remaining: ICC preservation, HEIC read on CI (no decoder), batch export,
   a 16-bit preview, and closer clarity/vignette parity with the macOS
   references. None of these is claimed until tested.
2. W3 on Windows is BLOCKED on an approved, distributable landmark model.
   The in-box detector gives boxes only, which cannot drive masks.
3. W5: only after an approved runtime package exists.
4. W6: installer, then updater, each with a clean-install proof on CI.
5. Notarization stays BLOCKED until credentials exist; never simulate it.
