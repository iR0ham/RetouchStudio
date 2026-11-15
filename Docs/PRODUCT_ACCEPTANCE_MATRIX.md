# Product acceptance matrix

**Basis:** `main` at `4e31596` (PR #54 milestone merge), 2026-11-14, with the evidence recorded in §5 of the ledger (run 43631106819, PR run 43632188008), plus the Windows UI-automation run 43647604771 on `bb06e28`. Evidence is the verification ledger
in [`MASTER_PRODUCT_COMPLETION_STATUS.md`](MASTER_PRODUCT_COMPLETION_STATUS.md)
(§5) and the CI runs named there. Windows evidence is CI-only: there is no
physical Windows machine, and only the interactions the UiTests harness drives
are proven interactively.

**Addendum 2026-11-15 (runs on `develop`).** The basis line above is kept as
written. Pointer-driven UI automation has since merged: the crop corner drag and
Apply (run 43681175327), the compare divider drag (run 43681175327), pointer
zoom/pan with Fit restore, batch progress and Cancel Batch, multi-select in the
photo picker, and the open/export failure reports (run 43696215085). Drop-to-open
is also driven by merged branch `windows/drop-open-test` (run 43712286626); the
hold-Space peek is still not driven. The rows and the list below are corrected in
place.

**Addendum 2026-11-15 (reliability completion, run 43736047883 on `089a413`).**
A single export now checks cancellation at stage boundaries and publishes
through a dot-prefixed sibling temp that replaces the destination instead of being
overwritten in place; a project save and autosave do the same; a sweep removes
only names that match the temp pattern for that exact destination and leaves
every other file alone; a batch and a single export exclude each other. The
Windows host runs `WINDOWS HOST TESTS: PASS (370 checks)` and twelve
UI-automation passes, and the macOS suites stay green (`StudioCore: 287 checks
passed`, `ABI TESTS: PASS (104 checks)`, engine, model and runtime PASS). The
rows below are corrected in place.

Statuses: VERIFIED, TESTED (measured but narrower than the capability), PARTIAL,
NOT VERIFIED, ABSENT, BLOCKED, NOT APPLICABLE.

| Area | macOS | Windows | Cross-platform | Evidence / limitation |
|---|---|---|---|---|
| App startup | PARTIAL | VERIFIED | N/A | Windows smoke step loads the published, extracted, installed and upgraded copies and prints time to first window (recorded, not gated). The macOS app builds and self-tests; a window-launch record is not in the ledger. |
| Project create/open/save | VERIFIED | VERIFIED | VERIFIED | macOS ModelTests and codec fixtures; Windows host checks open/save through the C ABI; interchange fixtures round-trip structurally. 2026-11-15: a save and an autosave write through a sibling temp and replace the destination; a save over a held project, onto a directory and a retry after a refusal all leave the earlier file and the document state intact (run 43736047883); a failed open keeps the previous document because the new session is adopted only after it loads, and a corrupt project or a save onto a held file is driven through its dialog, reports, and leaves the previous photo and the held bytes untouched (run 43736047883). |
| V3/V4 compatibility | VERIFIED | VERIFIED | VERIFIED | v3 fixture re-encodes byte-identically and stays v3; v4 keeps `futureFlag`, `requiredFeatures` and keyed crop; Windows run 43534410772. |
| Unknown fields | VERIFIED | VERIFIED | VERIFIED | Top-level across save and reopen; modelled records preserved; unmodelled nested records dropped by documented design. |
| Undo/redo | VERIFIED | VERIFIED | N/A | `DocumentHistory`, 55 Windows host checks; the Undo and Redo buttons move a slider through UIA (runs 43654765580, 43658018867). |
| Image import and adjustments | VERIFIED | TESTED | PARTIAL | Nine adjustments render on Windows (preview median 721 ms, run 43618132157); the Open Photo dialog and all nine sliders are driven end to end through UIA (runs 43647604771, 43659238621); cross-host MAE: exposure 0.01, levels 0.007, clarity 0.06, vignette 0.47, each gated at one level. |
| Crop/rotation/mirror/straighten | VERIFIED | TESTED | PARTIAL | Windows crop arithmetic, orientation order and turn/straighten/mirror composition are tested pixel for pixel; the overlay drag is not driven by CI (2026-11-15: superseded — the corner drag, Apply and the exported frame are driven through injected pointer input, run 43681175327); no cross-host straighten pixel reference (corpus protected). |
| Face detection/landmarks/regions | VERIFIED | ABSENT | N/A | macOS Vision, ≥0.35 confidence, largest-first, ~76 points plus derived regions. In-box Windows detector returns boxes only, which cannot drive masks. |
| Mask generation/edit/persistence | VERIFIED | ABSENT | N/A | macOS geometric masks, 1024 px preview, 4096 px export, feather and gates; no standalone mask layers or stable per-face identities anywhere. |
| Heal/stamps/stickers/watermarks | VERIFIED | ABSENT | N/A | macOS edits exist; Windows keeps the records and asks before exporting pixels without them. The export guard names every macOS-only adjustment group (skin, face, makeup, look, grain, curves, HSL, body, background, hair, lens) and the prompt itself is driven through UIA: a project with `smooth` 30 names skin retouching, and No writes nothing (run 43653664500). |
| AI runtime | BLOCKED | ABSENT | N/A | `AIRuntime.package` nil; no approved package or weights; AI edit records are preserved and named, not executed. |
| JPEG/PNG/TIFF/HEIC | VERIFIED | PARTIAL | PARTIAL | Windows: JPEG/PNG/TIFF import/export verified, 16-bit PNG/TIFF verified, HEIC decode unavailable on `windows-2025` (`0x88982F8B`), HEIC export explicitly refused. macOS supports all four. |
| 16-bit and ICC/colour | VERIFIED | PARTIAL | NOT VERIFIED | Windows 16-bit PNG/TIFF export sample-exact and 16-bit source preview tested; decode converts P3 to sRGB within one level of ColorSync at four in-gamut points; exports declare a generated sRGB ICC profile (JPEG APP2, PNG iCCP) and a no-op export is pixel-identical; wide-gamut colours still clip, TIFF is untagged and output is always sRGB. 2026-11-15: sRGB output is the approved 1.0 policy on both hosts (W4-4 Option A, `Docs/OUTPUT_COLOR_POLICY.md`); macOS now converts a Display P3 source to sRGB on export and leaves an sRGB source byte-identical, with `F11_export_256.png` the only renewed corpus artifact (macOS suite and corpus pass locally; CI run recorded in `Docs/CI_GATES.md` when green). |
| Metadata keep/strip | VERIFIED | TESTED | PARTIAL | Windows writes the allowlist into JPEG/TIFF/16-bit PNG, carries the source EXIF block and XMP into JPEG/PNG at container level, carries the source IPTC resource (Photoshop APP13, 8BIM 0x0404) into JPEG byte for byte, and composes an EXIF block (make, model, date, exposure, aperture, ISO, flash, focal length, white balance, lens) when the source has none to carry, all normalised to the exported frame through crop, turn and resize; stripping removes all of it; TIFF keeps only the allowlist and PNG/TIFF carry no IPTC. WIC exposes no GPS through its WinRT properties, so a composed block carries no position. |
| Batch export/cancellation | VERIFIED | TESTED | N/A | Windows batch shares the single-export path, output sample-exact, collision-safe, per-file failures isolated; a page-one batch runs from the UI through both pickers and its JPEG decodes (run 43655814761); progress and Cancel Batch are driven on a 64-photo batch (run 43696215085). 2026-11-15: the cancel is now honoured inside the file in flight — after decode, after render and after encode, before the publish — and a cancelled write deletes its sibling temp and leaves an existing destination byte-for-byte (8-bit and 16-bit, run 43736047883); on macOS a cancel at the commit point publishes nothing and keeps a pre-existing destination (ModelTests R6-X); a batch and a single export refuse to overlap. A Windows cancel is observed at those boundaries and does not preempt the codec mid-encode. |
| Recovery | VERIFIED | TESTED | TESTED | Windows candidate store mirrors the macOS rules (one working slot, immutable candidates, quarantine, restore write→verify→delete, monotonic savedAt, source identity) with injected failures; the launch prompt is driven through UIA — the seeded copy raises it, Yes restores the unsaved Exposure value and the app closes cleanly (run 43647604771). 2026-11-15: a working slot that could not be lifted is never overwritten by an autosave — the launch offer is kept, a refused autosave leaves no temp, and the autosave commits by replace only after the slot is resolved or discarded; a restore that cannot write reports failure and re-locks the slot, so the unresolved copy stays the only one and the next autosave cannot replace it (run 43736047883); parity is proven by matching checks, not shared code. |
| Installer/updater | PARTIAL (DMG verified; notarization BLOCKED) | PARTIAL (MSI verified; updater ABSENT) | N/A | Windows MSI silent install, start from `Program Files`, in-place upgrade and clean uninstall proven on CI; macOS DMGs build and verify, Gatekeeper rejects until notarized, credentials unavailable. |
| Security/performance | PARTIAL | PARTIAL | NOT VERIFIED | Windows has measured preview/export/start-up, a flat managed heap over twenty renders, an export guard and a printed native working set after sixty renders (300 MB, peak 328 MB in run 43631106819); no cross-host performance comparison. |
| Project data movement | VERIFIED | VERIFIED | VERIFIED | Serialization and feature-record interchange; feature-data parity beyond records (face/mask/heal rendering) is not verifiable on Windows because those renderers are absent. |

## What a green CI run does not prove

- Interactive Windows behaviour the harness does not yet drive: the Cancel
  Export button itself (the cancellation is proven headlessly, not by a click).
  The open/save failure paths are now driven through their dialogs: a corrupt
  project, a save onto a held file and an export onto a held file each report,
  keep the open photo in place and leave the held bytes untouched (run
  43736047883).
- OS-produced failures. The Windows write, remove, quarantine and lift failures
  are injected — a held handle, a directory target, a name the process cannot
  create — not produced by a full disk; a codec encode is never interrupted
  mid-encode because cancellation is observed at the stage boundaries. The
  macOS unwritable-folder and commit-point cancel cases run in-process, not
  through the app shell. A crash between a temp write and its replace is
  simulated by leaving the temp behind, not by killing the process.
- macOS window launch and clean-machine installation.
- Rendering parity for straighten and freeform crop across hosts.
- Real AI inference, notarization, or an update feed.

These limits are requirements of the plan, not temporary caveats: the matrix
must carry them until evidence exists.

One of them is now met: the drop-in open is driven by the UiTests harness. A
helper WPF window starts `DragDrop.DoDragDrop` from a real press on its own
window, OLE ends the drag on the injected button-up over the canvas with
`DROPEFFECT_COPY`, the dropped photo opens, and its export decodes at the source
size (Windows App job, run 43712286626, commit `89c9683`; the mode runs from
`Tools/build-windows.ps1` on `windows-2025`). The input is injected, not a
physical mouse or touchscreen, and no drag-out is covered.
