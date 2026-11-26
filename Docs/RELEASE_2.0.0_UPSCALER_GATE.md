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

**M2b — Windows conversion and inference.** A read-only investigation of this tree (2026-11-24)
changed the shape of this milestone, mostly for the better. **ONNX Runtime is already a shipped,
pinned dependency**: `Windows/RetouchStudio.AI/RetouchStudio.AI.csproj:17` references
`Microsoft.ML.OnnxRuntime 1.32.0`, `Providers.Ensure()` loads the native library and confirms the CPU
execution provider (`Providers.cs:29-35`), `AI/onnxruntime.dll` ships in the built app, and CI asserts
its recorded size and SHA-256 (`ci.yml:556`). **But no inference has ever been created here**: there is
not one `InferenceSession`, `OrtValue` or `Run()` call anywhere under `Windows/`. `WorkerServer.RefuseJob`
(`WorkerServer.cs:188-211`) returns `-32020` for every capability unconditionally, and the gate is
`Capabilities.Runnable()` (`Capabilities.cs:150`) reading the `Fixed` table where
`Capabilities.cs:59-60` marks `upscale.4x` `Blocked`. There is no resize pretending to be a model — no
bicubic fake to remove. And there is **no tiling, overlap or banding code at all on Windows**: the
measured banded pipeline exists only in Python (`worker/retouch_ai_worker/engine.py:35-42`,
`_axis_tiles` / `_axis_plan`), so that algorithm must be ported, not enabled. Memory is a real constraint,
not a formality: `WindowsImageCodec.DecodeAsync` holds two full-resolution buffers at once and
`Decode16Async` three (`:194-245`), and `PixelBuffer`'s `new byte[width * height * 4]` (`PixelBuffer.cs:29`)
multiplies in `int`, so a large 4× output throws `OverflowException` before it allocates.
So the Windows work is: the conversion recipe and its provenance, `windows-x64` plus a usable provider in
`Resources/model-catalog.json` (the `swin2sr-x4` entry is `macos-arm64` / `macos-python` at :218-221, and
`ModelCatalog.Platform` + `Supports()` mark it unsupported on Windows), a C# session create/run plus the
port of the tile-and-blend band, a derivative-artefact licence record, and the inversion of three
assertions that currently *require* refusal (`Windows/RetouchStudio.AI.Tests/Program.cs:166-167,173-176,280-281`).
Files: new `Tools/export-swin2sr-onnx.py`, `Windows/RetouchStudio.AI/Providers.cs`, `Capabilities.cs`,
`WorkerServer.cs`, `Windows/RetouchStudio.Imaging`, `Resources/model-catalog.json`,
`Windows/RetouchStudio.AI.Tests/Program.cs`, `Windows/README.md`. Owner: Full-stack Engineer, with the
Researcher for the export spike. Reviewer: Code Reviewer, plus a licence check on the derivative artefact.
**A shared-file note**: this milestone touches `Resources/model-catalog.json`, which M1 also touches — they
must be serialised, not parallel.

