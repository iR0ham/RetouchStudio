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
| Windows | any | not built | `Tests/run-studiocore-windows.ps1` prepared, never run | **not a shipping target in 1.0.0** |
| Linux | any | not built | `Tests/run-studiocore-linux.sh` prepared, smoke-tested on macOS only | supplementary test target only |

No native Intel Mac, Windows machine or Linux machine is available in this
environment. The x86_64 result is a Rosetta execution of an Intel slice, which
is not the same as a native Intel run.

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

## macOS-specific (not portable)

Rendering (Core Image), face/eye/teeth analysis (Vision), the pixel engine,
Metal-backed preview, AppKit/SwiftUI UI, file dialogs, Keychain-free settings,
the `.app` installer/updater and DMG packaging. A Windows release requires
native implementations of all of these; no shim is claimed.

## Windows path — what exists and what blocks it

Exists:

- the portable core above, with a Windows PowerShell runner
  (`Tests/run-studiocore-windows.ps1`) that scans imports, builds the module and
  runs `StudioCoreTests` with a native Swift toolchain;
- a code-level Windows implementation audit with the reusable surfaces, the
  macOS-only replacements, the recommended host stack and milestones W0–W6
  (`Docs/WINDOWS_IMPLEMENTATION_PATH.md`);
- an intended CI job (`Docs/CI_GATES.md` section "Windows portability"),
- a prepared release workflow for macOS arm64, macOS x86_64 and one Windows x64
  artifact (`Tools/ci/release-pipeline.yml`), with a packaging script that
  writes the zip and SHA-256 (`Tools/package-windows.ps1`); neither is installed
  or executed on Windows,
- a technology decision document that keeps the renderer boundary
  implementation-agnostic (`Docs/CROSS_PLATFORM_TECHNOLOGY_DECISIONS.md`).

Blocked:

1. **No Windows runner has executed the portability script.** The one available
   token lacks the GitHub `workflow` scope, so the prepared job cannot be added
   to `.github/workflows/ci.yml`; the permission was not bypassed and no claim
   of a Windows run is made.
2. **No Windows renderer/UI/installer exists.** Even a green portability run
   would prove only that the shared module compiles on Windows.
3. The `windows-2025` runner label, third-party Swift setup action and toolchain
   tag in the prepared job are unconfirmed.

Result: Windows is **0% product-ready** and **unverified** for the shared core,
while the core is **designed and prepared** for it. It is not a 1.0.0 shipping
target. Linux remains a supplementary test target, not a product.

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
