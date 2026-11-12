# CI Merge Gates

**Status:** Proposed in PR; required branch protection is not yet enabled.
**Date:** 2026-11-12
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
AI runtime or UI behavior on any other platform.

The GitHub-hosted `macos-14` runner image was retired on 2026-11-02. This
workflow therefore uses `macos-15` (arm64) instead.
