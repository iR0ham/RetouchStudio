# AI-01 — Multi-Platform Addendum (2026-11-16)

**Status:** Review record of an owner-approved direction, revised after the
owner review of 2026-11-16. A1/A2 are approved and the decisions in §7 are
answered; the exact consequences are recorded here because Master Plan V4's
text stays unedited by owner instruction. It changes no application code,
project schema, catalog, runtime package or release artifact, and it
authorizes no download. This revision no longer asks the owner to decide the
W5-0 questions; it records the answers.
**Milestone:** AI-01 / W5-0 under the RetouchStudio Master Execution Plan V4.
**Base:** `main` at `8000c9d` (PR #65 merge, 2026-11-16), which contains the
AI-01 research package
([AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md),
[AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md) and
[AI_11_ROADMAP.md](AI_11_ROADMAP.md)). Line references in this addendum are
to that commit; the dated pointers added to those files move their current
line numbers.
**Owner direction:** the W5 multi-platform approval brief of 2026-11-16
(recorded here in §1; no external document is cited because none was supplied)
and the W5-0 owner review of the same date (recorded in §4 and §7).
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

The W5-0 owner review of 2026-11-16 approved the V4 amendments A1/A2 (§4),
the ONNX Runtime CPU dependency, bringing the macOS worker source into this
repository, a source-built self-contained macOS runtime for W5-1, keeping
Windows face analysis, landmarks and masks as mandatory but gated by F1 and
real Windows validation, and blocking Windows W5-4 until the Swin2SR x4 ONNX
artifact's evidence is reviewed and approved. §7 records each outcome.

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

**Approved amendment (2026-11-16; V4 text unchanged).** The owner approved A1
and A2. By explicit owner instruction the Master Plan V4 file is not edited;
this section is the record of the approved sequencing and its exact
consequences. A reader of V4 alone still sees the old stage-4 bullet; this
addendum is the approved operative exception.

- **A1 — approved: move one bullet.** In V4 §2 item 4 and §6 (line 253),
  Windows "AI edits when runtime is available" stops being a stage-4
  completion criterion. It becomes a W5 completion criterion, satisfied for
  the W5-adopted capability set — initially `upscale.4x` — with the remaining
  edits still preserved, named and refused as today. The capability is moved,
  not removed.
- **A2 — approved: make the interleaving explicit.** After W4 completes,
  W5-0, W5-1, W5-2 and W5-3 may proceed while W3 proceeds independently. W3
  still precedes any Windows face, landmark or mask support claim; the exact
  Windows landmark model remains an F1 decision. Every other V4 stage and
  ordering constraint is unchanged.
- **A3 — reading, not a change.** "Feasible W5" is defined by the W5 exit
  gates ([W5_ROADMAP.md](W5_ROADMAP.md) §3), not by "whatever happens to
  work".

The approval does not edit Master V4, does not add Windows face/mask
capabilities to W5, does not make GPU acceleration mandatory and does not
permit a support claim without a recorded run. If V4 is edited later, that is
a separate authorized change and must reproduce these consequences exactly.

The V4 file itself is not edited by this addendum. The approval is recorded
here as the operative sequencing; the amendment changes no code.

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
| Upscaling | Swin2SR 4x, export-time (shipped) | **W5-4**, ONNX Runtime CPU; BLOCKED pending approved artifact evidence | U1 / W5-4 |
| Enhancement, restoration and AI Enhancer | classical same-size tools only | E1 with its own corpus and same-size contract | E1 |

A follow-on milestone is a concrete path with named gates; it is not a claim
that the capability works on Windows today.

`enhance.photo` (the AI Enhancer surface) is a same-size operation and is never
implemented as, or labelled, Upscaler. `upscale.*` changes dimensions;
`enhance.photo` and `restore.photo` do not.

## 7. Owner decisions (answered 2026-11-16)

The complete record, with each outcome and its effect, is
[W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
§7. In summary, the owner:

1. **Approved V4 A1/A2** (§4 above); V4's text is unchanged and the approval
   is recorded here.
2. **Approved ONNX Runtime CPU** and its required native payload as a Windows
   application dependency; DirectML stays optional and no GPU performance
   claim is made without native hardware validation.
3. **Decided to bring the complete macOS worker source into this repository**
   (the owner's preferred option), preserving its licence and dependency
   notices and pinning every dependency by version and hash; no mutable
   branch or unverified download.
4. **Chose a source-built, self-contained macOS runtime for W5-1**; end users
   never install Python manually. No package URL, size or hash was invented;
   packaging and signing follow verified build artifacts. `AIRuntime.package`
   stays nil in W5-1.
5. **Kept Windows face analysis, landmarks and masks mandatory**, with the
   exact landmark model deferred to F1; offline inference and cleared
   commercial weight rights are required, and no support is claimed before
   real Windows validation. This does not block W5 infrastructure or Upscaler.
6. **Did not approve any unverified community Swin2SR x4 ONNX conversion.**
   Windows W5-4 stays BLOCKED until a reproducible conversion, source
   checkpoint, opset, artifact, size, SHA-256, licence evidence and quality
   validation are reviewed and approved. W5-1–W5-3 continue independently.

The remaining decisions are recorded as fixed policy or deferred, not open:
official model sources only for W5; bit depth measured before advertising;
DirectML opportunistic; AI Enhancer keeps E1 and its own quality corpus;
fine-matte, LaMa and outpainting licence grants stay in their follow-on
milestones. No capability is removed.

**Remaining evidence-bound blockers (not owner decisions):** the Swin2SR x4
Windows artifact (blocks W5-4 Windows only), the F1 landmark model (blocks
Windows face/mask claims only), the ORT binding pin (W5-1 engineering) and
packaged-runtime metadata (a later distribution step).

## 8. Consistency review of the resulting documents

Reviewed against `main` at `8000c9d` on 2026-11-16.

| Document | Verdict | Note |
|---|---|---|
| `ORIGINAL_MASTER_PLAN.md` (V4) | **Conflict recorded; A1/A2 approved; file unmodified** | §2 order, §5 W3 Windows requirements and §6 line 253 circular bullet. A1/A2 were approved on 2026-11-16; their exact consequences are §4 above. By owner instruction the V4 file itself is not edited. |
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

It resolves the three named conflicts with dated markers, records A1/A2 as
approved and their exact consequences, keeps the full AI scope, leaves V4 and
the schema untouched, states the owner decisions with their outcomes and
names the remaining evidence-bound blockers. It claims no implementation, no
download and no support on either platform.
