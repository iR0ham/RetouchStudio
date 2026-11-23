# Retouch Studio 2.0.0 — 4× upscaler release gate and recovery plan

Recorded 2026-11-24. The owner has made one real 4× upscaler working **inside the actual
distributable application** a release-blocking requirement for 2.0.0. This document is the
accountable-PM plan that turns that decision into milestones, owners, tests, estimates and risks.
It does not weaken any acceptance criterion, and it does not declare any capability supported.
It follows [`W5_SCOPE_AUDIT_2.0.0.md`](W5_SCOPE_AUDIT_2.0.0.md), whose defect R1 and remediation R2/R3
become mandatory workstreams R1–R6 here.

## 0. The decision, and what it changes immediately

**Owner decision (2026-11-24).** 2.0.0 must not be released until at least one production-usable 4×
upscaler runs inside the distributable app. The editor acceptance already performed does not satisfy
this. Scope is deliberately limited to `upscale.4x`: MI-GAN, SAM 2, FLUX and generative editing stay
outside the gate unless a concrete dependency is discovered.

**Consequences accepted here, in writing.**

- The DMG pinned in `Docs/RELEASE_2.0.0_ACCEPTANCE.md` §0b (`b3711d0c…2ed2b4`) stops being a release
  candidate. It remains valid evidence for one thing only: the editor, bilingual shell and export
  paths the owner tested. Rows that passed keep their value; the artefact is not publishable.
- `Docs/RELEASE_2.0.0_READINESS.md` §3 no longer describes a releasable state. The release gate is
  the eight items in §6 below, and `RETOUCH_SKIP_WORKER: '1'` in `.github/workflows/release.yml`
  becomes a blocker to remove rather than a product shape.
- `README.md`, `Docs/RELEASE_NOTES_2.0.0.md` and the acceptance pack may not present 2.0.0 as shipping
  until §6 is evidenced. The AI-claim corrections already merged are necessary, not sufficient.

**Evidence labels used throughout** (the owner's report vocabulary, plus the ladder from
`Docs/W5_SCOPE_AUDIT_2.0.0.md` §2): **IMPLEMENTED** (code exists, type-checks), **TESTED** (a committed
test passes), **MEASURED** (a number was produced by a stated command), **REVIEWED** (an independent
reviewer signed the diff or the evidence), **NOT VERIFIED**, **BLOCKED**. An import smoke test is never
reported as inference, and a green CI leg is never reported as an artefact-level pass.

**Team note.** The named implementation, test and review owners below are the team roles that must do
that work. In this session the team delegation channel is unavailable, so independence is obtained by
dispatching separate agents with non-overlapping briefs and by my own re-verification of every
load-bearing claim; the reviewer is never the implementer of the same diff. If the delegation channel
returns, the same briefs move to the named roles unchanged.

## 1. Milestone breakdown and dependencies

