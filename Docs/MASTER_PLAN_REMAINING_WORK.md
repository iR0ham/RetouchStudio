# Master plan remaining work

**Basis:** `main` at `4a034cd` (PR #48 merge), 2026-11-14. This queue is derived
from [`ORIGINAL_MASTER_PLAN.md`](ORIGINAL_MASTER_PLAN.md) and the evidence in
[`MASTER_PRODUCT_COMPLETION_STATUS.md`](MASTER_PRODUCT_COMPLETION_STATUS.md).
It is not a substitute for the verification ledger: a row here without a ledger
entry is not verified.

Status vocabulary follows the plan: VERIFIED, IMPLEMENTED, PARTIALLY
IMPLEMENTED, NOT IMPLEMENTED, FAILED, BLOCKED, NOT VERIFIED, NOT APPLICABLE.

**Workflow (2026-11-14 steering):** development is GitHub-based and
milestone-driven, per [`WORKFLOW.md`](WORKFLOW.md). Work is pushed continuously
to organized development branches and folded into the shared `develop`
integration branch; the full five-context matrix runs at a milestone (dispatch
on `develop` or the milestone branch, then the milestone PR). Implementation,
tests and documentation of one milestone share a single PR; routine changes and
documentation-only changes do not get their own PR. Rows below keep their old
evidence links, which remain valid history.

**Current integration state:** the W4 metadata workstream — crash recovery,
batch cancellation, EXIF/XMP carry, the sRGB export declaration and the
crop/turn/resize read-back checks — is merged into `main` as `4e31596` (PR #54)
after five green checks on `91dde65` (run 43632188008). The UI-automation
workstream landed on `windows/ui-automation` (`bb06e28`, green run
43647604771) and is merged into `develop` as `7af20f2`: the Windows harness now
drives the golden path (window → Open Photo dialog → Exposure slider → 150%
zoom → Export dialog → typed path → decoded JPEG) and the launch recovery
prompt. On 2026-11-15 the branches were reconciled: `main` at `df289cf` was
merged into `develop` at `63fdbd3` as `00a48d6`. The three commits `main` held
that `develop` did not are merge commits with an empty net diff, so the merged
tree equals the pre-merge develop tree; five checks are green on `develop` in
run 43660568463. The same day, JPEG exports gained the source IPTC resource
(`windows/iptc-carry`, `04dac17`, green run 43663201459, 268 checks), and a
source with no EXIF block to splice gained a composed one
(`windows/exif-compose`, `431783b`, green run 43671478242, 283 checks).
The same day the chosen face learned to follow its person across a crop
(`windows/face-identity`, `26c59be`, green run 43685429036), and the Windows
UI harness grew to eleven scenarios (`windows/zoom-pan-ui`, `0c88498`, green
run 43696215085, 283 checks): pointer zoom and pan, a cancelled batch of 64,
open and export error reports, and the decline half of the launch prompt.
Both are merged into `develop` as `ca637ee`.
The next milestone PR carries that work plus these documents.

## Delivery infrastructure (completed in the 2026-11-14 batch)

| ID | Item | Status | Evidence |
|---|---|---|---|
| D-1 | All five checks required on `main` (Windows included) | VERIFIED | protection API read-back, `CI_GATES.md` |
| D-2 | Duplicate post-merge matrix on `main` removed; full gate once per candidate | VERIFIED in configuration | `.github/workflows/ci.yml`, `CI_GATES.md` cadence section; first merges to use it are the next workstream PRs |
| D-3 | Status, plan, audit and acceptance documents reconciled and created | VERIFIED as documents | this batch on `main` after merge |

## WS-1 — W4 image engine on Windows (next milestone)

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| W4-1 | Metadata keep-safe / strip / allowlist for JPEG, TIFF, 16-bit PNG | TESTED (camera model + ISO, resolution; EXIF/XMP carry read back after crop, quarter turn and resize; a JPEG also carries the source IPTC resource byte for byte, run 43663201459) | TIFF keeps only the WinRT allowlist; PNG and TIFF carry no IPTC; unsupported keys are documented in `WINDOWS_FORMAT_AUDIT.md` | none |
| W4-2 | XMP write, IPTC write | Carry IMPLEMENTED for macOS parity (JPEG IPTC, EXIF/XMP in JPEG and PNG; macOS also only carries); composing new records NOT IMPLEMENTED | a source with no splice-able block (TIFF, HEIC) still loses these records; composing them needs a writer because WIC exposes no write path | library choice (Lead decision), licence review |
| W4-3 | Full EXIF rewrite (GPS, date, exposure, lens) | IMPLEMENTED for sources a decoder can describe (composed EXIF, run 43671478242): a TIFF source exports make, model, capture time, exposure, aperture, ISO, flash, focal length, white balance and lens, rewritten to the written frame and upright | WIC's WinRT properties report no GPS, so a composed block carries no position in practice (a macOS ImageIO control JPEG reads the same absent), and tags WIC does not decode are not composed; carried EXIF still travels whole for JPEG/PNG sources | none for the composed path; a new field needs a decoder that reports it |
| W4-4 | ICC preservation on write / wide-gamut output | DECIDED 2026-11-15 (Option A: sRGB for 1.0) — `Docs/OUTPUT_COLOR_POLICY.md` | Implemented: `RenderPolicy.plan` names sRGB for every export, macOS converts a wide-gamut source and leaves an sRGB source byte-identical, and only `F11_export_256.png` was renewed with the owner's authorisation; wide-gamut clipping and the untagged Windows TIFF are documented limits | carrying wide gamut remains a future feature with its own fixtures |
| W4-5 | HEIC read on CI | BLOCKED | no HEIF decoder on `windows-2025` (`0x88982F8B`) | install the HEIF extension or accept and document the gap |
| W4-6 | Format audit document (import, decode, orientation, colour, metadata, bit depth, export, batch) | DONE as a document (`Docs/WINDOWS_FORMAT_AUDIT.md`) | records the gaps it cannot close: HEIC needs the optional codec, RAW is absent, TIFF is untagged | none |
| W4-7 | RenderPlan consumed end to end (dimensions, depth, alpha, profile, compression, quality, metadata, orientation) | PARTIAL | dimensions, depth, alpha, orientation, quality, the strip policy and the sRGB output profile are honoured; pass-through of a source profile is explicitly out of 1.0 (W4-4 Option A) | none |
| W4-8 | Deterministic cross-host corpus comparisons (MAE, max error, SSIM, colour difference) | IMPLEMENTED locally 2026-11-15 (Option A, additive); Windows evidence runs on CI | `F13_GEOMETRY_GRID` plus `Q01`–`Q07` and `baselines.geometry.v1.json` were added without touching `baselines.json` or any existing fixture/reference; macOS harness is `428 checks, 0 failures`; Windows `GeometryEvidence()` gates crop/mirror at MAE 0 and prints interpolation MAE/PSNR. Straighten interpolation has **no approved numeric tolerance** — pending owner decision if a gate is wanted. Adjustment comparisons unchanged (exposure 0.01, levels 0.007, clarity 0.06, vignette 0.47 MAE) | none for the measurement; owner decision for an interpolation tolerance |

**Backlog correction (2026-11-15, read-only audit).** The Windows request builder's
hardcoded `includeStamps`/`includeAnalysis`/`aiUpscale` = false and `faceCount` = 0
are correct-by-design, not gaps: the host has no heal/sticker renderer
(`ExportRunner.cs:20`), no analysis or face model, and no upscaler toggle; projects
carrying those edits are named and confirmed before export (`DocumentModel.cs:221,233`,
`MainWindow.xaml.cs:874`), and the 4096 long edge behaves identically because macOS
also refuses to enlarge with upscale off (`RenderPolicy.swift:69`). Latent, not
fixed: a batch request copies `aiEdits` where macOS clears them per file
(`BatchRenderPolicy.swift:45`), invisible while the plan never reads `aiEdits`.

## WS-2 — W3 face analysis and masks

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| W3-1 | macOS face detection, landmarks, regions, masks | VERIFIED | preserve; no dense mesh or learned segmentation claims | none |
| W3-2 | Portable face/mask contract (IDs, landmarks, masks, transforms, versioning) | PARTIAL | v4 schema can carry analysis records; stable per-face IDs and mask persistence are absent on macOS too | shared-contract design |
| W3-3 | Windows detection and landmarks | ABSENT | needs a distributable landmark model; in-box `Windows.Media.FaceAnalysis` returns boxes only | model and weights choice — a measured Lead decision under plan §5 |
| W3-4 | Windows masks, edit, persistence, export consumption | ABSENT | follows W3-3 | W3-3 |
| W3-5 | Orientation transform consistency (top-left canonical vs stored bottom-left) | PARTIAL | documented inconsistency on macOS; resolve with the contract work | W3-2 |

## WS-3 — Windows product workflows and parity

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| WP-1 | Import, preview, adjustments, crop, rotation, mirror, straighten | TESTED headless; the golden path is driven through UIA (Open Photo dialog, all nine global sliders, zoom buttons, Export dialog writing a decoded JPEG) in runs 43647604771 and 43659238621, the crop overlay's corner drag with injected pointer input (512×512 to 449×472) in run 43681175327, and the open/export failure reports (corrupt photo, destination held by another process) in run 43696215085 | none for the interactions listed; drop-to-open is driven by a helper WPF drag source with injected input (run 43712286626 on `89c9683`) | extend the harness per interaction |
| WP-2 | Zoom, pan, compare split, peek | TESTED (arithmetic); the Fit/Zoom in buttons reach Fit and 150% through UIA (run 43647604771); pointer zoom takes the dock to 150%, a 70-pixel drag pans the canvas without changing the zoom, and Fit restores the opening view within 0.2% of sampled pixels (run 43696215085); the compare divider is turned on by a pointer click, dragged 80 px right and back within 6 px, and removed on the second click (run 43681175327) | the peek modifier is not driven by CI | as WP-1 |
| WP-3 | Drop-to-open photo or project | TESTED (UI, photo) | the harness starts a real WPF drag from a helper window and OLE ends it on the injected button-up over the canvas with `DROPEFFECT_COPY`; the dropped photo opens and its export decodes at the source size (run 43712286626 on `89c9683`, from `Tools/build-windows.ps1` on `windows-2025`). A dropped project, a physical mouse and drag-out are not covered | none |
| WP-4 | Batch export (planning, collisions, progress, cancellation, failure isolation) | TESTED headless (sample-exact, collision-safe, per-file failure); a one-photo batch runs from the UI through the photo and folder pickers and writes a decoded file (run 43655814761); a 64-source batch reports `Exported 9 of 64…`, Cancel stops it between files (`Export cancelled after 10 of 64 photos.`) and the destination holds exactly those ten files (run 43696215085); a cancel inside the file in flight is honoured after decode, after render and after encode, before the publish, and leaves no temp sibling and an intact destination (8-bit and 16-bit, run 43736047883); the Cancel Export button itself is clicked through UIA on a 4000×3000 16-bit photo — it is disabled while idle, enabled once the export runs, and the click yields `Export cancelled.` with no destination and no temp sibling (run 43758837302) | the codec encode itself is not interruptible; per-file failure isolation is headless only | extend the harness |
| WP-5 | Project lifecycle, undo/redo, save/reopen, recovery | TESTED headless and driven through UIA: Open Project with a codec-saved project (run 43653664500), Save Project through its dialog, Undo and Redo on the slider (run 43654765580), a fresh-process reopen keeping Exposure 40 (run 43658018867), the launch recovery prompt (run 43647604771), and the decline answer that leaves an empty editor with nothing offered on the next launch (run 43696215085); a refused save (held file, directory target) and its retry are proven headlessly and leave the earlier project and the dirty flag intact, and a restore that cannot write re-locks the slot instead of exposing it to the next autosave (run 43736047883), and a corrupt project and a save onto a held file are driven through their dialogs and leave the previous photo and the held bytes intact (run 43736047883); closing the window while an export runs asks the unsaved-work question first and, on Yes, cancels, unwinds and exits with code 0 with no destination and no temp sibling (run 43758837302) | an unreadable project is not driven with an empty editor | none |
| WP-6 | AI edits on Windows | NOT APPLICABLE until a runtime exists | blocked with W5 | W5 |

## WS-4 — W5 AI runtime

**2026-11-16 note (additive).** The rows below stay the current-state record
and their statuses do not change. The owner made Windows a first-class AI
platform from the start of W5; the W5 plan is now
[`W5_ROADMAP.md`](W5_ROADMAP.md), with the contract freeze in
[`W5_IMPLEMENTATION_DECISION_RECORD.md`](W5_IMPLEMENTATION_DECISION_RECORD.md)
and the resolved conflicts in
[`AI_11_MULTI_PLATFORM_ADDENDUM.md`](AI_11_MULTI_PLATFORM_ADDENDUM.md). The
delivery queue at the end of this file remains the operative order until W5-0
receives final owner approval; A1/A2 was approved on 2026-11-16 and is
recorded in the addendum §4.

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| W5-1 | Approved runtime package, packaging/versioning | BLOCKED | `AIRuntime.package` is nil by design; no approved protocol-v2 package | owner-approved package URL, size, SHA-256 |
| W5-2 | Model discovery, download, checksum, install, load, inference, cancellation, recovery | IMPLEMENTED infrastructure only; real inference BLOCKED | test doubles exist for infrastructure tests; real weights absent | W5-1 and model licences |
| W5-3 | Worker source in the repository or reproducible dependency | BLOCKED | worker source lives outside the repository; regression corpus preserved in `Docs/worker-regressions` | owner decision to publish or vendor |
| W5-4 | DirectML / Core ML provider integration | NOT IMPLEMENTED | evaluate after W5-1 | W5-1 |

## WS-5 — Reliability, performance, recovery

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| R-1 | Windows preview/export performance | MEASURED (median 721 ms preview, 1189 ms 16-bit export, run 43618132157) | environment-specific; no universal claim | none |
| R-2 | Windows start-up to first window | MEASURED, recorded not gated | plain numbers per run; noise expected | none |
| R-3 | Managed heap across twenty renders | MEASURED flat, gated at 150 MB | longer sessions NOT VERIFIED | none |
| R-4 | Native working-set / decoder buffers | MEASURED on CI (`64b4008`, line in run 43631106819): 300 MB working set, 328 MB peak after sixty renders | decoder-buffer accounting by format is not split out; the `windows/memory-perf` branch is superseded | none |
| R-5 | Interrupted saves, disk full, crash during processing, shutdown recovery | TESTED on Windows for the crash path, and for refused writes, removals and lifts on both hosts: a held project, a directory target and a retried save keep the earlier file; an unresolved working slot is never overwritten by an autosave, and a restore that cannot write re-locks it (run 43736047883); a folder whose ACE denies this process refuses the export with the OS's own `UnauthorizedAccessException`, leaving no destination (`714b142`) | removals, quarantine and lift failures are injected rather than produced by the OS; disk-full is not exercised; a session end (logoff or shutdown) is wired to cancel the work and flush the commit but is not executed by CI; a crash between a temp write and its replace is simulated by leaving the temp, not by killing the process | none |
| R-6 | Cancellation races in export/batch | TESTED at the stage boundaries (run 43736047883): Windows cancels after decode, after render and after encode with no temp and no damaged destination; macOS cancels at the commit point and keeps an existing destination; a batch and a single export exclude each other; the UI Cancel Export button raises the cancel, and a close during an export asks before cancelling, unwinds and exits with no destination and no temp (run 43758837302) | the encode itself is not interruptible; a close during an export waits up to 20 s for the work to unwind before closing, and a cancel that arrives in that window still publishes nothing | none |

## WS-6 — Distribution and update

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| DS-1 | Windows MSI install/upgrade/uninstall | VERIFIED on CI | keep the CI path green | none |
| DS-2 | Windows updater and update feed | NOT IMPLEMENTED | design signed metadata, download verification, rollback, test channels | signing; no public feed without authorization |
| DS-3 | macOS DMG build | VERIFIED locally and on a release dry run | clean-machine install NOT VERIFIED | none |
| DS-4 | Developer ID signing, notarization, stapling, Gatekeeper | BLOCKED | pipeline prepared; credentials unavailable | owner Apple Developer membership |
| DS-5 | Tag release publishing | REPAIRED, NOT VERIFIED | a tag used to skip its Release because `release` inherited the `windows-app` skip; the job now uses `always()` with explicit results, `-PackageVersion` stamps the published assembly, and `Tools/check-versions.sh` fails a tag that disagrees with Info.plist and Directory.Build.props. Only a real tag can prove the paths, so they stay unverified; a `workflow_dispatch` dry run built and uploaded artifacts without publishing | owner authorization for a release or a throwaway tag |

## WS-7 — Cross-platform acceptance

| ID | Item | Current status | Remaining work |
|---|---|---|---|
| X-1 | Project interchange (v3/v4, unknown keys, feature records) | VERIFIED | keep in the regression set |
| X-2 | Rendering parity for global adjustments | PARTIAL | straighten/crop need a cross-host pixel reference (owner-approved fixture) |
| X-3 | Feature-data parity (crop, analysis, masks, heal, stickers, AI records) | PARTIAL | shared records exist; Windows cannot render several of them and names them before export |
| X-4 | Metadata and colour parity across hosts | PARTIAL | Windows always writes sRGB; XMP/IPTC absent |
| X-5 | Recovery parity | TESTED per host (same observable rules: one working slot, immutable candidates, quarantine, restore write→verify→delete, monotonic savedAt, source identity) | the rules are reimplemented in C# rather than shared through the C ABI, so parity is proven by matching checks, not by shared code |

## Blockers (unchanged unless noted)

| Blocker | Affects | Needed |
|---|---|---|
| No Apple Developer membership | notarization, warning-free macOS distribution | owner credentials |
| No approved AI runtime package or weights | W5 real inference | owner approval |
| Worker source outside the repository | fresh-clone AI builds | publish or vendor |
| No approved face-landmark model | W3 on Windows | a measured Lead decision on a distributable model |
| No HEIF decoder on `windows-2025` | HEIC read on CI | CI image change or documented gap |
| No physical Windows machine | interactive UI acceptance | CI-only evidence remains the standard |
| Golden corpus may not be regenerated | cross-host straighten/crop pixel reference | owner-approved fixtures |

## Owner decisions needed (WS-1)

Product decisions, not engineering choices. Each states what the code does now,
the options and their impact. Work that does not depend on them continues.

| Decision | Options | Impact | Current behaviour / recommendation |
|---|---|---|---|
| W4-4 — output colour space (**DECIDED 2026-11-15: A**) | (A) keep sRGB output for 1.0; (B) pass the source profile through to the render and the written file; (C) target Display P3 for every export | (B) and (C) change every exported pixel for a wide-gamut source, change the preview/render comparison and the cross-host corpus references, and need a P3 fixture set; (A) keeps today's comparable output | Approved: sRGB for every export on both hosts, profile declared in JPEG and PNG, out-of-gamut colours clip, no pass-through in 1.0 (`Docs/OUTPUT_COLOR_POLICY.md`); P3 remains a next-milestone feature with its own fixtures |
| W4-5 — HEIC on Windows CI | (A) accept and document the gap; (B) install the HEIF extension in the CI job; (C) vendor a third-party decoder | (B) adds a network dependency and licence acceptance to every Windows run; (C) adds a licence and patent review; (A) leaves HEIC read unverified on CI | no decoder on `windows-2025` (`0x88982F8B`). Recommendation: (A) now, revisit if HEIC import becomes a requirement |
| W4-2 — composing XMP/IPTC and vendor blocks | (A) stay carry-only, as macOS does; (B) adopt a metadata-writing library and compose new records | (B) adds a library choice, licence review and a new source of writes for records no current feature edits; (A) matches the macOS host | carry-only. Recommendation: (A) unless an editing feature must set those fields |
| W4-8 — straighten/crop cross-host reference (**DECIDED 2026-11-15: A**, implemented) | (A) add owner-approved fixtures and references; (B) keep the current adjustment-only comparison | (A) grows the golden corpus, which is otherwise frozen; (B) leaves straighten/crop compared by arithmetic, not by pixels across hosts | Approved and implemented additively: `F13_GEOMETRY_GRID`, `Q01`–`Q07`, versioned `baselines.geometry.v1.json`; existing fixtures byte-identical. Crop/mirror are exact cross-host gates; straighten interpolation is measured with no numeric tolerance — that bound is the remaining owner decision |

## Queue order

1. Close WS-1 (W4): the metadata and format-audit work is done, W4-4 is
   decided and implemented as sRGB for 1.0, and the additive W4-8 corpus
   extension is implemented on macOS and waiting for its Windows CI run
   (profile pass-through is out of 1.0).
2. WS-3 items that are verifiable without a UI harness (crash recovery,
   project lifecycle).
3. WS-2 after the landmark-model decision (a measured Lead decision).
4. WS-5 R-4 and R-5 inside the reliability batch.
5. WS-6 after a signing decision.
6. WS-4 only when the runtime package exists.