**M3 — distributable runtime.** The mechanism already exists and is nearly complete; what is missing is
wiring, budget and one proof. `Tools/build-python-runtime.sh` source-builds a relocatable
CPython **3.13.15** (pinned SHA-256, arm64-only, Homebrew `openssl@3 xz sqlite` at build time) and writes
the `.source-stamp` that `Tools/bundle-worker.sh:60-73` demands; `bundle-worker.sh` copies the framework
plus the venv site-packages, rewrites `libpython` to `@loader_path`, converts the two internal links to
relative symlinks and **refuses** the bundle if any Mach-O still mentions `/opt/homebrew` or a symlink is
broken. Host discovery already prefers the bundle: `AIWorker.interpreter()` tries
`Bundle.main.resourceURL/Worker/bin/python3` second, right after the `RETOUCH_AI_PYTHON` override, and
`selectedRuntimeIsDownloaded` deliberately returns false when a bundled helper exists. So no app-side
discovery change is needed — the artefact simply never contains that directory today.
Changes therefore land in: `build.sh` (the `RETOUCH_SKIP_WORKER` branch at :170-176, and the nested
re-sign loop at :207-218), `.github/workflows/release.yml` (remove the flag for the **arm64** job only —
`AIWorker.bundledRoot` returns nil under `#if arch(x86_64)`, so the Intel DMG stays helper-less by design
and must say so — plus the Homebrew setup and venv steps that `ci.yml:340-342` already performs, inside a
`timeout-minutes: 60` budget that has **not** been shown to fit), `Tools/validate-bundle.sh` (it lipo-checks
only the app executable, never the nested interpreter), and `Tools/make-dmg.sh` (whether the two symlinks
survive the image is NOT VERIFIED). The payload build itself is already proven end to end in
`ci.yml:319+`, but as a `continue-on-error: true` job that is not a required context, and `ci.yml:297-299`
states plainly that no CI job ever ran the bundle script on a release path. Owners: Full-stack Engineer
(build and CI), Test Engineer (the clean-machine launch proof). Reviewer: Code Reviewer, with the
sealed-runtime and quarantine findings (#94, #102, #31) closed first.
**Weights stay outside the bundle**: `AIWorker.supportDirectory` is fixed to Application Support with an
invariant comment that runtimes must never hold weights, and no code path reads weights from inside the
app — which is precisely why R1 (M1) is on the critical path for M4 rather than a side quest.

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
| Windows inference is not vacuous | the same `job.submit upscale.4x` path the app uses, asserted against a pre-committed reference crop | output dimensions alone **fail** — bicubic satisfies them; the gate is SSIM against the reference plus the PSNR floor, and the three existing assertions that demand refusal are inverted rather than deleted |
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

**R-P1 — Windows real inference is the critical path and is bigger than it first looked.** The good news
is measured: ONNX Runtime 1.32.0 is already referenced, loaded, shipped in the app and hash-checked in CI,
so no new dependency is needed. The bad news is that the Windows side has **never executed a model** — no
`InferenceSession` exists — and has **no tiling code**, while the memory behaviour of the decoder holds two
to three full-resolution buffers and `PixelBuffer` multiplies its length in `int`, so a large 4× output cannot
even be allocated. On top of that sits the export itself: Swin architectures are historically awkward to
export (cyclic shifted-window attention with `torch.roll`, bicubic positional-bias interpolation) and per-tile
CPU latency here is unmeasured. Mitigation: a **two- to three-day spike first** (M2b.0) that exports the pinned
checkpoint, runs one 256 px tile through the CPU execution provider and reports PSNR against the torch
reference on two corpus images — that single experiment prices both the export risk and the latency risk.
If it fails, the owner is told immediately with the measured reason, and the options are a fixed-input-size
export, a different 4× model in the same licence class, or Windows being re-scoped out of the gate **by the
owner**. I will not silently relax gate item 4 to macOS-only, and I will not accept a Windows test that only
asserts output dimensions, because bicubic passes that vacuously.

**R-P2 — the artefact grows from ~16 MB to ~1.3–1.6 GB, and that number is already in the repo, not a guess.**
`ci.yml:315-317` records the full lock unpacking to **1.4 GB** of site-packages, `Docs/PHASE0_CROSSPLATFORM_AUDIT.md:200,222`
reports **1.3 GB measured** with `du -sh` for an app carrying the helper, and `Docs/RELEASING.md:54,192` states
~16 MB light versus ~1.3–1.6 GB with it. Model weights are **additional** — they stay outside the bundle by
invariant — so a user's first AI-enabled run costs the DMG plus tens of MB of weights. Mitigation: keep per-arch
DMGs, state the size honestly in the release notes before anyone publishes, validate the nested interpreter actually
executes after the DMG's own copy (the `ditto`/quarantine class of defect, and `make-dmg.sh`'s symlink preservation
is NOT VERIFIED), and note that `Resources/RetouchStudio.entitlements` is an empty dictionary with no JIT or dyld
exception while `build.sh:195-205` only applies `--options runtime` when a real signing identity exists — which it
never does here, so the whole tree is ad-hoc signed.

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