| ID | Milestone | Depends on | Gate item(s) it produces |
|---|---|---|---|
| M0 | Audit, gate recorded, plan landed (this document, ledger S.17, PR #136 merged) | — | — |
| M1 | R1 — redirect-aware downloader integrity, both hosts | M0 | 1 |
| M2a | R2 — macOS model qualification, provisional on dev runtime, final on the M3 artefact | M0 | 2 |
| M2b | R2 — Windows: reproducible Swin2SR→ONNX conversion, qualification and parity | M0, decision D2/D4 | 2, 5 |
| M3 | R3 — distributable runtime: helper inside the built package, both platforms | M2a (macOS), M1 (not strictly) | 3 |
| M4 | R4 — real 4× inference from the packaged app, evidence records v2 | M1, M3, M2a/M2b | 4, 5 |
| M5 | R5 — truthful Model Manager states, cancel / retry / recovery | M3 | 6 (partial) |
| M6 | R6 — clean-install acceptance of the artefacts proposed for release | M4, M5 | 6 |
| M7 | Independent review of the whole evidence set, then the owner's publication decision | M1…M6 | 7, 8 |

M1, M2a and M2b are independent of each other and run in parallel. M2b is the critical path (§5 R-P1).
M3 cannot start its final slice before M2a picks the runtime shape, but its build-scripting slice is
independent. M4 is strictly after M3 because the artefact under test must be the distributable.

## 2. Work breakdown: files, components, owners, reviewers

**M1 — R1 redirect integrity.**

| Slice | Affected files and components | Implementer | Independent reviewer |
|---|---|---|---|
| M1.1 macOS policy | `Sources/RetouchStudio/Models/ModelStore.swift` (`ModelDownloadTransfer` delegate method, `download`, the `statusCode != 200` rejection), new `ModelRedirectPolicy` next to it | Full-stack Engineer | Code Reviewer (security-sensitive) |
| M1.2 catalogue policy data | `Resources/model-catalog.json` (per-entry allowed redirect hosts and path classes), `Sources/RetouchStudio/Models/ModelCatalog.swift`, `Windows/RetouchStudio.AI/Models/ModelCatalog.cs`, the shared conformance fixture so both parsers agree | Full-stack Engineer | Code Reviewer |
| M1.3 consent disclosure | `Sources/RetouchStudio/Views/ModelManagerView.swift`, `Sources/RetouchStudio/Models/ModelManager.swift`, `Sources/RetouchStudio/Models/Localization.swift` (English and Persian for the terminal destination), the Windows equivalent in `Windows/RetouchStudio.App/ModelManagerWindow.xaml.cs` | Full-stack Engineer | Test Engineer |
| M1.4 fixtures, both hosts | `Tests/ModelStoreTests.swift` (redirect routes on the existing local test server), `Windows/RetouchStudio.AI.Tests` (302 and 307 handler cases), `Tests/run.sh` registration only if a new suite is unavoidable | Test Engineer | Code Reviewer |
| M1.5 limited real-host probe | probe script or recorded transcript, no weight body fetched | Researcher | — |

**M2a — macOS qualification.** `Docs/AI_RUNTIME.md`, `Docs/W5_UPSCALER_ACCEPTANCE.md` §§7–12 (source of
the existing numbers), `worker/tools/upscale_acceptance.py`, new `Docs/UPS4X_QUALIFICATION.md`. Owner:
Researcher, with the Test Engineer for the harness run. Reviewer: Code Reviewer for the licence fields.

**M2b — Windows conversion.** New `Tools/export-swin2sr-onnx.py` plus a committed recipe, the artefact
record in `Windows/README.md` (size, SHA-256, opset), `Resources/model-catalog.json` (a Windows-platform
entry, or a separate version of the same model), `Windows/RetouchStudio.AI/Capabilities.cs` (unblock
`upscale.4x` only after the gate passes), `Windows/RetouchStudio.AI` model-load path. Owner: Full-stack
Engineer with Researcher for the export feasibility spike. Reviewer: Code Reviewer, plus a licence check
on the derivative artefact.

**M3 — distributable runtime.** `build.sh` (the `RETOUCH_SKIP_WORKER` branch, the stamping block),
`Tools/bundle-worker.sh`, `Tools/validate-bundle.sh`, `.github/workflows/release.yml` (all three macOS
jobs), `Tools/build-windows.ps1`, `Tools/make-dmg.sh`, `Sources/RetouchStudio/Core/AIRuntime.swift`,
`Sources/RetouchStudio/Core/AIWorker.swift`. Owners: Full-stack Engineer (build), Full-stack Engineer
(host discovery) — different files, no overlap. Reviewer: Code Reviewer, with the sealed-runtime and
quarantine findings (tasks #94, #102, #31) closed first.

**M4 — real inference evidence.** `worker/retouch_ai_worker/capability-evidence.json` (schema
`retouchstudio.capability-evidence/2`, the fields listed by the owner), the host reader and any gate that
greps it, a headless harness target that uses the **bundled** helper through the app's own
`AIWorker`/`ExportService.upscale`, and one bounded GUI session for the product path. Owners: Test
Engineer (runs), Full-stack Engineer (harness), Project Manager (the session pack). Reviewer: Code
Reviewer on the records.

**M5 — UI and failure handling.** `Sources/RetouchStudio/Views/ModelManagerView.swift`,
`Sources/RetouchStudio/Models/ModelManager.swift`, `Sources/RetouchStudio/Core/AIWorker.swift`
(`AIWorkerFailure`), `Sources/RetouchStudio/Models/Localization.swift`, `Windows` counterparts, plus the
chip-state tests. Owner: Full-stack Engineer; Test Engineer owns the cancel/retry/recovery matrix.
Reviewer: Code Reviewer.

**M6 — clean-install acceptance.** `Docs/RELEASING.md`, `Docs/RELEASE_2.0.0_ACCEPTANCE.md` (a new
artefact-level section, not a rewrite), a `workflow_dispatch` CI job that installs the MSI on a fresh
`windows-2025` runner and runs one real 4× pass, and the macOS clean-state harness. Owner: Test
Engineer. Reviewer: Code Reviewer.

## 3. Test strategy and measurable acceptance criteria

| Test | Concrete form | Measurable pass condition |
|---|---|---|
| Allowed redirect | fixture route `302` → second local route whose host and path class are allow-listed | store reaches `installed`, recorded SHA-256 equals the fixture hash, one consent sheet visible naming the terminal host |
| Rejected redirect | fixture `302` to a host absent from the allow-list; separate `307` cases to a disallowed path class | refusal, **zero bytes** written into the version directory, error sentence contains "redirect" and names our policy, not the source |
| Same-host `307` | fixture `307` on the same host, cache path (the real Hugging Face config case) | allowed or refused by the declared rule **as tested**, never by accident; the rule is asserted in both directions |
| Truncated / wrong hash after redirect | fixture redirects to bytes whose hash differs | `invalid`/`unverified` verdict, no active model, staging cleaned |
| Both-host agreement | shared fixture consumed by `Tests/ModelStoreTests.swift` and `Windows/RetouchStudio.AI.Tests` | identical verdict strings and identical allow-list outcome for identical inputs |
| Real-host probe, no body | `HEAD` plus a first-byte range against one pinned file URL | redirect chain and terminal host recorded; terminal host present in the catalogue's allow-list; no weight body stored |
| Bundled helper boots from the artefact | mounted DMG, `AIWorker` launch, protocol-2 handshake | `hello`, readiness, health, `provider.list`, shutdown; run recorded with the DMG SHA-256 — **not** a checkout |
| Packaged real inference | one 4× pass on the fixed corpus through the product path | 4× dimensions out, 8-bit or measured bit depth, provenance sidecar verifies, PSNR ≥ 24.0 dB per image and against the predeclared control |
| Memory and latency | harness `--measure`, peak RSS sampled during the job | numbers recorded in the evidence entry; no threshold invented after the run |
| Windows parity | ONNX vs torch reference on the same pairs | PSNR within the D4 tolerance, predeclared before the first run |
| Cancel / retry / recovery | cancel at load, at tile, at write; retry after each; kill during install | cancelled reported as cancelled, no partial model active, retry succeeds, no orphan staging |
| Clean install | fresh runner (Windows) or redirected support directory with no prior state (macOS headless) plus one GUI first-launch session | first launch offers AI honestly, install→verify→run works with nothing pre-seeded |

Two rules protect the ladder: **no quality bar may be moved after a run** (W5-5's own "does not" list),
and **an evidence entry whose fields are empty fails the build** — which is why M4 extends the evidence
schema instead of writing prose into a free-text `evidence` string.

## 4. Reusable evidence versus evidence that must be regenerated

**Reusable as-is.** The licence dossier and verdicts (`permitted_use` blocks, `Docs/MODEL_LICENCES.md`,
the FLUX refusal and its CI-verified gate). Catalogue integrity pins, including the SAM 2 size-and-hash
that this audit re-confirmed against a live `content-length`. The A1 quality results (per-image minimum
30.65 dB, control beaten on all eight images, SSIM higher on every image, determinism 0.00 dB spread) —
as **qualification** evidence. The banded-path memory model (`26.4 B/px`, RSS `0.558 + 0.01842·R`, `R²
0.918`). The 40 MP ceiling decision and the truthful ETA model. The Windows host check set (396 checks)
as a build-and-adapter baseline. The race/lease/rollback suites.

**Reusable only after being re-pointed at the artefact.** Everything currently labelled DEV-RUNTIME: the
protocol-2 handshake, `capability.list`, `provider.list` after a loader ran, and the inference record.
`Docs/W5_UPSCALER_ACCEPTANCE.md` §10.5 already says the installed bundle "carries no
`Contents/Resources/Worker`", so none of it is artefact evidence.

**Must be regenerated or newly created.** Every R4 evidence entry, in schema v2, with artefact SHA-256.
The Windows ONNX artefact and its whole provenance chain — none exists and W5-4's BLOCKED condition
forbids adopting a community conversion. The bundled-helper build and its bundle-validation verdict. The
clean-install records. The `Tests/ModelStoreTests.swift` redirect cases (the current suite proves the
200 path only). The seal/manifest state of the payload, because `verifyArchive` is known fail-open when
`package == nil` and the payload is advisory in CI today.

## 5. Risks, with the mitigation actually scheduled

**R-P1 — Windows ONNX export of Swin2SR is the critical path and is genuinely uncertain.** Swin
architectures export badly: the cyclic shifted-window attention with `torch.roll`, and the
interpolated positional bias (`F.interpolate` with bicubic modes), have historically needed recent opsets
and sometimes custom nodes; CPU EP latency at 512 tiles is unknown. Mitigation: a **two-day feasibility
spike first** (M2b.0) that exports the pinned checkpoint, runs it on the hosted runner, and reports PSNR
against the torch reference on two corpus images. If it fails, the owner is told immediately with the
measured reason, and the options are: a fixed-input-size export, a different 4× model licensed for the
same class, or Windows being re-scoped out of the gate **by the owner**. I will not silently relax gate
item 4 to macOS-only.

**R-P2 — a ~1.3–1.6 GB arm64 DMG changes distribution.** Bundling the helper multiplies the artefact by
about 150× against the 10 MB measured in the audit, under ad-hoc signing with no notarisation.
Mitigation: keep per-arch DMGs, validate the nested interpreter runs after the DMG's own copy (the
`ditto`/quarantine class of defect), and report real sizes before any release-body text is written.

**R-P3 — a 16 GB MacBook Air is both the build host and the acceptance host.** Source-building CPython
plus a 48 MB torch inference is survivable (the banded path measured ~1.3 GB at the ceiling), but a
concurrent CI-leg re-run, a local build and the app must not overlap. Mitigation: builds serialised,
payload built in CI where possible, disk preflight respected, no large download onto the owner's machine
without a stated size and a yes.

**R-P4 — shared-file collisions.** `Tests/run.sh` (suite-count pin), `.github/workflows/ci.yml`,
`Resources/model-catalog.json` and `Localization.swift` are all hot. Mitigation: one owner per file per
moment, M1.2 and M2b serialised on the catalogue, and the suite-count source touched once.

**R-P5 — the redirect fix is a security-relevant relaxation.** Mitigation: allow-list is data, not code
per call; SHA-256 remains the integrity gate; the reviewer is separate; the refused path must stay
fail-closed and tested in both directions.

**R-P6 — GUI dependency.** Gate items 4 and 6 in their strict form need the packaged app to run.
Mitigation: everything provable headlessly is proven headlessly, then **one** bounded session is
requested with a written pack (see D6).

## 6. The release gate, as the owner stated it

| # | Gate criterion | Producing milestone | Status now |
|---|---|---|---|
| 1 | Downloader tests pass on both platforms | M1 | BLOCKED on implementation (defect R1 open) |
| 2 | Selected model has approved licensing and technical assessment | M2a/M2b | macOS licence approved, technical assessment exists at DEV-RUNTIME; Windows unassessed |
| 3 | Required runtime/helper present in the distributable | M3 | NOT VERIFIED — absent from the audited artefact, measured |
| 4 | Real 4× inference succeeds from the packaged application | M4 | NOT VERIFIED on any artefact |
| 5 | Quality, runtime and memory meet predeclared thresholds | M2a/M2b, M4 | macOS MEASURED on dev runtime; thresholds for Windows not yet declared |
| 6 | Clean-install acceptance passes | M6 | NOT VERIFIED |
| 7 | Evidence independently reviewed | M7 | NOT VERIFIED |
| 8 | Owner authorises publication | after M7 | WITHHELD, correctly |

Passing CI changes none of these rows by itself.

## 7. Effort estimate by workstream

| Milestone | Engineer-hours | Calendar, single track | Variance |
|---|---|---|---|
| M1 R1 downloader, both hosts + review round | 10–16 | 1.5–2 days | low |
| M2a macOS qualification dossier | 4–6 | 0.5 day | low |
| M2b Windows ONNX conversion, parity, review | 16–30 | 3–5 days | **high** — dominates the plan |
| M3 bundled runtime, seal, bundle validation | 12–20 | 2–3 days | medium |
| M4 packaged inference + evidence schema v2 | 6–10 + a 60–90 minute session | 1–2 days | medium |
| M5 Model Manager states + cancel/retry/recovery | 6–12 | 1–2 days | medium |
| M6 clean-install acceptance | 8–14 | 1–2 days | medium |
| M7 review of the evidence set, plus one rework loop | 3–5 | 0.5–1 day | low |
| **Total** | **65–107 h** | **10–18 working days** | driven by M2b and M3 |

A defensible commitment is: M1, M2a and the M2b spike inside the first three days; the first helper-bearing
macOS artefact within a week; gate items 1–5 reachable in two to three weeks; gate 6–8 shortly after, with
the Windows conversion as the only item that can extend the schedule materially.

## 8. Unresolved technical decisions

| ID | Decision | Recommendation | Whose call |
|---|---|---|---|
| D1 | Helper **inside** the DMG versus a consented runtime archive installed by the app | Inside the DMG — it is what R3 states literally, and it removes the unpublished-package dependency entirely | Project Manager proceeds; flagged to the owner as a distribution-size change |
| D2 | Windows model source | Convert the pinned `caidas` checkpoint ourselves with a committed, reproducible recipe; never adopt a community ONNX | Project Manager (W5-4 already forbids the alternative) |
| D3 | Export mechanics: opset, fixed versus dynamic input size, tile size, precision | Settled by the M2b spike and recorded, not guessed | Full-stack Engineer, recorded here |
| D4 | Windows acceptance thresholds, fixed **before** the first run | PSNR ≥ 24.0 dB per image **and** within 0.5 dB of the macOS reference on the same pairs, plus the banded memory envelope reproduced on CPU | Project Manager declares before the run; the owner may raise, not lower |
| D5 | Intel slice | Stays helper-less; its DMG says so and it is reported separately, never claimed verified | Owner's existing rule, unchanged |
| D6 | Clean-install method for macOS | Headless clean-state harness first, then one bounded GUI session for first-launch and Gatekeeper truth | Owner authorises the session; I prepare the pack |
| D7 | Whether SAM 2 / MI-GAN / FLUX ride along | No — excluded by the owner's scope limit; only `upscale.4x` may change state | Decided, not open |

## 9. Safety posture kept while executing

No tag, no release or asset mutation, no publication. No GUI launch before the owner authorises a bounded
session. The owner's checkout and personal data untouched; work happens in separate worktrees. MIT stays.
No Developer ID and no notarisation requirement is introduced; ad-hoc signing plus SHA-256 distribution
stays. The updater stays disabled. No paid service. No capability is marked supported without its §3
evidence row, and no incomplete work is marked accepted.
