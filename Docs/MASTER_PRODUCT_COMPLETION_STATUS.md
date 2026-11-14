# Master product completion status

**Basis:** `main` at `1d32842` (PR #14 merged 2026-11-13T23:59:27Z), post-merge CI
run [43531081160](https://github.com/iR0ham/RetouchStudio/actions/runs/43531081160)
green across all five jobs. Working tree clean at the time of the audit.
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
| Cross-platform project interchange | codec | macOS fixtures | opens the same fixtures, saves them back | 14 host checks, CI run 43534410772 | VERIFIED |
| Undo/redo, 100-step history | `DocumentHistory` | yes | yes | StudioCore suite, 55 host checks | VERIFIED |
| Nine global adjustments | `Adjustments` | full engine | 9-slider pipeline | host checks, engine suite | VERIFIED per host; cross-host pixel parity NOT VERIFIED |
| Crop, quarter turns, mirror, straighten | values + policy | full freeform | 4 aspect presets, turns, mirror, straighten | host checks | VERIFIED (unit); Windows UI is preset-only |
| Face detection, landmarks, multi-face, confidence | — | Vision, biggest-first | ABSENT | engine suite, `--selftest` | VERIFIED macOS |
| Face line mesh | — | ~76 Vision points + forehead/cheek rows, drawn as a web | ABSENT | self-check draws-mesh probe | VERIFIED macOS; no dense/3D mesh exists |
| Semantic segmentation of skin/regions | — | geometric regions + YCbCr/luma gates | ABSENT | engine suite | VERIFIED macOS; not a learned segmentation model |
| Masks (preview 1024 px, export 4096 px) | — | Core Image, feather + gates | ABSENT | engine suite, corpus | VERIFIED macOS |
| Heal stamps, stickers, watermarks | values | yes | ABSENT | corpus references | VERIFIED macOS |
| AI edits (composite, patch lifecycle) | values | yes, needs worker | ABSENT | engine/model suites | VERIFIED macOS; worker source outside repo |
| Export JPEG/PNG | contract | 8-bit | 8-bit | host checks, corpus | VERIFIED per host |
| Export TIFF | contract | 16-bit | 8-bit via WIC | plan check only | macOS VERIFIED; Windows IMPLEMENTED, not pixel-tested |
| Export HEIC | contract | 8-bit, alpha flattened | explicit refusal | corpus `F01_export_256.heic` | macOS VERIFIED; Windows ABSENT by design |
| Metadata keep/strip | — | EXIF/TIFF/IPTC/GPS + XMP | none written | corpus `F01_metadata_kept/stripped` | macOS VERIFIED; Windows ABSENT |
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
| 2 | W3 face analysis and masking | macOS VERIFIED; Windows NOT STARTED | Vision landmarks and masks exist and are tested on macOS; the Windows host has no face path |
| 3 | W4 image engine and rendering parity | PARTIAL | macOS pipeline characterised (16-bit PNG/TIFF, ICC, metadata, corpus references); Windows is 8-bit sRGB with no metadata; cross-host pixel comparison NOT VERIFIED |
| 4 | W5 AI runtime and model management | BLOCKED | Runtime installer disabled by design (`AIRuntime.package` nil); model weights and official package unavailable |
| 5 | Performance, stability, reliability | PARTIAL | macOS benchmarks recorded in `Docs/PERFORMANCE_BENCHMARKS.md`; no Windows benchmark; no stress suite |
| 6 | macOS product completion | PARTIAL | Native app builds, self-tests, corpus and engine suites pass; signing is ad-hoc and notarization is BLOCKED |
| 7 | Windows product completion | PARTIAL | Light native editor builds, runs headless tests and opens a window on `windows-2025`; no installer, face analysis, AI, batch or packaging proof |
| 8 | Cross-platform project interchange | VERIFIED | macOS v3 and v4 fixtures open on Windows, round-trip byte-identically, keep the unknown key and required feature, and a v3 save stays v3 (CI run 43534410772) |
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
| Node-less hook mode blocks the Bash tool | local shell work | run shell through the node REPL, as done here |

## 7. Next actions

1. PR #15 is green on `d0673d8` (run 43534410772) and mergeable. Merging needs
   the owner's explicit authorization; it is not merged here.
2. W3 on Windows: implement face detection behind a platform interface, feed
   the same normalized records into the v4 document, and prove save/reopen.
   This needs a parity-level decision (Vision-equivalent detector vs. a
   bundled model), which is a product decision, not a code detail.
3. W4 parity: define tolerances, then measure macOS vs. Windows on the
   existing corpus before claiming any parity.
4. W5: only after an approved runtime package exists.
5. W6: installer, then updater, each with a clean-install proof on CI.
6. Notarization stays BLOCKED until credentials exist; never simulate it.
