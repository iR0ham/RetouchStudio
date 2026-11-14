# Original master execution plan (recovered record)

**Provenance:** supplied by the product owner as
`RET0UCHSTUDIO_MASTER_EXECUTION_PLAN_v4.md` and received on 2026-11-14. The
text below is copied verbatim, including its amendment and live checkpoint.
Earlier plan versions are not present in this repository and cannot be
recovered from accessible records, so this file does not reconstruct them.

**Authority:** the owner's later instructions take precedence over this plan.
Current state, evidence and gaps are kept in
[`MASTER_PRODUCT_COMPLETION_STATUS.md`](MASTER_PRODUCT_COMPLETION_STATUS.md),
[`MASTER_PLAN_REMAINING_WORK.md`](MASTER_PLAN_REMAINING_WORK.md),
[`FINAL_PRODUCT_COMPLETION_AUDIT.md`](FINAL_PRODUCT_COMPLETION_AUDIT.md) and
[`PRODUCT_ACCEPTANCE_MATRIX.md`](PRODUCT_ACCEPTANCE_MATRIX.md).

---

# RETOUCHSTUDIO --- COMPLETE PRODUCT ENGINEERING & DELIVERY

## Final Master Execution Plan

**macOS + Windows \| Shared Core \| Native Platform Integrations \|
Autonomous Execution \| Optimized Workflow**

------------------------------------------------------------------------

## 0. Mission

Act as Lead Engineer, Technical Lead, and autonomous multi-agent
orchestrator for RetouchStudio. The user is the Product Owner and retains
final authority over product direction, priorities, scope, and material
user-facing trade-offs. Do not assume Product Owner authority.

Deliver a genuinely usable, reliable, professionally engineered desktop
image-retouching product for:

-   **macOS:** first-class product platform.
-   **Windows:** first-class product platform.
-   **Linux:** not a product platform. Keep only lightweight Ubuntu
    architecture/conformance CI where useful. Do not build, package,
    release, or advertise a Linux application.

This is a continuation of the existing project, not a rewrite. Preserve
working functionality, complete missing functionality, and verify real
user workflows.

The mission is not complete merely because PRs are merged, the app
builds, CI is green, Shared Core is stable, or an audit is written.
Completion requires implementation, integration, tests, documentation,
and evidence. Do not stop after planning or auditing.

## 1. Source of truth and context recovery

Before acting, inspect the actual repository and GitHub state, the
original Master Execution Plan, its Autonomous Execution & Approval
Policy, `Docs/MASTER_PRODUCT_COMPLETION_STATUS.md`, relevant
architecture documents, PRs, commits, tests, and workflows.

Create or maintain:

-   `Docs/ORIGINAL_MASTER_PLAN.md`
-   `Docs/MASTER_PRODUCT_COMPLETION_STATUS.md`
-   `Docs/MASTER_PLAN_REMAINING_WORK.md`
-   `Docs/FINAL_PRODUCT_COMPLETION_AUDIT.md`
-   `Docs/PRODUCT_ACCEPTANCE_MATRIX.md`

