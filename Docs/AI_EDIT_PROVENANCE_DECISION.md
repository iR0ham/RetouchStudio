# Provenance for adopted AI edits — a proposal, not a decision

**Status:** OPEN. This document changes nothing. It exists so one owner decision
can be made with the consequences written down, because closing the §3.6 edit
gap requires either naming a capability the code cannot derive or accepting a
refusal the product does not currently give.
**Written:** 2026-11-18, during the W5 completion sprint, on `36dd06d`.
**Owner of the decision:** the product owner. Nothing here is implemented.

## 1. What the contract asks for

`Docs/W5_IMPLEMENTATION_DECISION_RECORD.md` §3.6 states two things that have not
been reconciled with the shipped edit path:

> Artifacts stay beside the edit id in the existing edit store; the project body
> gains no keys (AI-01 ADR-2/ADR-5).
> Each adopted artifact has a sidecar `*.provenance.json` with `schema:
> "retouchstudio.ai.provenance/1"`, `contractVersion`, `capabilityId`, `jobId`,
> `createdAt`, model `{id, version, format, provider, files[].sha256}`, adapter
> `{platform, version}`, parameters, seed, input/output SHA-256 and dimensions
> and bit depth, the authorized rectangle, `outsidePixelsIdentical`, elapsed time
> and result state.

Slice 2 recorded the gap itself rather than papering over it (same file, the
"Not decided here" paragraph): *"Keeping provenance with an adopted artifact past
the job workdir — copied beside the edit id, or written into the exported photo
as metadata — is a product decision with a privacy side, and neither slice
implements §3.6's 'beside the edit id' wording."* The roadmap does not track the edit-store half as a
check to pass: §7's numbered acceptance item is the *cleanup* gap, and the only
provenance line in it is R1's scope, "provenance beside artifacts"
(`Docs/AI_11_ROADMAP.md:110`). So §3.6 and Slice 2 are where this item lives.

## 2. What the code does today, per path

| Path | Publication | Host adoption | Honest? |
| --- | --- | --- | --- |
| 4× upscale (export-time) | `provenance.publish` writes sidecar → artifact rename → re-verify (`worker/retouch_ai_worker/provenance.py`) | `AIProvenance.verifiedArtifact` refuses to decode a pair it cannot account for (`Sources/RetouchStudio/Models/AICapability.swift:113-136`, called from `ExportService.swift:204-260`) | yes |
| `mask` (subject/click) | writes `mask.png` only (`engine.py:277-317`) | decoded into a selection, never adopted as an artifact | n/a |
| `patch_edit` (heal, object removal, reimagine) | writes `result.png`/`patch.png`/`alpha.png` with no sidecar (`engine.py:320-415`) | `AIEditStore.adopt(id:patch:alpha:)` copies both files into `…/RetouchStudio/AI/edits/<edit-id>/` (`Sources/RetouchStudio/Models/AIEdit.swift:63-75`) | **no** |

So the shipped AI edits are the case §3.6 describes and the shipped upscale is
the case it was written for. What an edit record carries today is
`preset, prompt, seed, patchFile, alphaFile, box, imagePixels, patchOrientation,
createdAt, seconds, outsidePixelsIdentical`
(`Sources/StudioCore/DocumentValue.swift:284-306`): enough to re-draw and to say
"the pixels outside are yours", **not enough to name the model that produced the
bytes or to prove the file is those bytes**. Availability is a
`fileExists` check (`AIEdit.isAvailable`), so an overwritten or truncated
`patch.png` reads as a healthy edit.

## 3. Two things block "just implement §3.6", and neither is code

**(a) `capabilityId` cannot be derived by the worker.** A sidecar must name a
capability. Four frozen vocabulary entries share the one job kind
(`worker/retouch_ai_worker/capabilities.py:57-60`), and the lookup the worker
has returns all four: `job_capability(kind)` is a filter, not a choice
(`capabilities.py:214-215`). Only the host knows which tool ran. It knows more
than that already: `preset.engine` is `"inpaint"` for `.healArea` and `"patch"`
otherwise (`Sources/RetouchStudio/Models/QuickEdit.swift:34-39`), the engine
picks the model (`:137` — flux for `patch`, migan otherwise), and `fullFrame`
separates a re-imagined whole frame from a masked edit (`:118-122`). That yields
a defensible mapping for two of three tools:

- `.reimagine` (full frame, flux) → `generative.reimagine`
- `.removeObject` (masked, flux) → `generative.edit` **or** `inpaint.object`
- `.healArea` (masked/point, migan) → `inpaint.spot`

