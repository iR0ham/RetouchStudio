# CI Merge Gates

**Status:** enabled on `main` on 2026-11-13; widened from three to all five
contexts on 2026-11-14. Every check below is required, strict, and enforced for
administrators; force pushes and branch deletion are disabled.
**Actions:** the workflows run `actions/checkout@v7`,
`actions/upload-artifact@v7` and `actions/download-artifact@v8` on the Node 24
runtime, so the deprecated Node.js 20 notices are gone. Both workflows were
installed on 2026-11-13 after the GitHub token gained the `workflow` scope; the
history is under [Action runtimes and versions](#action-runtimes-and-versions).
**Date:** 2026-11-14
**Workflows:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
[`.github/workflows/release.yml`](../.github/workflows/release.yml)

The repository workflow is named `CI`. It runs five jobs and each job reports a
status check under its own name. All five are required merge checks:

| Check | Runner | Command |
|---|---|---|
| `StudioCore Boundary` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` |
| `Platform-neutral Conformance` | `ubuntu-24.04` (x64) | `./Tests/Conformance/run-conformance.sh` |
| `macOS Integration` | `macos-15` (Apple silicon, arm64) | `./Tests/run-studiocore.sh` and `RETOUCH_ARCH=arm64 ./Tests/run.sh` |
| `Windows StudioCore` (required since 2026-11-14) | `windows-2025` (x64) | `./Tests/run-studiocore-windows.ps1` and the conformance gate |
| `Windows App` (required since 2026-11-14) | `windows-2025` (x64) | `pwsh ./Tools/build-windows.ps1 -RequireMsi` |

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

**Correction (2026-11-26) to the paragraph above, measured at `5aac9c3a`.** The
historical claim is kept visible; it is only partly true, and it under-names the
suite list. Verified line by line:

- The job runs three steps into one log: the worker regressions
  (`ci.yml:162-165`, `tee`, which creates the log), the StudioCore gate
  (`ci.yml:167-170`, `tee -a`) and `Tests/run.sh` (`ci.yml:172-177`, `tee -a`).
- `Tests/run.sh` runs two gates plus ten suites, not four suites:
  `Tests/run-studiocore.sh` and `Tests/run-abi.sh` at `Tests/run.sh:41-42`, then
  `run_suite` at `Tests/run.sh:61-70` for Engine, Model, Model Store, Runtime
  Process, Runtime V2, Mask Quality, AI Disclosure, AI Failure Taxonomy, Runtime
  Install and Runtime Transfer.
- The `Assert every suite reported a verdict` step (`ci.yml:179-207`) greps
  twelve patterns in `$RUNNER_TEMP/macos-integration.log`. **One** of them is
  derived from a file — `Ran ${expected_worker_tests} tests` at `ci.yml:184`,
  from `Tests/expected-worker-tests.txt`, which holds `286` at this commit. The
  other **eleven** (`ci.yml:185-195`) are hardcoded literals. So the single-source
  rule holds for the worker count only; the suite verdict list has no source of
  truth in the repository.
- Two verdict lines are produced into that log and never asserted:
  `MASK QUALITY TESTS: PASS` (`Tests/MaskQualityTests.swift:853`, suite 6 of 10)
  and `ABI TESTS: PASS (104 checks)` (`Tests/ABI/abi_tests.c:578`, executed at
  `Tests/run-abi.sh:68`). `grep -qE 'MASK QUALITY|ABI TESTS'` over
  `.github/workflows/ci.yml` finds nothing (exit 1).
- Both enforcement directions, stated exactly: removing, renaming or rewording
  one of the twelve asserted literals fails the job, because the `grep -qE` at
  `ci.yml:196` exits 1 under the `set -euo pipefail` set at `ci.yml:181`; removing
  `Tests/run.sh:66` (Mask Quality) or the `Tests/run-abi.sh` call at
  `Tests/run.sh:42` keeps the job green, because no assertion asks for either
  line. A new suite added to `Tests/run.sh` is likewise unenforced until someone
  hand-adds its literal. This is the defect recorded as **A4** in
  `Docs/RELEASE_2.0.0_READINESS.md:881-883`; that ticket's own citation
  "`ci.yml:164-175`" is stale — the assertion step is `ci.yml:179-207`.
- What *is* still caught, so this is not a claim that the gate is hollow: a
  **failing** suite fails the run. `Tests/run.sh:8` is `set -euo pipefail`,
  `Tests/MaskQualityTests.swift:858` exits 1 on failure and
  `Tests/ABI/abi_tests.c:576` returns 1, so `ci.yml:177` aborts before the
  assertion loop. The step also turns self-skipping into failure: any line
  matching `NOT run` in the same log aborts the job with the offenders echoed
  (`ci.yml:199-206`). The exposure is therefore silent *omission* of a suite or of
  a verdict word — not suppression of a failure, and not a skipped suite passing
  unseen.

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
`cc`) and `PYTHON=python`. The job is a required check since 2026-11-14. It
first ran green on `eba8075` (PR #13) on 2026-11-13, which confirms the runner
label, the third-party action, the toolchain tag and the `clang` assumption; the
run is recorded under [Verified runs](#verified-runs).

The Windows gap and the intended implementation are analysed in
[`WINDOWS_IMPLEMENTATION_PATH.md`](WINDOWS_IMPLEMENTATION_PATH.md).

## Windows application job

`windows-app` in `ci.yml` installs Swift 6.4.2 and the .NET 10 SDK on
`windows-2025` — the Swift installer download is cached by the setup action —
and runs `Tools/build-windows.ps1 -RequireMsi`, which builds the
Foundation-only core, links it into `studioscore_core.dll` with the 13-entry
`.def` export list, publishes the WPF host self-contained for x64, runs the 169
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
the MSIs can be inspected. On 2026-11-15 the script gained one version input:
`-PackageVersion` stamps the published assembly (`Tools/build-windows.ps1:160-162`)
and names the zip and the MSI, and it defaults to the `Version` in
`Windows/Directory.Build.props` (`Tools/build-windows.ps1:37-38`). Until then
`dotnet publish` received no version, so a tag reached the artifact names but the
executable kept the props value. The release workflow passes the tag version
(`release.yml:129-132`). On failure it uploads the published folder
(`windows-app-publish`), so a broken build can be inspected. The job is a
required check since 2026-11-14, by owner direction: Windows is a first-class
product, so a Windows regression must be able to block `main`. The job had
already run green on every PR between 2026-11-13 and the switch, including the
runs recorded below.

**Addendum (2026-11-17, W5-4 Slice 1).** `build-windows.ps1` output now tees to
`$RUNNER_TEMP/windows-app.log`, and a following step fails the job unless that
log reports `WINDOWS APP BUILD: PASS`, `AI RUNTIME TESTS: PASS`, `ONNX Runtime
1.32.0 matches the recorded size and SHA-256`, `AI worker, protocol library and
ORT CPU payload present` and `upscale stays blocked without an approved
artifact`. Those five lines are what the run proved about Windows AI, including
the refusal; a script that threw partway never prints the later ones, so the
assertion — not the step's own exit status — is what closes the gap between a
green job and a green claim. The log travels with the failure artifact. No
required check, runner, timeout or job was added or removed, and no assertion
was relaxed. In the `macOS Integration` verdict list the worker pin moved from
`Ran 88 tests` to `Ran 100 tests` with the twelve new worker tests. No run on
this head exists yet, so the widened gate itself is unverified until CI executes
it.

**2026-11-17, executed.** Run `44145839011` on head `fec5930` ran that widened
gate: `Windows App` passed in 14m16s with its step
"Assert every Windows verdict was reported" succeeding, and the job log carries
`found: WINDOWS APP BUILD: PASS`, `found: AI RUNTIME TESTS: PASS`,
`found: ONNX Runtime 1.32.0 matches the recorded size and SHA-256`,
`found: AI worker, protocol library and ORT CPU payload present` and
`found: upscale stays blocked without an approved artifact`. `macOS Integration`
passed in 17m1s with `Ran 100 tests in 2.880s / OK`, `StudioCore: 288 checks
passed` and `ABI TESTS: PASS (104 checks)`. The assertion step is therefore
proven to fire on real output. What it proves about Windows is the generic host
build plus an upscale **refusal**; it establishes no Windows inference. The
publication work later the same day pins `Ran 115 tests`, and that pin is
unverified until CI executes it.

**2026-11-17, later.** The macOS Integration job of head `9b2b807`
(`134322437405`) executed that pin: `found: Ran 115 tests`, `ENGINE TESTS:
PASS`, `MODEL TESTS: PASS`, `StudioCore: 288 checks passed` and `ABI TESTS:
PASS (104 checks)` — so the fifteen publication tests pass in the pinned
source-built 3.13 environment, not only in the developer venv. Windows App and
StudioCore Boundary were also green on that head. The independent review then
moved the pin to `Ran 120 tests`, which stays unverified until the next macOS
run prints it.

**2026-11-18.** That sentence is now historical: run `44174322949`, macOS
Integration job `134361670612`, printed `found: Ran 120 tests` on head
`54e3e60`. The submission-boundary work of the same day adds two worker tests —
the named-versus-kind-only pair and the frozen-field tripwire — so the pin moves
to `Ran 122 tests` for the next run to execute.

**2026-11-18, later.** Also historical: run `44211766326`, macOS Integration
job `134491776648`, printed `found: Ran 122 tests` on head `6c28281`, and PR
#70 merged as `480fe88`. This branch now carries both halves of that day's
work — the two submission-boundary tests and the two acceptance-harness tests —
so the merged suite is 124 tests and every pin (`ci.yml`,
`Tests/run-worker.sh`, `Docs/W5_ADAPTERS.md`,
`Docs/worker-regressions/README.md`, `worker/README.md`) moves to
`Ran 124 tests` for the next run to execute.

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
| 2026-11-14 | `cf3acf9` (merge of PR #33) | `CI` run 43597640995, `main` | all five jobs green on the merged tree |
| 2026-11-14 | `6f65650` (PR #36, Windows performance and stress) | `CI` run 43598349755 | five jobs green; `Windows App` reports `PASS (145 checks)`; `perf preview 1600x1067 nine sliders: median 1187 ms (1189 1187 1189 1166 1137)`, `perf 16-bit PNG export 1594 ms`, forty stress documents render, repeat pixel-identically, and keep the source area |
| 2026-11-14 | `dd7177f` (PR #34, unsupported-edit guard) | `CI` run 43599860760 | five jobs green; `Windows App` reports `PASS (146 checks)`; both interchange fixtures name the six unrenderable edits, empty lists and disabled tools name none, one sticker warns |
| 2026-11-14 | `dd14310` (merge of PR #34) | `CI` run 43600764519, `main` | all five jobs green |
| 2026-11-14 | `1c3bae1` (PR #36 head, merged as `3fa6883`) | `CI` run 43600876917 | five jobs green; `Windows App` reports `PASS (152 checks)`; the perf lines print again (median 1056 ms, export 1368 ms), meeting the budgets on a second runner |
| 2026-11-14 | `0ab9a4d` (`workflow_dispatch` of `Release`) | `Release` run 43598113385 | four build jobs green, publish skipped by design: both per-arch DMGs and the Windows zip and MSI built and uploaded; artifacts re-verified locally (`shasum -c` OK, `hdiutil verify` valid, ad-hoc signature valid, Gatekeeper rejection expected without notarization); the run exposed the `$CONFIG` multibyte fault in `build.sh` and the leftover upgrade MSI |
| 2026-11-14 | `d57aa78` (merge of PR #32) | `CI` run 43599028784, `main` | all five jobs green |
| 2026-11-14 | `07c7713` (PR #38 head, merged as `b6b72cb`) | `CI` run 43603560807 | five jobs green; `Windows App` reports `PASS (156 checks)`; a crop renders the 205x134 box at (26, 19) of the photo, a flip mirrors each row and a quarter turn reads the clockwise source, against indices written in the test |
| 2026-11-14 | `b6b72cb` (merge of PR #38) | `CI` run 43604723334, `main` | all five jobs green on the merged tree |
| 2026-11-14 | `d233a3d` (PR #37 head, merged as `32912ba`) | `CI` run 43604785315 | five jobs green; the export long edge is chosen in the dialog and reaches the plan |
| 2026-11-14 | `32912ba` (merge of PR #37) | `CI` run 43605954063, `main` | all five jobs green |
| 2026-11-14 | `1bf843e` (PR #39 head, merged as `a5e65eb`) | `CI` run 43606194309 | five jobs green; `Windows App` reports `PASS (169 checks)`; the orientation/crop order, the turn-straighten-mirror composition in both depths and the crop that follows a turn are proved pixel for pixel |
| 2026-11-14 | `a5e65eb` (merge of PR #39) | `CI` run 43607538778, `main` | all five jobs green on the merged tree |
| 2026-11-14 | `60513b8` (PR #41 head, merged as `4422df3`) | `CI` run 43610920612 | five jobs green; `Windows App` reports `PASS (169 checks)`; the smoke step prints each copy's time to first window (895 / 762 / 2094 / 2080 ms) and the perf lines |
| 2026-11-14 | `4422df3` (merge of PR #41) | `CI` run 43612107743, `main` | all five jobs green |
| 2026-11-14 | `863f528` (PR #42 head) | `CI` run 43612284616 | five jobs green; `Windows App` reports `PASS (171 checks)`; the overlay draws thirds, slides from inside, reads the pixel size and compares against the untouched photo; its drag wiring is not driven by CI |
| 2026-11-14 | `11f670c` (PR #44 head, merged as `2c0d1fa`) | `CI` run 43611687120 | five jobs green; `Windows App` reports `PASS (172 checks)`; the histogram bins are pinned against a four-pixel fixture |
| 2026-11-14 | `2c0d1fa` (merge of PR #44) | `CI` run 43614356967, `main` | all five jobs green |
| 2026-11-14 | `0e0be3d` (PR #44 head) | `CI` run 43613038894 | five jobs green; `Windows App` reports `PASS (172 checks)`; start-up 907 / 1649 / 662 / 764 ms |
| 2026-11-14 | `de269d8` (PR #42 head, merged as `53e1c36`) | `CI` run 43615178242 | five jobs green; `Windows App` reports `PASS (174 checks)`; start-up 896 / 1097 / 4395 / 2751 ms; the run that gates the #42 merge |
| 2026-11-14 | `53e1c36` (merge of PR #42) | `CI` run 43616466216, `main` | all five jobs green on the merged tree |
| 2026-11-14 | `6a80ba1` (PR #45 head) | `CI` run 43612517678 | five jobs green; `Windows App` reports `PASS (170 checks)`; the managed heap is flat across twenty photo-sized renders |
| 2026-11-14 | `e43412b` (PR #47 head) | `CI` run 43618132157 | five jobs green; `Windows App` reports `PASS (184 checks)`; the parallel per-row adjustment pass measured a median 721 ms preview and passed the repeat-render byte checks |
| 2026-11-14 | `e940271` (merge of PR #45) | `CI` run 43618192192, `main` | all five jobs green on the merged tree |
| 2026-11-14 | `3e4b517` (PR #46 head, merged as `03748fe`) | `CI` run 43618240754 | five jobs green; `Windows App` reports `PASS (184 checks)`; zoom, pan and the before/after split; the run that gated the #46 merge |
| 2026-11-14 | `49a028d` (PR #47 head, merged as `f58b336`) | `CI` run 43619500646 | five jobs green on the exact head; `Windows App` reports `PASS (184 checks)`; the run that gated the #47 merge |
| 2026-11-14 | `f58b336` (merge of PR #47) | `CI` run 43620792640, `main` | all five jobs green on the merged tree |
| 2026-11-14 | `e4bc466` (PR #48 head, merged as `4a034cd`) | `CI` run 43620925118 | five jobs green after `main` was merged into the branch; the run that gated the #48 merge |
| 2026-11-14 | `4a034cd` (merge of PR #48) | `CI` run 43622071155, `main` | all five jobs green on the merged tree; the last post-merge `main` matrix, because push runs to `main` were removed in the same change (see [Post-merge runs and CI cadence](#post-merge-runs-and-ci-cadence)) |
| 2026-11-14 | `675ae0a` (PR #49 head, merged as `be9a46d`) | `CI` run 43623366599 | five jobs green — the first run gated by all five required contexts, including `Windows StudioCore` and `Windows App`; the run that gated the #49 merge |
| 2026-11-14 | `78f8cc5` (develop milestone head) | `CI` run 43631106819, `workflow_dispatch` on `develop` | five jobs green; `Windows App` reports `PASS (253 checks)`; the candidate recovery store proves lift, restore, discard, quarantine and injected write/remove failures; a no-op export is pixel-identical in 8 and 16 bits because the decoder recognises its own sRGB profile, and the one test that compared a candidate with itself was corrected |
| 2026-11-14 | `91dde65` (PR #54 head, merged as `4e31596`) | `CI` run 43632188008 | five jobs green on the exact head; `Windows App` reports `PASS (253 checks)`; the run that gated the #54 merge |
| 2026-11-14 | `bb06e28` (`windows/ui-automation`, merged into `develop` as `7af20f2`) | `CI` run 43647604771, `workflow_dispatch` on `windows/ui-automation` | five jobs green; `Windows App` reports `PASS (258 checks)` and two UI-automation passes: the golden path opens the photo through the Open dialog, moves Exposure through UIA, reaches 150% zoom, types the export path into the Save dialog's file-name edit as keystrokes, commits it with Enter and reads the 42609-byte 512×512 JPEG back; the recovery path answers the seeded prompt, keeps the unsaved Exposure value and closes cleanly |
| 2026-11-14 | `88dc743` (`windows/guard-coverage`, merged into `develop` as `092206f`) | `CI` run 43651063832, `workflow_dispatch` on `windows/guard-coverage` | five jobs green; `Windows App` reports `PASS (263 checks)` and both UI-automation passes; the export guard now names every macOS-only adjustment group (skin, face, makeup, look, grain, curves, HSL, body, background, hair, lens) while the nine renderable sliders and a lone background blend amount stay silent |
| 2026-11-14 | `c80a8c1` (`windows/guard-ui`, merged into `develop` as `7af37cf`) | `CI` run 43653664500, `workflow_dispatch` on `windows/guard-ui` | five jobs green; `Windows App` reports `PASS (263 checks)` and three UI-automation passes: golden, recovery and guard — a codec-saved project carrying `smooth` 30 opens through the Open Project dialog, Export raises the unsupported-edit prompt naming skin retouching, No writes nothing, and the app closes cleanly |
| 2026-11-14 | `39e3cb0` (`windows/project-ui`) | `CI` run 43654765580, `workflow_dispatch` on `windows/project-ui` | five jobs green; `Windows App` reports `PASS (263 checks)` and four UI-automation passes; Save Project writes 2801 bytes through its dialog, the title loses its unsaved marker, and Undo returns Exposure to 0 through the button |
| 2026-11-15 | `7d3a89b` (`windows/batch-ui`, merged into `develop` as `5cd65a1`) | `CI` run 43655814761, `workflow_dispatch` on `windows/batch-ui` | five jobs green; `Windows App` reports `PASS (263 checks)` and five UI-automation passes; the batch photo picker takes a photo, the folder picker takes a folder, and the batch writes a 48603-byte 512×512 JPEG that decodes back |
| 2026-11-15 | `6e09cc7` (`windows/reopen-ui`, merged into `develop` as `65b672f`) | `CI` run 43658018867, `workflow_dispatch` on `windows/reopen-ui` | five jobs green; `Windows App` reports `PASS (263 checks)` and six UI-automation passes; Redo reapplies Exposure 40, the second Save writes without a dialog, and a fresh process reopens the saved project with Exposure still at 40 |
| 2026-11-15 | `15d89fe` (`windows/sliders-ui`, merged into `develop` as `83900a9`) | `CI` run 43659238621, `workflow_dispatch` on `windows/sliders-ui` | five jobs green; `Windows App` reports `PASS (263 checks)` and six UI-automation passes; all nine global sliders take their values through UIA before the export |
| 2026-11-15 | `00a48d6` (`develop`, reconciliation merge) | `CI` run 43660568463, `workflow_dispatch` on `develop` | five jobs green; `Windows App` reports `PASS (263 checks)` and five UI-automation passes; the merge of `origin/main` (`df289cf`) leaves the develop tree identical to its pre-merge state |
| 2026-11-15 | `04dac17` (`windows/iptc-carry`, merged into `develop` as `30cb277`) | `CI` run 43663201459, `workflow_dispatch` on `windows/iptc-carry` | five jobs green; `Windows App` reports `PASS (268 checks)` and five UI-automation passes; a JPEG carries the source's Photoshop IPTC resource (8BIM 0x0404) byte for byte, and an overlong resource is skipped instead of read out of bounds |
| 2026-11-15 | `431783b` (`windows/exif-compose`) | `CI` run 43671478242, `workflow_dispatch` on `windows/exif-compose` | five jobs green; `Windows App` reports `PASS (283 checks)` and five UI-automation passes; a TIFF source exports a composed EXIF block that macOS ImageIO reads in full (GPS, date, lens, model, 35°41′12″N 51°25′3″E), while WIC's WinRT properties report `System.GPS.Latitude` absent for the composed block and for a macOS-written control JPEG |
| 2026-11-15 | `17ed293` (`windows/crop-ui`, merged into `develop` as `2b56992`) | `CI` run 43681175327, `workflow_dispatch` on `windows/crop-ui` | five jobs green; `Windows App` reports `PASS (283 checks)` and seven UI-automation passes; the bottom-right crop corner is hit-tested and dragged with injected pointer input from 512×512 to 449×472, Apply crop commits it and the exported file decodes at 449×472; the compare toggle is clicked with the pointer, the divider is dragged 80 px right and back within 6 px, and turning Compare off removes it |
| 2026-11-15 | `26c59be` (merge of `windows/face-identity`) | `CI` run 43685429036, `pull_request` on `develop` (PR #57) | five jobs green; `WINDOWS HOST TESTS: PASS (283 checks)` and seven UI-automation passes; the chosen face keeps its identity across a crop: boxes are mapped into the original photo's normalised bottom-left frame and matched one-to-one at IoU ≥ 0.5, an absent face's box is remembered, and the selection index is re-derived after re-detection. The matching checks run in the macOS Model suite (`testFaceSelectionFollowsIdentity`) |
| 2026-11-15 | `0c88498` (`windows/zoom-pan-ui`, merged into `develop` as `ca637ee`) | `CI` run 43696215085, `workflow_dispatch` on `windows/zoom-pan-ui` | five jobs green; `Windows App` reports `PASS (283 checks)` and eleven UI-automation passes; pointer zoom reaches 150% and the dock reports it, a drag pans the canvas without changing the zoom, and Fit restores the exact opening view; a 64-source batch reports `Exported 9 of 64…`, Cancel stops it between files (`Export cancelled after 10 of 64 photos.`) and the folder holds exactly those 10; a corrupt photo and a locked destination are each reported, with the locked file left untouched; declining a recovered copy leaves an empty editor and the next launch offers nothing. The file picker's view is virtualised, so the sources are ticked by clicking one row and pressing Ctrl+A; a posted Enter never navigates the shell, so the folder is entered with an injected Return |
| 2026-11-15 | `089a413` (`reliability/completion`, PR #59) | `CI` run 43736047883, `workflow_dispatch` on `reliability/completion` | five jobs green; `WINDOWS HOST TESTS: PASS (370 checks)` and twelve UI-automation passes, including the corrupt-project, held-save and held-export reports; `StudioCore: 287 checks passed`, `ABI TESTS: PASS (104 checks)`, engine, model and runtime PASS. Adds to `ac75eb4`'s 368 checks two recovery checks: a restore that cannot write reports failure and re-locks the working slot, so the next autosave cannot replace the only unresolved copy. The `pull_request` trigger targets only `main`, so a PR into `develop` runs nothing on its own and this run was dispatched at the head. |
| 2026-11-15 | `b90aa54` (`w4/color-corpus`, merged into `develop` as `75e4837`; PR #60) | `CI` run 43749112787, `workflow_dispatch` on `w4/color-corpus` | five jobs green; `WINDOWS HOST TESTS: PASS (384 checks)` and twelve UI-automation passes; `corpus lock: 13 fixtures, 78 cases, 21 references, 11 exports` and `corpus geometry (additive, approved): 7 cases, 7 references`; `GeometryEvidence()` prints `Q01_CROP_CENTER: mae 0 psnr 99`, `Q02_CROP_EDGE: mae 0 psnr 99`, `Q03_STRAIGHTEN_CW: mae 0.008 psnr 69.04`, `Q04_STRAIGHTEN_CCW: mae 0.008 psnr 68.85`, `Q05_STRAIGHTEN_CROP: mae 0.011 psnr 67.87`, `Q06_TURN_STRAIGHTEN_CROP: mae 0.014 psnr 66.7`, `Q07_MIRROR_CROP: mae 0 psnr 99`; the crop and mirror references are byte-exact on both hosts, the straighten numbers are measured but no tolerance is approved. The `pull_request` trigger targets only `main`, so a PR into `develop` runs nothing on its own and this run was dispatched at the head |
| 2026-11-16 | `5fec82d` (`reliability/shutdown`) | `CI` run 43758837302, `workflow_dispatch` on `reliability/shutdown` | five jobs green; `WINDOWS HOST TESTS: PASS (396 checks)` and **fourteen** UI-automation passes, including `exportcancel` (the Cancel Export button clicked on a 4000×3000 16-bit photo — it opens, the button is disabled while idle, enabled once the export runs, and the click yields `Export cancelled.` with no destination and no temp sibling) and `exportclose` (the window closed mid-export answers the unsaved-work question, cancels, unwinds, exits 0, no destination, no temp); the +7 Windows checks are `SixteenBitGeometry`, which drives the two 16-bit resamplers and a real 16-bit straighten export after the byte-offset defect fixed in `59b4287`; `StudioCore: 288 checks passed` on both hosts, `ABI TESTS: PASS (104 checks)` on both, engine/model/runtime-process/runtime-v2 `PASS`, `R1 conformance: PASS`, `StudioCore Windows portability check: PASS`; the headless suite also refuses an export into a folder denied by a real ACE (`icacls /deny`, `714b142`) |
| 2026-11-23 | `c68995b` (PR #120 head, merged as main `f356838`) | `CI` run 45101960656, `pull_request` targeting `main` | all seven jobs `completed/success`, i.e. the five strict contexts plus the two advisory worker jobs. `WINDOWS HOST TESTS: PASS (405 checks)` — the figure that supersedes the 55 checks still quoted as `28f8462`'s 2026-11-13 baseline in `Docs/WINDOWS_IMPLEMENTATION_PATH.md`, which is why that number is now dated where it reads. `macOS Integration` asserts every suite printed a verdict and reports `found: Ran 203 tests` for the worker, the count `#114` raises to 211 through the single source `Tests/expected-worker-tests.txt`. The run checked out `refs/pull/120/merge`, whose tree is `f356838`'s tree, so the merge itself is what these verdicts cover. |
| 2026-11-14 | `be9a46d` (merge of PR #49) | no post-merge run | merge of `675ae0a` after five green required checks; no `main` push matrix was created, which is the behaviour PR #49 introduced. The `pull_request` run had checked out `refs/pull/49/merge`, whose tree is this commit's tree, so no tree went unvalidated |

`ci.yml` runs on `pull_request` targeting `main` and on pushes to
`v1-macos-delivery`, `m5-cross-platform-core` and `ci/**`; pushes to `main` no
longer run it (see
[Post-merge runs and CI cadence](#post-merge-runs-and-ci-cadence)). The
pull-request event checks out `refs/pull/N/merge` — the head merged into the
current `main` — so the run validates exactly the tree the merge commit will
contain. A pull request stacked on another feature branch still receives no
checks, because the base is not `main`. PR #43 was opened that way and never
ran; its commits were folded into PR #42 instead (which targets `main`) and #43
was closed as merged when the base branch merged. Any new work that needs a
green run must target `main`, either directly or by merging the base branch in.


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
pushes and on manual dispatch. Only the `release` job carries
`if: startsWith(github.ref, 'refs/tags/v')` (`release.yml:160`), so a manual
dispatch builds and uploads the per-run artifacts to the run but never creates
a Release.

The release job's conditions were corrected on 2026-11-15
(`release.yml:151-167`). It used to inherit the skip of a gated job through
`needs`, so while `WINDOWS_APP_READY` was unset a tag skipped `windows-app`,
skipped the dependent `release`, and produced no Release at all. The job now
uses `always()` with explicit result checks: it runs when every macOS and core
job is `success` and `windows-app` is `success` or `skipped`, and it is skipped
when any of them is `failure` or `cancelled`; `!cancelled()` keeps an
explicitly cancelled run from publishing. A skipped Windows application
therefore publishes the macOS artifacts, and a failed job still blocks the
release.

The release job also runs `Tools/check-versions.sh` with the tag version
(`release.yml:174-175`) before downloading artifacts, so a tag that disagrees
with `Resources/Info.plist` and `Windows/Directory.Build.props` fails the
release instead of publishing mislabelled files. CI runs the same script
without a tag (`ci.yml:73-74`), so the two version sources cannot drift between
releases.

The Windows application job is gated behind the repository variable
`WINDOWS_APP_READY=true` (`release.yml:111`). With the variable unset a tag run
skips it, and since 2026-11-15 the release still publishes the macOS artifacts
without a Windows package. A green release therefore never implies a Windows
product. The gate is a product decision, not a statement that the job is
untested: the dispatch recorded on 2026-11-14 (run 43598113385) built and
uploaded both DMGs and the Windows zip and MSI, and the required `Windows App`
check runs the same script on every PR. A job-level `hashFiles()` condition
would be read before `actions/checkout`, so it was replaced with the repository
variable.

No paid signing certificate or notarization is used; macOS builds are ad-hoc
signed and Windows output is unsigned.

## Post-merge runs and CI cadence

Since 2026-11-14 `ci.yml` no longer runs on pushes to `main`. The reason is
that the post-merge matrix was a provable duplicate: strict required checks
force the pull-request head to contain the current `main` tip, and the
`pull_request` checkout uses `refs/pull/N/merge`, whose tree is exactly the
tree of the merge commit GitHub then creates. The five jobs for that tree had
already passed before the merge, so the push run re-validated the same tree for
about twenty minutes of hosted-runner time and competed with the next
workstream's runs. PR #47 and PR #48 are the last two merges with a post-merge
run recorded in [Verified runs](#verified-runs) above.

What replaces it:

- `workflow_dispatch` still starts the full five-job matrix on any ref, so a
  direct push to `main` (outside this project's policy) can be validated by
  dispatching on that SHA.
- Pushes to `ci/**` still run the workflow, so a workflow change is tested
  before it is proposed.
- `concurrency` cancels a superseded `pull_request` run when the same PR is
  pushed again; `cancel-in-progress` is off for non-PR events, so an
  intentionally dispatched run is never cancelled.
- The full matrix runs once per coherent merge candidate. Intermediate commits
  are validated with focused local suites; a red or missing required check
  still blocks the merge.
- Since the 2026-11-14 steering ([`WORKFLOW.md`](WORKFLOW.md)) development is
  GitHub-based and milestone-driven: work is pushed continuously to organized
  development branches (folded into the shared `develop` integration branch),
  a dispatch on `develop` or the milestone branch runs the full matrix at a
  milestone boundary, and a milestone PR is the only PR that reaches `main`.
  Targeted checks run during development; there are no per-task PRs, no
  documentation-only PRs and no re-dispatches for an unchanged head.

If GitHub's settings ever require a post-merge run again, re-add `main` to the
`push.branches` list in `ci.yml`; the rest of the gate is unchanged.

## Branch protection for `main`

All five status checks are required. Their exact context names were read from
the check runs of `main` at `4a034cd` before the protection was changed:

```
StudioCore Boundary
Platform-neutral Conformance
macOS Integration
Windows StudioCore
Windows App
```

The policy was applied on 2026-11-14 and read back with
`gh api repos/iR0ham/RetouchStudio/branches/main/protection`: strict, the five
contexts above, `enforce_admins` on, force pushes off, deletions off, no
required review. The read-back is:

```json
{"strict": true,
 "contexts": ["StudioCore Boundary", "Platform-neutral Conformance",
              "macOS Integration", "Windows StudioCore", "Windows App"],
 "admins": true, "force_push": false, "deletions": false}
```

The configuration is reproduced here so it can be re-applied if it is ever
lost. The `checks` form binds each context to the GitHub Actions app, which is
the binding the live policy uses:

```bash
gh api -X PATCH \
  repos/iR0ham/RetouchStudio/branches/main/protection/required_status_checks \
  --input - <<'JSON'
{
  "strict": true,
  "checks": [
    {"context": "StudioCore Boundary", "app_id": 15368},
    {"context": "Platform-neutral Conformance", "app_id": 15368},
    {"context": "macOS Integration", "app_id": 15368},
    {"context": "Windows StudioCore", "app_id": 15368},
    {"context": "Windows App", "app_id": 15368}
  ]
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

## W5-5 gate audit (2026-11-18)

An audit of the five `CI` jobs against the W5-5 brief ("missing gates,
duplicated or misleading checks") produced four findings; three are
implemented here, one is recorded for the owner. Evidence standard: the
findings below were read from `ci.yml` at `67486d0` plus the scripts the
jobs invoke, not from memory.

1. **Missing gate — a pull request targeting `develop` ran no CI.**
   `on.pull_request.branches` listed only `main`, so any stacked or staged PR
   against the integration branch was unguarded. `develop` is now listed next
   to `main`. Pushes stay deliberately unlisted for both branches (the merge
   tree has already been proven by the pull-request run; the comment at the
   top of `ci.yml` records that reasoning).
2. **Missing gate — `Windows StudioCore` had no verdict assertion.** Every
   other job asserts its recorded verdict from the log (macOS asserts the
   suite lines, Windows App asserts five verdicts), but `windows-core` relied
   on the script's exit code through a bare invocation. The run step now tees
   to a log and a new assert step requires `StudioCore Windows portability
   check: PASS`; the script prints that line only after `if ($failed) { exit
   1 }` passes, so a partially-run script fails the assert exactly the way
   the Windows App job's comment describes. The log is added to the failure
   upload.
3. **Misleading gap — the acceptance harness was untested.** The W5-4 harness
   (`worker/tools/upscale_acceptance.py`) existed as a tool with no
   regression coverage, so a protocol change could silently break the very
   gate the owner will later trust. `worker/tests/test_upscale_acceptance_tool.py`
   now drives the harness as a subprocess against a deterministic fake engine
   over a real socket and judges both outcomes the real approval will
   produce: exit 2 with the recorded refusal when the capability is not
   `supported`, and the five-gate pass (dimensions, provenance, cleanup,
   provider, cancelCleanup) with the cancelled job leaving nothing. The
   worker suite count moves `120 → 122` and every pin (`Tests/run-worker.sh`,
   `ci.yml`, `Docs/W5_ADAPTERS.md`, `Docs/worker-regressions/README.md`)
   moves with it; the new pin is unverified until the next macOS job executes
   the suite.
4. **Deliberate duplication, now recorded rather than removed.**
   `StudioCore Boundary` (macOS, fast PR signal) and the StudioCore step
   inside `macos-integration` run the same script, and the platform-neutral
   conformance gate runs on both `ubuntu-24.04` and the Windows image. Both
   are intentional: the boundary exists for early signal, the integration
   copy pins the verdict into the full-suite log, and the double-platform
   conformance is what makes "platform-neutral" a tested claim rather than a
   name. Removing either would save a minute and lose a proof, so they stay
   and are recorded here as deliberate.

Also in this branch, from the independent review of PR #70: the Windows
provider record for an unavailable runtime carried its explanation under
`error` while macOS and the shared fixture's unavailable-shape convention use
`reason` (the macOS suite asserts the field). The Windows adapter now emits
`reason`, and both platforms' contract tests assert the fixture provider
shape `{id, state, execution_providers}` with the `reason` explanation when
unavailable. The Windows runner can only observe the available shape live;
the unavailable branch is exercised by the macOS helper test, and that
asymmetry is stated in the Windows test's comment.

Follow-up (2026-11-18, `0688fa9`): opening PR #71 (base `w5-4/upscaler`) with
no checks reported exposed the same unguarded-PR class as finding 1 — the
filter matched only the two integration branches, so a stacked milestone PR
ran nothing. `pull_request.branches` now also carries `w5-**`, so every PR in
the W5 stack passes the same five contexts regardless of where its base
lands. The audit's finding 1 therefore closes in its general form.

Follow-up (2026-11-18, after `480fe88`): **finding 5 — the Intel slice is not
a gate, and its local run already fails at the base.** The macOS Integration
job pins `RETOUCH_ARCH: arm64`, so none of the five required contexts compiles
or runs an x86_64 test binary; `Docs/CROSS_PLATFORM_COMPATIBILITY.md` has
always labelled the x86_64 result as Rosetta evidence rather than native Intel
validation. Measuring it on this head for the W5-4 verification round gave
`StudioCore: 288 checks passed`, `ABI TESTS: PASS (104 checks)` and
`ENGINE / MODEL / RUNTIME PROCESS / RUNTIME V2 TESTS: PASS`, but
`MODEL STORE TESTS: FAIL (11)` — the cases whose *child process* performs the
install ([10] lease-during-delete, [12] two processes one winner, [13] crash
injection; in-process fixture installs all pass under the same translation).
The identical 11 checks fail when the same suite is built and run at the base
commit `40b157f`, which carries none of W5-4's changes and touches none of
`ModelStore`, `ModelManager`, `LockFile`, `ModelCatalog` or
`ModelStoreTests`, so the failure is a property of `main` on this machine that
this round discovered rather than a finding against either PR. The mechanism
is **not root-caused here and no claim about it is made.** Options for the
owner, in order of cost: run the x86_64 suites as a sixth, non-required CI
context on the `macos-15` runner (`arch -x86_64`, which would have caught this
before it reached a milestone branch); root-cause the child-process install
failure in its own slice; or record the arm64-only scope in
`Docs/CROSS_PLATFORM_COMPATIBILITY.md` and accept it as Rosetta evidence with
a known gap. Nothing in W5-4 or W5-5 changes this behaviour.

**Resolution (2026-11-18, `fix/model-test-child-platform`): the middle option
was taken and the cause was in the harness, not in Rosetta.**

- Root cause. The `--install-once` and `--delete-once` child modes built their
  `ModelStore` without a `platform:` argument, so it took the default
  `ModelPlatform.current` (`Sources/RetouchStudio/Models/ModelStore.swift:227`),
  which is chosen by `#if arch(arm64)` in
  `Sources/RetouchStudio/Models/ModelCatalog.swift:248-255`. An x86_64-compiled
  child therefore asked for `macos-x64`, which no fixture catalog offers — every
  entry in `Tests/Fixtures/model-store/` lists `["macos-arm64","windows-x64"]`
  and `macos-x64` appears nowhere — so `install` refused at its own platform
  guard (`ModelStore.swift:320-321`, via `ModelCatalog.swift:137-139`) and the
  child exited 2 before any socket, lock, staging tree or crash hook was
  reached. The parent always passed the fixture platform explicitly, which is
  why only the child-process cases failed and why in-process installs passed
  under the same translation. That explains each recorded symptom: `[2, 2]`
  where `[0, 3]` was expected, status 2 instead of 86, a staging count of 0
  because no staging was ever created, and a delete that saw no lease.
- Fix. One `fixturePlatform` constant in `Tests/ModelStoreTests.swift`, now used
  by the parent store, both child modes and the legacy-layout store, so a child
  cannot resolve a different platform from the parent that launched it. No
  product code changed.
- Measured on this head, this machine (MacBook Air M3), one variable at a time,
  same command in both runs
  (`RETOUCH_WORKER_PYTHON=/private/tmp/rs-worker-venv/bin/python3 RETOUCH_ARCH=x86_64 Tests/run.sh`):
  at `36dd06d` without the constant, `MODEL STORE TESTS: FAIL (11)` — the ten
  child-process checks named in finding 5 plus their summary line; with the
  constant, the full x86_64 matrix is green: `StudioCore: 288 checks passed`,
  `ABI TESTS: PASS (104 checks)` and `ENGINE / MODEL / MODEL STORE / RUNTIME
  PROCESS / RUNTIME V2 TESTS: PASS`, matrix exit 0. On arm64, `MODEL STORE
  TESTS` exits 0 both with and without the constant, which is the expected
  result and the reason no CI context ever noticed: `ModelPlatform.current`
  already equals the fixture platform there.
- What this does not buy. No required context compiles an x86_64 test binary, so
  CI cannot regress this either way; the guard is the shared constant, this
  record, and the local recipe above. Native Intel hardware remains
  **NOT VERIFIED** — the green x86_64 result is Rosetta evidence on Apple
  silicon, as `Docs/CROSS_PLATFORM_COMPATIBILITY.md` has always labelled it.
- One product question this surfaced, unchanged by the fix and still the owner's.
  `Resources/model-catalog.json` gives no entry a `macos-x64` platform
  (`flux2-klein-4b-q4`, `sam2.1-hiera-tiny` and `swin2sr-x4` are
  `["macos-arm64"]`, `migan` is `["macos-arm64","windows-x64"]`) while
  `.github/workflows/release.yml` builds a `macos-x86_64` slice. An Intel build
  therefore reports every model `.unsupportedPlatform`
  (`ModelStore.swift:247`). That is consistent with the recorded arm64-only AI
  packaging decision, so nothing was changed here; making models available on
  Intel is a catalog, measurement and licensing decision, not a string edit.

## Worker payload and lock jobs — advisory (2026-11-21)

**Correction to the status line and to "What each check proves" above, which
describe the gate set as it stood on 2026-11-14.** PR #104 (merged as
`80b23eea7` on 2026-11-21, "Prove the shipping worker lock and payload in CI")
added two jobs to `.github/workflows/ci.yml`; neither is a required context.
The five contexts in the table at the top of this document remain the required
set, and the branch protection check confirms it (the required list still names
only `StudioCore Boundary`, `Platform-neutral Conformance`, `macOS Integration`,
`Windows StudioCore` and `Windows App`).

| Job | Runner | What it runs | Gate state |
|---|---|---|---|
| `Worker Lock Closure` | `macos-15` | Resolves `worker/requirements.lock` with `pip --dry-run --report`, then `worker/tools/lock_closure.py --report` proves the resolver picked exactly the locked set and that the shipped package's third-party imports are pinned | Advisory: not a required context. The job itself has no `continue-on-error`, so a failure marks the run failed even though it cannot block a merge |
| `Worker Payload Bundle` | `macos-15` | Builds the pinned runtime, installs the full lock, runs `pip_check_gate.py`, bundles `Tools/bundle-worker.sh`, packages with `Tools/make-runtime.sh`, verifies the archive's distribution set with `worker/tools/verify_payload.py`, then imports from the extracted runtime | Advisory: `continue-on-error: true` and not a required context |

**Owner ruling (2026-11-21).** Both jobs stay advisory until the fail-open
paths in their first version are closed and the checks are shown to fail when a
defect is seeded. That work is on the `w5-worker-gates-failclosed` branch and
does not promote either job: the three holes were

1. the import guard accepted `except Exception:`, a bare `except:` and
   `BaseException` as proof that an import was optional, so a missing pin
   behind the common defensive idiom passed;
2. the `pip check` step discarded the exit status and stderr, so a crashed
   check with empty stdout passed;
3. the archive check compared dist-info *counts*, so a duplicated, renamed or
   wrong-version distribution passed while the count stayed at 68 for 67 pins.

The promotion criteria are: (a) those three checks judge identity and status,
not presence or count; (b) each seeding runs in the required macOS job, not
only by hand; (c) a deliberately seeded defect is shown to fail the job it
targets; (d) a green streak on `main` long enough to show the jobs are not
flaky on the hosted runners. Only then should the two names be added to the
required contexts, and `continue-on-error` removed from `Worker Payload
Bundle`. This addendum records the state; it does not change branch
protection.

## CI follow-ups registered 2026-11-26 (not implemented in this document)

Two gaps were confirmed while making the macOS Integration record above
truthful. **Neither is fixed**: both need edits under `.github/`, and the
single-source item additionally needs a file the workflow can read, so they are
separate engineering follow-ups rather than part of the documentation pass that
produced this section.

**CI-LOG-PERSIST-1 — a green run archives no log.** Every log-uploading step in
`ci.yml` is gated on failure, so when a job passes there is no archived artifact to
audit afterwards and the claim "CI was green on this head" cannot be re-checked line
by line: `ci.yml:56-57` (`studioscore-boundary`, `Upload gate log`),
`ci.yml:120-121` (`platform-conformance`, `Upload gate log`), `ci.yml:209-210`
(`macos-integration`, `Upload suite log`), `ci.yml:286-287`
(`worker-lock-closure`, `Upload the closure log`), `ci.yml:491-492`
(`windows-core`, `Upload gate logs`) and `ci.yml:572-573` (`windows-app`,
`Upload the published host on failure`) all carry `if: failure()`, and each of
those six sets `if-no-files-found: ignore` (`:62`, `:126`, `:219`, `:294`,
`:500`, `:580`). The counter-example already in the file is `ci.yml:565-570`
(`Upload the packaged zip and MSI`): no `if:` and `if-no-files-found: error`.
The one-line change that closes the gap is `if: failure()` → `if: always()` on
the log steps. The scope of the gap is storage, not visibility: each run step
`tee`s to the console as well, so a green run's verdict lines remain readable in the
Actions job page for as long as GitHub keeps that run's log — what is missing is the
downloadable artifact a reviewer can diff or re-grep. Until this
lands, "the archived macOS log proves X" is only available for a **failed**
attempt.

**CI-VERDICT-SINGLE-SOURCE-2 — the assertion list has no source of truth.**
`ci.yml:179-207` hardcodes eleven verdict literals while only the worker count
is derived from a file (`Tests/expected-worker-tests.txt`, used at
`ci.yml:184`). The list this needs already exists in prose form —
`Tests/run.sh:41-42` and `Tests/run.sh:61-70` enumerate exactly the gates and
suites that run — what is missing is a machine-readable file the workflow can
iterate, so the fix is to drive the loop from one authoritative suite/verdict list
and have `Tests/run.sh` consume the same source. That closes the mechanism behind
**A4** (`Docs/RELEASE_2.0.0_READINESS.md:881-883`) rather than patching one suite
name at a time, and it needs a `Tests/` file besides the workflow, which is why it
is a follow-up and not a documentation edit. Naming the two currently-unasserted
verdicts by hand would leave the same hole for the next suite.
