# CI Merge Gates

**Status:** enabled on `main` on 2026-11-13. The three checks below are
required, strict, and enforced for administrators; force pushes and branch
deletion are disabled.
**Actions:** the workflows run `actions/checkout@v7`,
`actions/upload-artifact@v7` and `actions/download-artifact@v8` on the Node 24
runtime, so the deprecated Node.js 20 notices are gone. A fourth job,
`Windows StudioCore`, runs on `windows-2025`. Both workflows were installed on
2026-11-13 after the GitHub token gained the `workflow` scope; the history is
under [Action runtimes and versions](#action-runtimes-and-versions).
**Date:** 2026-11-13
**Workflows:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
[`.github/workflows/release.yml`](../.github/workflows/release.yml)

The repository workflow is named `CI`. It runs four jobs and each job reports a
status check under its own name. The first three are the required merge checks:

| Check | Runner | Command |
|---|---|---|
| `StudioCore Boundary` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` |
| `Platform-neutral Conformance` | `ubuntu-24.04` (x64) | `./Tests/Conformance/run-conformance.sh` |
| `macOS Integration` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` and `RETOUCH_ARCH=arm64 ./Tests/run.sh` |
| `Windows StudioCore` (not required; green on 2026-11-13) | `windows-2025` (x64) | `./Tests/run-studiocore-windows.ps1` and the conformance gate |

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

The upgrade is installed:

| Action | Installed | Runtime | Used by |
|---|---|---|---|
| `actions/checkout` | `v7` (7.0.1, 2026-07-20) | `node24` | both workflows |
| `actions/upload-artifact` | `v7` (7.0.2, 2026-10-07) | `node24` | both workflows |
| `actions/download-artifact` | `v8` (8.0.2, 2026-10-07) | `node24` | `release.yml` |
| `compnerd/gha-setup-swift` | `v0.5.1` (2026-10-14) | composite, no Node runtime | the Windows jobs in both workflows |

The installation PR keeps the three original jobs byte-for-byte apart from the
checkout and upload-artifact majors, and adds one new `windows-core` job. No
existing job, runner, timeout, gate command or verdict assertion changes, so no
required check is weakened. Both workflows pass actionlint v1.7.12 and a PyYAML
parse. The tag of every referenced action was resolved through the GitHub API
before the push.

Node 24 actions need Actions Runner 2.327.1 or newer, which GitHub-hosted
runners satisfy. The prepared Windows jobs use the supported `swift-version`,
`swift-build` and `build_arch` inputs; the deprecated `branch` and `tag` aliases
are gone. They request Swift 6.4.2 (`swift-6.4.2-release` / `6.4.2-RELEASE`):
the tag exists on `swiftlang/swift` (2026-10-30) and `download.swift.org` serves
the 2.1 GB Windows installer (checked with a ranged HEAD request on 2026-11-13).
The earlier 6.4.1 pin is superseded; 6.5 has no release tag yet.

The runner labels in use (`macos-15`, `ubuntu-24.04`, `windows-2025`) are current
GitHub-hosted labels; the Windows job was installed and ran green on 2026-11-13
([Verified runs](#verified-runs)).

### How the upgrade was installed

Until 2026-11-13 the token available to this checkout had the `gist`,
`read:org` and `repo` scopes but not `workflow`, and GitHub rejected every push
that added or edited a file under `.github/workflows`:

```
! [remote rejected] ci/node24-actions -> ci/node24-actions
(refusing to allow an OAuth App to create or update workflow
`.github/workflows/ci.yml` without `workflow` scope)
```

The permission was not bypassed: no token swap, no force push, no direct commit
to `main`, and the live workflow stayed on the Node 20 majors while the blocker
held.

On 2026-11-13 the account completed `gh auth refresh -s workflow` and the
upgrade was installed normally through a pull request. `Tools/ci/ci-node24.yml`
and `Tools/ci/release-pipeline.yml` were deleted in that PR: the installed
workflows are now the only copy, so the two cannot drift apart.

`Tests/Conformance/run-conformance.sh` honours a `PYTHON` variable and falls
back to `python` when `python3` is absent, because the Windows images expose
the interpreter as `python`. The macOS and Linux jobs still use `python3`.

Acceptance: a run on `main` after the merge prints no
`Node.js 20 is deprecated` line. The merge run is recorded under
[Verified runs](#verified-runs).

## Windows portability job

`Tests/run-studiocore-windows.ps1` is the Windows equivalent of
`Tests/run-studiocore.sh`: it scans `Sources/StudioCore` for platform imports
and types, builds the module and its tests with a native Windows Swift
toolchain, runs the same `StudioCoreTests`, builds the StudioCore C ABI static
library and runs the C ABI test. It proves only that the shared module is
portable — it says nothing about a Windows renderer, UI, installer or
application, none of which exists yet.

`windows-core` in `ci.yml` installs Swift 6.4.2 with
`compnerd/gha-setup-swift@v0.5.1` on `windows-2025`, runs that script, then runs
the same conformance gate with `CC=clang` (Git Bash on the Windows image has no
`cc`) and `PYTHON=python`. The job is not a required check. It first ran green
on `eba8075` (PR #13) on 2026-11-13, which confirms the runner label, the
third-party action, the toolchain tag and the `clang` assumption; the run is
recorded under [Verified runs](#verified-runs).

The Windows gap and the intended implementation are analysed in
[`WINDOWS_IMPLEMENTATION_PATH.md`](WINDOWS_IMPLEMENTATION_PATH.md).

## Verified runs

Read from the GitHub Actions API, not simulated locally.

| Date | Ref | Workflow | Result |
|---|---|---|---|
| 2026-11-13 | `eba8075` (PR #13, push and pull request) | `CI` | all four jobs green |

The `Windows StudioCore` step log on `windows-2025` (Windows Server 2025,
10.0.26100, Actions Runner 2.338.2) ends with:

```
-> building StudioCore on Microsoft Windows NT 10.0.26100.0
StudioCore: 260 checks passed
-> building the StudioCore C ABI library
-> compiling the C11 ABI test against the public header
-> linking the C test with the Swift libraries
ABI TESTS: PASS (86 checks)
StudioCore Windows portability check: PASS
R1 conformance: PASS
```

The first real runs exposed four defects that no macOS run could show. Each was
fixed on the branch:

1. PowerShell `-match` is case-insensitive, so `\bColor\b` matched the lowercase
   `.color` property and the boundary scan failed on `Adjustments.swift`. The
   scan now uses `-cmatch`, matching the case-sensitive `grep -E` gate.
2. Git for Windows ships a coreutils `link.exe` that shadowed the MSVC linker
   the Swift driver calls. The script now resolves the VC tools directory
   through `vswhere` and puts it first.
3. The fixtures are compared byte for byte and the repository had no
   `.gitattributes`, so the Windows checkout rewrote every text file to CRLF.
   `* text=auto eol=lf` now pins the working tree on every host.
4. `Tests/ABI/abi_tests.c` read and wrote its state length inside one argument
   list. That is unsequenced behaviour: it happened to pass with the macOS
   compiler and failed with the Windows one. The length is now computed at each
   call site.

This proves the shared module, its C ABI and the conformance fixtures work with
a native Windows Swift toolchain. It does not prove any Windows renderer, UI,
installer or application; none exists.

## Release pipeline

[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds an
arm64 DMG, an x86_64 DMG, runs the Windows StudioCore portability job, verifies
every SHA-256 manifest, and publishes a GitHub Release. It triggers on `v*` tag
pushes and on manual dispatch; a manual dispatch runs only the
platform-independent Windows job, because every other job carries
`if: startsWith(github.ref, 'refs/tags/v')`. A manual dispatch therefore cannot
create a release or a non-versioned artifact.

The Windows application job is gated behind the repository variable
`WINDOWS_APP_READY=true` and is skipped until a real application exists; a green
release therefore never implies a Windows product. A job-level `hashFiles()`
condition would be read before `actions/checkout`, so it was replaced with the
repository variable.

No paid signing certificate or notarization is used; macOS builds are ad-hoc
signed and Windows output is unsigned.

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

The macOS jobs prove the module boundary, the conformance fixtures and the
macOS suites on the runner images named above. They say nothing about rendering
parity, Vision, AI runtime or UI behavior on any other platform. `Windows
StudioCore` proves only that `StudioCore` compiles and passes its own tests with
a Windows toolchain; it is not a Windows application.

Linux is not implemented. It remains on the long-term roadmap and starts only
after a Windows release candidate is verified; the repository ships no Linux
build and no CI job here validates one.

The GitHub-hosted `macos-14` runner image was retired on 2026-11-02. This
workflow therefore uses `macos-15` (arm64) instead.
