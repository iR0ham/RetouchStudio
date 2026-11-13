# CI Merge Gates

**Status:** enabled on `main` on 2026-11-13. The three checks below are
required, strict, and enforced for administrators; force pushes and branch
deletion are disabled.
**Actions:** the live workflow still runs `actions/checkout@v4` and
`actions/upload-artifact@v4`, both on the deprecated Node.js 20 runtime;
checkout prints the notice on every run. The Node 24 upgrade is validated in
[`Tools/ci/ci-node24.yml`](../Tools/ci/ci-node24.yml) but cannot be installed
yet; the reason and the install steps are under
[Action runtimes and versions](#action-runtimes-and-versions).
**Date:** 2026-11-13
**Workflow:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)

The repository workflow is named `CI`. It runs three jobs and each job reports a
status check under its own name. Those three names are the required merge
checks:

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

## Action runtimes and versions

Audited on 2026-11-13 against the CI job logs for `main` (`cbf0b32`, dispatched
run `43347128659`) and each action's published `action.yml`.

The live workflow shows one deprecation, once per job:

```
##[warning]Node.js 20 is deprecated. The following actions target Node.js 20
but are being forced to run on Node.js 24: actions/checkout@v4.
```

Those three identical lines are the only deprecation warnings in the logs: no
`set-output`, no `save-state`, no deprecated input, no unsupported runner label.
`actions/upload-artifact@v4` also targets Node.js 20 but runs only on failure, so
a green run never prints its notice; it is upgraded as well.

The upgrade is prepared and validated but **not installed**:

| Action | Live in `ci.yml` | Prepared | Runtime | Where prepared |
|---|---|---|---|---|
| `actions/checkout` | `v4` | `v7` (7.0.1, 2026-07-20) | `node24` | `Tools/ci/ci-node24.yml`, `Tools/ci/release-pipeline.yml` |
| `actions/upload-artifact` | `v4` | `v7` (7.0.2, 2026-10-07) | `node24` | same |
| `actions/download-artifact` | — | `v8` (8.0.2, 2026-10-07) | `node24` | `Tools/ci/release-pipeline.yml` |
| `compnerd/gha-setup-swift` | — | `v0.5.1` (2026-10-14) | composite, no Node runtime | `Tools/ci/release-pipeline.yml` |

`Tools/ci/ci-node24.yml` is the live workflow with exactly two changes: the
checkout and upload-artifact majors. Every job, runner, timeout, gate command and
verdict assertion is identical, so no required check is weakened. It passes
actionlint v1.7.12 and a PyYAML parse.

Node 24 actions need Actions Runner 2.327.1 or newer, which GitHub-hosted
runners satisfy. The prepared Windows jobs use the supported `swift-version`,
`swift-build` and `build_arch` inputs; the deprecated `branch` and `tag` aliases
are gone. They request Swift 6.4.1 (`swift-6.4.1-release` /
`6.4.1-RELEASE`), the newest Windows installer line that `download.swift.org`
serves (6.4 and 6.5 return 404).

The runner labels in use (`macos-15`, `ubuntu-24.04`, `windows-2025`) are current
GitHub-hosted labels; the Windows job remains **NOT VERIFIED** until it is
installed and run.

### Why the upgrade is not in the live workflow

The token available to this checkout has the `gist`, `read:org` and `repo`
scopes but not `workflow`. GitHub rejects any push that adds or edits a file
under `.github/workflows`:

```
! [remote rejected] ci/node24-actions -> ci/node24-actions
(refusing to allow an OAuth App to create or update workflow
`.github/workflows/ci.yml` without `workflow` scope)
```

The permission was not bypassed: no token swap, no force push, no direct commit
to `main`. Until a token with the `workflow` scope installs the copy, the
Node.js 20 notice stays in the logs and is expected, not a regression.

To finish it:

```bash
gh auth refresh -s workflow                         # interactive browser flow
cp Tools/ci/ci-node24.yml .github/workflows/ci.yml  # then delete the file header
git switch -c ci/node24-actions
git add .github/workflows/ci.yml
git commit -m "ci: move actions to the Node 24 majors"
git push -u origin ci/node24-actions
gh pr create --fill                                 # the three required checks must pass
```

Acceptance: a fresh run after that merge prints no `Node.js 20 is deprecated`
line. It cannot be reached from the current token.

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
      - uses: actions/checkout@v7
      - uses: compnerd/gha-setup-swift@v0.5.1
        with:
          swift-version: swift-6.4.1-release
          swift-build: 6.4.1-RELEASE
          build_arch: amd64
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
release therefore never implies a Windows product. A job-level `hashFiles()`
condition would be read before `actions/checkout`, so it was replaced with the
repository variable.

The file was refreshed on 2026-11-13 with the actions in the table above and
validated with actionlint v1.7.12. It is installed at the same time as
`Tools/ci/ci-node24.yml`, with the same `workflow` scope, and no paid signing
certificate or notarization is used.

## Branch protection for `main`

The required status checks are exactly:

```
StudioCore Boundary
Platform-neutral Conformance
macOS Integration
```

This policy is applied to `main` and was read back on 2026-11-13 with
`gh api repos/iR0ham/RetouchStudio/branches/main/protection`: strict, the three
contexts above, `enforce_admins` on, force pushes off, deletions off, no required
review. The configuration is reproduced here so it can be re-applied if it is
ever lost:

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

Because the checks are strict, every PR must be re-run against the current
`main` before merging. That is what blocked nothing in the 2026-11-13
consolidation, but it does mean an old green run is never enough.

## Scope

The workflow says nothing about Windows or Linux application support. A passing
run proves the module boundary, the conformance fixtures and the macOS suites
on the runner images named above; it does not prove rendering parity, Vision,
AI runtime or UI behavior on any other platform. The prepared Windows job above
would prove only that `StudioCore` compiles and passes its own tests with a
Windows toolchain. Linux is not a product target.

The GitHub-hosted `macos-14` runner image was retired on 2026-11-02. This
workflow therefore uses `macos-15` (arm64) instead.
