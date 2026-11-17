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
44095581869 is green on head `cd872e0` (macOS Integration, Windows App,
Windows StudioCore, StudioCore Boundary, Platform-neutral Conformance;
`Ran 88 tests`, `AI RUNTIME TESTS: PASS`, `WINDOWS APP BUILD: PASS`). Only
`upscale.4x` on macOS is `supported`, from the recorded 4× run; every other
capability carries an explicit state and reason. The macOS job path still
submits by kind, so capability refusal applies to callers that name a
`capabilityId`. Windows W5-4 stays blocked; the live capability panel has not
been exercised in a UI session.

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
