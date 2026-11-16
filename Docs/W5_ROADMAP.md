# W5 Roadmap — Multi-Platform AI Runtime and First Capability

**Status:** Proposed execution roadmap for the W5-0 review package. It
schedules no implementation before the decision record is approved and
changes no code, catalog, schema or release artifact.
**Date:** 2026-11-16.
**Base:** `main` at `8000c9d` (PR #65 merge, 2026-11-16).
**Authority:** product-owner direction of 2026-11-16
([AI_11_MULTI_PLATFORM_ADDENDUM.md](AI_11_MULTI_PLATFORM_ADDENDUM.md) §1),
under Master Execution Plan V4, whose proposed amendment A1/A2 is still open.
**Companions:**
[W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md),
[AI_11_ROADMAP.md](AI_11_ROADMAP.md),
[AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md),
[MASTER_PLAN_REMAINING_WORK.md](MASTER_PLAN_REMAINING_WORK.md).

## 1. How this roadmap relates to V4 and AI-01

Master V4 §2 remains the delivery authority. This roadmap is the W5 execution
view: it does not reorder V4 by itself. It assumes the proposed amendment in
[AI_11_MULTI_PLATFORM_ADDENDUM.md](AI_11_MULTI_PLATFORM_ADDENDUM.md) §4 (move
the Windows "AI edits" bullet from stage 4 to W5, and allow W3/W5 to
interleave after W4). If the owner declines that amendment, W5 waits for W3
completion and this roadmap's W5-1..W5-3 start moves accordingly; the content
does not change.

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
owner decisions in decision-record §7.
**Exit:** decision-record §5 is complete; the V4 amendment has an answer; the
Swin2SR x4 Windows artifact source is approved or W5-4 is marked BLOCKED.
**Does not:** implement, download or change a UI.

### W5-1 — Reproducible runtime, both platforms

**Depends on:** W5-0; worker-source and dependency decisions.
**Deliverables (macOS):** worker source in the repository or a pinned,
hash-verified dependency; lockfile; licence inventory; the 60 regression tests
run from a fresh checkout; a real helper process started from that tree that
answers protocol 2 (`HelperRegistry.protocolVersion`, handshake check in
`WorkerClient`) and reports readiness, health and shutdown.
**Deliverables (Windows):** a C# worker executable built from this repository,
contained by a job object, with the same JSON frames over its transport;
ONNX Runtime CPU EP initialises and reports its provider without a model; no
Python and no GPU requirement.
**Exit:** on both platforms, a fresh checkout starts a real worker process and
completes the protocol handshake, with the run recorded. Starting a stub or a
mock is not this exit.
**Does not:** adopt a model, change the macOS inference stack, enable
`AIRuntime.package`, or add a Windows MSI dependency before the policy
decision.

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

### W5-4 — First cross-platform capability: Upscaler 4x

**Depends on:** W5-3; owner-approved Swin2SR x4 ONNX source, size, SHA-256
and licence for Windows.
**Deliverables:** `upscale.4x` on macOS (existing behavior, contract
conformance) and on Windows (ORT CPU); provenance sidecar; quality comparison
on a fixed corpus with a tolerance fixed before the run; measured bit depth,
memory and CPU wall time; cancellation at load, tile and write.
**Exit:** the eight acceptance gates in decision-record §4.3 pass on both
platforms, with the Windows artifact produced on `windows-2025`. A successful
job alone is not the exit.
**Does not:** claim macOS/Windows performance parity, claim 16-bit unless
measured, or turn upscaling into a canvas mutation (AI-01 ADR-3).

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

These are approved scope. Ordering after W5 follows V4 (with A1/A2 if
approved); none may be silently dropped.

| ID | Milestone | Platforms | Depends on | Closes when |
|---|---|---|---|---|
| F1 | Face analysis model decision | macOS keeps Vision; Windows backend chosen | owner decision | named backend, cleared weights licence, golden-face stability |
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
| V4 amendment declined | W5 waits for W3; stage 4 stays circular | Owner decision in the W5-0 package |
| Windows ORT/MSI dependency not approved | No Windows inference baseline | Decision before W5-1; the host stays AI-free if declined |
| Swin2SR ONNX source unapproved | W5-4 Windows BLOCKED | Approve a recorded conversion with hashes, or defer Windows upscale |
| Worker source unavailable for publication | W5-1 macOS BLOCKED | Vendor with licence inventory or pin a fetchable dependency |
| Quality parity assumption | Overclaiming | Tolerance fixed before the run; no parity claim without measurement |
| Bit-depth assumption | False 16-bit claim | Measure the round trip; advertise what survives |
| Shared-runner timings | Misread as performance | Label observations; hardware runs separate |
| Contract drift between hosts | Silent divergence | Shared fixtures in both CI contexts |

## 7. Definition of done for W5

W5 is done when both platforms start a reproducible worker, manage models with
consent, integrity, leases and safe deletion, report capabilities truthfully,
and run `upscale.4x` end to end with acceptance evidence — and when every
unverified behavior (GPU, DirectML, Windows ML, 16-bit, unmeasured performance)
is stated as unverified. It is not done because a capability list exists, a
model downloaded, or a job returned without an artifact.

W5 does not claim feature parity, does not claim Windows face/mask support and
does not remove any follow-on milestone in §4.
