# G-CAT — Model licence evidence in the shipped catalog

Status: **data layer only**. This gate records licence evidence; it changes no
install, download or refusal decision. Acting on the evidence is a separate,
later, reviewed change.

Baseline measured at `cd5741b76`.

## 1. Why

`Resources/model-catalog.json` stored three free-text licence strings per entry
(`codeLicense`, `weightsLicense`, `licenseEvidenceUrl`) and nothing else. That
cannot be audited later:

- A URL without a date cannot rot-detect. Licences do change.
- An inferred repository-level licence tag is indistinguishable from an author's
  explicit grant about the weights. This project has already been bitten by that
  conflation once, so the distinction is stored as data rather than left to a
  reader's judgement.
- No field recorded what notice text would have to be reproduced if a weight file
  were ever mirrored or bundled, so a redistribution decision could not be made
  without re-reading the web.

## 2. What was added

Per entry, one optional nested object `weightsEvidence`:

| Key | Meaning |
|---|---|
| `licenseUrl` | Where the **weights** grant itself lives. May differ from `licenseEvidenceUrl` when the author ships a dedicated file (MI-GAN's `LICENSE-WEIGHTS`). |
| `readOn` | ISO-8601 calendar date the grant was actually read. Never defaulted. |
| `explicit` | Did the author state the grant *about the weights*? `false` means "we inferred it from a repo-level tag". |
| `commercialOk` | Commercial use in a public MIT-licensed app is granted. Recorded, never derived. |
| `noticeText` | Attribution to reproduce if a file were mirrored or bundled. |
| `verdict` | Closed set: `usable` \| `usable-with-conditions` \| `excluded`. |
| `verdictReason` | One sentence. |
| `datasetNote` | Residual-risk statement. **Omitted entirely when the dataset position is not confirmed** — absence is the encoding of "not confirmed", so a missing fact can never be read as a cleared one. |

### Backward compatibility

`ModelCatalog.load` decodes with a strict `JSONDecoder`, so every new key is
optional in the Codable representation and decodes to `nil` when absent. The
entry struct keeps its memberwise initializer with `weightsEvidence` defaulting
to `nil`, so existing construction sites compile unchanged.

Two spellings decode into the same record: the nested `weightsEvidence` object
(what this repository ships) and the flat top-level keys named by the release
gate (`weightsLicenseUrl`, `weightsLicenseReadOn`, `commercialOk`,
`weightsLicenseExplicit`, …). Encoding always writes the nested form.

No `catalogVersion` bump was made, and none is required: nothing is mandatory
yet. When a later gate wants to require these fields, that is where the version
check belongs.

## 3. The four shipped rows

All values come from the model licence dossier (§0.1, §2.1, §3.1, §6, §7.1 and
Appendix A). Every read is dated **2026-11-21**; that is the dossier's own
recorded date, not the date of this commit.

| Entry | `explicit` | `commercialOk` | `verdict` | `datasetNote` |
|---|---|---|---|---|
| `sam2.1-hiera-tiny` | true | true | `usable` | omitted — training set NOT CONFIRMED (§3.1) |
| `migan` | true | true | `usable` | omitted — Places2 terms NOT CONFIRMED (§6, §9 #1) |
| `flux2-klein-4b-q4` | true | true | `usable` | omitted — the dossier records no dataset row for this entry at all |
| `swin2sr-x4` | **false** | true | `usable-with-conditions` | DIV2K research-only + Swin2SR set unconfirmed (§2.1) |

The FLUX row is a deliberate deviation from the brief: its `datasetNote` is left
absent rather than reusing MI-GAN's Places2 caveat. §6 attributes Places2 to
"MI-GAN and the LaMa family" only, so carrying it onto FLUX would be an inference
presented as a recorded fact. The same rule that keeps `explicit` honest applies
here. Closing it needs one dossier read of the FLUX.2-klein-4B card.

### Dossier inconsistencies found while transcribing

Two things in the source document are worth correcting before it is cited again;
neither changes a verdict, and both are reasons not to treat this table as
self-verifying:

- **§10 sizes the FLUX artefact at 4.61 GB, which is decimal.** The catalogue's
  own recorded total is 4,608,176,697 B = 4.29 GiB. Elsewhere the dossier uses
  MiB (LaMa's "196 MiB" for 205,803,670 B), so the unit convention is mixed
  within one document. A size quoted without a binary/decimal marker cannot be
  compared against a pin.
- **A32 cites two sources but carries one timestamp, marked "earlier today."**
  Every other row in Appendix A has a full UTC timestamp. The four rows recording
  the shipped entries' grants — A21 (swin2sr), A26 (MI-GAN), A28/A29 (SAM 2) —
  are precise; A32 is the weakest evidence behind a `readOn` stamp in this file,
  and the `flux2-klein-4b-q4` grant URL is the repo page rather than the
  FLUX.2-klein-4B card that actually carries the quoted commercial sentence.

Notes on two rows that are easy to get wrong:

- **`swin2sr-x4`** carries `explicit: false` because the only statement about the
  weights is the repository-level `license:apache-2.0` tag on the Hugging Face
  repo whose sole payload is the checkpoint. The outcome is still shippable; the
  auditability differs, which is exactly what the field is for.
- **`flux2-klein-4b-q4`** is `usable` *on licence*. It is excluded on this
  hardware by measured memory (16.7 GB peak on M3 16 GB), and that fact stays in
  `notes` — a licence verdict must not absorb a performance rejection, or the
  two stop being independently checkable.

## 4. Rules enforced, and rules deliberately not enforced

`validate()` rejects, for any entry that carries the object:

- a `licenseUrl` that is not HTTPS on a default port, or that carries credentials
  or a fragment;
- a `readOn` that is not a well-formed, plausible ISO-8601 calendar date;
- a `verdict` outside the closed set;
- a `verdict` of `usable` or `usable-with-conditions` alongside
  `commercialOk: false`.

`isVerifiable`, `verificationProblem`, `unverifiableReason` and every download
gate are untouched. Nothing branches on `verdict` yet.

A verdict word this build does not know decodes into `verdictRaw` with
`verdict == nil` and is then rejected by `validate()` — it never fails the whole
strict decode, and it round-trips through `encode` instead of silently vanishing.

## 5. Worker cross-check

`worker/retouch_ai_worker/catalog.py` gained `license_url` and `license_read_on`
per entry, plus the same two keys appended at the end of `ModelEntry.public()`.
The change is additions-only: no existing field, order or refusal path moved, so
the worker's commercial gate behaves byte-for-byte as before.

`Tests/ModelStoreTests.swift` §[19](g) reads that file and asserts the two
surfaces agree on SPDX id, grant URL, read date and commercial clearance for all
four entries, so drift between them fails the Swift suite. Doing this in Swift
rather than Python is deliberate: registering a new Python suite would need
`Tests/run-worker.sh` or `Tests/expected-worker-tests.txt`, both off-limits here.

## 6. Verification

Run via the project's own runner (`./Tests/run.sh`); `swift build` is unusable on
this machine — the project builds against Command Line Tools only.

- Old-format decode: the shipped catalog with every `weightsEvidence` key stripped
  still loads, and its entries compare equal to the real ones in every field
  except the evidence.
- Behaviour freeze: `isVerifiable` / `verificationProblem` / platform support
  asserted identical with and without the evidence, and pinned per entry.
- Rejection cases for each rule in §4, for both spellings.
- Property check over all 12 `verdict × commercialOk × explicit` combinations:
  8 decode with every field round-tripping independently, and the only 4 refused
  are the `commercialOk: false` non-excluded pairs.
- The 268 model-store checks pass (172 before this change, +96 new).

Pre-existing and unrelated to this gate: `RUNTIME V2 TESTS: FAIL (4)` locally,
identical on the pristine baseline, because `worker/.venv` does not exist on this
machine. CI provisions it.

## 7. Left for the UI task (deliberately not done here)

- Render `weightsEvidence.licenseUrl` and the verdict in the consent sheet and the
  model row, in English and Persian. Today `licenseEvidenceUrl` is stored and
  validated but displayed nowhere, so a user still cannot reach the URL that
  justifies the claim.
- Show `readOn` so a human can see how old the claim is, and decide a staleness
  threshold plus a re-read workflow.
- Decide whether `verdict` should gate anything, and whether `explicit: false`
  deserves a distinct visual weight from `explicit: true`.
- Localize the three verdict words; `Localization.swift` and `PersianL10n.swift`
  were out of scope here.

## 8. Reproducing the data edit

`Docs/licence-evidence-apply.py` adds the blocks to `Resources/model-catalog.json`
textually and asserts afterwards that no pre-existing value changed and no key was
removed, so the diff stays provably additions-only.