`.removeObject` is the genuine ambiguity: it is a semantic removal
(`inpaint.object`) that is *executed* as a generative edit
(`generative.edit`), and both readings are true in different sentences. Picking
one is naming a product capability, which is not an engineering choice, and
guessing would write metadata that only looks accounted for.

**(b) Naming the capability on the *submit* path changes what users can do.**
The protocol deliberately has a kind-only submission path that does not apply the
worker's verdict (`Docs/AI_PROTOCOL_V2.md:107, 116-123`). If the host starts
naming capabilities for edits, DR-4 applies: `supported` requires a recorded run
binding platform+provider+model+version, and
`worker/retouch_ai_worker/capability-evidence.json` contains exactly **one**
entry — `upscale.4x`. Every AI edit on every machine would then be refused as
unsupported until someone records a run for migan and flux. That is a bigger
behavior change than the provenance question it was meant to answer.

## 4. Options

**A1 — sidecars for edits, host-asserted capability, no gating.** The worker
publishes `patch.png`/`alpha.png` through the existing `provenance.publish`
(order and withdraw-on-mismatch already implemented and tested), the host passes
the capability name it can derive and marks the record as host-asserted, and
`AIEditStore.adopt` moves the pair and verifies the digest before the document
learns about the edit. Submissions stay on the kind path, so no new refusals.
*Cost:* the `.removeObject` name must be decided (3); the id in the record is
the host's word, not the worker's verdict — which §3.6 permits but DR-5 asks us
to label. *Closes:* §3.6 for the edit path, and makes the "an edit is never
blank or stale" promise provable instead of assumed.

**A2 — A1 plus named submission.** Adds the worker's own verdict before weights
load, which is the strict reading of §3.6 and matches upscale. *Cost:* every
edit needs an evidence entry first (3b), so it either refuses shipped features
or requires recording runs — and recording a run is real inference on a real
model, which needs owner approval and a measured artifact.

**B — portable identity in the project.** Add model id/version/digests to
`AIEdit` so accountability travels with the `.retouch` file. *Blocked by the
contract itself:* §3.6 says the project body gains no keys (AI-11 ADR-2/ADR-5),
so this is a schema and C ABI change and a separate, larger approval.

**C — an explicit carve-out.** Decide that §3.6 sidecars bind export-time
artifacts, record the decision in the ledger, and leave edits with what they
have. *Cost:* §3.6 stays unimplemented for adopted edits, and a stale or
swapped `patch.png` still reads as a healthy edit.

**D — status quo.** Keep both texts standing, change nothing. *Cost:* the same
gap is now described in three documents and closed in none.

## 5. Recommendation

**A1.** It is the only option that makes a shipped artifact accountable without
a schema change, a new refusal, or a model run. Then decide A2 separately,
because its price is an evidence policy, not code.

Two questions A1 still needs answered by the owner, both answerable in one line
each:

1. What is `.removeObject` — `generative.edit` or `inpaint.object`?
2. Should a stored edit whose sidecar does not match its bytes be shown as
   missing (the §3.6 reading of `E_ARTIFACT_MISSING`) or kept editable with a
   warning? The first is stricter and destroys nothing; it can strand an edit
   the user made hours ago.

## 6. The privacy side, measured rather than feared

Sidecars would sit in
`~/Library/Application Support/RetouchStudio/AI/edits/<edit-id>/`
(`AIEdit.swift:33-37`) — not in the project and not beside the photo, so
**sharing a `.retouch` file or exporting a JPEG carries none of it**. The
fields §3.6 names are a job uuid, model ids/versions/file digests, adapter
version, parameters, seed, dimensions, bit depth, elapsed time and two SHA-256
digests. The input digest is of the host's downscaled working copy, which is
deleted when the job returns (`QuickEdit.swift:105`), not of the original file,
and the original path never leaves the host
(`Docs/STUDIOCORE_ARCHITECTURE.md` §privacy rules). What it does add is another
local file that survives a cache clean of the pixels and would need the same
retention as the pixels — and `Docs/AI_RUNTIME.md` §`E_IDENTITY_REDACTION`
already promises the worker keeps no personal identifiers, which a digest of
derived pixels does not break.

If the answer is "no extra local residue", option C becomes the honest label for
that choice instead of a silent half-implementation.

## 7. What is deliberately *not* claimed here

No inference was run and no weights were downloaded to write this. Nothing in
the table above was tested end-to-end with a real model: the statement that
`patch_edit` writes no sidecar was read from the worker source, and the
statement about `verify` is about code paths, not about a real installed model
being validated. Windows is out of scope: the host has no Windows sweep or
adoption path for these artifacts, and `Docs/W5_UPSCALER_ACCEPTANCE.md` §6 (2026-11-17)
records the Windows adapter as not started.
