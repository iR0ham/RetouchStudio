# CI Merge Gates

**Status:** enabled on `main` on 2026-11-13. The three checks below are
required, strict, and enforced for administrators; force pushes and branch
deletion are disabled.
**Actions:** the workflows run `actions/checkout@v7`,
`actions/upload-artifact@v7` and `actions/download-artifact@v8` on the Node 24
runtime, so the deprecated Node.js 20 notices are gone. Two further jobs,
`Windows StudioCore` and `Windows App`, run on `windows-2025` and are not
required. Both workflows were installed on
2026-11-13 after the GitHub token gained the `workflow` scope; the history is
under [Action runtimes and versions](#action-runtimes-and-versions).
**Date:** 2026-11-13
**Workflows:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
[`.github/workflows/release.yml`](../.github/workflows/release.yml)

The repository workflow is named `CI`. It runs five jobs and each job reports a
status check under its own name. The first three are the required merge checks:

| Check | Runner | Command |
|---|---|---|
| `StudioCore Boundary` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` |
| `Platform-neutral Conformance` | `ubuntu-24.04` (x64) | `./Tests/Conformance/run-conformance.sh` |
| `macOS Integration` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` and `RETOUCH_ARCH=arm64 ./Tests/run.sh` |
| `Windows StudioCore` (not required; green on 2026-11-13) | `windows-2025` (x64) | `./Tests/run-studiocore-windows.ps1` and the conformance gate |
| `Windows App` (not required; green on 2026-11-13) | `windows-2025` (x64) | `pwsh ./Tools/build-windows.ps1` |

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
| `actions/setup-dotnet` | `v6` (`10.0.x`) | `node24` | the `Windows App` job |

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
application.

`windows-core` in `ci.yml` installs Swift 6.4.2 with
`compnerd/gha-setup-swift@v0.5.1` on `windows-2025`, runs that script, then runs
the same conformance gate with `CC=clang` (Git Bash on the Windows image has no
`cc`) and `PYTHON=python`. The job is not a required check. It first ran green
on `eba8075` (PR #13) on 2026-11-13, which confirms the runner label, the
third-party action, the toolchain tag and the `clang` assumption; the run is
recorded under [Verified runs](#verified-runs).

The Windows gap and the intended implementation are analysed in
[`WINDOWS_IMPLEMENTATION_PATH.md`](WINDOWS_IMPLEMENTATION_PATH.md).

## Windows application job

`windows-app` in `ci.yml` installs Swift 6.4.2 and the .NET 10 SDK on
`windows-2025` — the Swift installer download is cached by the setup action —
and runs `Tools/build-windows.ps1 -RequireMsi`, which builds the
Foundation-only core, links it into `studioscore_core.dll` with the 13-entry
`.def` export list, publishes the WPF host self-contained for x64, runs the 141
headless host checks against the real DLL and the real WIC codec, starts the
published app until the loaded window writes its own marker file, zips the
folder and starts the extracted copy, then builds an MSI with WiX v3, installs
it silently, starts the copy in `Program Files`, and uninstalls it with the
folder, shortcut and Programs-and-Features entry gone. A second package, built
from the same folder with the patch number bumped, is then installed over the
first: the job requires exactly one Programs-and-Features entry, the new
version, the shortcut, and an upgraded copy that still loads a window.
`-RequireMsi` makes a missing WiX toolset fail the job instead of silently
skipping the installer. The job uploads `build/windows/dist/**` so the zip and
the MSIs can be inspected. On failure it uploads the published folder
(`windows-app-publish`), so a broken build can be inspected. The job is not a
required check: it is a light editor, and a required Windows context would
block `main` on a runner image that is still proving itself.

The application lives in `Windows/` and is described in
[`../Windows/README.md`](../Windows/README.md). Like the portability job, it is
one operating system, one renderer, no pixel-parity claim: the macOS Core Image
pipeline is not reproduced stage for stage.

## Verified runs

Read from the GitHub Actions API, not simulated locally.

| Date | Ref | Workflow | Result |
|---|---|---|---|
| 2026-11-13 | `eba8075` (PR #13, push and pull request) | `CI` | all four jobs green |
| 2026-11-13 | `260cb41` (merge of PR #13, push to `main`) | `CI` | all four jobs green; no Node deprecation line in any job log |
| 2026-11-13 | `28f8462` (PR #14, push and pull request) | `CI` | five jobs green: three required macOS contexts, `Windows StudioCore` and `Windows App` |
| 2026-11-14 | `d0673d8` (PR #15, push and pull request) | `CI` run 43534410772 | five jobs green; `Windows App` reports `PASS (69 checks)` including the interchange gate |
| 2026-11-14 | `2c50802` (PR #15, documentation only) | `CI` run 43535723386 | five jobs green on the PR head |
| 2026-11-14 | `20d3a8c` (PR #21, Windows 16-bit export) | `CI` run 43557855311 | five jobs green; `Windows App` reports `PASS (108 checks)`, including 16-bit PNG/TIFF depth read from the file headers and sample-exact round trips |
| 2026-11-14 | `2488ae4` (PR #22, Windows MSI) | `CI` run 43561151628 | five jobs green; `Windows App` builds a 398 MB MSI, installs it silently to `Program Files\Retouch Studio`, starts the installed copy into a loaded window, and uninstalls with the folder, shortcut and Programs-and-Features entry gone |
| 2026-11-14 | `657781b` (PR #23, MSI upgrade) | `CI` run 43563787267 | five jobs green; `Windows App` installs 0.0.1.0 over an installed 0.0.0.0, leaving one entry with the new version, an upgraded copy that loads a window, and a clean uninstall |
| 2026-11-14 | `49c3798` (PR #24, Windows batch export) | `CI` run 43566124482 | five jobs green; `Windows App` reports `PASS (116 checks)`, including a three-file batch whose output decodes sample-exactly like a single export, collision-safe names, untouched sources and per-file failure isolation |
| 2026-11-14 | `93ad90a` (PR #24, documentation head) | `CI` run 43567380416 | five jobs green on the exact head; merged as `42a3b65` |
| 2026-11-14 | `1199210` (merge of PR #23) | `CI` run 43565828542, `main` | all five jobs green |
| 2026-11-14 | `42a3b65` (merge of PR #24) | `CI` run 43568795622, `main` | all five jobs green |
| 2026-11-14 | `04defe0` (PR #26, Windows vignette parity) | `CI` run 43573329343 | five jobs green; `Windows App` reports `PASS (118 checks)`; `G11_VIGNETTE: mae 0.473` (was 5.2) now gated at one level; a negative vignette is a no-op, as on macOS |
| 2026-11-14 | `a7d478e6` (merge of PR #26) | `CI` run 43575818731, `main` | all five jobs green |
| 2026-11-14 | `528c597` (PR #27, Windows clarity parity) | `CI` run 43576450870 | five jobs green; `Windows App` reports `PASS (122 checks)`; `G09_CLARITY_UP: mae 0.06` (was 5.8) now gated at one level; positive clarity leaves a flat field untouched and a step edge gains contrast, negative clarity softens it; `G11_VIGNETTE` unchanged at 0.473 |
| 2026-11-14 | `cb9937d` (PR #27, documentation head) | `CI` run 43577351736 | five jobs green on the exact head; merged as `5ce61ca` |
| 2026-11-14 | `5ce61ca` (merge of PR #27) | `CI` run 43578692160, `main` | all five jobs green |
| 2026-11-14 | `c66cf38` (PR #29, colour-managed P3 decode) | `CI` run 43582087464, attempt 2 | five jobs green; `Windows App` reports `PASS (124 checks)`; a Display P3 photo decodes to sRGB within one level of ColorSync at four in-gamut points, and the 16-bit path agrees within four; attempt 1 was cancelled at the 45-minute job timeout while installing the Swift toolchain, with no failing step |
| 2026-11-14 | `1adafa0` (PR #29, documentation head) | `CI` run 43586982825 | five jobs green on the exact head; merged as `413363f` |
| 2026-11-14 | `413363f` (merge of PR #29) | `CI` run 43588258162, `main` | all five jobs green |
| 2026-11-14 | `48b8b75` (PR #31, 16-bit preview) | `CI` run 43593470894 | five jobs green; `Windows App` reports `PASS (131 checks)`; the container depth probe reads PNG IHDR and TIFF BitsPerSample; the 16-bit preview is within one level of the 8-bit preview at rest and 8 levels under a strong adjustment set, gated at 10 |
| 2026-11-14 | `6307c09` (PR #33, custom crop) | `CI` run 43596432866 | five jobs green; `Windows App` reports `PASS (139 checks)`; the eight crop checks fit, resize, move and clamp a box in photo coordinates; merged as `cf3acf9`; the overlay's drag wiring is not driven by CI |
| 2026-11-14 | `249f4c1` (PR #32, throughput and 16-bit crop) | `CI` run 43596513201 | five jobs green; `Windows App` reports `PASS (133 checks)`; the Swift installer download is cached and the job budget is 60 minutes after a 45-minute timeout cancelled an install |


PR #13 was merged with a normal merge commit after every required context and
the non-required `Windows StudioCore` job reported success on the final head.
The post-merge `main` run `43430686940` had jobs `131903102518` (Windows
StudioCore), `131903102840` (Platform-neutral Conformance), `131903102866`
(StudioCore Boundary) and `131903102899` (macOS Integration), all completed with
`success`. The four logs contained zero `Node.js … is deprecated` lines, which
is the acceptance criterion stated above.

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
a native Windows Swift toolchain. It says nothing about the host application;
that is the next job.

### Windows App run (2026-11-13, PR #14)

Run `43439843389` on `28f8462`, job `132239473907` (`windows-2025`), succeeded
and the log ends with:

```
-> building studioscore_core.dll
-> checking the DLL export table
   all 13 exports present
-> collecting the Swift runtime
   copied 142 runtime DLLs
-> publishing the WPF host (win-x64, self-contained)
-> running the Windows host tests
WINDOWS HOST TESTS: PASS (55 checks)
-> smoke-running the published app
   the published app loaded its window: 'Retouch Studio' (native handle 262482)
WINDOWS APP BUILD: PASS
```

The three required macOS contexts reported success on the same head. What is
now proven: the StudioCore C ABI links into a real DLL on Windows, the WPF host
publishes self-contained for x64, its 55 checks pass against the real DLL and
WIC, and the published executable reaches a loaded window. What is still
**NOT VERIFIED**: pixel parity with macOS, HEIC, 16-bit output, metadata, an
installer, a zip release, AI tools and behaviour on a real desktop session.

The first runs of this job found real faults rather than infra noise: a host
test asserted the wrong undo rule (an uncommitted edit is already undoable in
`DocumentHistory`); the smoke check polled `MainWindowHandle`, which a hosted
session does not always expose, and was replaced by a marker written from the
loaded window; and a WPF binding then threw
`Cannot find non-neutral culture related to 'en-us'` on first layout because
`InvariantGlobalization` was on. All three were fixed on the branch. A later
`Windows StudioCore` execution on the same head failed in the Swift toolchain
installer with exit code 12006 before any check ran; the job was re-run and is
recorded above as green.

### Windows App run (2026-11-14, PR #15)

Run `43534410772` on `d0673d8`, all five jobs succeeded. The `Windows App` step
log ends with:

```
-> running the Windows host tests
WINDOWS HOST TESTS: PASS (69 checks)
```

The 14 new checks open the shared macOS fixtures
(`Tests/Fixtures/ProjectV3/project-v3-full.retouch` and
`ProjectV4/project-v4-full.retouch`), save them back, and compare the parsed
JSON with the fixture (key order and whitespace are not part of the portable
contract, so this is structural equality, not byte identity), prove the unknown
top-level key and required feature survive, and prove a v3 save stays v3 with
unkeyed geometry. The unknown key is asserted on the save after a
reopen: the C ABI returns the typed record and carries unknown top-level keys
in the write context, so checking the reopened record was a wrong assertion and
failed the first run of this job before it was corrected in `d0673d8`.

## Release pipeline

[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds an
arm64 DMG, an x86_64 DMG, runs the Windows StudioCore portability job, verifies
every SHA-256 manifest, and publishes a GitHub Release. It triggers on `v*` tag
pushes and on manual dispatch; a manual dispatch runs only the
platform-independent Windows job, because every other job carries
`if: startsWith(github.ref, 'refs/tags/v')`. A manual dispatch therefore cannot
create a release or a non-versioned artifact.

The Windows application job is gated behind the repository variable
`WINDOWS_APP_READY=true` and is still skipped: the host builds and opens a
window, but packaging, signing and a release decision are unverified, so the
variable stays unset. The job now installs the .NET SDK and packages
`build/windows/app`, but it has never executed, and the release job's `needs`
list does not yet include it. Treat the job and `Tools/package-windows.ps1` as
**NOT VERIFIED**; both must be reworked and run before the variable is set. A
green release therefore never implies a Windows product. A job-level
`hashFiles()` condition would be read before `actions/checkout`, so it was
replaced with the repository variable.

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
a Windows toolchain. `Windows App` proves that the light editor in `Windows/`
builds and opens a window on `windows-2025`; it does not prove macOS parity,
packaging or a shipped Windows product.

Linux is not implemented. It remains on the long-term roadmap and starts only
after a Windows release candidate is verified; the repository ships no Linux
build and no CI job here validates one.

The GitHub-hosted `macos-14` runner image was retired on 2026-11-02. This
workflow therefore uses `macos-15` (arm64) instead.
