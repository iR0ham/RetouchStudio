# AI-01 — Multi-Platform Addendum (2026-11-16)

**Status:** Proposed review record of an owner-approved direction. It changes
no application code, project schema, catalog, runtime package or release
artifact, and it authorizes no download. Its resolutions and the proposed V4
amendment await owner review. It does not modify the Master Execution Plan V4;
where V4 sequencing must change, §4 states the exact conflict and a proposed
amendment that waits for product-owner approval.
**Milestone:** AI-01 / W5-0 under the RetouchStudio Master Execution Plan V4.
**Base:** `main` at `8000c9d` (PR #65 merge, 2026-11-16), which contains the
AI-01 research package
([AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md),
[AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md) and
[AI_11_ROADMAP.md](AI_11_ROADMAP.md)). Line references in this addendum are
to that commit; the dated pointers added to those files move their current
line numbers.
**Owner direction:** the W5 multi-platform approval brief of 2026-11-16
(recorded here in §1; no external document is cited because none was supplied).
**Companions:**
[W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md),
[W5_ROADMAP.md](W5_ROADMAP.md),
[ORIGINAL_MASTER_PLAN.md](ORIGINAL_MASTER_PLAN.md).

## 1. The decision being recorded

The product owner decided on 2026-11-16 that RetouchStudio AI is a genuinely
multi-platform product:

- macOS and Windows are first-class AI platforms from the beginning of W5.
- Full feature parity is not required in one milestone, but every approved AI
  capability must have a concrete cross-platform implementation path.
- No approved AI capability may be silently removed from product scope.
- Windows is not a macOS-first platform whose AI support is postponed
  indefinitely.

The same direction fixes the Windows shape: a C# host with an independently
managed worker, ONNX Runtime CPU as the initial inference baseline, DirectML
only as an optional backend, GPU acceleration never mandatory, and native
Windows model storage and lifecycle management. A Python sidecar on Windows is
not the preferred architecture; changing that requires concrete evidence and
alternatives, neither of which exists in the repository today.

This addendum exists because three statements in the AI-01 package were written
under the earlier assumption and now conflict with the owner's direction. Each
is resolved below with an explicit dated marker rather than a silent rewrite.
The AI-01 documents remain in the repository as the research record of
2026-11-16; this branch adds dated pointers to them and does not rewrite their
findings.

## 2. Supersession 1 — "Windows AI is last on purpose"

**Where it appears.**
[AI_11_ROADMAP.md](AI_11_ROADMAP.md) §1, consequence 2 (lines 36–38):
"**Windows AI is last on purpose.** The Windows host has no inference runtime,
no landmarks and no mask rendering; a Windows AI claim before those exist would
be unsupported by the platform."

**What it asserted.** A sequencing principle: Windows AI follows macOS AI,
after Windows landmarks and masks exist; N1 (the Windows adapter) depends on
R1, F1 and Windows masks ([AI_11_ROADMAP.md](AI_11_ROADMAP.md) §4, lines
262–271).

**Resolution (2026-11-16).** The *sequencing principle* is superseded. Windows
AI is scheduled inside W5 itself: the runtime (W5-1), model manager (W5-2),
adapter (W5-3), the first cross-platform capability (W5-4) and its acceptance
gates (W5-5) all include Windows. Windows AI is not "last"; it is a W5
deliverable, and the follow-on capabilities are retained for both platforms
([W5_ROADMAP.md](W5_ROADMAP.md) §4).

**What remains true.** The *evidence* behind the old sentence was correct and
becomes the gate instead of the delay:

- The Windows host still has no inference runtime, landmarks or mask
  rendering today; PR #65's own tables record that
  ([AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §2.2, lines 72–73;
  [AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md) §13).
- No Windows AI capability may be reported as supported before a real Windows
  run produces an artifact ([W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md) §3.4).
- CPU-only CI can prove correctness, never GPU speed or quality.
- Face analysis, landmarks and masks on Windows keep their own dependency on
  the F1 landmark-model decision (V4 stage 5 / W3); moving Windows AI into W5
  does not make `Windows.Media.FaceAnalysis` produce landmarks it does not
  have.

**Scope preserved.** F1/F2 (face analysis and landmarks), S1/S2 (masking and
segmentation), E1 (Enhancer, enhancement and restoration), H1 (healing and
object removal), B1 (background), G1 (generative and outpainting) and P1
(portrait augmentation) remain approved follow-on milestones in
[W5_ROADMAP.md](W5_ROADMAP.md) §4. None is removed, renamed or downgraded.

## 3. Supersession 2 — "AI remains Apple-silicon-only for now"

**Where it appears.**
[AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §13, risks table (line 445):
"AI remains Apple-silicon-only for now; other platforms are gated by
measurement." The same document leaves the Windows runtime open in §7.3
(lines 286–295): "Whether Windows ships a Python sidecar, an ONNX adapter or
both remains an owner decision in W5."

**Resolution (2026-11-16).** Two different claims were bundled in one sentence,
and only one changes:

| Claim | Status |
|---|---|
| The shipped AI helper is arm64-only, and Intel Macs have no AI today | **Retained.** This is a fact about the current build, not a product decision ([AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §12; [AI_RUNTIME.md](AI_RUNTIME.md)). |
| The *target architecture* is Apple-silicon-only | **Superseded.** Windows is a first-class AI target from W5, with an ONNX Runtime CPU baseline and native model management. |
| The Windows adapter shape (Python sidecar vs ONNX adapter) is an open owner decision | **Resolved by the owner.** ONNX Runtime on Windows, not a Python sidecar; DirectML optional. |

The sentence in AI_11_ARCHITECTURE.md is therefore read as a current-state
statement about the 1.0/1.1 artifacts. It is no longer read as the product's
AI scope. Feature availability is now declared per capability and per
platform, never as one global "AI" flag.

## 4. Supersession 3 — the V4 / W3 / W5 dependency conflict

**Where it appears.** [ORIGINAL_MASTER_PLAN.md](ORIGINAL_MASTER_PLAN.md) §2
(lines 95–99) orders the work as:

1. W4 image engine and Windows metadata,
2. Windows feature parity, including face analysis, masks, processing and
   batch export,
3. W3 face analysis and masking on both platforms,
4. W5 AI runtime and inference.

§6 (line 253) lists "AI edits when runtime is available" as part of the
Windows parity work, and §5 (lines 220–240) requires real Windows face
analysis and landmarks for W3. AI-01 then says N1 depends on R1, F1 and
Windows masks ([AI_11_ROADMAP.md](AI_11_ROADMAP.md) §4, lines 262–271).

**The exact conflict.**

- **Circular dependency.** V4 stage 4 requires Windows "AI edits when runtime
  is available", but the runtime is the subject of stage 6. Stage 4 cannot be
  completed under its own definition before stage 6 exists, and stage 6
  cannot be started under §2's ordering until stage 5 (W3 on both platforms)
  is complete.
- **Mis-ordered dependency.** W5's first cross-platform capability is
  Upscaler 4x ([W5_ROADMAP.md](W5_ROADMAP.md) §3, W5-4). It needs the
  contract, runtime and model manager — not face landmarks, masks or Windows
  face analysis. V4 §2 opens with "Proceed continuously; parallelize
  independent work", so limited overlap is arguably permitted, but the
  numbered order is the stated delivery order and AI-01 reads it as one
  ([AI_11_ROADMAP.md](AI_11_ROADMAP.md) §1). As written, the first W5
  capability is placed behind unrelated W3 work.
- **Contract direction.** W3-2 (portable face/mask contract) and W3-5
  (orientation canonicalization) are inputs to the W5 contract freeze, not
  outputs of it ([MASTER_PLAN_REMAINING_WORK.md](MASTER_PLAN_REMAINING_WORK.md)
  WS-2). Running W3 entirely after W5 would either duplicate the contract or
  force W5 to freeze it without W3's input.
- **Scope wording.** "Windows feature parity" in stage 4 can no longer mean
  "Windows AI parity", because Windows AI is now W5 work. Leaving the phrase
  undefined is exactly how an approved capability gets silently dropped.

**Proposed amendment (requires owner approval; not applied).** A minimal,
additive proposal for V4 §2 and §6; A3 is a reading, not a change:

- **A1 — Move one bullet.** In V4 §2 item 4 and §6 (line 253), Windows "AI
  edits when runtime is available" stops being a stage-4 completion criterion.
  It becomes a W5 completion criterion, satisfied for the W5-adopted capability
  set — initially `upscale.4x` — with the remaining edits still preserved,
  named and refused as today. The capability is moved, not removed.
- **A2 — Make the interleaving explicit.** V4 §2 items 5 and 6 may run
  concurrently after stage 3: W5-0/1/2/3 may start once W4 is complete, and W3
  may consume the frozen face/mask contract. W3 still precedes any Windows
  face, landmark or mask capability claim, and F1 remains an owner decision.
  Every other V4 stage and ordering constraint is unchanged.
- **A3 — Define "feasible".** No wording change; W5 defines feasibility
  through its exit gates ([W5_ROADMAP.md](W5_ROADMAP.md) §3) so "feasible W5"
  in V4 §2 item 6 cannot be read as "whatever happens to work".

If the owner declines A1/A2, the documentation still stands, but the W5
contract sequence stays behind W3 completion and stage 4 keeps a completion
criterion that only stage 6 can satisfy. That consequence is recorded here
rather than hidden.

The V4 file itself is not edited by this addendum. The amendment is a proposal
in the review package; applying it is a separate, owner-authorized change.

## 5. What does not change

- Master Execution Plan V4 remains authoritative; this addendum requests an
  amendment instead of redefining it.
- Schema v5 is unchanged; AI provenance remains beside artifacts, never as new
  project keys ([AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) ADR-5).
- The AI contract never enters `StudioCore` or the C ABI; the 13 JSON-only C
  ABI exports are untouched.
- No cloud inference, no silent download, no background catalog fetch, no
  weights redistributed in the app.
- The shipped macOS runtime stays as it is; W5-1 makes its source
  reproducible; it is not rewritten in this milestone.
- Intel Macs keep no AI; Windows ARM64 remains out of scope for the Windows AI
  baseline.
- No feature is supported because an interface exists. Evidence gates are in
  [W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
  §3.4 and [W5_ROADMAP.md](W5_ROADMAP.md) §3.

## 6. Approved capability scope retained

All capabilities from AI-01 §3 remain in scope. The full mapping, platform
path and retained milestone are in [W5_ROADMAP.md](W5_ROADMAP.md) §4. In
summary:

| Capability | macOS path | Windows path | Retained milestone |
|---|---|---|---|
| Face analysis and landmarks | Vision (shipped) | F1 landmark-model decision, then W3 | W3 / F1, F2 |
| Smart masking and segmentation | SAM 2.1 box prompts, geometric masks (shipped) | W3 adapter, then model manager enables SAM/ONNX models | S1, S2 |
| Portrait AI augmentation | classical engine stays default | P1 gate; classical stays default | P1 |
| Healing and object removal | MI-GAN + FLUX.2 klein (shipped) | H1 after W5-2; ONNX port to be verified | H1 |
| Background editing | Vision person matte + composite (shipped) | B1 after masking exists | B1 |
| Generative editing and outpainting | FLUX.2 klein patch (shipped); outpainting refused | G1 with a CPU-viable or optional-GPU licensed engine; outpainting refused until licensed | G1 |
| Upscaling | Swin2SR 4x, export-time (shipped) | **W5-4**, ONNX Runtime CPU | U1 / W5-4 |
| Enhancement, restoration and AI Enhancer | classical same-size tools only | E1 with its own corpus and same-size contract | E1 |

A follow-on milestone is a concrete path with named gates; it is not a claim
that the capability works on Windows today.

`enhance.photo` (the AI Enhancer surface) is a same-size operation and is never
implemented as, or labelled, Upscaler. `upscale.*` changes dimensions;
`enhance.photo` and `restore.photo` do not.

## 7. Remaining owner decisions

The complete list, with options, impact and blocking milestones, is
[W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
§7. The decisions that block W5-0 from closing are:

1. **V4 amendment A1/A2** (§4 above) — approve, modify or decline.
2. **Windows ML dependency policy** — the WPF host currently has no package
   dependency by design; adding an ONNX Runtime / Windows ML package and its
   native payload to the MSI needs approval.
3. **Worker source publication** — move the external Python worker into the
   repository or pin a fetchable, hash-verified dependency.
4. **Runtime package distribution** — approve the macOS runtime package
   metadata (URL, size, SHA-256) or accept that W5-1 ships a source-built
   runtime only.
5. **Windows landmark backend (F1)** — needed before Windows face/landmark or
   mask capabilities, not before W5-4.

Decisions that can follow a measurement or a licence step: bit-depth
advertising for upscaling (16-bit only if measured), whether any GPU
(DirectML) claim is needed at all, fine-matte and LaMa weight grants, the
outpainting engine, and the AI Enhancer's preset corpus. Model hosting needs a
decision only if official sources prove insufficient; official sources are
the default for W5.

## 8. Consistency review of the resulting documents

Reviewed against `main` at `8000c9d` on 2026-11-16.

| Document | Verdict | Note |
|---|---|---|
| `ORIGINAL_MASTER_PLAN.md` (V4) | **Conflict recorded; amendment proposed** | §2 order, §5 W3 Windows requirements and §6 line 253 circular bullet; A1/A2 wait for owner approval. V4 unmodified. |
| `AI_11_ARCHITECTURE.md` | **Consistent after supersession** | §13 "Apple-silicon-only" and §7.3 adapter choice resolved by §3 above; §2.2 current-state rows and ADR-4/ADR-5 retained. |
| `AI_11_ROADMAP.md` | **Consistent after supersession** | §1 consequence 2 and §4 N1 re-baselined by §2; R0–R4, F1/F2, S1/S2, U1, E1, H1, B1, P1, G1 kept. |
| `AI_11_MODEL_EVALUATION.md` | **Consistent; current-state only** | §9 upscale facts, §12/§13 Windows "no path" rows and §15 NOT VERIFIED register remain accurate today; §13's "before a landmark decision" is now scoped to face/mask capabilities. |
| `MASTER_PLAN_REMAINING_WORK.md` | **Consistent; queue re-pointed** | WS-4 rows stay the current-state record; the 2026-11-16 note points at the new W5 documents. WP-6 ("AI edits on Windows") is still "not applicable until a runtime exists". |
| `MASTER_PRODUCT_COMPLETION_STATUS.md` | **Consistent** | §4 Windows face/mask BLOCKED and the W5 runtime BLOCKED row remain true; this package changes plans, not states. |
| `PRODUCT_ACCEPTANCE_MATRIX.md` | **Consistent** | AI runtime row stays BLOCKED/ABSENT; no acceptance claim is upgraded. |
| `PROJECT_SCHEMA_V5.md` | **Consistent** | No schema change; provenance stays beside artifacts. |
| `AI_RUNTIME.md` | **Consistent** | Describes the current macOS runtime; W5-1's reproducibility work is additive. |
| `WINDOWS_IMPLEMENTATION_PATH.md` | **Consistent with a naming hazard noted** | Its local step numbers `W0–W6` are not Master V4's `W1–W5` (its "W5" is packaging). The risk statement that Windows AI is NOT VERIFIED still holds; the planned path now exists. |
| `WORKFLOW.md` | **Consistent with an explicit owner exception** | It deprecates documentation-only PRs; the owner instructed one coherent W5-0 documentation PR. Recorded in the decision record §1. |

## 9. Definition of done for this addendum

It resolves the three named conflicts with dated markers, keeps the full AI
scope, leaves V4 and the schema untouched, states the exact V4 amendment for
approval, and lists the owner decisions W5-0 still needs. It claims no
implementation, no download and no support on either platform.
