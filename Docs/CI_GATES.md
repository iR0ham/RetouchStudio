# CI Merge Gates

**Status:** enabled on `main` on 2026-11-13. The three checks below are
required, strict, and enforced for administrators; force pushes and branch
deletion are disabled.
**Date:** 2026-11-13
**Workflow:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)

The repository workflow is named `CI`. It runs three jobs and each job reports a
status check under its own name. Those three names are intended to become the
required merge checks:

| Check | Runner | Command |
|---|---|---|
| `StudioCore Boundary` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` |
| `Platform-neutral Conformance` | `ubuntu-24.04` (x64) | `./Tests/Conformance/run-conformance.sh` |
| `macOS Integration` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` and `RETOUCH_ARCH=arm64 ./Tests/run.sh` |

## What each check proves

**StudioCore Boundary.** The module under `Sources/StudioCore` imports nothing
but Foundation, mentions no platform type (`NSImage`, `CIImage`, `CGPoint`,
`UTType`, …), builds on its own, and its test binary links no AppKit, SwiftUI,
Core Image, Vision, ImageIO, Core Graphics, UIKit, Metal or AVFoundation
framework. The script scans imports, compiles `Tests/StudioCoreTests.swift`
with no `-framework` flags, inspects the binary with `otool -L`, then runs it.

The job additionally requires the `StudioCore: N checks passed` verdict, so a
module that builds but never runs its tests cannot pass silently.

**Platform-neutral Conformance.** `Tests/Conformance/conformance.py` (standard
library only) validates the canonical JSON fixtures, the contract references,
the 17-stage render order and the read-only corpus lock: manifest and baselines
hashes, fixture count, every fixture's SHA-256, every reference PNG's SHA-256
and the export file set. The same script compiles and runs the C ABI smoke test
with `-std=c11 -Wall -Wextra -Werror -pedantic`.

The job requires the exact `R1 conformance: PASS` and
`studioscore abi=1 status_count=20 error_codes=20` lines and fails if the gate
leaves any file in the checkout modified.

This is not `Tests/run-corpus.sh`. The corpus harness renders images and is
opt-in on a developer machine; CI never regenerates or rewrites a baseline.

**macOS Integration.** The established suites that link the real app sources:
Engine, Model, Runtime Process and Runtime V2, through `Tests/run.sh`. The job
asserts that each suite printed its own `PASS` line, so a suite silently
dropped from `run.sh` fails the check instead of shrinking coverage.

## Local equivalents

```bash
./Tests/run-studiocore.sh              # host architecture
./Tests/run-studiocore.sh x86_64       # Rosetta on Apple silicon
./Tests/Conformance/run-conformance.sh
RETOUCH_ARCH=arm64 ./Tests/run.sh
```

The conformance gate needs `python3` (3.10 or newer, standard library only)
and a C11 compiler. The other two need macOS with Command Line Tools.

## Windows portability (prepared, not in the workflow)

`Tests/run-studiocore-windows.ps1` is the Windows equivalent of
`Tests/run-studiocore.sh`: it scans `Sources/StudioCore` for platform imports
and types, builds the module and its tests with a native Windows Swift
toolchain, and runs the same `StudioCoreTests`. It proves only that the shared
module is portable — there is no Windows renderer, UI, installer or application
behind it.

The job intended for the workflow is:

```yaml
  windows-portability:
    name: Windows StudioCore Portability
    runs-on: windows-2025
    steps:
      - uses: actions/checkout@v4
      - uses: compnerd/gha-setup-swift@v0.3.0
        with:
          branch: swift-6.1-release
          tag: swift-6.1-release
      - shell: pwsh
        run: ./Tests/run-studiocore-windows.ps1
```

This snippet is **NOT VERIFIED**: it has not been added to
`.github/workflows/ci.yml`, because the token in use lacks the GitHub
`workflow` scope and pushing a workflow change is rejected. The permission was
not bypassed. The runner label `windows-2025`, the third-party action version
and the toolchain tag must be confirmed on a Windows runner before the job can
be made a required check. A required check needs a green run on the default
branch first.

The Windows gap and the intended implementation are analysed in
[`WINDOWS_IMPLEMENTATION_PATH.md`](WINDOWS_IMPLEMENTATION_PATH.md). The release
workflow for macOS arm64, macOS x86_64 and Windows x64 is prepared at
[`Tools/ci/release-pipeline.yml`](../Tools/ci/release-pipeline.yml); it is also
**not installed** for the same scope reason.

## Release pipeline (prepared, not installed)

`Tools/ci/release-pipeline.yml` is a copy-ready workflow, not a live one. It
builds an arm64 DMG, an x86_64 DMG, runs the Windows StudioCore portability job,
verifies every SHA-256 manifest, and publishes a GitHub Release. The Windows
application job is gated behind the repository variable
`WINDOWS_APP_READY=true` and is skipped until a real application exists; a green
release therefore never implies a Windows product. No paid signing certificate
or notarization is used.

## Branch protection for `main`

The required status checks are exactly:

```
StudioCore Boundary
Platform-neutral Conformance
macOS Integration
```

After these checks have completed successfully on the default branch, the
repository owner can enforce them with branch protection. The intended policy
is strict (a branch must be up to date with `main` before merging), applies to
administrators, disallows force pushes and branch deletion, and does not add a
review requirement that the repository did not previously have.

Example command (run only after the checks exist on `main`):

```bash
gh api -X PUT repos/iR0ham/RetouchStudio/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "StudioCore Boundary",
      "Platform-neutral Conformance",
      "macOS Integration"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

## Scope

The workflow says nothing about Windows or Linux application support. A passing
run proves the module boundary, the conformance fixtures and the macOS suites
on the runner images named above; it does not prove rendering parity, Vision,
AI runtime or UI behavior on any other platform. The prepared Windows job above
would prove only that `StudioCore` compiles and passes its own tests with a
Windows toolchain. Linux is not a product target.

The GitHub-hosted `macos-14` runner image was retired on 2026-11-02. This
workflow therefore uses `macos-15` (arm64) instead.
