# W5 Roadmap — Multi-Platform AI Runtime and First Capability

**Status:** Execution roadmap after the owner review of 2026-11-16. The W5-0
decisions are answered (decision record §7) and A1/A2 is approved; this
revision reflects those outcomes. No runtime implementation has started, and
this document changes no code, catalog, schema or release artifact.
**Date:** 2026-11-16 (revised after the owner review).
**Base:** `main` at `8000c9d` (PR #65 merge, 2026-11-16).
**Authority:** product-owner direction of 2026-11-16 and the W5-0 owner
review of the same date
([AI_11_MULTI_PLATFORM_ADDENDUM.md](AI_11_MULTI_PLATFORM_ADDENDUM.md) §1, §4,
§7), under Master Execution Plan V4, whose A1/A2 amendment is approved and
recorded there; the V4 text itself is unchanged.
**Companions:**
[W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md),
[AI_11_ROADMAP.md](AI_11_ROADMAP.md),
[AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md),
[MASTER_PLAN_REMAINING_WORK.md](MASTER_PLAN_REMAINING_WORK.md).

## 1. How this roadmap relates to V4 and AI-01

Master V4 §2 remains the delivery authority. This roadmap is the W5 execution
view. A1/A2 is approved: the Windows "AI edits" completion criterion moved
from stage 4 to W5 for the adopted set, and after W4 completes, W5-0, W5-1,
W5-2 and W5-3 may proceed while W3 proceeds independently. W3 still precedes
any Windows face, landmark or mask support claim; the landmark model itself is
an F1 decision. The approval and its exact consequences are recorded in
[AI_11_MULTI_PLATFORM_ADDENDUM.md](AI_11_MULTI_PLATFORM_ADDENDUM.md) §4, and
the V4 file is unchanged by owner instruction.

AI-01's work packages remain the capability definitions: R0–R4, F1/F2, S1/S2,
U1, E1, H1, B1, P1, G1 and N1
([AI_11_ROADMAP.md](AI_11_ROADMAP.md) §3–4). This roadmap maps them onto W5 and
the milestones that follow. Only `upscale.4x` is promoted into W5 itself; every
other approved capability keeps an explicit follow-on milestone in §4.

**Nothing is dropped.** The audit table below is the contract that no approved
capability disappears:

| Approved capability (AI-01 §3) | W5 treatment | Retained milestone |
|---|---|---|
| A — Face analysis, landmarks, regions | contract only; no Windows model in W5 | W3 / F1, F2 |
| B — Smart masking and segmentation | contract only; model manager enables later models | S1, S2 |
| C — Portrait AI augmentation | none; classical stays default | P1 |
| D — Healing and object removal | none; records preserved and named | H1 |
| E — Background editing | none; person matte preserved | B1 |
| F — Generative editing and outpainting | none; outpainting stays a refusal | G1 |
| G — Upscaling | **Upscaler 4x is W5-4** | U1 |
| H — Enhancement, restoration, AI Enhancer | none; distinct from upscaling | E1 |
| Infrastructure — runtime, models, resources | W5-1..W5-3, W5-5 | R0–R4, M9 |

## 2. Evidence discipline

The labels and gates are unchanged from AI-01: a milestone closes only on
**VERIFIED** or **MEASURED** evidence with cited context; an **ESTIMATE** may
plan but not close; **NOT VERIFIED** may not become a support claim. The
decision record's NOT VERIFIED register
([W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
§8) is the authoritative list of open facts for W5.

One rule overrides speed: a capability is never `supported` because an
interface, a class, a merged PR or a green build exists. The state definition
is [W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
§3.3–3.4.

## 3. W5 steps

### W5-0 — Architecture and contract freeze

**Deliverables:** this roadmap, the decision record and the addendum; the
owner decisions in decision-record §7 (answered 2026-11-16).
**Exit:** decision-record §5 is complete; the documents receive final owner
approval; the Swin2SR x4 Windows artifact evidence is approved or W5-4 is
marked BLOCKED (it is BLOCKED today). W5-1–W5-3 do not wait on Swin2SR.
**Does not:** implement, download or change a UI.

### W5-1 — Reproducible runtime, both platforms

**Depends on:** W5-0; the worker-source and dependency decisions (answered
2026-11-16).
**Deliverables (macOS):** the complete worker source in this repository, with
its licence and dependency notices; every dependency pinned by version and
hash; no mutable branch or unverified download; a reproducible, source-built,
self-contained app runtime, so end users never install Python manually; the 60
regression tests run from a fresh checkout; a real helper process started from
that tree that answers protocol 2 (`HelperRegistry.protocolVersion`,
handshake check in `WorkerClient`) and reports readiness, health and shutdown.
**Deliverables (Windows):** a C# worker executable built from this repository,
contained by a job object, with the same JSON frames over its transport;
ONNX Runtime CPU EP (dependency approved 2026-11-16, including its native
payload) initialises and reports its provider without a model; its binding
version, payload size and hash are pinned and recorded; no Python and no GPU
requirement.
**Exit:** on both platforms, a fresh checkout starts a real worker process and
completes the protocol handshake, with the run recorded. Starting a stub or a
mock is not this exit.
**Does not:** adopt a model, change the macOS inference stack, set
`AIRuntime.package` to a downloadable package, or claim GPU support. The ONNX
Runtime CPU dependency is approved; adding it does not authorize an unverified
version or an unpinned payload.

**Implementation (2026-11-16, in review):** the worker source and 67 tests live
under `worker/` with hashed test and runtime locks. `Tools/build-python-runtime.sh`
builds CPython 3.13.15 from the pinned source tarball and records a source
stamp; `Tools/setup-worker-venv.sh --full` installs the lock into that
interpreter, and `Tools/bundle-worker.sh` refuses any interpreter without the
stamp. Locally, the source-built runtime created the full environment, the full
hashed lock check passed, the bundled 1.5 GB runtime started outside Homebrew
with no Homebrew load-command references, and it completed the protocol-2
handshake (`hello`, `health`, `provider.list` CPU, `ping`, `shutdown`, socket
removed); 67 worker tests, the Swift engine/model/runtime suites and the
StudioCore/ABI gates passed on that tree. Protocol
2, the readiness registry and `Tests/Contract/protocol2.json` are documented in
`Docs/AI_PROTOCOL_V2.md`. Windows adds `RetouchStudio.AI`, `.AI.Worker` and
`.AI.Tests`, with ONNX Runtime 1.32.0 (size and SHA-256 recorded in
`Windows/README.md`) and Job Object containment. CI run 43878989037 passed on
macos-15 and windows-2025: the macOS job rebuilt the source runtime from the
tarball, installed the hashed environment and passed all suites, and the
Windows job passed the AI runtime tests, including ONNX Runtime CPU without a
model, the real worker's ready registry record, the protocol-2 handshake,
foreign-contract refusal, shutdown exit, Job Object containment and the
protocol-1 refusal. That is CI-on-a-hosted-runner evidence, not physical
Windows hardware or GPU evidence.

### W5-2 — Model Manager

**Depends on:** W5-0 semantics, W5-1 workers.
**Deliverables:** per-user store; bundled versioned catalog with mandatory
size and SHA-256; consent before bytes; staging and atomic install; update by
pointer and rollback; OS-lock leases; safe deletion; startup cleanup;
indeterminate progress when a total is unknown.
**Exit:** the race suite in decision-record §3.9 passes on both platforms;
deletion during a job is refused with `E_MODEL_LEASED`; an interrupted install
leaves no active model; the verify action catches a mutated file; the
unverifiable-entry rule (DR-5) is enforced.
**Does not:** fetch a remote catalog, delete an unleased model without
explicit consent, or download weights in the job path.

**Status (2026-11-16):** implemented on macOS and Windows; PR #68. Hosted CI
run 43932552840 is green on both hosts (macOS and Windows model-store suites).
The Windows worker does not load model weights yet (W5-3 owns inference), so
its shared-lease attachment is pending; Windows Swin2SR remains blocked.

### W5-3 — Platform adapters and truthful capability reporting

**Depends on:** W5-1, W5-2.
**Deliverables (macOS):** the existing worker behind the frozen contract; the
capability list comes from the adapter, not hard-coded UI; typed errors and
cancel latency.
**Deliverables (Windows):** the C# adapter and capability list over ORT CPU;
every state carries a reason; unsupported capabilities are refused, never
silently dropped, and the export guard keeps naming preserved records.
**Exit:** both adapters answer `capability.list` with the frozen vocabulary;
no capability is `supported` without a recorded run; a stopped worker produces
`E_WORKER_MISSING`, not a timeout; a model gap produces `E_MODEL_MISSING` and
opens the model manager.
**Does not:** add face, landmark, mask, heal, generative or enhancement
capabilities.

**Status (2026-11-17):** implemented on both adapters; PR #69. Hosted CI run
44110079042 is green on head `45e9e30` (macOS Integration, Windows App,
Windows StudioCore, StudioCore Boundary, Platform-neutral Conformance;
`Ran 88 tests`, `AI RUNTIME TESTS: PASS`, `WINDOWS APP BUILD: PASS`). Only
`upscale.4x` on macOS is `supported`, from the recorded 4× run; the ledger
entry at `worker/retouch_ai_worker/capability-evidence.json` is the textual
record of it (`Docs/PHASE5_ACCEPTANCE.md` §4, `Docs/PRIVACY_AUDIT.md` §4), and
it names no run id, host or artefact hash, so no CI gate re-checks it. Every
other capability carries an explicit state and reason. The macOS job path still
submits by kind; a review found that a size-mismatched install reported
`blocked` was still loaded by that path, and the load path now refuses it with
`-32019` (`E_MODEL_UNVERIFIED`). Qualification states (no recorded run, legacy
layout, DR-5 metadata) stay runnable on purpose. Windows W5-4 stays blocked;
the live capability panel has not been exercised in a UI session.

**Dated corrections to the two paragraphs above (2026-11-17, W5-4 Slice 1).**
The text is kept as the evidence those runs produced; three statements in it are
not true of the current tree and must not be read as present-tense claims.

1. "Only `upscale.4x` on macOS is `supported`, from the recorded 4× run" is
   wrong as a live statement. A read-only `capability.list` against this Mac's
   store (`~/Library/Application Support/RetouchStudio/AI/models`) reports
   `upscale.4x` as `blocked`: "swin2sr-x4 is installed without a version; adopt
   it in the model manager before a capability can bind it". The ledger entry
   records that a run happened; it binds a model *version*, and a legacy flat
   install has none, so the capability is claimable only after that install is
   adopted. See [W5_ADAPTERS.md](W5_ADAPTERS.md) §Limitations.
2. "`provider.list` CPU" in the W5-1 implementation evidence was the static
   macOS record this slice removed. `Docs/AI_PROTOCOL_V2.md` already required a
   provider to be reported only after it initialised; the macOS worker now
   complies (empty plus `state: "unavailable"` and a reason before the first
   model, `mps`/`cpu` after a loader used one). Windows still answers `CPU`,
   because `Providers.Ensure()` really initialises it. W5-1's exit — a real
   worker completing the protocol-2 handshake — is unaffected.
3. `Ran 88 tests` was that run's worker count. The suite is 100 tests since
   Slice 1, and the macOS CI gate now pins `Ran 100 tests`.
   **Same-day addendum, 2026-11-17:** the §3.6 publication work then added 15
   more tests and the gate pins `Ran 115 tests`; the 100-test figure above is
   the Slice 1 count and stays as recorded. Run `44145839011` on head `fec5930`
   is the evidence for the 100-test pin, and macOS Integration job
   `134322437405` on head `9b2b807` executed the 115 pin
   (`found: Ran 115 tests`). The review fixes then moved it to 120; that
   figure is unverified until a macOS run prints it.

### W5-4 — First cross-platform capability: Upscaler 4x

**Depends on:** W5-3. **Windows W5-4 is BLOCKED** until the owner reviews and
approves the Swin2SR x4 ONNX evidence: a reproducible conversion procedure,
the source checkpoint, the opset, the output artifact, its size, its SHA-256,
licence evidence and quality validation. No unverified community conversion is
approved. macOS W5-4 work and W5-1–W5-3 continue independently.
**Deliverables:** `upscale.4x` on macOS (existing behavior, contract
conformance) and, once unblocked, on Windows (ORT CPU); provenance sidecar;
quality comparison on a fixed corpus with a tolerance fixed before the run;
measured bit depth, memory and CPU wall time; cancellation at load, tile and
write.
**Exit:** the acceptance gates in decision-record §4.3 pass for every platform
and gate that applies; the Windows artifact is produced on `windows-2025` only
after its evidence is approved. A successful job alone is not the exit.
**Does not:** adopt an unverified ONNX conversion, claim macOS/Windows
performance parity, claim 16-bit unless measured, or turn upscaling into a
canvas mutation (AI-01 ADR-3).

**Status (2026-11-17): Slice 1 is in review on `w5-4/upscaler`; W5-4 is NOT
complete.** Slice 1 changes the macOS worker's contract conformance without
downloading, installing or running a model: it writes the
`retouchstudio.ai.provenance/1` sidecar (decision-record §3.6) beside a
published 4× artifact and returns its path, checks for cancellation at model
load and at output publication instead of only between tiles, verifies the
catalog's SHA-256 digests on the upscaler load path (`-32019`, lease released on
failure), reports the execution provider a loader actually used, and adds 12
deterministic fake-engine tests for all four (no Torch, no weights, no
inference). Nothing here is a `supported` claim: with no re-recorded 4× run and
the live store still a legacy flat install, `capability.list` reports
`upscale.4x` as `blocked` on this Mac.
**Open for W5-4:** a recorded macOS 4× run with the provenance sidecar, the
quality tolerance fixed before the run on a corpus, measured bit depth, memory
and wall time, cancel-at-load/tile/write proven through a real job
(decision-record §4.3), and the host-side consumption of the sidecar. **Windows
W5-4 remains BLOCKED** exactly as stated above: no conversion procedure,
checkpoint, opset, artifact, size, SHA-256, licence evidence or quality
validation has been submitted or approved, and the Windows worker still loads no
model weights. Slice 1 does not change any Windows capability state.

**Addendum (2026-11-18, same branch, through `0d8ee20`; W5-4 is still NOT
complete).** Slice 2 landed the host-side consumption the paragraph above
listed as open: `ExportService.upscale` now names `capabilityId: "upscale.4x"`
so the worker's verdict gates every 4× pass, and
`AIProvenance.verifiedArtifact` refuses to decode a returned artifact whose
sidecar does not verify against its own bytes. Consequence on this Mac: the
legacy flat install is reported `blocked`, so a 4× export stops with
`E_UNSUPPORTED` until the owner adopts the model — designed behaviour,
recorded in the adapters doc and decision ledger. The acceptance harness
(`worker/tools/upscale_acceptance.py`) implements the §4.3 measurements with
judgments only where the record freezes a criterion, and
`Docs/W5_UPSCALER_ACCEPTANCE.md` holds the measured readiness facts and the
runtime approval request; the run itself has NOT executed — no download,
adoption or inference happened. Two independent review rounds are recorded in
the decision ledger; the second returned ready-for-authorization. Remaining
for W5-4 exit: the recorded macOS 4× run on the approved setup, the owner's
quality corpus + tolerance decision, and the measured bit depth/memory/wall
time on real jobs. **Windows W5-4 remains BLOCKED**; the recorded finding
(same date) documents why the community ONNX conversions were not adopted.

**Addendum (2026-11-18, branch `feat/ai-refusal-routing`): the refusal stands,
the sentence changed.** Nothing here makes a 4× pass run before the owner
adopts the install — `Docs/W5_ADAPTERS.md` and the decision ledger keep that
consequence. What changed is what the owner is told and where the app takes
them next.

- `AIWorkerFailure` now keeps the `capabilityId` and `state` the worker already
  sends in the error `data` (both wire shapes carry it: `protocol.py`'s
  `to_dict` is used for the RPC error and for the stored `job["error"]`), so
  `-32020` can tell an adapter that does not offer a capability from one that
  offers it and is waiting on a tap.
- `blocked` gets its own English and Persian sentence, naming the task rather
  than the build, and the same refusal now opens the model manager the way
  `-32011` already did. The old wording told the owner of weights already on
  disk that the feature was not in their build.
- The export path asks `capability.list` before it renders a 4× pass. It has to
  ask early because `RenderError` is frozen StudioCore and
  `MacDocumentRenderer.map` collapses every AI refusal into one case, so an
  late-reported verdict arrives as "Export failed". Asking first also stops a
  doomed export before it tiles a photo the helper has already refused.
  The manager sheet is not opened from the export path: the export sheet is
  already in front of it, so the status line carries the instruction.

`Docs/AI_REFUSAL_ROUTING_PROPOSAL.md` §5's options C and D are what this
implements. That document left the wording and the sheet-opening to the owner
because they are product-visible; under the owner's 2026-11-18 autonomy mandate
they are routine engineering rather than a boundary item, so they are decided
here in the shape §5 recommends and recorded for review. Windows parity is NOT
done: `Windows/RetouchStudio.AI/WorkerClient.cs` keeps the typed-code table
only, and Windows loads no weights, so no legacy install can reach
`-32020`/`blocked` there today.

**Addendum (2026-11-18, same branch, review follow-up).** The addendum above
said both wire shapes carry `capabilityId` and `state`. That was true for
refusals the capability queue emits, and not yet for the engine-originated one
the mask path sees: `_ensure_sam` sent `capabilityId` and `package` with no
`state`, so the host had nothing to route on and printed the build sentence for
a task the adapter offers. `engine.py` now sends `state: "blocked"` and the
reason inside `data` beside `package`, so the host routes that refusal the way
it routes the queue's.

What each `-32020` carries, exactly:

- capability-queue verdict (`server.py:332-334`, a capability reported
  `blocked` or `unsupported`): `data` is `{capabilityId, state}`; the reason is
  the error `message`, which is what the host displays.
- engine mask refusal (`engine.py:872-876`, nothing can import `sam2`): `data`
  is `{capabilityId, state: "blocked", package, reason}`.
- a name that is not a capability of the submitted kind (`server.py:326-328`):
  `data` is `{capabilityId, kind}` and there is no `state`. That is a caller
  error rather than a capability verdict, so the host keeps the generic build
  sentence for it.

The host's sentences follow from those shapes:

- A missing runtime package is `blocked` and is still not the model manager's
  queue: the host gives it its own English and Persian sentence ("… cannot
  load the sam2 runtime package it needs … Downloading the model again will not
  change that"), and a refusal that names `package` opens no sheet.
  The adoption sentence stays for weights waiting for a tap, where it is true.
- `ModelManager` owns the capability report and re-reads it at the end of
  `refresh()`, so an adoption, an install, an activation or a removal updates
  the chips together with the model list instead of leaving them stale against
  the export pre-flight, which always asks fresh.
- The export pre-flight checks cancellation before and after its blocking
  `capability.list` call, so a cancel inside that window reports "Export
  cancelled" rather than the refusal it was waiting for.
- `upscale.4x` is spelled once (`AICapabilityReport.upscale4x`) for both the
  export job and the pre-flight.

Known debt left in this branch and recorded in the pull request only: the
worker's refusal `message`/`reason` text is not localized, and a latent
`.unsupported` renderer case still collapses to "Export failed".

### W5-5 — CI and acceptance

**Depends on:** W5-1..W5-4 as each lands.
**Deliverables:** contract fixtures in the existing contexts where practical —
macOS Integration, Windows App, and the platform-neutral checks that can
validate JSON; CPU-only correctness for both adapters; a separate recorded
hardware/performance section; honest NOT VERIFIED entries for DirectML, GPU,
Windows ML and quality beyond the measured corpus.
**Exit:** the five required checks are green on the milestone head; every W5
support claim cites a run; the unverified register is current.
**Does not:** add a new required CI context or gate without owner approval;
weaken a tolerance to pass; present shared-runner timings as benchmarks.

Addendum (2026-11-18, branch `w5-5/ci-gates` at `02d7acd`, stacked on PR
#70): the gate audit found four items and three are implemented —
`pull_request` now guards `develop` as well as `main` (a PR against the
integration branch previously ran no CI at all); `Windows StudioCore` tees
its log and must print its PASS verdict like every other job; the W5-4
acceptance harness is regression-tested as a subprocess against a
deterministic fake engine (`worker/tests/test_upscale_acceptance_tool.py`,
worker suite 120 → 122, pins moved). The fourth finding records the
deliberate StudioCore/conformance duplications rather than removing them.
From the PR #70 review: the Windows provider record now explains
unavailability as `reason` (was `error`), matching macOS and the shared
fixture convention, and both platforms assert the fixture provider shape.
NOT VERIFIED: the Windows-side changes compile and pass only on the GitHub
Windows runners (no local Windows); the moved 122-test pin executes on the
next macOS job; no new required check context was added, per the constraint
above.

Addendum (2026-11-18, after PR #70 merged as `480fe88`): the stack was
synchronised the ordinary way — `origin/main` merged into this branch, no
rebase, no force-push, no rewritten commit — and PR #71's base is now `main`,
so its diff carries W5-5 only. The two addenda above are historical: the
merged worker suite is 124 tests (W5-4's two submission-boundary tests plus
W5-5's two acceptance-harness tests), the pins move to `Ran 124 tests`, and
they stay unverified until a macOS job prints them. The gate audit gained a
fifth finding in `Docs/CI_GATES.md`: no required context builds or runs the
x86_64 slice, and that slice's `MODEL STORE TESTS` child-process cases already
fail identically at `40b157f`, which is a property of `main` on this machine
rather than of W5-5.

## 4. Retained follow-on milestones

These are approved scope. Ordering after W5 follows V4 with A1/A2 approved;
none may be silently dropped.

| ID | Milestone | Platforms | Depends on | Closes when |
|---|---|---|---|---|
| F1 | Face analysis model decision | macOS keeps Vision; Windows backend chosen | W3 face/mask contract | named offline backend, cleared commercial weight rights, real Windows validation, golden-face stability |
| F2 | Face parsing / mesh upgrade | both, if F1 asks for it | F1, measurement | corpus shows gain over geometric masks |
| S1 | Semantic mask classes | both | W5 contract, models | classes beyond "person" pass the mask corpus |
| S2 | Click-to-mask and fine matte | both | W5 model manager | point prompts and a licensed matte model, or documented refusal |
| E1 | Enhancement, restoration and AI Enhancer | both | W5-2/W5-3; its own corpus | same-size contracts with a quality corpus; never labelled upscale |
| H1 | Healing and object-removal tiers | both | W5 model manager | per-scale corpus; 512 px refusal/escalation |
| B1 | Background matte and composite | both | S2, G1 for generated backgrounds | hair/clothing edge corpus |
| G1 | Generative edit and outpainting | macOS; Windows only if measured | memory and licence gates | 16 GB envelope; outpainting only with a licensed engine |
| P1 | AI portrait augmentation | both | F2, measurement | A/B texture and identity corpus; classical stays default |
| U1 | 2× output and upscale polish | both | W5-4 | 2× corpus; face-aware only if measured |
| R3 | Benchmark harness | macOS hardware; Windows CPU observation | W5-4 | repeatable table with thermal notes |
| R4 / M9 | Accelerator and optimization gate | per component | measurements | per-component decision, no migration without a gate |
| N1 | Windows AI breadth | Windows | W5-3, F1, masks | real Windows runs per capability, no CI-only estimation |

W3 in Master V4 owns Windows face analysis and masks; F1/S1/S2 are its
work packages. W5 does not absorb them.

## 5. Testing and acceptance

1. **Contract fixtures.** One request/result/error set per job kind, parsed by
   both hosts with test doubles; schema drift fails both.
2. **Golden corpus.** Existing exports keep their hashes; a new AI corpus is
   additive and versioned; a baseline is never rewritten to pass.
3. **Outside-the-box rule.** For patch capabilities, pixels outside the
   authorized rectangle are identical; testable without a quality judgement.
   Upscale is exempt by definition and says so.
4. **Cancellation and crash.** Cancel at queued/loading/running/writing, worker
   crash, and host crash leave no half-edit and no working copy.
5. **Leases and deletion races.** The decision-record §3.9 suite runs on both
   platforms.
6. **Memory and performance.** Peak memory per adopted model; a refusal before
   load beats a crash; Windows numbers are observations on a shared runner.
7. **Bit depth and colour.** Measured per job; 8-bit is never reported as
   16-bit; sRGB output policy is unchanged.
8. **Privacy.** Zero endpoints during a job; re-audit per adapter/model.
9. **Licence.** No model ships without a written commercial grant for its
   weights, whatever its code licence says.

Native hardware validation stays separate from CPU-only CI correctness: CI can
prove the artifact and the contract, never GPU speed or thermal behavior.

## 6. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Approved A1/A2 not reflected in V4's text | A reader of V4 alone sees the old stage-4 bullet | Addendum §4 records the approval and exact consequences; V4 is edited only by a separate owner authorization |
| ORT binding or native payload pin slips | W5-1 Windows delay; MSI growth | Pin and record version, size and hash in W5-1; DirectML stays optional |
| Swin2SR ONNX evidence unapproved | Windows W5-4 BLOCKED | Submit conversion procedure, checkpoint, opset, artifact, size, SHA-256, licence and quality evidence; W5-1–W5-3 continue |
| Worker-source import incomplete or licence gap | W5-1 macOS BLOCKED | Import the complete source with notices and pinned hashes before claiming reproducibility |
| Quality parity assumption | Overclaiming | Tolerance fixed before the run; no parity claim without measurement |
| Bit-depth assumption | False 16-bit claim | Measure the round trip; advertise what survives |
| Shared-runner timings | Misread as performance | Label observations; hardware runs separate |
| Contract drift between hosts | Silent divergence | Shared fixtures in both CI contexts |

## 7. Definition of done for W5

W5 is done when both platforms start a reproducible worker, manage models with
consent, integrity, leases and safe deletion, report capabilities truthfully,
and run `upscale.4x` end to end with acceptance evidence where the artifact is
approved — and when every unverified behavior (GPU, DirectML, Windows ML,
16-bit, unmeasured performance) is stated as unverified. If the Windows
Swin2SR artifact is not approved, Windows W5-4 remains BLOCKED and reported
as such while W5-1–W5-3 may still close. W5 is not done because a capability
list exists, a model downloaded, or a job returned without an artifact.

W5 does not claim feature parity, does not claim Windows face/mask support and
does not remove any follow-on milestone in §4.
