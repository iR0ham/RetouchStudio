# Development workflow (2026-11-14 steering, GitHub-based milestone model)

This document is the default workflow for RetouchStudio. It replaces both the
earlier PR-per-change cadence and the short-lived "local-first" variant:
development stays on GitHub as the central platform, and only the size and
cadence of pull requests change. Product direction from the owner still takes
precedence over this document.

## Default: GitHub-based, milestone-driven

- GitHub is the central development and collaboration platform. Branches are
  pushed continuously; work is never kept only on one machine.
- Work is organized in development branches. `develop` is the shared
  integration branch; a large workstream may use its own branch or worktree and
  is integrated once into `develop` before the milestone PR.
- Commits checkpoint progress as it becomes meaningful, not one commit per
  file, and are pushed regularly.
- A push does not open a pull request and does not by itself start the full
  matrix.
- Targeted checks run during implementation. The full five-context matrix runs
  once at a meaningful milestone boundary, on the exact head that will be
  reviewed or merged.
- A pull request is opened only when a milestone or coherent workstream is
  complete. Implementation, tests and documentation of that milestone live in
  the same PR. There are no per-task PRs and no documentation-only or
  bookkeeping PRs.
- `main` receives milestone merges only, through a milestone PR whose five
  required checks are green. The branch-protection rules on `main` do not
  change.

## Branches

| Branch | Role |
|---|---|
| `main` | Milestone baseline. Merges only through a milestone PR with green required checks. |
| `develop` | Shared integration branch. All in-progress workstreams are folded here. |
| `windows/*`, `delivery/*`, `macos-*`, `ci/*` | Workstream and historical branches. Preserved; not deleted, not force-pushed, not rewritten. |

Folding a workstream into `develop` is a normal merge commit after the diff is
reviewed and the branch builds. Branches that have served their purpose stay on
origin as a record unless the owner asks otherwise.

## Parallel work

Parallel agents may work at the same time on independent workstreams, either in
isolated branches or in worktrees. Each delegation names one owner, one scope
and the files it may touch. The Lead agent coordinates architecture,
dependencies, integration and quality, and integrates each workstream once,
after reviewing its diff. Two agents never edit the same file concurrently; if
scopes collide, the work is sequenced instead. CI is never idled on: while a
run is in flight, the next independent task continues.

## Validation cadence

- During development: the narrowest check that covers the change — Swift tests
  for StudioCore or the macOS app; for Windows code the headless suite is the
  fastest real check, but it needs the Windows runner, so Windows changes are
  validated in batches by `workflow_dispatch` on `develop`, on the workstream
  branch, or by the milestone PR.
- At a milestone: the full five-context matrix (StudioCore Boundary,
  Platform-neutral Conformance, macOS Integration, Windows StudioCore, Windows
  App) exactly once on the exact head that will be reviewed or merged.
- Avoid redundant runs: do not re-dispatch for an unchanged head, and do not
  update a PR just to restart checks.
- Evidence discipline is unchanged: only run IDs, measured log lines and
  read-back files count. A required test is never weakened, skipped or bypassed
  to make a run green, and branch protection is never circumvented.

## Pull requests at milestones

- Keep the number of active PRs small; complete and integrate one coherent
  milestone before opening another.
- A milestone PR states the workstreams it contains, the evidence run, and the
  known gaps; its history stays reviewable.
- It is merged with a normal merge commit once the five required checks are
  green and the state is `CLEAN`. No force-push, no history rewrite, no direct
  push to `main`.

## Preservation rules (unchanged)

- Never reset, discard, force-push or rewrite published history.
- Never delete a branch or PR that contains unreviewed work.
- Golden corpus fixtures are never regenerated.
- Private photos are never committed.
- No secrets or credentials in the repository.
