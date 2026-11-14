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

**Current integration state:** `develop` folds the W4 metadata workstream —
batch cancellation, EXIF/XMP carry, the sRGB export declaration and the
crop/turn/resize read-back checks — pending full-matrix validation.

## Delivery infrastructure (completed in the 2026-11-14 batch)

| ID | Item | Status | Evidence |
|---|---|---|---|
| D-1 | All five checks required on `main` (Windows included) | VERIFIED | protection API read-back, `CI_GATES.md` |
| D-2 | Duplicate post-merge matrix on `main` removed; full gate once per candidate | VERIFIED in configuration | `.github/workflows/ci.yml`, `CI_GATES.md` cadence section; first merges to use it are the next workstream PRs |
| D-3 | Status, plan, audit and acceptance documents reconciled and created | VERIFIED as documents | this batch on `main` after merge |

## WS-1 — W4 image engine on Windows (next milestone)

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| W4-1 | Metadata keep-safe / strip / allowlist for JPEG, TIFF, 16-bit PNG | TESTED (camera model + ISO, resolution) | verify read-back after crop/rotate/resize and after colour conversion; document unsupported keys | none |
| W4-2 | XMP write, IPTC write | NOT IMPLEMENTED | evaluate a distributable XMP packet writer; WIC exposes no write path | library choice (Lead decision), licence review |
| W4-3 | Full EXIF rewrite (GPS, date, exposure, lens) | NOT IMPLEMENTED | WIC drops most keys; needs an EXIF writer outside WIC | library choice (Lead decision) |
| W4-4 | ICC preservation on write / wide-gamut output | NOT IMPLEMENTED | source profile is converted to sRGB on decode and clipped; carry the profile through render and write | scoped project; owner-visible colour trade-off |
| W4-5 | HEIC read on CI | BLOCKED | no HEIF decoder on `windows-2025` (`0x88982F8B`) | install the HEIF extension or accept and document the gap |
| W4-6 | Format audit document (import, decode, orientation, colour, metadata, bit depth, export, batch) | PARTIAL | JPEG/PNG/TIFF per host verified; HEIC macOS only; RAW absent | follows W4-1…W4-5 |
| W4-7 | RenderPlan consumed end to end (dimensions, depth, alpha, profile, compression, quality, metadata, orientation) | PARTIAL | dimensions/depth/alpha/orientation/quality verified; profile and metadata policy are fixed, not passed through | W4-1, W4-4 |
| W4-8 | Deterministic cross-host corpus comparisons (MAE, max error, SSIM, colour difference) | PARTIAL | adjustments compared to macOS references (exposure 0.01, levels 0.007, clarity 0.06, vignette 0.47 MAE); straighten/crop lacks a cross-host pixel reference | golden-corpus fixture needs owner approval |

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
| WP-1 | Import, preview, adjustments, crop, rotation, mirror, straighten | TESTED headless; UI wiring NOT VERIFIED | CI does not drive the crop overlay drag, sliders by pointer, or dialogs | interactive harness is outside current CI; keep the limitation explicit |
| WP-2 | Zoom, pan, compare split, peek | TESTED (arithmetic); UI wiring NOT VERIFIED | divider drag and pointer wiring not driven by CI | as WP-1 |
| WP-3 | Drop-to-open photo or project | IMPLEMENTED; UI wiring NOT VERIFIED | the drop handler is compiled and reviewed, not exercised by CI | as WP-1 |
| WP-4 | Batch export (planning, collisions, progress, cancellation, failure isolation) | TESTED headless (sample-exact, collision-safe, per-file failure) | progress/cancel UI NOT VERIFIED; cancellation during a running batch is not exercised | UI harness |
| WP-5 | Project lifecycle, undo/redo, save/reopen, recovery | PARTIAL | save/reopen and undo tested; Windows crash recovery is not recorded in the ledger | recovery workstream |
| WP-6 | AI edits on Windows | NOT APPLICABLE until a runtime exists | blocked with W5 | W5 |

## WS-4 — W5 AI runtime

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
| R-4 | Native working-set / decoder buffers | MEASUREMENT EXISTS ONLY ON THE UNPUSHED LOCAL BRANCH `windows/memory-perf` (`3e00182`) | review and integrate under a workstream, or re-implement | workstream decision |
| R-5 | Interrupted saves, disk full, crash during processing, shutdown recovery | NOT VERIFIED on Windows | recovery tests need a scoped batch | WP-5 |
| R-6 | Cancellation races in export/batch | PARTIAL | per-file failure isolation tested; cancellation mid-render not exercised | UI/harness |

## WS-6 — Distribution and update

| ID | Item | Current status | Remaining work | Dependency |
|---|---|---|---|---|
| DS-1 | Windows MSI install/upgrade/uninstall | VERIFIED on CI | keep the CI path green | none |
| DS-2 | Windows updater and update feed | NOT IMPLEMENTED | design signed metadata, download verification, rollback, test channels | signing; no public feed without authorization |
| DS-3 | macOS DMG build | VERIFIED locally and on a release dry run | clean-machine install NOT VERIFIED | none |
| DS-4 | Developer ID signing, notarization, stapling, Gatekeeper | BLOCKED | pipeline prepared; credentials unavailable | owner Apple Developer membership |
| DS-5 | Tag release publishing | NOT VERIFIED | a `workflow_dispatch` dry run built and uploaded artifacts without publishing | owner authorization for a release |

## WS-7 — Cross-platform acceptance

| ID | Item | Current status | Remaining work |
|---|---|---|---|
| X-1 | Project interchange (v3/v4, unknown keys, feature records) | VERIFIED | keep in the regression set |
| X-2 | Rendering parity for global adjustments | PARTIAL | straighten/crop need a cross-host pixel reference (owner-approved fixture) |
| X-3 | Feature-data parity (crop, analysis, masks, heal, stickers, AI records) | PARTIAL | shared records exist; Windows cannot render several of them and names them before export |
| X-4 | Metadata and colour parity across hosts | PARTIAL | Windows always writes sRGB; XMP/IPTC absent |
| X-5 | Recovery parity | NOT VERIFIED | Windows recovery is not recorded |

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

## Queue order

1. Close WS-1 (W4): validate the metadata/colour workstream on `develop`,
   then the format audit and the remaining RenderPlan pass-through.
2. WS-3 items that are verifiable without a UI harness (crash recovery,
   project lifecycle).
3. WS-2 after the landmark-model decision (a measured Lead decision).
4. WS-5 R-4 and R-5 inside the reliability batch.
5. WS-6 after a signing decision.
6. WS-4 only when the runtime package exists.
