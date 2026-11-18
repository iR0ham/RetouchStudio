# Which refusal sentence the owner sees — proposal, not a decision

Status: **proposal prepared by the engineering agent on 2026-11-18.** Nothing
here is adopted. It asks one product question and one wording question, listed
in §6. No code in this repository was changed by it.

Every `file:line` pointer below was re-pinned against `main` on 2026-11-18.
This branch now sits on a `main` whose task-label, provenance and
jobs-retention merges moved `server.py` and the strings table, so the numbers
the first draft carried had drifted. The quoted sentences, the measured
capability states and the two questions are unchanged.

## 1. What was measured, on this Mac, today

The shipped worker was started the way the app starts it and asked
`capability.list` over its socket. Two of the sixteen records came back
`blocked` for a reason the app itself can fix:

```
upscale.4x    blocked  swin2sr-x4   swin2sr-x4 is installed without a version; adopt it in the model manager …
inpaint.spot  blocked  migan        migan is installed without a version; adopt it in the model manager …
```

The sentence is built in `worker/retouch_ai_worker/capabilities.py:138-140`,
and the state comes from an internal class the adapter names `legacy`
(`capabilities.py:138`) — an installed model whose bytes are on disk in the
pre-versioning layout. The remedy is real and it is one tap:
`Sources/RetouchStudio/Views/ModelManagerView.swift:411-417` renders an Adopt
chip for `manager.legacyBytes`, which asks first (`:128-131`) and then
re-layouts the files. Nothing is downloaded, so no consent and no cost.

What the owner sees instead is decided by two lines of the host. The worker
answers a blocked capability with `-32020`
(`worker/retouch_ai_worker/server.py:330-334`), whose JSON-RPC `message` *is*
that actionable sentence, and `Core/WorkerClient.swift:119-121` copies the
message into `AIWorkerFailure`. Then `Models/EditorModel.swift:1758`
replaces it: `case -32020: return L10n.current.aiCapabilityUnsupported`, which
reads, in English, "This AI tool is not available for this Mac build yet.
Manage Models… shows what this adapter can run." (`Models/Localization.swift:1278-1280`,
and the same shape in Persian at `Models/PersianL10n.swift:1217-1219`).

So the helper's own instruction reaches the app and is discarded, and the
sentence that replaces it is not true of this state: the build does support
4× upscaling, the bytes are on disk, and the only thing missing is the tap the
message does not mention. By contrast `-32011` gets both a sentence and a
sheet — `EditorModel.swift:1749` sets `showModelManager = true` — so the
mechanism the blocked case needs already exists one `case` away.

## 2. What is already decided, and what is not

The refusal itself is recorded twice as deliberate, and this proposal does not
reopen it:

- `Docs/W5_ADAPTERS.md:158-161` — "a 4× pass is refused with `E_UNSUPPORTED`
  until the owner adopts it in the model manager. The refusal is the contract's
  answer, not a defect".
- `Docs/W5_IMPLEMENTATION_DECISION_RECORD.md:618-623` — the same consequence,
  with the measurement that the kind path ran this very install on 2026-11-07.

Neither passage ever considered the second half: **which code, and therefore
which sentence and which sheet**, carries that refusal. The code table they
rely on says `E_MODEL_MISSING` is a model "that is not installed"
(`W5_IMPLEMENTATION_DECISION_RECORD.md:190`) and `E_UNSUPPORTED` is a
capability "not provided by this adapter/platform" (`:198`). An installed,
adoptable model in the legacy layout is neither: the adapter does provide the
capability and the model is installed. The state is being reported through the
closest existing code rather than the correct one, and the wording that code
owns was written for the other meaning. That mismatch is the open question,
not the refusal.

## 3. The states that arrive at `-32020` are not one class

Measured from the same live answer, all sixteen records sort into three kinds
that today share one sentence:

| kind | records on this Mac | does the app contain the remedy? |
|---|---|---|
| not provided by this platform, by design | `face.analysis`, `face.parsing`, `mask.subject`, `background.replace`, `upscale.2x`, `enhance.photo`, `restore.photo`, `portrait.ai` | no — classical processing is the product answer |
| `blocked`, unfixable from inside the app | `mask.click` (DR-5: no recorded size or SHA-256), `matte.fine` (no cleared rights), `generative.outpaint` (no licensed engine) | no — it needs a model decision by the owner |
| `blocked`, one tap from being usable | `upscale.4x`, `inpaint.spot` (legacy flat installs present on disk) | **yes** — the Adopt chip in the model manager |

