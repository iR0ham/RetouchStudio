# Cross-Platform Compatibility — Release Cycle

Status of each platform for the 1.0.0 release cycle. "Verified" means a command
was run on this checkout and its output was inspected; everything else says so.

Last full macOS gate: 2026-11-13 at `037db3a` (`main`). arm64 and x86_64 suites
PASS, golden corpus 376 checks / 0 failures against the captured baselines, and
the three distribution artifacts match their published SHA-256 files.

## Platform matrix

| Platform | Architecture | Build | Tests | Product status |
| --- | --- | --- | --- | --- |
| macOS 14+ | arm64 (native) | `build.sh release` PASS | `Tests/run.sh` PASS; corpus PASS; benchmarks PASS | shipping |
| macOS 14+ | x86_64 (Rosetta on Apple silicon) | universal build PASS; `--selftest` runs the Intel slice | `RETOUCH_ARCH=x86_64 Tests/run.sh` PASS | shipping (Intel slice not tested on native Intel hardware) |
| Windows | x64 | `StudioCore` built with Swift 6.4.2; no application | `Windows StudioCore` CI job on `windows-2025` PASS (260 core checks, 86 C ABI checks, conformance PASS), 2026-11-13 | **not a shipping target in 1.0.0** |
| Linux | any | not built | `Tests/run-studiocore-linux.sh` prepared, smoke-tested on macOS only | long-term, after a verified Windows RC |

No native Intel Mac, Windows machine or Linux machine is attached to this
development checkout. The Windows result above comes from the GitHub-hosted
`windows-2025` runner; the x86_64 macOS result is a Rosetta execution of an
Intel slice, which is not the same as a native Intel run.

## Shared core (portable across all three)

`Sources/StudioCore` imports Foundation only; the boundary gate scans for
CoreGraphics, AppKit, CoreImage, Vision and CoreML imports/types and fails the
build if one appears. It owns:

- the document value types and edit state;
- the project codec, including v3 wire compatibility and v4 unknown-field
  preservation (nested unknown fields inside known records are kept);
- history rules, recovery policy and batch/export policy;
- the canonical JSON form used by the conformance fixtures;
- the render contract (what a renderer must do, not how);
- the update manifest, version selection and signature descriptor rules.

Interchangeability evidence:

| Property | Evidence |
| --- | --- |
| The same project bytes decode on any host | `StudioCoreTests` project fixtures; `Tests/Conformance` canonical JSON gate |
| v3 projects still open | v3 wire types frozen at the codec boundary; app-boundary conversion tests |
| Unknown v4 fields survive save/reopen | recursive preservation tests added with the v4 codec |
| Selection/refusal rules are host-independent | `UpdatePolicy` tests in `Tests/EngineTests.swift` |
| The module builds without platform frameworks | boundary gate (260 checks) and independent `swiftc` build |
| The module builds and passes its tests on Windows | `Windows StudioCore` CI job, `windows-2025`, 2026-11-13: 260 core checks, 86 C ABI checks, conformance PASS |

## macOS-specific (not portable)

Rendering (Core Image), face/eye/teeth analysis (Vision), the pixel engine,
Metal-backed preview, AppKit/SwiftUI UI, file dialogs, Keychain-free settings,
the `.app` installer/updater and DMG packaging. A Windows release requires
native implementations of all of these; no shim is claimed.

## Windows path — what exists and what does not

Exists and is verified:

- the portable core above, with a Windows PowerShell runner
  (`Tests/run-studiocore-windows.ps1`) that scans imports, builds the module and
  runs `StudioCoreTests` with a native Swift toolchain;
- the `Windows StudioCore` CI job on the GitHub-hosted `windows-2025` runner.
  It ran green on `eba8075` (PR #13) on 2026-11-13 with Swift 6.4.2:
  `StudioCore: 260 checks passed`, `ABI TESTS: PASS (86 checks)` and
  `R1 conformance: PASS`. The four defects found by the first runs are recorded
  in [`CI_GATES.md`](CI_GATES.md#verified-runs);
- the installed release workflow (`.github/workflows/release.yml`) that builds
  both macOS DMGs, runs the Windows core job and verifies the SHA-256 manifests
  before publishing; its Windows application job is gated behind the repository
  variable `WINDOWS_APP_READY` and is skipped until an application exists;
- a prepared packaging script that writes the Windows zip and SHA-256
  (`Tools/package-windows.ps1`); it has not been executed on Windows;
- a code-level Windows implementation audit with the reusable surfaces, the
  macOS-only replacements, the recommended host stack and milestones W0–W6
  (`Docs/WINDOWS_IMPLEMENTATION_PATH.md`);
- a technology decision document that keeps the renderer boundary
  implementation-agnostic (`Docs/CROSS_PLATFORM_TECHNOLOGY_DECISIONS.md`).

Not implemented:

1. **No Windows renderer, UI or installer exists.** The green portability run
   proves only that the shared module and its C ABI work with a native Windows
   toolchain.
2. **No Windows artifact has been built or run.** The release workflow never
   publishes a Windows product, and `Tools/package-windows.ps1` is untested.
3. The Windows application work (W2–W6: C#/.NET host, WIC decode/encode, crop,
   orientation, global adjustments, masks, editor shell, packaging) is designed
   but not started.

Result: the shared core is **verified portable** on a real Windows runner, while
Windows is **0% product-ready**. It is not a 1.0.0 shipping target. Linux is
unimplemented and stays on the long-term roadmap after a verified Windows RC.

## Update compatibility

The manifest format is platform-tagged. The macOS updater only installs
`platform=macos` artifacts whose architecture matches or is `universal`; it
refuses a Windows artifact with an explicit reason. A future Windows updater can
consume the same manifest through `UpdatePolicy`.

## Packaging compatibility

- Separate arm64 and x86_64 DMGs plus a light universal zip, each with a
  SHA-256 file.
- Projects saved by either slice open in the other; export behavior is identical
  for the same settings.
- Intel builds cannot run AI tools (Apple-silicon-only helper) and say so
  instead of failing silently.