Recover the original requirements from accessible records; never invent
missing requirements. Historical reports (including PR #14/#15/#16 merge
SHAs and PR #17 review status) are not guaranteed current. Reverify all
current SHAs, PRs, CI, implementation, and blockers. Do not redo
verified work.

For each requirement, track ID, description, phase, files, commits/PRs,
tests, macOS status, Windows status, cross-platform status, remaining
work, and evidence. Use statuses: VERIFIED, IMPLEMENTED, PARTIALLY
IMPLEMENTED, NOT IMPLEMENTED, FAILED, BLOCKED, NOT VERIFIED, NOT
APPLICABLE. A class, UI element, build, merged PR, or green CI alone is
not proof of product behavior.

## 2. Execution sequence

Proceed continuously; parallelize independent work:

1.  Finish current active execution, reviews, CI, authorized merges, and
    post-merge checks.
2.  Audit every original and current requirement against the actual
    repository.
3.  Finish W4 image engine and Windows metadata.
4.  Complete Windows feature parity, including face analysis, masks,
    processing, and batch export.
5.  Complete W3 face analysis and masking on both platforms.
6.  Complete feasible W5 AI runtime and inference.
7.  Complete reliability, performance, stress, and recovery work.
8.  Complete Windows installer/updater and feasible macOS distribution
    preparation.
9.  Run cross-platform acceptance on exact candidate SHAs.
10. Produce evidence-based release-readiness assessments.

After each stage, continue to the next feasible stage. Do not stop at a
report or roadmap.

## 3. Architecture --- Shared Core and platform adapters

Preserve the existing architecture unless evidence justifies a change:

-   Portable shared project model and contracts.
-   StudioCore as shared product logic boundary.
-   Stable C ABI where needed.
-   Native macOS app/adapters.
-   Native Windows app/adapters.
-   Platform-specific rendering and AI backends where justified.
-   Consistent project serialization and feature behavior.

Do not leak platform-specific types into portable schemas or create
incompatible project formats.

### Shared Core acceptance

Verify portable schema, stable IDs, V3/V4 compatibility, versioned
serialization, backward-compatible migrations, unknown-field
preservation, asset references, non-destructive edit state,
autosave/recovery, undo/redo, RenderPlan/export contracts, face/mask/AI
contracts, and error states.

Test old-project migration, save/reopen, unknown top-level and nested
fields, missing assets, interrupted saves, recovery, and cross-platform
open/save.

### ABI acceptance

Test version compatibility, invalid/null inputs, memory ownership,
buffer lifetime, error propagation, cancellation, large payloads, and
backward compatibility.

## 4. W4 --- Image engine, metadata and rendering

Finish existing metadata work (including PR #17 if still relevant) after
re-verification.

### Metadata

Implement and test EXIF, ICC, XMP where supported, IPTC where feasible,
TIFF/HEIC metadata where supported, camera/lens data, orientation, and
resolution. Provide explicit keep-safe, strip-private, allowlist, and
regenerate-invalid-metadata policies. Never blindly copy metadata after
crop, rotation, resize, color conversion, orientation normalization, or
recomposition. Read back actual encoded output.

Reverify Windows WIC/WinRT limitations. If insufficient, evaluate a
legally distributable metadata library. Do not claim parity until output
metadata is read back and verified. Document unsupported keys.

### Bit depth

Verify 8-bit and 16-bit input/output, TIFF 16-bit, PNG 16-bit where
applicable, precision-preserving intermediates, and explicit conversion
policies. Close the historical Windows 8-bit limitation. Never silently
reduce precision.

### Color management

Implement and test ICC read/preserve, working/export spaces, color
conversion, untagged-image policy, profile assignment versus conversion,
preview/export consistency, and cross-platform behavior. Test Display P3
and measure output differences. Evaluate HDR/EDR separately; do not
advertise without end-to-end proof.

### Formats

Audit JPEG, PNG, TIFF, HEIC/HEIF, and RAW/DNG where technically and
legally feasible. For each, document import, decode, orientation, color,
metadata, editing, alpha, bit depth, encoding, export, batch export, and
limitations. Opening a file alone does not mean full support. Provide
clear Windows HEIC limitations if unresolved.

### RenderPlan and parity

Verify that the actual writer consumes dimensions, bit depth, alpha,
color profile, format, compression, quality, metadata policy, and
orientation. Reject unsupported combinations explicitly. Single and
batch export must share policies.

Create a deterministic image corpus. Compare macOS/Windows using pixel
equality where appropriate, per-channel differences, MAE, maximum error,
SSIM/perceptual metrics, and color difference. Set justified tolerances
before testing; never weaken them to pass CI. JSON equality is not
rendering parity.

## 5. W3 --- Face analysis and masking

Preserve and improve the existing macOS implementation, including
`FaceAnalyzer.swift`, `MaskBuilder.swift`, and related render/overlay
code.

Verify detection, confidence, multiple faces, landmarks, regions, masks,
preview/export resolution, feathering, composition, persistence, crop,
and orientation transforms.

The historical baseline described approximately 76 Vision points and
derived geometric regions---not a dense 3D mesh. It described geometric
segmentation and YCbCr/luma gates---not learned semantic segmentation.
Keep capability claims accurate.

### Shared contract

Define portable face IDs/association, landmarks and types, confidence,
bounds, regions, analysis results, mask data/transforms/parameters,
errors, versioning, and serialization. Do not use array index as
permanent identity. Use a canonical coordinate system and explicit
platform-boundary transforms; resolve historical top-left/bottom-left
inconsistencies.

### Windows backend

Implement real Windows detection and landmarks. Evaluate native APIs and
legally distributable offline models. Compare quality, accuracy,
performance, memory, runtime availability, licensing, redistribution,
offline operation, and cross-platform compatibility. Use the shared
result schema. A face rectangle alone is not a completed workflow. The
Lead must make a measured technical decision instead of indefinitely
asking the user to choose between equivalent approaches.

### Masks

Implement generation, editing, persistence/reload, multiple masks/faces,
feathering, supported boolean composition, luminance/color gates where
supported, crop/rotation/resize transforms, renderer/export consumption,
and project save/reopen. Verify actual exported pixels.

Test one/multiple/no faces, orientation/resolution variation, low
confidence, partial occlusion, boundary faces, save/reload, and
cross-platform rendering. Do not claim Windows W3 completion until the
actual Windows app performs the workflow.

## 6. Windows product completion and parity

Windows is a first-class product, not a viewer. Reverify the baseline
and complete real user workflows:

-   Project creation/open/save and asset management.
-   Image import, preview, full-resolution rendering.
-   Adjustments, crop, freeform crop where supported, rotation, mirror,
    straighten.
-   Face analysis, facial regions, masks, mask editing.
-   Heal/stamps, stickers, watermarks where supported.
-   AI edits when runtime is available.
-   Undo/redo, history, save/reopen.
-   Single and batch export.
-   Cancellation, recovery, and clear errors.

Consume shared contracts; do not invent a separate Windows project
model.

### Windows batch export

Implement job planning, multiple inputs, output paths/collision
handling, settings, metadata policy, progress, cancellation, failure
isolation, retry where appropriate, partial completion reporting,
cleanup, and consistency with single export. Test large and interrupted
batches.

Verify that actual UI actions call the correct Core/rendering
operations. Headless tests alone do not prove UI completion.

Use real Windows CI and automation for app startup, UI loading, import,
editing, face analysis, masks, persistence, project lifecycle,
single/batch export, cancellation, recovery, metadata, and installer
launch. The user has no physical Windows machine; do not require manual
Windows commands.

## 7. W5 --- AI runtime and model management

Reverify historical blockers such as missing approved runtime package,
missing weights, or external worker source.

Implement runtime packaging/versioning, model
discovery/download/checksum/integrity, installation/recovery/loading,
inference, cancellation/timeouts, shutdown, memory cleanup, crash
recovery, concurrency, upgrade, removal, and reinstall.

Evaluate Core ML on macOS and DirectML or another justified Windows
provider. Verify provider availability. Bring worker source into the
repository or use a reproducible dependency mechanism where possible. A
fresh clone must have a documented setup path.

Verify model license, redistribution rights, size, source, checksum,
compatibility, memory, performance, and offline behavior. Never
fabricate URLs, checksums, or weights.

If an external package/model is genuinely unavailable, finish all
feasible runtime infrastructure and provider integration, use test
doubles only for isolated infrastructure tests, mark real inference
BLOCKED, document the exact dependency, and continue other work. Never
present placeholder AI as production inference.

Test fresh install, discovery, download, checksum, load, inference,
cancellation, invalid model, insufficient memory, crash, restart,
upgrade, removal, and reinstall.

## 8. Performance, stability and reliability

Measure on both platforms where feasible: startup, project open, import,
preview, face analysis, masks, rendering, single/batch export, AI
inference, peak memory, CPU/GPU, and cleanup.

Record OS, hardware, SHA, corpus, methodology, results, and limitations.

Stress-test large images, multiple projects, long sessions, large
batches, repeated analysis/inference, cancellation, interrupted saves,
disk full, invalid inputs, missing runtime, crashes, shutdown during
processing, and recovery.

Investigate image-buffer leaks, native ownership, temporary files, GPU
resources, worker lifecycle, model memory, cancellation races, and
concurrent export safety. Never claim performance improvements without
measurements.

## 9. macOS completion

Preserve the native macOS app. Verify actual `.app` startup, project
lifecycle, import, editing, face analysis, masks, feasible AI,
single/batch export, cancellation, recovery, logging, cleanup, install,
upgrade, and uninstall.

Prepare Developer ID signing, Hardened Runtime, entitlements,
notarization, stapling, Gatekeeper, and clean-machine installation.
Apple Developer membership/credentials are unavailable: prepare the
pipeline but mark actual notarization BLOCKED until valid credentials
exist. Do not repeatedly ask for credentials. Do not claim Intel support
without real build/test evidence.

## 10. Windows installer and updater

ZIP packaging is not a completed installer.

Implement an appropriate production installer with runtime dependencies,
installation directory, Start Menu integration, optional desktop
shortcut, registration, uninstaller, upgrades, clean installation,
version handling, file associations where applicable, logging, recovery,
and safe behavior.

On clean Windows CI: build release, create/verify installer, install,
launch, verify DLLs, open project, import/edit/export, verify output,
upgrade, verify user/project data, uninstall, and verify cleanup.

Implement secure updater with version checking, authenticated/signed
metadata, download/artifact verification, installation, failure
recovery, rollback where supported, release channels, clear errors, and
data preservation. Test real artifacts. Do not publish a public
production update feed without authorization; use controlled test
channels.

## 11. Cross-platform acceptance

Test macOS-created projects on Windows and Windows-created projects on
macOS; save/reopen; V3 migration; V4 preservation; unknown fields;
assets; adjustments; crop; face analysis; masks; heal; stickers;
watermarks; AI records; render settings; metadata policies; recovery.

Test separately serialization parity, feature-data parity, rendering
parity, metadata parity, and user-workflow parity.

## 12. Security and data integrity

Audit project/media validation, path traversal, archive extraction,
model integrity, process execution, temporary files, privacy, logging,
dependency vulnerabilities, installer/updater security, and overwrite
behavior.

Never silently overwrite original images. Preserve non-destructive
editing. Validate external paths and archives. Never commit secrets or
upload private photos/user data without explicit authorization. Never
bypass host security hooks.

## 13. CI/CD

Maintain CI for Shared Core, macOS integration, Windows Core/App,
rendering conformance, metadata, face/masks, AI runtime, batch export,
installer/updater, release artifacts, and security/dependency checks.

**Windows is a first-class product, so Windows regressions must be able
to block integration.** The protected-branch merge gate must include
`Windows StudioCore` and `Windows App` in addition to the existing
`StudioCore Boundary`, `Platform-neutral Conformance`, and
`macOS Integration` checks. Do not leave Windows validation as an
optional, post-merge signal. Configure the checks once, verify the exact
status-context names, and record the resulting protection state.

Reduce waiting by changing *when and how often* the full matrix runs,
not by removing platform coverage: batch related work into one coherent
PR; run focused tests during implementation; run the complete required
matrix once at the integration boundary; avoid duplicate full post-merge
runs when the exact merge candidate/tree has already passed the same
required validation and the merge introduced no code changes. If the
repository's merge method or branch-protection semantics require a
post-merge run, retain it but do not also launch redundant overlapping
runs. Use merge queue / `merge_group` validation where supported so the
actual merge candidate receives the full required gate.

Verify exact final SHAs (or the exact merge candidate under merge queue)
using real macOS and Windows runners. Keep lightweight Ubuntu
conformance only; no Linux product builds. Do not swallow installer
failures, weaken assertions, or mark a check successful without running
it. Pin/cache toolchains and dependencies where safe. Verify Windows
release artifacts at release milestones, not after every small edit.

## 14. Execution speed optimization

**Maximize implementation and testing time; minimize workflow
overhead.** Never trade away correctness, security, data integrity,
required verification, or quality.

### Work batching — hard operating rule

The user's reported experience is that roughly 12 hours of work yielded
only about 5% perceived product progress, while individual PR/check
cycles consumed around 20 minutes each. Treat this as a serious delivery
throughput problem, not as a request for more status reporting.

**Do not create a PR for every small implementation step.** Keep one
active integration PR per coherent workstream/milestone wherever
possible. Continue committing related changes to that branch, run fast
focused tests locally, and update the PR only when a meaningful batch is
ready for review. Do not stop implementation to wait for CI after every
commit. Do not open a second PR for the same workstream just because the
first one is waiting on checks.

A PR is justified when a coherent user-visible capability or a
meaningful, independently reviewable engineering milestone is ready—not
when an agent completes a file, a small fix, or a handful of tests.

Avoid one PR per tiny change, repeated PRs for one workstream, and
unnecessary documentation-only PRs. Do not create huge unreviewable PRs
or mix unrelated risky changes just to reduce count. If independent
branches are essential, integrate them in a deliberate batch and avoid
multiple overlapping full CI matrices.

Suggested workstreams: 1. W4 metadata/color/bit depth/formats/rendering.
2. W3 face analysis/landmarks/masks/Windows parity. 3. Windows UI/batch
export/product workflows. 4. W5 AI runtime/model management. 5.
Reliability/performance/recovery. 6.
Distribution/installer/updater/signing. 7. CI/CD/security/release
validation.

Adapt grouping to real dependencies and ownership.

### Branch strategy

Use a small number of long-lived workstream branches/worktrees. Separate
only genuinely independent work. Assign file ownership, integrate
frequently, avoid branch proliferation, and respect protected branches.

### Smart test pyramid and CI cadence

-   **Level 1 — every development loop:** focused unit tests,
    changed-component tests, formatting/static checks, and narrow builds.
    Run these frequently; they should be fast and targeted.
-   **Level 2 — before PR update / integration batch:** related modules,
    ABI, platform hosts, and the actual changed user workflow.
-   **Level 3 — once per coherent merge candidate:** full required
    macOS + Windows matrix and cross-platform acceptance relevant to the
    batch. Run broader corpus, installer/updater, security, and release
    suites at their appropriate milestone, not on every tiny edit.

A commit is not a reason by itself to launch a new full CI run. The Lead
must explicitly decide whether the change invalidates existing evidence
or whether focused tests are sufficient until the next batch boundary.
Never skip required CI or weaken assertions. Never run two equivalent
full matrices for the same candidate unless diagnosing a failure or
verifying a changed environment.

### Avoid duplicate work

Before building/running CI, check whether valid evidence exists for the
exact SHA and same dependencies/configuration. Reuse valid
artifacts/results where possible. A green older SHA does not verify a
newer SHA. Invalidate affected evidence after relevant source,
dependency, configuration, or test-condition changes.

### Parallelism and idle time

Parallelize genuinely independent tasks with clear dependencies,
ownership, shared contracts, and integration points. Do not parallelize
work that depends on unfinished APIs. While CI/reviews run, continue
independent implementation, documentation, investigation, or
preparation. Do not sit idle or start risky dependent work just to stay
busy.

### Review and integration

Review complete logical changesets for correctness, architecture,
security, data integrity, regression risk, coverage, and platform
compatibility. Do not repeat a full review when the diff is unchanged
and evidence remains valid. Review changed scope and affected boundaries
after revisions; do a final review before merge.

Merge coherent milestones only after review, required CI, no critical
defect, satisfied dependencies, correct base, and no unexpected
destructive changes. The PR must contain a meaningful batch; do not
merge a stream of micro-PRs to make activity look busy. Never
force-push, rewrite published history, or bypass protection.

For `main`, the required merge gate is:
- `StudioCore Boundary`
- `Platform-neutral Conformance`
- `macOS Integration`
- `Windows StudioCore`
- `Windows App`

The Lead must verify the exact context names from a real run before
changing protection. If a job is renamed, update the protection and
workflow together so the gate cannot silently lose coverage. A red or
missing Windows check blocks the merge candidate; do not merge first
and discover the failure afterward.

### Blocker independence

Missing Apple credentials must not block Windows. Missing AI weights
must not block W4. Windows work must not block independent macOS work.
One unavailable agent must not stop the mission. Record blockers and
stop re-investigating confirmed blockers without new evidence or a
viable alternative.

Measure progress by verified capabilities, resolved defects, parity,
reliable workflows, coverage, and evidence---not commits, PRs, branches,
agent messages, CI count, or documentation edits.

Speed never authorizes skipping CI, weakening tests, hiding failures,
unreviewed merges, force pushes, bypassing security, rewriting history,
or claiming unverified completion.

## 15. Multi-agent execution

Use a Lead Orchestrator and specialists where available: Shared Core,
W4, W3, W5, Windows, macOS, QA/performance, CI/CD/release.

Define ownership and avoid conflicting edits. Review every agent diff
and require tests before integration. If a preferred agent/model is
unavailable, use a compatible fallback or execute directly. Do not retry
unavailable agents endlessly. The Lead owns integration and
verification.

## 16. Persistent progress and context compression

Update persistent documents after every meaningful milestone. Each
checkpoint records completed/remaining requirements, active
agents/tasks, branch/SHA, PRs, CI, tests, decisions, blockers, and next
actions.

After context compression/restart: 1. Read the persistent
plan/status/remaining-work documents. 2. Inspect repository and GitHub
state. 3. Verify current SHAs/PRs/CI. 4. Identify the next incomplete
requirement. 5. Continue without repeating verified work.

Never rely exclusively on conversation memory.

## 17. Git, PR and approval policy

Routine in-scope repository inspection, source changes, tests/builds,
approved dependency installation, branches/worktrees, commits,
feature-branch pushes, PR creation/updates, CI, docs, and normal
engineering integration are authorized.

The user previously authorized normal merges for PR #15 and #16 when
final diffs are reviewed, required CI is green, no unresolved critical
defect exists, the correct base is used, and no unexpected destructive
change is included. The same conditions apply to future in-scope
implementation PRs. Reverify current states before acting.

Never force-push, rewrite published history, delete protected branches,
bypass checks, hide failing tests, destructively reset shared branches,
overwrite others' work, delete user data, or bypass host security hooks.

No public production release without explicit authorization. No spending
money, registering accounts, purchasing services, or using credentials
not provided. Do not ask for routine approvals. Default: continue
execution.

## 18. External blockers and honest limitations

Reverify potential blockers: Apple Developer/Developer ID credentials,
approved AI runtime package, legally distributable model weights,
external worker source, no physical Windows machine, and metadata
library limitations.

For each blocker: identify exact dependency, assess valid alternatives,
complete independent work, document impact, mark only affected criteria
BLOCKED, and continue elsewhere. Use real Windows CI. Never claim
signing, notarization, real inference, or performance verification
without evidence.

## 19. Acceptance gates

-   **A --- Shared Architecture:** portable contracts, schema,
    migrations, interchange verified.
-   **B --- W3:** real face analysis and masks on macOS and Windows.
-   **C --- W4:** bit depth, color, metadata, formats, rendering
    verified.
-   **D --- W5:** real runtime/inference verified or genuine external
    blockers documented.
-   **E --- Reliability:** performance, memory, batch, cancellation,
    recovery verified.
-   **F --- Applications:** both native apps perform actual supported
    workflows.
-   **G --- Distribution:** artifacts, install, upgrade, uninstall,
    updater verified.
-   **H --- Cross-platform:** projects and supported feature data move
    without loss.
-   **I --- Release readiness:** required CI green, artifacts verified,
    docs accurate, critical defects resolved, blockers transparent.

Green CI alone does not prove product readiness.

## 20. Product acceptance matrix

Maintain a detailed evidence-backed matrix covering at least:

  ---------------------------------------------------------------------------------------
  Area                              macOS             Windows           Cross-platform
  --------------------------------- ----------------- ----------------- -----------------
  App startup                       Verify            Verify            N/A

  Project create/open/save          Verify            Verify            Verify

  V3/V4 compatibility               Verify            Verify            Verify

  Undo/redo                         Verify            Verify            Verify

  Image import and adjustments      Verify            Verify            Verify

  Crop/rotation/mirror              Verify            Verify            Verify

  Face detection/landmarks/regions  Verify            Verify            Verify

  Mask generation/edit/persistence  Verify            Verify            Verify

  Heal/stamps/stickers/watermarks   Verify            Verify            Verify

  AI runtime                        Verify or Blocked Verify or Blocked Verify or Blocked

  JPEG/PNG/TIFF/HEIC                Verify/document   Verify/document   Verify

  16-bit and ICC/color              Verify            Verify            Verify

  Metadata keep/strip               Verify            Verify            Verify

  Batch export/cancellation         Verify            Verify            Verify

  Recovery                          Verify            Verify            Verify

  Installer/updater                 Verify or Blocked Verify or Blocked N/A

  Security/performance              Verify            Verify            Compare
  ---------------------------------------------------------------------------------------

This is a minimum, not a replacement for the complete requirement list.
Never mark VERIFIED without evidence.

## 21. Final report

Produce one consolidated report containing executive summary,
original-plan audit, current PR/merge/commit/CI state, completed and
newly implemented requirements, remaining work with
severity/owner/dependency/next action, exact test evidence and SHAs,
macOS status, Windows status, cross-platform status, AI runtime status,
distribution status, security/reliability, acceptance gates, and
separate release-readiness assessments.

Do not use arbitrary completion percentages. If a percentage is useful,
calculate it from the complete requirement matrix with explicit
weighting and separate blocked criteria.

------------------------------------------------------------------------

## FINAL DIRECTIVE

Finish current active execution first. Audit every requirement. Preserve
verified work. Implement everything feasible. Prioritize W4 Windows
metadata; Windows face/mask parity; Windows
image/color/bit-depth/rendering; Windows batch export; W5 real AI
runtime; performance/recovery; Windows installer/updater; complete
macOS/Windows acceptance; cross-platform verification.

Group related changes, reduce unnecessary PRs, avoid repeated reviews,
reuse valid evidence, use targeted tests frequently, run full acceptance
at milestones, parallelize independent work, and continue while CI runs.
Never weaken quality gates.

Do not stop after auditing. Do not duplicate verified work. Do not fake
evidence. Do not introduce Linux as a product. Do not publish a public
production release without authorization. Maintain durable progress
through context compression.

**Deliver a complete, reliable, professional RetouchStudio for macOS and
Windows, with maximum engineering efficiency and without sacrificing
quality.**

---

# MASTER PLAN AMENDMENT — BATCHED DELIVERY, LOW-OVERHEAD CI, AND USER STEERING
## This amendment is part of the Master Plan and takes precedence wherever it adds more specific workflow or control rules.

## A. Reduce PR, merge, and CI overhead

The goal is to spend engineering time building and verifying RetouchStudio—not repeatedly managing tiny PRs.

### A1. Workstream-first delivery
Organize work around meaningful product workstreams and milestones. Keep related implementation, tests, and documentation together in one coherent PR whenever practical.

Do not create a separate PR solely to record that another PR was merged, to copy merge metadata into a document, or to make a trivial documentation-only follow-up. Update the relevant status/acceptance documents in the feature PR or in an existing documentation batch.

Create a separate PR only when the change has independent value, a distinct risk/ownership boundary, or must be integrated separately.

Do not combine unrelated or high-risk changes merely to reduce PR count. Keep each PR reviewable, testable, and reversible.

### A2. Batch implementation before requesting integration
For each workstream:
1. Define a small set of related acceptance criteria.
2. Implement the related changes together.
3. Add/update focused tests as part of the same batch.
4. Run fast local checks while developing.
5. Run integration and platform checks at the batch boundary.
6. Review the complete logical diff.
7. Open/update one PR for that coherent milestone.
8. Let required CI finish, address failures, and merge when authorized and safe.
9. Continue to the next batch.

Do not stop development after every small commit merely to open a PR or wait for CI.

### A3. CI efficiency and concurrency
- Run focused tests locally/within the agent environment after small edits.
- Avoid triggering a new full CI matrix for every intermediate commit when the branch/PR workflow can validate the final batch.
- Use CI concurrency cancellation or superseding runs only when the workflow is configured safely and the newer run covers the same required validation.
- Do not cancel the only run that can provide required evidence.
- Reuse successful results only for the exact same SHA and equivalent dependencies, configuration, and test conditions.
- Do not treat a green older SHA as verification of a newer SHA.
- Separate fast required PR checks from expensive milestone/release acceptance only if branch protection and required validation remain intact.
- Do not create duplicate post-merge documentation PRs. Record merge SHA, CI run, and evidence in the same workstream's durable status document.
- Investigate slow or stalled jobs. Do not wait indefinitely or repeatedly rerun them without diagnosing the cause.
- If one CI job is waiting, continue independent implementation, analysis, or tests that do not depend on its result.

### A4. Agent utilization
Use parallel agents only for independent tasks with explicit ownership and interfaces. One Lead owns integration and conflict resolution.

Do not spawn agents for tiny tasks that cost more coordination than they save. Do not have multiple agents repeatedly inspect the same files or independently create overlapping PRs.

Maintain a small active work queue:
- one primary implementation batch;
- independent secondary tasks while CI runs;
- one integration/review lane;
- a short blocker list.

The Lead should continuously choose the next safe, high-value task rather than waiting for the user to say "continue."

### A5. Measure overhead
Track, at least qualitatively:
- implementation time;
- test/build time;
- CI waiting time;
- review/PR administration time;
- blocked time.

If PR/CI administration becomes a significant share of elapsed time, adjust batching and workflow. Do not optimize by removing necessary checks.

---

## B. USER STEERING — THE USER RETAINS PRODUCT DIRECTION

Autonomous execution does not mean autonomous product direction.

The user wants to actively steer RetouchStudio. Treat the user as the Product Owner and final authority on product priorities, scope, user-facing behavior, and important trade-offs. The Lead Engineer owns technical execution and routine engineering decisions.

### B1. Steering authority
The user may redirect the work at any time by specifying:
- a new priority;
- a feature to pause, accelerate, remove, or defer;
- a desired product behavior;
- a quality/performance trade-off;
- a platform priority;
- a design or UX direction;
- an architectural preference;
- a constraint or acceptance criterion;
- a request to inspect or explain the current state before proceeding.

A new explicit user instruction overrides the previous task ordering where they conflict, unless it conflicts with safety, legal constraints, repository protection, or an earlier explicit restriction that the user has not changed.

Do not treat the Master Plan as permission to ignore later user direction.

### B2. Steering commands are ordinary language
The user should not need to learn a command syntax. Understand natural-language instructions such as:
- "فعلاً Windows رو متوقف کن، برو سراغ W3."
- "اولویت رو بده به سرعت Preview."
- "این قابلیت رو فعلاً نساز."
- "قبل از تغییر معماری، گزینه‌ها رو بهم بگو."
- "برو وضعیت فعلی رو توضیح بده، فعلاً کد نزن."
- "همین مسیر رو ادامه بده."
- "این تصمیم رو خودت بگیر و ادامه بده."

Interpret these as direct steering instructions. Confirm the changed priority briefly, update the durable task queue/status, and act.

### B3. When to ask the user
Do not ask for routine implementation decisions, naming, refactoring details, test selection, or other reversible engineering choices. Decide independently and document material decisions.

Ask the user before proceeding only when a decision materially changes product direction or user-visible behavior and reasonable options have meaningfully different consequences; when a requested action is destructive or irreversible; when scope, budget, external credentials, paid services, public release, or sensitive data authorization is needed; or when two explicit user instructions conflict and cannot be reconciled.

When asking:
- ask one focused question;
- explain the consequence briefly;
- provide a recommended option;
- keep unrelated work moving while awaiting the answer.

Do not turn every technical uncertainty into a user question. Investigate and recommend first.

### B4. Preserve the user's steering context
Maintain a concise section in `Docs/MASTER_PRODUCT_COMPLETION_STATUS.md` called `Current Product Direction / User Steering`.

Record:
- current user-set priorities;
- explicit exclusions or paused work;
- accepted trade-offs;
- decisions awaiting user input;
- the current next milestone.

Do not reinterpret a temporary priority as a permanent cancellation. Record whether a direction is temporary, milestone-specific, or permanent when the user makes that clear.

After context compression, read this section before selecting the next task.

### B5. Give the user visibility and control without interrupting execution
At meaningful milestones, provide a compact steering update:
- **Current focus:** what is being built now.
- **Recently completed:** verified product outcomes, not just PR count.
- **Next:** the next planned workstream.
- **Risks/blockers:** only material ones.
- **Steering needed:** say "none" if no decision is needed; otherwise ask one focused question.

Do not send repetitive progress messages for every commit or test. Do not hide major direction changes. The user must be able to redirect the work without restarting the project or rewriting the Master Plan.

### B6. Autonomous execution within user direction
Once the user sets a direction, continue independently through implementation, testing, integration, and documentation. Do not pause for routine approvals. If the user changes direction mid-task, assess the current work:
- preserve useful completed changes;
- safely pause or finish the current atomic operation;
- avoid abandoning uncommitted work;
- update the queue;
- switch to the new priority;
- explain any unavoidable dependency or rework.

The user controls WHAT and WHY. The engineering lead determines HOW, executes, verifies, and reports.

### B7. Initial steering gate for this checkpoint

The Master Plan defines the mission and engineering constraints; it does not
by itself resolve the user's next product priority. The user has explicitly
said they want to steer RetouchStudio. Until the user gives the first concrete
priority or confirms a proposed milestone, do not begin a new product-feature
workstream or make a material product-direction choice. It is acceptable to
finish already-authorized in-flight operations, verify CI, preserve work,
reconcile factual status, and present concise options with a recommendation.
Once the user sets a priority, execute it autonomously within this plan.

---

## C. UPDATED OPERATING LOOP

Use this continuous loop:

1. Read current user steering and durable project status.
2. Select the highest-priority feasible workstream consistent with user direction.
3. Define a bounded, coherent implementation batch.
4. Delegate only independent work.
5. Implement and run fast focused tests.
6. Continue independent work while expensive checks run.
7. Integrate related changes into one reviewable milestone.
8. Run required CI and acceptance checks on the exact candidate SHA.
9. Review, fix, and merge under the existing authorization policy.
10. Update durable status and acceptance evidence in the same workstream—avoid a separate bookkeeping PR.
11. Report the milestone and next planned task.
12. Continue automatically unless user steering, a genuine blocker, or a required authorization changes the plan.

**The intended balance is: autonomous engineering execution, user-controlled product direction, and minimal administrative overhead.**

---

## 22. LIVE REPOSITORY CHECKPOINT — 2026-11-14

This section records a live GitHub verification performed while reviewing
this Master Plan. It supersedes older conversational snapshots, but it does
not replace the repository's detailed verification ledger. Recheck it before
any subsequent implementation or merge.

### 22.1 Verified GitHub state

- Repository: `iR0ham/RetouchStudio`.
- `main` points to `4a034cdbedd32daa0c3d8c0a1f19f05aec7ece72` (`4a034cd`).
- The head commit is the merge commit for PR #48. Its first parent is the
  PR #47 merge `f58b3363ba6d2203a62453d108d81da0bca78975`; the second parent
  is the updated PR #48 head `e4bc4668af725bd6eccaf5cc9dc93c4629487008`.
- PR #47 (Windows parallel-render performance) is merged as `f58b336`.
  Its reported final PR run `43619500646` passed all five jobs. The post-merge
  `main` run `43620792640` was reported green.
- PR #48 (Windows drop-to-open, accessibility names, compare split off by
  default) is merged as `4a034cd`. Its updated head `e4bc466` was reported to
  pass all five checks in run `43620925118` before merge.
- GitHub currently reports no open pull requests.
- Post-merge `main` run
  [43622071155](https://github.com/iR0ham/RetouchStudio/actions/runs/43622071155)
  is still `in_progress` on the exact `main` SHA `4a034cdb...`. At the time
  checked, `StudioCore Boundary` and `Platform-neutral Conformance` had
  succeeded; `Windows StudioCore`, `Windows App`, and `macOS Integration`
  were still running. Do not call the merged tree fully verified until this
  run completes successfully.
- At the time of this inspection, `main` required only `StudioCore Boundary`,
  `Platform-neutral Conformance`, and `macOS Integration`; `Windows StudioCore`
  and `Windows App` were not required. This is now a direct owner instruction:
  close the gap by making both Windows checks required for `main`, alongside
  the three existing checks. Do not ask the user again for this already-given
  direction. Apply the protection change only after verifying the exact live
  check-context names and the workflow's PR/merge-queue behavior; then read
  protection back and record the result. Do not change unrelated protection
  settings.

### 22.2 Preserved but not independently verifiable from GitHub

The user/agent checkpoint reports a local-only branch `windows/memory-perf`
at commit `3e00182`, containing working-set/peak-memory instrumentation. It
was reported as unpushed and intentionally preserved. GitHub has no remote
branch by that name, consistent with the local-only report. The local working
tree and local branch cannot be verified through GitHub; do not claim they are
clean or intact based only on remote state. Preserve the commit and do not push,
cherry-pick, reset, or discard it until its integration is reviewed under the
user's next steering instruction.

### 22.3 Product evidence and current limitations

The current repository status document on `main` is behind the live PR state:
it includes the PR #47 head evidence but does not yet record the #47 merge,
PR #48 merge, or the post-merge run `43622071155`. Its evidence ledger and
phase/next-action sections therefore need reconciliation. Do this in the next
relevant workstream or a deliberately batched status update; do not create a
standalone bookkeeping PR merely to record the two merges.

The following are supported by the status document and recent CI evidence;
they are not blanket claims of full Windows parity:

- Windows has verified shared-project interchange, 16-bit PNG/TIFF export,
  16-bit source preview, metadata allowlist behavior, several rendering
  parity improvements, batch export through the single-export path, MSI
  clean install/upgrade/uninstall, crop/orientation arithmetic, zoom/pan
  arithmetic, compare behavior, histogram, and measured performance checks.
- PR #47 records a Windows preview median of 721 ms across five runs, versus
  the earlier 1187 ms measurement, with 16-bit export measured at 1189 ms on
  that run. Treat these as environment-specific measurements, not universal
  performance guarantees.
- PR #48 adds Windows canvas drop-to-open, spoken/accessibility names for
  sliders and symbol controls, and compare split defaulting to off. The
  Windows interactive UI wiring remains only partially verified by CI; do
  not infer complete end-to-end UI acceptance from headless checks.
- Windows face detection/landmarks/masks and AI inference remain absent or
  blocked; the Windows updater remains unimplemented. Windows HEIC decoding
  is unavailable on the current CI image. ICC source conversion to sRGB is
  tested, but wide-gamut preservation on write is not established.
- macOS notarization remains blocked by missing Apple Developer credentials.
  No public production release is authorized by this plan.

### 22.4 Required status reconciliation

Before selecting the next implementation batch, update the durable project
status from live evidence and the exact `main` SHA. In particular:

1. Record PR #47 and #48 merge SHAs and their exact PR CI runs.
2. Record the final result of post-merge run `43622071155` once complete.
3. Preserve the PR #47 performance measurements and PR #48 feature scope,
   while marking UI interactions that CI does not actually drive as NOT
   VERIFIED or TESTED rather than VERIFIED.
4. Reconcile phase status and next actions against the actual current code;
   do not carry forward stale next-action wording.
5. Confirm whether `Docs/MASTER_PLAN_REMAINING_WORK.md`,
   `Docs/FINAL_PRODUCT_COMPLETION_AUDIT.md`, and
   `Docs/PRODUCT_ACCEPTANCE_MATRIX.md` exist. The first two returned 404 on
   `main` during this review, and the acceptance matrix path also returned
   404. Create or maintain them as part of a coherent documentation/status
   batch, not as separate bookkeeping PRs.
6. Keep the unpushed `windows/memory-perf` commit preserved until the user
   chooses or confirms its next workstream.

### 22.5 Current steering state

- Master Plan framework: supplied by the user and reviewed in this version.
- Product Owner: the user.
- First next product milestone: awaiting the user's explicit steering.
- No new feature implementation is authorized merely by the existence of
  this plan. The Lead may complete the pending post-merge CI verification,
  reconcile factual status, and present the next milestone recommendation.
- No open PRs were found in the live GitHub check. Do not create a new PR
  until a coherent implementation milestone is selected and batched.

## 23. OWNER DIRECTIVE — DELIVERY THROUGHPUT AND REQUIRED WINDOWS GATES

**Added 2026-11-14 from explicit user feedback. This section supersedes any
weaker or ambiguous PR/CI cadence wording elsewhere in this plan.**

The user reports that approximately 12 hours of work produced only about
5% perceived product progress, with repeated PR/check cycles taking about
20 minutes each. The current process is not acceptable. The objective is
substantially more finished product capability per working session—not a
higher PR count, more agent messages, or more green checkmarks.

### 23.1 Branch protection: close the Windows regression gap

The user has directed that Windows checks become required. Configure
`main` to require all five checks:

1. `StudioCore Boundary`
2. `Platform-neutral Conformance`
3. `macOS Integration`
4. `Windows StudioCore`
5. `Windows App`

First verify the exact job/status context names emitted by the current
workflow. Apply only this required-check change; preserve existing strict
up-to-date behavior, administrator enforcement, no-force-push and
no-deletion settings. Read the protection back after the update and
record the actual result. If the GitHub integration cannot modify branch
protection, provide the exact command/payload for the repository owner;
do not claim the setting changed when it did not.

### 23.2 One meaningful PR per workstream batch

- Keep one active PR for each coherent workstream whenever possible.
- Accumulate related implementation, tests, and status documentation on
  that branch until the batch is reviewable.
- Do not open PRs for individual commits, isolated tiny fixes, or
  documentation-only merge bookkeeping.
- Do not create a new PR while an existing PR for the same workstream is
  merely waiting for CI. Continue independent implementation or testing.
- Do not create a new full-matrix run for each commit. Trigger the full
  gate at the coherent merge-candidate boundary.
- Do not produce repeated post-merge full matrices if the same exact
  candidate was already validated and the merge adds no code changes;
  use merge queue / `merge_group` where practical to validate the actual
  integration candidate once. If GitHub's protection semantics require
  another run, retain the required gate but eliminate any other redundant
  duplicate run.
- Keep focused local/agent tests running throughout development. A full
  CI wait must not idle the implementation lane.

### 23.3 Required checks stay strong; duplicate waiting goes away

The user is not asking to remove Windows quality gates. The correct
solution is to require Windows checks while reducing how many times the
same expensive checks are triggered. Keep all five required checks, but
run them once per meaningful integration candidate, not once per tiny
change. Never fake, skip, or weaken a required result.

### 23.4 Throughput accountability

At each milestone, report only:
- user-visible or engineering capability actually completed;
- evidence and unresolved limitations;
- next coherent batch;
- material blockers.

Track cycle time and distinguish implementation time from CI wait and
administrative overhead. If a work session produces many PRs but little
verified capability, stop splitting work further and redesign the batch.
Do not publish arbitrary completion percentages. The user's estimate of
5% is a warning about perceived throughput, not a measured completion
metric; establish the actual baseline from the acceptance matrix before
claiming a numeric progress figure.

### 23.5 Immediate execution order

1. Verify current `main` protection and the exact five status contexts.
2. Add `Windows StudioCore` and `Windows App` to required checks, changing
   no unrelated settings; verify the result by reading protection back.
3. Inspect `.github/workflows/ci.yml` triggers, concurrency, job dependencies,
   and push/PR/merge-queue behavior. Remove redundant full post-merge runs
   only where exact candidate validation remains guaranteed.
4. Adopt workstream batching immediately: no micro-PRs and no repeated
   full-matrix runs for intermediate commits.
5. Reconcile the current project status and continue with the highest-value
   incomplete product capability under the user's next explicit steering.