One sentence now covers all three, and it is accurate for the first two and
wrong for the third.

Corrected 2026-11-18, with the table above kept as the measurement it was: the
`mask.click` parenthetical no longer describes the shipped catalog. PR #83
recorded SAM 2.1 tiny's size (156,008,466 bytes) and SHA-256 (`7402e0d8…be69`)
from the installed file, so DR-5's "no recorded size or SHA-256" branch cannot
be what blocks that capability any more. Its row does not change, but the reason
under it does: `sam2` is in neither `worker/requirements.lock` (68 pinned names,
counted the same day) nor the `models` extra, so a lock-reproducible worker has
nothing that can read those weights, and the only `sam2` on this machine sits in
the stale 2026-11-08 `build/Worker.cache`. Saying so in the report — a
capability whose loading package this interpreter cannot import is `blocked`, not
offered — is a separate slice and is not part of this document; until that
lands, `mask.click` answers with whatever its install layout says, which is why
it is listed by reason rather than by code.

## 4. Options

**A. Do nothing.** The status quo is documented, so this stays honest. Cost:
the owner of a machine that already has the weights is told a shipped feature
"is not available for this Mac build yet", and may go looking for a build that
does — or re-download 46 MB he already owns.

**B. Emit `-32011` for the legacy class.** One-line change in
`server.py:330-334`, and the sheet opens by itself. Rejected as written:
`-32011`'s sentence is "The local AI models are not installed. Open Settings →
Manage Models… **to download them**" (`Localization.swift:1269-1271`), which
would invite a re-download of bytes on disk, and it contradicts the recorded
meaning of the code. Changing the code's meaning is a contract change, not a
fix.

**C. Keep the code, fix the host's routing.** `WorkerClient` already receives
the error `data` object and drops it; `AIWorkerFailure` carries `code` and
`message` only (`WorkerClient.swift:5-8`). Carry the `state` (and the
capability id) across and give `blocked` a sentence of its own, with the sheet
opening for the case the manager can act on. No protocol, schema, ABI or
worker change: the fields the host needs are already sent, exactly as
`Docs/AI_PROTOCOL_V2.md:109` documents them (`-32020` with
`{capabilityId, state, reason}`). Costs worth naming: the host learns a third
`case`, the wording must be written in English and Persian, the Windows host
needs the same rule to stay at parity (it has the code table at
`Windows/RetouchStudio.AI/WorkerClient.cs:44-51` and no such routing today),
and "the blocked state says nothing about the app being able to fix it" means
`state == "blocked"` alone cannot separate row 2 from row 3 of the table
above. Separating them without guessing needs a machine-readable reason class,
which *is* a payload change and a decision of its own.

**D. Copy only.** Rewrite `-32020`'s sentence so it is true for all three
kinds — something like "This AI tool is not available on this Mac yet; Manage
Models… says what is missing and what you can adopt." No behaviour change, no
new plumbing, no protocol question; the sheet still does not open, and the
owner still has to find the tap. It also touches a string the first kind uses
correctly today.

## 5. Recommendation

**C, without the reason-class field**, plus **D** as the wording step: the
host should stop overwriting a message it was given when the message names an
action the app can perform, and `blocked` refusals should land the owner in the
model manager rather than in a sentence about builds. Coarse routing on
`state == "blocked"` is honest for row 3 and merely opens a sheet that is the
right place for row 2 as well: the manager renders the worker's own answer per
state (`ModelManagerView.swift:195`, `:266`) and names an unverifiable model
with its reason (`:397-398`). If the owner prefers precision over a sheet
appearing unasked, **D** alone is a strict improvement and costs one string.

This is a product decision about what the app says and whether a sheet may open
on its own, so it is left to the owner rather than implemented.

## 6. The two questions

1. May a blocked capability open the model manager by itself, the way a missing
   model already does?
2. What should the English and Persian sentence say for a capability that is
   blocked because an installed model has not been adopted?

## 7. What this document does not claim

- No UI session was driven. Every string quoted was read from source; no
  screenshot was taken and the owner's running app was not touched.
- The live `capability.list` answer is a property of this machine's model
  directory, not of CI: another Mac without those two installs reports
  `missing`/`requires_model` instead and already routes to the manager.
- Nothing here changes a capability state, a licence, a catalog entry or the
  frozen contract, and no model was downloaded, installed or run.
- Whether the Windows host should mirror option C was not researched beyond the
  code table cited above; Windows AI stays BLOCKED regardless.
