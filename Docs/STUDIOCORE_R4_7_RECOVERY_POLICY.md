# StudioCore R4.7 — Recovery Policy

Status: complete on branch `r4-3-document-codec`.

Baseline: `4cf5b38` (R4.6).

## 1. What was extracted

`RecoveryStore` mixed three kinds of work: the directory layout and durability
operations, the launch/restore sequencing, and decisions that can be made from
values alone. The value-only decisions now live in `RecoveryPolicy`
(`Sources/RetouchStudio/Models/RecoveryPolicy.swift`). `RecoveryStore` keeps the
file system and calls the policy; its public surface is unchanged.

| Member | Rule |
|---|---|
| `CandidateOrderKey` / `olderFirst` | Oldest `savedAt` first; the file name breaks a same-millisecond tie |
| `isCandidateFileName` | A candidate is a non-dotfile with the `retouch` extension |
| `snapshot(from:modified:)` | A snapshot decodes as written; a bare project decodes as legacy version 0 with no source identity; anything else is not a snapshot |
| `sourceState(url:recorded:version:current:)` | No photo is `.missing`; legacy version 0 without identity is `.available`; a current copy without identity is `.changed`; equal size/date is `.available`; a different identity is `.changed`; an unreadable identity stays `.available` |
| `monotonic(_:after:)` | Legacy copies promoted in one launch get strictly increasing dates |
| `quarantineFileName(base:pathExtension:id:)` | The damaged file keeps its recognizable name and gains a UUID so two copies cannot collide |
| `AutosaveEpoch` | A captured generation is accepted only while the store has not invalidated it |

`RecoverySourceState` is now a top-level type; `RecoveryStore.SourceState` is a
typealias for it, so callers and tests keep the same spelling.

## 2. What stayed in the store

Directory URLs, `working.retouch`, `candidates/`, `quarantine/`, legacy
`session.retouch` and `pending.retouch`, atomic writes with read-back
verification, renames, quarantine moves, failure injection, `workingLocked`,
and the write → verify → delete restore order. No timing, threshold, prompt or
cleanup rule changed.

`RecoverySnapshot` version 1 is unchanged. Legacy version 0 interpretation is
unchanged and now has an explicit test.

## 3. Tests

- `testRecoveryPolicyDecisions` — ordering by date and tie-break; candidate
  file filtering; version 1 and legacy version 0 decoding plus junk rejection;
  every source-state branch; monotonic legacy dates; quarantine naming and
  collision avoidance; epoch acceptance after invalidation.
- The existing A–G recovery scenarios, independence, cancellation, working-slot
  lock, moved vs changed source, quarantine failure and autosave invalidation
  tests all still run unchanged.

Results: full model suite 879 checks on arm64 and 880 check lines on Rosetta
x86_64 (the extra line is a runtime log interleaving with a `✓`, as in earlier
milestones), zero failures on both. Corpus hashes unchanged; `git diff --check`
clean.
