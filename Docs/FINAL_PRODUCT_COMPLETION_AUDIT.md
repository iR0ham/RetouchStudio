# Final product completion audit

**Audit date:** 2026-11-14
**Repository:** `iR0ham/RetouchStudio`
**Basis:** `main` at `4a034cd` (PR #48 merge), post-merge CI run 43622071155
green on all five jobs. PR #47 is `f58b336`, post-merge run 43620792640 green.
**Nature of this document:** a point-in-time, evidence-based audit. It is not a
completion certificate, and nothing here is VERIFIED without a ledger entry in
[`MASTER_PRODUCT_COMPLETION_STATUS.md`](MASTER_PRODUCT_COMPLETION_STATUS.md).
Windows evidence is CI-only; there is no physical Windows machine.

## 1. Live state at audit time

| Item | State |
|---|---|
| `main` | `4a034cd` |
| Open pull requests | none |
| Required checks | all five: `StudioCore Boundary`, `Platform-neutral Conformance`, `macOS Integration`, `Windows StudioCore`, `Windows App` |
| Protection | strict up-to-date, admin-enforced, no force push, no deletion; read back 2026-11-14 |
| Post-merge matrices | removed on 2026-11-14; the strict pull-request gate validates the merge tree (see `CI_GATES.md`) |
| Preserved local work | `windows/memory-perf` at `3e00182`, unpushed, untouched |
| Last Windows host count | `WINDOWS HOST TESTS: PASS (184 checks)` |

## 2. Acceptance gates

| Gate | Verdict | Evidence | Gap |
|---|---|---|---|
| A — Shared architecture | PARTIAL | Portable StudioCore boundary, C ABI v1, V3/V4 codecs, migrations, interchange fixtures, unknown top-level keys (runs 43531081160, 43534410772) | unmodelled nested records are dropped by design; per-face identities and mask persistence are absent |
| B — W3 real face analysis and masks on both platforms | NOT MET | macOS Vision landmarks, regions and masks verified | Windows has no detector with landmarks, no masks; blocked on a distributable model |
| C — W4 bit depth, colour, metadata, formats, rendering | NOT MET | Windows 16-bit PNG/TIFF export sample-exact; 16-bit preview tested; P3 decode within one level of ColorSync; adjustment MAE 0.01–0.47 | wide-gamut clipping, no ICC preservation on write, no XMP/IPTC, most EXIF dropped, no HEIC on Windows, no cross-host straighten/crop reference |
| D — W5 real runtime/inference | BLOCKED | runtime infrastructure and test doubles; installer disabled by design | no approved runtime package, no weights, worker source outside the repository |
| E — Reliability | PARTIAL | preview 721 ms median and 1189 ms 16-bit export (run 43618132157); flat managed heap over twenty renders, gated at 150 MB; start-up printed | native working set only on the unpushed local branch; long sessions, interrupted saves, disk-full and mid-render cancellation not verified |
| F — Applications perform supported workflows | PARTIAL | Windows: import, adjustments, crop/orientation, zoom/pan, compare, histogram, batch export, MSI lifecycle on CI; macOS suites and corpus green | Windows has no face/mask/AI/heal renderer and no updater; interactive Windows UI actions are not driven by CI; macOS launch/clean-install not in the ledger |
| G — Distribution | PARTIAL / BLOCKED | Windows MSI install, in-place upgrade, clean uninstall on CI; macOS per-arch DMGs build and verify on a dry run | no Windows updater; macOS notarization BLOCKED on Apple credentials; tag-published release NOT VERIFIED |
| H — Cross-platform projects and feature data | PARTIAL | v3/v4 interchange, unknown keys, feature records (run 43534410772) | feature rendering parity (face, masks, heal, stickers, AI) impossible on Windows while the renderers are absent; straighten/crop lacks a cross-host pixel reference |
| I — Release readiness | NOT MET | required CI green, artifacts verified at the dry run | Windows product gaps above, macOS notarization blocked, no updater, no authorized public release |

## 3. Requirement audit against the plan

| Plan area | Verdict | Notes |
|---|---|---|
| §1 Source of truth and durable records | IMPLEMENTED | plan, status, remaining work, audit and acceptance matrix now exist; earlier plan versions unrecoverable and not reconstructed |
| §3 Shared Core acceptance | PARTIAL | schema, stable IDs, V3/V4, versioned serialisation, migrations, asset references, non-destructive state, autosave/recovery, undo/redo, export plan verified; nested unknown-field preservation limited by design; cross-host open/save verified |
| §4 W4 metadata | PARTIAL | allowlist write tested; explicit policies exist; XMP/IPTC and full EXIF absent; no blind copy after crop/rotate observed because most metadata is not written at all |
| §4 W4 bit depth | VERIFIED per host | 8- and 16-bit input/output, 16-bit PNG/TIFF on Windows, precision-preserving intermediates; JPEG remains 8-bit by format |
| §4 W4 colour | PARTIAL | ICC read/convert verified at decode; no profile write, no wide-gamut preservation; HDR/EDR not implemented and not advertised |
| §4 W4 formats | PARTIAL | JPEG, PNG, TIFF, HEIC on macOS; Windows HEIC read unavailable; RAW/DNG absent on both |
| §4 RenderPlan parity | PARTIAL | writer consumes dimensions, depth, alpha, orientation, format, compression, quality; colour and metadata policy are fixed rather than parameters |
| §5 W3 | macOS VERIFIED; Windows BLOCKED | capability claims kept accurate: no dense/3D mesh, no learned segmentation |
| §6 Windows product completion | PARTIAL | broad workflow exists; face/mask/AI/heal absent; batch export and MSI proven; UI interaction unverified |
| §7 W5 | BLOCKED | infrastructure only; no placeholder inference is presented as real |
| §8 Performance and reliability | PARTIAL | measurements exist for Windows preview/export/start-up and heap; native memory, long sessions and recovery gaps |
| §9 macOS completion | PARTIAL | preserves the native app; notarization BLOCKED; no Intel-support claim |
| §10 Windows installer/updater | PARTIAL | installer verified; updater NOT IMPLEMENTED |
| §11 Cross-platform acceptance | PARTIAL | serialisation and feature records verified; rendering and recovery parity not |
| §12 Security and data integrity | PARTIAL | non-destructive editing, no silent overwrite, export guard for unrenderable edits, no secrets committed; installer/updater security awaits an updater; the existing privacy and release-security reviews were not re-run in this batch |
| §13 CI/CD | VERIFIED (configuration) | five required contexts; Windows regressions now block; duplicate post-merge matrices removed |
| §14 Work batching | ADOPTED | one PR per coherent workstream; focused local checks; full matrix per merge candidate |
| §20 Acceptance matrix | MAINTAINED | `PRODUCT_ACCEPTANCE_MATRIX.md` |

## 4. Critical defects

No open critical defect is recorded in the verification ledger as of this date.
That is a statement about the ledger, not a claim that a defect search was
exhaustive. Known, documented behaviour differences are not defects: the
Windows compare split starts off while macOS starts it on, and Windows names
edits it cannot render instead of dropping them silently.

## 5. Release readiness

- **macOS:** not release-ready. The app builds and its suites pass, DMGs build
  and verify, but signing is ad-hoc, notarization is BLOCKED on credentials, and
  clean-machine installation is not verified.
- **Windows:** not release-ready. Windows is no longer a viewer, but it lacks
  face/mask/AI/heal rendering and an updater, HEIC read, wide-gamut output, and
  interactive UI acceptance evidence.
- **Cross-platform:** project interchange is solid; product-level feature and
  rendering parity is not.
- **Public release:** not authorized by the plan; none is proposed here.

## 6. Next step

The next implementation milestone is W4 on Windows (metadata, colour, formats),
followed by the verifiable reliability items and the face-landmark decision.
The queue, dependencies and blockers are in
[`MASTER_PLAN_REMAINING_WORK.md`](MASTER_PLAN_REMAINING_WORK.md).
