# Release Security Review — 1.0.0

Scope: what the shipping macOS build does with untrusted input, files it owns,
network access and updates. Every claim cites the code that enforces it. Items
that were not exercised are labelled **NOT VERIFIED**.

## Network surface

The app has no telemetry, analytics or crash reporting. Outbound connections
are limited to two explicit, owner-approved downloads:

| Connection | When | Enforced by |
| --- | --- | --- |
| AI runtime archive | only after the consent sheet; disabled in 1.0.0 (`AIRuntime.package` is nil) | `Sources/RetouchStudio/Core/AIRuntime.swift` |
| Model weights | per-model approval sheet, individual download | `Sources/RetouchStudio/Models/ModelManager.swift` |
| Update manifest/artifact | only when the owner presses Check and then Install | `Sources/RetouchStudio/Core/UpdateController.swift` |

The 1.0.0 bundle ships no update feed URL (`Resources/Info.plist` has no
`RSUpdateFeedURL*` key), so the update button reports that no feed is configured
and performs no request. A feed can only be added by editing `Info.plist` in a
signed build.

## Update integrity

- The manifest is data; the Ed25519 signature covers the exact descriptor
  (`version`, `build`, `platform`, `architecture`, `format`, `size`, `sha256`,
  `url`) in a fixed order. Tampering with any of them invalidates the plan
  before the download starts (`Sources/StudioCore/UpdateManifest.swift:154`).
- The signature is verified twice: when the plan is offered and again before
  unpacking (`Sources/RetouchStudio/Core/UpdateController.swift:99` and `:121`).
- HTTPS is required by the portable policy, by the feed fetch, by the download
  and by every redirect; a redirect leaving HTTPS cancels the transfer
  (`UpdateVerification.swift`, `BoundedDownload`).
- The download is cancelled as soon as it exceeds the signed byte count, so a
  hostile feed cannot fill the disk before the hash is checked.
- The finished file must match the signed size and SHA-256 before it is
  unpacked.
- The unpacked bundle must contain exactly one `.app` with the running
  bundle identifier and the manifest's version. A valid signature over a
  different app is therefore not enough.
- Installation requires a writable parent on the same volume; the swap is
  journaled and rolled back on failure, and an interrupted swap is completed or
  undone on the next launch (`UpdateInstaller.swap` / `recover`).
- Nothing is installed without an explicit button press. There is no forced or
  silent upgrade path.
- The signing private key is outside the repository (`~/.config/retouchstudio/update-signing-key.txt`,
  mode 600). Only the public key is shipped. Losing the private key requires a
  key rotation, not a weaker check.

Gaps that remain, stated plainly:

- **End-to-end install from a live feed is NOT VERIFIED.** No feed or signed
  release archive exists, so the network behaviours above are covered by code
  review and unit tests of the pure rules, not by a live transfer.
- The updater does not verify that the new bundle's code signature satisfies
  Gatekeeper; it relies on Gatekeeper at first launch, exactly as for a manual
  download.
- No rollback to a *previous version* is offered after a successful swap; the
  backup is deleted. A broken release must be corrected by a newer release or a
  manual reinstall.

## Export and file safety

- Export refuses to write over the opened source file, a symbolic link, a hard
  link, a case-only alias or any path that resolves to the source
  (`ExportService.referencesSameFile`, covered by the corpus suite's 7 checks).
- Exports are written atomically; the document being edited is never truncated
  by a failed write.
- Text and metadata never reach a shell: external commands use `Process` with
  argument arrays (`ditto`, `spctl`/`codesign` in the build self-test), never an
  interpolated shell string.

## Metadata and privacy

- With privacy stripping on (the default), GPS, camera identity, serial numbers
  and owner fields are removed from exported copies; the whitelist lives in
  `Sources/RetouchStudio/Core/ExportService.swift` and is exercised by the
  corpus suite.
- XMP is preserved only when stripping is off, and is carried through load and
  export without being merged into pixel data.
- The project document stores edits as named values, not raster copies of the
  source, so sensitive metadata is not duplicated into `.retouch` files.

## Local AI runtime

- Model and runtime archives are verified by SHA-256 before installation (the
  SAM 2.1 tiny catalogue entry has no published hash; the UI labels its progress
  as indeterminate rather than inventing one).
- The runtime installer is disabled in 1.0.0: no package is configured, so no
  runtime download can start.
- Runtime and model trees are path-validated; a symlink or an unexpected path
  field cannot reach outside `~/Library/Application Support/RetouchStudio/AI`.

## Process and data isolation

- Runtime leases and a bounded transaction lock prevent swapping a runtime while
  a helper is using it; cross-process tests cover a launcher crash, an orphan
  helper and a second process (`Tests/RuntimeProcessTests.swift`).
- Recovery copies go to `~/Library/Application Support/Retouch Studio/Recovery`
  (candidate store); the editor never deletes a user project or model folder.

## Secrets and repository hygiene

- No private key, token or credential is committed. The update private key is
  outside the repository; the release public key is public by design.
- Test photos in `~/Documents/image test` are never copied into the repository;
  benchmarks accept them only through `RETOUCH_BENCH_REAL_DIR`.
- The build is ad-hoc signed; Developer ID signing and notarization are absent
  because no credentials are available. This is a distribution limitation, not
  a hidden one: `Docs/RELEASING.md` and the README both say so.

## Residual risks

| Risk | Status |
| --- | --- |
| Live update feed is hostile or unavailable | rules and download guards implemented; live path NOT VERIFIED |
| Corrupted zip that passes hash (impossible without key compromise) | bundle identity/version still checked |
| Update installed on a read-only or secondary volume | refused with a specific message; staging moved beside the app |
| Privacy stripping regressions | corpus checks; baseline locked |
| AI model with missing checksum | only SAM 2.1 tiny; labelled indeterminate |
| Unnotarized first launch | documented Gatekeeper steps |
