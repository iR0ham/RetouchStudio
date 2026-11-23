# CI control run: is `Windows App` failing on *this* diff, or on the runner?

**Status: throwaway diagnostic branch. This pull request is opened to be closed unmerged.**

It contains one new file and no change to code, resources, catalogues, tests or build scripts, so
its `Windows App` job is a measurement of the runner, not of any pull request.

## The observation being tested

Pull request #126 (branch `w5-200-flux-unknown`, head `eee3e4b`) has failed the `Windows App`
required context three times on run `45138992397`, without a single line of the diff changing
between attempts:

| attempt | window | leg that failed | reported reason |
| --- | --- | --- | --- |
| 1 | 08:29–08:43Z | UI mode `exportclose` | `UI CHECK FAILED: Unrecognized error.` |
| 2 | 08:58–09:11Z | UI mode `exportclose` | `UI CHECK FAILED: Unrecognized error.` |
| 3 | 09:15–09:21Z | AI runtime suite, section `[C]` | `FAIL the helper publishes a ready registry record — (no log)` after exactly 30 s |

Every other leg of the same job passed in attempts 1 and 2 (`WINDOWS HOST TESTS: PASS (405 checks)`,
`MODEL STORE CHECKS: PASS`, `AI RUNTIME TESTS: PASS`), and in attempt 3 the run stopped earlier, at
`[C]`, so `exportclose` never executed there. The six remaining contexts — `StudioCore Boundary`,
`Platform-neutral Conformance`, `macOS Integration`, `Windows StudioCore`, `Worker Lock Closure`,
`Worker Payload Bundle` — are green on the same head.

## Why this smells like the environment rather than the diff

- **Two different legs fail across attempts of one identical commit.** A deterministic defect in
  `eee3e4b` would fail the same assertion every time; here the failure moved from the UI leg to a
  30-second startup timeout in a different suite.
- **Both failures are waits, not assertions about values.** `Unrecognized error.` is the message of
  an exception raised by Windows itself (it appears nowhere in this repository, and
  `Windows/RetouchStudio.UiTests/Program.cs:153-158` prints the caught message verbatim). The
  `[C]` check passed in attempts 1 and 2 on the byte-identical input.
- **The round-2 diff cannot reach either path.** It changes two string values in
  `Resources/model-catalog.json` (a longer `code.note` and `readOn` `2026-11-21` → `2026-11-23`),
  the macOS `RuntimeV2Tests` P block, one `ModelStoreTests` pin, Python admission wording and
  documentation. No Windows file reads `readOn`, `weightsLicense` or `permitted_use`, and section
  `[M17]` — the one Windows check that *does* load the shipped catalogue — passed in all three
  attempts.

## What each outcome means

- **`Windows App` red on this branch too** ⇒ the runner is currently unreliable for these two
  timing-sensitive legs, and PR #126's red is not attributable to it. #126 is then merged on a
  green attempt with this control recorded as the evidence, and the flake gets its own ticket.
- **`Windows App` green on this branch** ⇒ the control is only one sample; PR #126 keeps its
  failing status until an attempt of its own goes green, because a single green control does not
  prove the other diff innocent.

Neither outcome is used to merge with the required check unsatisfied.