### 6.1 Packaged-application evidence recorded 2026-11-26 (unmerged branch, developer runtime)

This section changes **none** of the rows above, and it cuts both ways. It exists
so a later reader cannot read gate row 4's "NOT VERIFIED on any artefact" as "no
packaged artefact was ever run" — one was, and it is documented below — and cannot
read that local diagnostic as a release gate pass either. Row 4 still cannot be
marked verified: the artefact is unmerged, was independently reviewed only at
`fd7a956`, was never rebuilt at the frozen head before that head moved, and was
never clean-installed — so gate 7's conclusion is unchanged and row 6's
clean-install condition was never met. The
historical table is left byte-for-byte intact; this dated section is where the
record is corrected. Everything below was observed on one developer machine
against the unmerged branch
`w5-m3-packaged-acceptance`; `main` at `5aac9c3a` contains neither
`Sources/RetouchStudio/Core/PackagedUpscaleSelfTest.swift` nor
`Tools/worker-integrity.py` nor `Tools/validate-m3-fixture.py`
(`git ls-tree 5aac9c3a Tools/` lists only `Tools/validate-bundle.sh` of that
group).

- **What ran.** A packaged arm64 `Retouch Studio.app` and its DMG were built
  locally and the app's own diagnostic (`--upscale-selftest`, dispatched at
  `Sources/RetouchStudio/Core/SelfCheck.swift:32-35` on that branch) was executed
  against the bundle. The recorded verdict is `UPSCALE SELFTEST: PASS` on a real
  4× job: 64×48 source, `tile 1/1`, `nearest-neighbour mean pixel delta 17.6382`
  (the statement that defeats "it was just a resize"), `independent mps RGB8
  reference matched exactly`, provenance `upscale.4x, swin2sr-x4 1.0.0, scale 4`,
  output SHA-256
  `7c64bb81ad39a7f8a4c8f9a4a0e56305b16dbbfe8c3259c15c7614d1e52c9ffd`. The run used
  an isolated `HOME`/`TMPDIR` (both trees are listed in the evidence) and was
  reproduced after relocating the bundle and from a read-only DMG mount.
  **"Performed zero downloads" is an inference here, not a direct measurement of
  the primary run:** the evidence set's environment dump
  (`evidence/ambient-env.txt`) is a 0-byte file, so the offline claim rests on the
  negative-case runner, whose recorded command line does strip
  `RETOUCH_AI_PYTHON`, `RETOUCH_AI_WORKER_ROOT`, `RETOUCH_AI_MODELS` and sets
  `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, `PYTHONDONTWRITEBYTECODE=1`, and on
  the owner AI-root snapshots hashing identically before and after. Treat "no
  network was needed" as supported and "no network traffic was possible" as
  **NOT VERIFIED** for the primary run.
- **Which commit the identity belongs to — and which it does not.** The evidence
  manifest names head `fd7a956e8d0500bce5e21f41e9d8d98a5276a622`, bundle content
  digest `df2649a904aaf3cc29e4222a061840c7f4bd7ae6c00a5f925ba3c9916c647b30` over
  29,178 files+symlinks, main executable
  `5a34eb6db532b4db988a05e74766f0c26d69997801e91e595f28371708fc03b4`, DMG
  `04a90aa7799447f8c7f237d1d904e5acabe3390354da5a0caaa04fd0e18ef651`. The branch
  head later became `d4ada2ac6337e4bc07fdc99442410852174a6bcc`, whose entire
  difference from `fd7a956` is a two-line edit inside
  `Tests/RuntimeProcessTests.swift` (`git diff --stat fd7a956 d4ada2a` → 1 file
  changed, 2 insertions, 2 deletions), so no bundle input changed. But the
  packaged bundle was **not** rebuilt at `d4ada2a` and **no evidence record binds
  the diagnostic to that SHA**: the claim is "the tested bundle is made from the
  sources `d4ada2a` also contains", not "the tested bundle is `d4ada2a`". (That
  limitation was closed the same evening — a later step rebuilt the bundle and
  re-measured the diagnostic at `d4ada2ac`, binding the acceptance identity to that
  SHA by execution; see §6.1a. The sentence above was true when recorded and is
  kept as written.) An
  earlier briefing cited a digest `8f392256…` over 64,832 entries; that citation
  is wrong and the manifest value above supersedes it.
- **Signature truth.** The shipped bundle is signed ad-hoc. Recorded
  `codesign -dvv` output: `Identifier=app.retouchstudio.mac`,
  `Format=app bundle with Mach-O thin (arm64)`, `flags=0x2(adhoc)`,
  `Signature=adhoc`, `TeamIdentifier=not set`, CDHash
  `840a69fc960784395b161e3a7e246cbcd737f6ab`. Ad-hoc means "this machine accepts
  its own build": there is no Apple-issued certificate and no notarization ticket
  behind it. The Apple Developer Program was declined by the owner on 2026-11-21, so
  Developer ID signing and notarization are out of scope and stay **NOT VERIFIED**;
  no distribution, Gatekeeper or first-launch promise may be built on this signature
  class.
- **Tamper detection: OFFLINE ONLY — NOT VERIFIED at runtime.** Ten scenario
  directories were run against disposable copies of that bundle, eight of them
  attacks on bundle integrity. The application refused
  01-fixture-missing, 02-fixture-modified and 03-fixture-symlink
  (`UPSCALE SELFTEST: FAIL`, recorded exit 1). 04-unsigned produced no application
  output at all (recorded exit 137 with an empty diagnostic log) — consistent with
  the launch-time kill macOS applies to an unsigned arm64 binary, and in any case no
  application check ran. Cases 05-invalid-signature, 05b-macho-text-tamper,
  06a-worker-payload and 06b-integrity-manifest each printed
  `UPSCALE SELFTEST: PASS` with recorded exit 0 **while the same bundle copies'
  offline gate records show exit 1**. The names of those cases describe the
  attack applied, not an outcome. The two remaining scenario directories,
  07-oversized-out and 08-multibyte-out, are not tamper cases at all: they probe
  `--out` and socket-path boundaries. Inside them `7a-boundary-accepted` printed
  `UPSCALE SELFTEST: PASS` at exit 0, while `7b-probe-sock-104`,
  `7c-worker-sock-104`, `8a-utf8-sock` and `8c-existing-out` each printed
  `UPSCALE SELFTEST: FAIL` at exit 1, and `8b-nested-trees` holds two refusal
  records (`model-in-out.log`, `out-in-model.log`) without exit files. Their
  top-level `offline-gates.txt` reports every gate at exit 0 because those bundles
  were never modified, so those two directories carry no tamper evidence in either
  direction. The refusals for the tamper cases therefore came from
  `Tools/validate-bundle.sh`, `Tools/worker-integrity.py` and
  `Tools/validate-m3-fixture.py` — scripts run outside the shipped binary, of which
  only `Tools/validate-bundle.sh` exists on `main` — and from
  `build.sh:221` (`codesign --verify --deep --strict`) plus `build.sh:224`
  (`./Tools/validate-bundle.sh … || exit 1`), the same two calls appearing on the
  acceptance branch at `:241` and `:249`, all of which run while the bundle is
  being built, before anyone launches it. Inside the product,
  `PackagedUpscaleSelfTest.swift:436-441` gates the loaded model only through
  `AIRuntimeValidation.functional(...)`; that file contains no `codesign`,
  `SecCode` or `csops` reference, so the integrity gap is specifically at
  launch time on the user's copy. Until `M3-RUNTIME-INTEGRITY-PREFLIGHT`
  (`Docs/POST_RELEASE_ROADMAP.md` §8.4, item **I10**) is built and observed, **no
  artefact in this repository may state that the application verifies its own
  bundle.**
- **What the packaged application *did* enforce, which is not nothing.** The
  canonical fixture has to be a real file inside the bundle: removing it, editing
  it or replacing it with a symlink each produced `UPSCALE SELFTEST: FAIL` at
  exit 1. Output-path guards refuse before any work starts, with exact numbers in
  the message: `--out` must name a new directory (and a sentinel planted in the
  target survived), `--out` and `--model` must be separate directory trees in both
  nesting directions, and the AF_UNIX capacity limits were reported as
  "the runtime probe socket path is too long for AF_UNIX (104 UTF-8 bytes; maximum
  103)" and "the worker socket path is too long for AF_UNIX (123 UTF-8 bytes;
  maximum 103)". Refusals left nothing behind: every case directory pairs a
  `digest-before.json` with a `digest-after.json` (spot-checked byte-identical for
  `8c-existing-out`, both `832ff45e876846e4db07c3f8e800dc942c768b3ad3a40526dbf8379e3a607847`),
  and the owner AI-root snapshots taken before and after the primary run hash
  identically (`64d61da86fc386e88c71af2bec6e9bfdf487e1df64671bfd21ed415900a163d6`),
  so no model was staged into the user's directory. The byte-identity claim was
  re-verified during this documentation pass rather than copied: the recorded raw
  output is 147,456 bytes hashing
  `095bd862b7bf7ec14bb65e853cda5f5330bbdf56dfe7b3eea86b01956066fdc6`, which equals
  the SHA-256 of the bundle's own `reference.mps.rgb` fixture in the same manifest,
  so a 256×192×3 packaged MPS result really did match the independent reference
  exactly.
- **What these runs say about weights, and what row 3 of the table above means.**
  The diagnostic's `--model` pointed at an installed checkpoint outside the bundle,
  so these runs prove the packaged app can *use* an installed model, not that
  weights ship inside the DMG. The same records do show the bundle carries a Worker
  payload (`Contents/Resources/Worker/…`, 32,133 entries reported verified by
  `Tools/worker-integrity.py`), so gate row 3's phrase "absent from the audited
  artefact" cannot describe this artefact — and that phrase is defined nowhere:
  `git grep -n "audited artefact"` at `5aac9c3a` returns only row 3 itself. Row 3
  therefore stays exactly as written and is neither confirmed nor refuted by this
  section; it asks about *the distributable*, and what is documented here is a
  locally built, unmerged acceptance bundle whose independent review covered the
  `fd7a956` artefact only (see the dated note at the head of this section).
- **Provider and platform boundaries.** Only the Metal/MPS provider branch was
  exercised by the packaged diagnostic. The bundle also carries
  `reference.cpu.rgb`, but no packaged CPU-provider run is recorded, so the CPU
  path is **NOT VERIFIED on the packaged artefact** even though the in-repo
  harness compares both references. The Intel `x86_64` slice and every Windows
  real-inference path remain **NOT VERIFIED**. The 64×48 canonical fixture is a
  synthetic acceptance image, not a portrait, so nothing here measures perceived
  quality on user photographs; quality thresholds stay exactly where gate row 5
  of the table above puts them (`macOS MEASURED on dev runtime`, Windows
  thresholds not yet declared).
- **Evidence class.** Developer runtime, not clean install. The bundle was built
  and tested in the same working copy by the same pass that produced the hashes;
  it was never installed from the DMG onto a fresh account and driven through the
  product UI, which is exactly what gate 6 asks for and why gate 6 stays
  `NOT VERIFIED`.
- **The automated packaged gate has never run a job.**
  `.github/workflows/m3-packaged-acceptance.yml` exists only on the same unmerged
  head, and the workflow named "M3 Packaged Real Inference" was never registered as
  a name-keyed workflow on the remote (observed 2026-11-26: `gh run list --workflow`
  still returns "could not find any workflows named M3 Packaged Real Inference", and
  the workflow's remote display name is the bare path
  `.github/workflows/m3-packaged-acceptance.yml`). What exists instead are three
  zero-duration push records: run `45834212705` at `d4ada2ac`, `45676097412` at
  `fd7a956`, and `45655364200` at `ad9ea48` — each `event: push`, `status: completed`,
  `conclusion: failure`, with `gh run view --json jobs` returning an empty list and
  the log fetch returning "log not found", so no job ever executed a step. The
  measured conclusion is therefore "no packaged CI step has ever run", not "no
  workflow record exists". Its inputs are
  `model_run_id`, `model_artifact`, `runner_label` (`:1-23`); it takes no `ref` or
  `sha` input, and `runner_label` defaults to `macos-15` with the file's own note
  that a hosted runner may expose no Metal device. A locally passed diagnostic is
  therefore not CI evidence, and G-ACCI-1/G-ACCI-2 below are open before any run
  can be trusted as an acceptance record.

### 6.1a Head-bound re-measurement at `d4ada2ac` (same day, recorded 2026-11-26 evening)

This subsection supersedes exactly one sentence of §6.1 — "the packaged bundle
was **not** rebuilt at `d4ada2a` and **no evidence record binds the diagnostic
to that SHA**" — and nothing else. Every other §6.1 statement stands, and the
gate rows above are unchanged: the artefact is still unmerged, still ad-hoc
signed, still never clean-installed, and no CI job has run. The record:
`EVIDENCE-MANIFEST-HEAD-15.txt` (165 lines, 19,949 bytes, sha256
`77ccc2c213c25a2f0f30c564000fad501983030463db0c081a6ccab71c5f87fc`).

- **Identity.** Branch head `d4ada2ac6337e4bc07fdc99442410852174a6bcc` before and
  after the build; `git diff --stat` against that head produced zero bytes of
  output and `git status --porcelain` zero lines (build outputs are gitignored,
  no repository file was written); the newest reflog entry is the `d4ada2a`
  commit itself at 17:27:24 local, predating the 20:16 build, and no git
  operation occurred during the run. No commit, push, branch, tag, merge,
  release or publish. The only execution of the app binary was the CLI
  `--upscale-selftest` invocation; the GUI was never launched.
- **Release build.** Exit 0, wall 89.69 s, with the documented acceptance stamps
  `RETOUCH_ARCH=arm64 RETOUCH_VERSION=0.0.0-m3-acceptance RETOUCH_BUILD=m3-acc-1`.
  Those stamps are required to reproduce the recorded `Info.plist`; without them
  the build produces the `2.0.0`/`2` plist and no digest can match. Disclosed as
  a deviation from "no extra flags", not a hidden input.
- **Byte-identity of the rebuilt bundle.** Content digest
  `df2649a904aaf3cc29e4222a061840c7f4bd7ae6c00a5f925ba3c9916c647b30` over 29,178
  files+symlinks — the §6.1 value — with a per-entry comparison against the
  retained `fd7a956` clone of only-in-ref 0, only-in-new 0, changed-hash 0:
  zero divergence, so the two-line `Tests/RuntimeProcessTests.swift` difference
  between `fd7a956` and `d4ada2ac` reaches no bundle input. Main Mach-O
  `5a34eb6db532b4db988a05e74766f0c26d69997801e595f28371708fc03b4`, equal to the
  §6.1 value; the outer seal re-signed to the same bytes (CDHash
  `840a69fc960784395b161e3a7e246cbcd737f6ab`, same identity fields as §6.1).
- **Packaged MPS inference on the head-built bundle.** Exit 0, wall 10.9 s,
  verdict `UPSCALE SELFTEST: PASS`; output PNG
  `7c64bb81ad39a7f8a4c8f9a4a0e56305b16dbbfe8c3259c15c7614d1e52c9ffd` and decoded
  RGB8 `095bd862b7bf7ec14bb65e853cda5f5330bbdf56dfe7b3eea86b01956066fdc6` both
  equal to the §6.1 record values, the RGB8 matching `reference.mps.rgb` with
  zero differing bytes; provenance `model.provider == "mps"`, which the
  self-test requires to equal the device and throws otherwise. An isolated
  `HOME`/`TMPDIR` re-run (exit 0, wall 11.6 s) reproduced the same PNG hash; the
  provenance sidecar differs only in `createdAt`, `elapsedSeconds` and `jobId`,
  with every content field identical. The primary AI-state tree's entry listing
  hashed identically before and after the packaged run.
- **Offline gates on the head-built bundle.** `validate-bundle` exit 0;
  `worker-integrity` exit 0 with 32,133 entries; `audit-bundle-notices` exit 0
  with 29,162 files accounted; `codesign --verify --strict --verbose=2` exit 0
  ("valid on disk", "satisfies its Designated Requirement"); `spctl -a` exit 3 —
  ad-hoc is not distribution trust, unchanged by this record. Bytecode residue
  (`__pycache__`/`*.pyc`/`*.pyo`) find returned zero lines before and after both
  inference runs, and the final tree digest was still `df2649a9…`/29,178.
- **Worker cache path exercised.** This build hit the documented
  `build.sh` park/restore short-circuit for `Contents/Resources/Worker`, so its
  log prints "helper runtime unchanged" / "worker integrity verified: 32133
  entries" instead of the §6.1 run's full re-bundle block. Both paths converge
  on the same 32,133-entry integrity manifest and the same bundle digest, so the
  cache reuse is a measured deviation recorded, not an unaccounted input.
- **The DMG, stated narrowly.** The image was **not** re-created by this step:
  its container sha256 `04a90aa7799447f8c7f237d1d904e5acabe3390354da5a0caaa04fd0e18ef651`
  equals the §6.1 value, and its container mtime (15:27:18) predates the
  existence of the `d4ada2a` commit (17:27:24); `build.sh` never invokes
  `hdiutil` — only `Tools/make-dmg.sh` does. What was measured is this: the
  distribution image's payload was measured read-only and is byte-identical to
  the head-built bundle (mounted read-only, payload digest `df2649a9…`/29,178,
  Mach-O `5a34eb6d…`, detached cleanly with no stale mount left). **The image
  container itself predates the head commit:** the earlier acceptance round's own
  `make-dmg.sh` log (exit 0, with its recorded creation line and its files
  listing) records this container — 588,477,130 bytes — as created 2026-11-26
  15:27:18 +0330, almost two hours before `d4ada2a` existed (17:27:24 +0330), so
  the container is content-equivalent to the head-built bundle but demonstrably
  **not head-built**. (Dated tightening the same evening: this measurement
  replaces this section's earlier framing "container-level provenance at
  `d4ada2ac` is NOT VERIFIED", written before the creation log was consulted;
  the payload statement above stands unchanged.) The app bundle itself is head-fresh
  because the build removes and reassembles it on every run; its Mach-O mtime
  (20:16:22) postdates the head commit.
- **What this binds and what it does not.** The §6.1 acceptance *identity* —
  bundle, digest, inference verdict — is now bound to `d4ada2ac` by execution
  rather than by the file-overlap argument. It adds no tamper detection (the
  shipped binary still has no in-process signature preflight; that stays a 2.1
  decision), no CPU-branch, x86_64-slice, Windows, GUI or clean-install
  evidence, and does not unlock gate rows 4, 6 or 7.

### 6.1b The accepted bundle is diagnostic-stamped — release-shape identity NOT VERIFIED (recorded 2026-11-26)

This is a release-gate requirement, not a cosmetic note, and §6.1a's head
binding does not satisfy it.

- **The accepted artefact carries non-release stamps.** `plutil -p` on the
  retained acceptance bundle's `Contents/Info.plist` reads
  `CFBundleShortVersionString = 0.0.0-m3-acceptance` and
  `CFBundleVersion = m3-acc-1`. `build.sh:110-115` (at `d4ada2ac`) writes exactly
  those two keys via `PlistBuddy` from `RETOUCH_VERSION`/`RETOUCH_BUILD`, and
  `Contents/Info.plist` is one of the 29,178 entries inside both the tree digest
  `df2649a904aaf3cc29e4222a061840c7f4bd7ae6c00a5f925ba3c9916c647b30` and the code
  seal. A release-stamped build therefore differs in at least one digest input by
  construction: the recorded digest **cannot** be shared with a `2.0.0`/`2` bundle
  under any build order. Every byte-identity claim in §6.1/§6.1a is the identity of
  a *diagnostic-stamped* artefact and must not be quoted as the identity of a
  shippable package.
- **A release-shaped image exists but predates both candidates.** The unmerged
  acceptance worktree also carries `RetouchStudio-2.0.0-arm64.dmg`
  (577,588,100 bytes, mtime 2026-11-24 22:44:42 +0330, sidecar
  `RetouchStudio-2.0.0-arm64.dmg.sha256` recording
  `f65444789e0ef784d18ab8b54ecd7fc764ba2d73f1a4f566c2b86402a5acb475`). Its
  timestamp is before `fd7a956` (2026-11-25 22:01:11 +0330) and before
  `d4ada2ac` (2026-11-26 17:27:24 +0330), and at the time of writing its payload
  had **never** been compared, file by file, against a head build.
- **Status of the requirement "the packaged acceptance holds for a
  release-stamped build": NOT VERIFIED — measurement IN PROGRESS** as of
  2026-11-26. A release-stamped (`2.0.0`) packaged measurement is being run
  separately; its result does not exist in this repository's records yet and
  belongs in a LATER dated addendum to this section. Nothing in §6.1/§6.1a may be
  read as pre-approving it.

### 6.2 Packaged-acceptance follow-ups registered 2026-11-26 (not implemented)

Both items need changes under `.github/`, which the documentation pass that added
this section is not allowed to touch. They are recorded so the first real run of
the workflow is interpreted correctly, not optimistically.

**G-ACCI-1 — the evidence set does not name the candidate commit.** The identity
step writes `gh run view "$MODEL_RUN_ID" --json
databaseId,headSha,headBranch,workflowName,conclusion,createdAt` to
`model-source-run.json` (`m3-packaged-acceptance.yml:51-53`). That binds the
evidence to the **model source** run's head, not to the revision whose bundle ran
inference: `grep -nE "GITHUB_SHA|github.sha"` over that workflow finds no match,
and the artifact is named only from `github.run_id`/`github.run_attempt`
(`:201`). The checked-out revision (`:42-43`, `actions/checkout@v7` with no `ref`
input) is recoverable from the Actions run record, but nothing inside the
downloaded evidence carries it, so an artifact cannot self-attest which candidate
it tested. Minimal fix: write `git rev-parse HEAD` (or `github.sha`) into
`$EVIDENCE_ROOT` next to `SHA256SUMS.txt` (`:193-195`).

**G-ACCI-2 — an empty evidence set uploads as a success.** The upload step
`Upload identifiable packaged acceptance evidence` is `if: always()` with
`if-no-files-found: warn` (`:197-202`), so a run whose evidence directory is empty
leaves only a step warning, and a job with no artifact can still be read as a
completed acceptance run. The Windows job in `ci.yml:565-570` already uses
`if-no-files-found: error`, which is the pattern this step should follow. Minimal
fix: `warn` → `error`. Until then, "the acceptance run has an artifact" is not
evidence that the acceptance run recorded anything.

## 7. Effort estimate by workstream

| Milestone | Engineer-hours | Calendar, single track | Variance |
|---|---|---|---|
| M1 R1 downloader, both hosts + review round | 10–16 | 1.5–2 days | low |
| M2a macOS qualification dossier | 4–6 | 0.5 day | low |
| M2b Windows ONNX conversion, **plus the first real C# inference and a ported tiling band** | 40–70 | 5–9 days | **high** — dominates the plan |
| M3 bundled runtime, release-CI wiring, seal, bundle validation | 14–24 | 2–4 days | medium — the 60-minute job budget is unproven |
| M4 packaged inference + evidence schema v2 | 6–10 + a 60–90 minute session | 1–2 days | medium |
| M5 Model Manager states + cancel/retry/recovery | 6–12 | 1–2 days | medium |
| M6 clean-install acceptance | 8–14 | 1–2 days | medium |
| M7 review of the evidence set, plus one rework loop | 3–5 | 0.5–1 day | low |
| **Total** | **100–155 h** | **15–25 working days** | driven by M2b, then M3 |

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
