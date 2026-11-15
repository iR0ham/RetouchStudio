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
photo picker, and the open/export failure reports (run 43696215085). The rows and
the list below are corrected in place; drop-to-open and the hold-Space peek are
still not driven.

Statuses: VERIFIED, TESTED (measured but narrower than the capability), PARTIAL,
NOT VERIFIED, ABSENT, BLOCKED, NOT APPLICABLE.

| Area | macOS | Windows | Cross-platform | Evidence / limitation |
|---|---|---|---|---|
| App startup | PARTIAL | VERIFIED | N/A | Windows smoke step loads the published, extracted, installed and upgraded copies and prints time to first window (recorded, not gated). The macOS app builds and self-tests; a window-launch record is not in the ledger. |
| Project create/open/save | VERIFIED | VERIFIED | VERIFIED | macOS ModelTests and codec fixtures; Windows host checks open/save through the C ABI; interchange fixtures round-trip structurally. |
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
| 16-bit and ICC/colour | VERIFIED | PARTIAL | NOT VERIFIED | Windows 16-bit PNG/TIFF export sample-exact and 16-bit source preview tested; decode converts P3 to sRGB within one level of ColorSync at four in-gamut points; exports declare a generated sRGB ICC profile (JPEG APP2, PNG iCCP) and a no-op export is pixel-identical; wide-gamut colours still clip, TIFF is untagged and output is always sRGB. |
| Metadata keep/strip | VERIFIED | TESTED | PARTIAL | Windows writes the allowlist into JPEG/TIFF/16-bit PNG, carries the source EXIF block and XMP into JPEG/PNG at container level, carries the source IPTC resource (Photoshop APP13, 8BIM 0x0404) into JPEG byte for byte, and composes an EXIF block (make, model, date, exposure, aperture, ISO, flash, focal length, white balance, lens) when the source has none to carry, all normalised to the exported frame through crop, turn and resize; stripping removes all of it; TIFF keeps only the allowlist and PNG/TIFF carry no IPTC. WIC exposes no GPS through its WinRT properties, so a composed block carries no position. |
| Batch export/cancellation | VERIFIED | TESTED | N/A | Windows batch shares the single-export path, output sample-exact, collision-safe, per-file failures isolated; a page-one batch runs from the UI through both pickers and its JPEG decodes (run 43655814761); progress/cancel UI and mid-render cancellation not exercised (2026-11-15: the progress count and Cancel Batch are driven on a 64-photo batch, run 43696215085; a cancel during the file in flight is still unproven). |
| Recovery | VERIFIED | TESTED | TESTED | Windows candidate store mirrors the macOS rules (one working slot, immutable candidates, quarantine, restore write→verify→delete, monotonic savedAt, source identity) with injected failures; the launch prompt is driven through UIA — the seeded copy raises it, Yes restores the unsaved Exposure value and the app closes cleanly (run 43647604771); parity is proven by matching checks, not shared code. |
| Installer/updater | PARTIAL (DMG verified; notarization BLOCKED) | PARTIAL (MSI verified; updater ABSENT) | N/A | Windows MSI silent install, start from `Program Files`, in-place upgrade and clean uninstall proven on CI; macOS DMGs build and verify, Gatekeeper rejects until notarized, credentials unavailable. |
| Security/performance | PARTIAL | PARTIAL | NOT VERIFIED | Windows has measured preview/export/start-up, a flat managed heap over twenty renders, an export guard and a printed native working set after sixty renders (300 MB, peak 328 MB in run 43631106819); no cross-host performance comparison. |
| Project data movement | VERIFIED | VERIFIED | VERIFIED | Serialization and feature-record interchange; feature-data parity beyond records (face/mask/heal rendering) is not verifiable on Windows because those renderers are absent. |

## What a green CI run does not prove

- Interactive Windows behaviour the harness does not yet drive: drop-to-open, a
  cancel during the file in flight, and the failure paths of project open/save.
- macOS window launch and clean-machine installation.
- Rendering parity for straighten and freeform crop across hosts.
- Real AI inference, notarization, or an update feed.

These limits are requirements of the plan, not temporary caveats: the matrix
must carry them until evidence exists.
