# Development workflow (2026-11-14 steering)

This document is the default workflow for RetouchStudio. It replaces the
earlier PR-per-change cadence. Product direction from the owner still takes
precedence over this document.

## Default: local-first, milestone-based

- Development happens on the shared integration branch `develop`.
- Work is checkpointed with local commits as it becomes meaningful, not one
  commit per file.
- `develop` is pushed to GitHub periodically as a backup. A push does not open
  a pull request and does not by itself start the full matrix.
- Targeted checks run while developing. The full five-context matrix runs at a
  meaningful milestone.
- A pull request is opened only when a milestone is complete and ready for
  review. Milestone PRs are the only PRs.
- `main` receives milestone merges only, through a milestone PR whose five
  required checks are green. The branch-protection rules on `main` do not
  change.

## Branches

| Branch | Role |
|---|---|
| `main` | Milestone baseline. Merges only through a milestone PR with green required checks. |
| `develop` | Shared integration branch. All in-progress workstreams are folded here. |
| `windows/*`, `delivery/*`, `macos-*` | Historical workstream branches. Preserved; not deleted, not force-pushed, not rewritten. |

Folding a workstream into `develop` is a normal merge commit made locally.
Branches that have served their purpose stay on origin as a record unless the
owner asks otherwise.

## Validation cadence

- During development: the narrowest check that covers the change — Swift tests
  for StudioCore or the macOS app; for Windows code the headless suite is the
  fastest real check, but it needs the Windows runner, so Windows changes are
  validated in batches by `workflow_dispatch` on `develop` or by the milestone
  PR.
- At a milestone: the full five-context matrix (StudioCore Boundary,
  Platform-neutral Conformance, macOS Integration, Windows StudioCore, Windows
  App) exactly once on the exact head that will be merged.
- Evidence discipline is unchanged: only run IDs, measured log lines and
  read-back files count. A test is never weakened or skipped to make a run
  green.

## Pull requests at milestones

A milestone PR states the workstreams it contains, the evidence run, and the
known gaps. It is merged with a normal merge commit once the five required
checks are green and the state is `CLEAN`. No force-push, no history rewrite,
no direct push to `main`.

## Parallel agents

Parallel agents may work on independent workstreams at the same time. Each
delegation names one owner, one scope and the files it may touch. Integration
into `develop` happens once per workstream, from a working tree that builds,
and the integrator reviews the diff before merging. Two agents never edit the
same file concurrently; if scopes collide, the work is sequenced instead.

## Preservation rules (unchanged)

- Never reset, discard, force-push or rewrite published history.
- Never delete a branch or PR that contains unreviewed work.
- Golden corpus fixtures are never regenerated.
- Private photos are never committed.
- No secrets or credentials in the repository.
