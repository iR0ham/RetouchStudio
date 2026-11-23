# Retouch Studio 2.0.0 — release-readiness record

**Owner of this document:** Project Manager / Release Manager.
**Last audited:** 2026-11-21 (all "measured today" facts below were produced in this audit).
**Baseline measured today:** `origin/main` = `cd5741b76f328e883be03f110a7c9c23f0c152fa`; `origin/develop` = `06e8ac4be2d7ec28058b3680805d90a7671a03f0` (**behind main** — must be fast-forwarded at the next merge).
**Target release:** `2.0.0` — the first release of the rewritten product. `v1.0.0` is pre-rewrite legacy and is not modified by this work.

This is a decision-and-evidence ledger. It is append-only: superseded statements are corrected with a dated addendum (§12), never deleted.

---

## 0. Status vocabulary and evidence rule

| Status | Meaning |
|---|---|
| **VERIFIED** | A named artefact (commit, log, probe output, source line) was read or run and proves the claim. Evidence pointer is mandatory. |
| **NOT VERIFIED** | The claim is plausible or implemented, but no evidence in this record proves the behaviour. Includes "implemented, not exercised". |
| **BLOCKED** | A named external condition (owner ruling, missing hardware, missing authorization) prevents verification or completion. |
| **NOT APPLICABLE** | Out of scope for 2.0.0 by a settled decision. |

Hard rules for this document:

1. Green CI proves the assertions that CI contains. It is not evidence about runtime behaviour it never exercises. No job in `.github/workflows/ci.yml` builds or launches the application bundle (measured: `.github/workflows/release.yml:38,68` are the only `build.sh` callers).
2. "Implemented on a branch" ≠ "verified in the product". Each is recorded separately.
3. A team member's self-reported PASS is recorded only after the supporting artefact is inspected.
4. Anything that would need the GUI is recorded as **NOT VERIFIED** or **BLOCKED**, never as passed — the owner's standing no-GUI ruling is in force (§11).

---

## 1. Owner decisions treated as final (from the release mandate)

| # | Decision | Effect on the plan |
|---|---|---|
| D1 | First post-rewrite release is **2.0.0** | Version bump needed in the two version sources (§3 G-VER) |
| D2 | macOS **and** Windows are first-class; Linux is not a product target | Windows evidence is a release gate, not an aspiration (§8) |
| D3 | **MIT** stays; no GPL migration | opencv-python/x264-x265 licence pressure must be resolved by dropping the dependency, not by relicensing |
| D4 | **No** Apple Developer Program, Developer ID or notarization | Ad-hoc signing is permanent; quarantine handling becomes load-bearing (§7) |
| D5 | macOS distribution = ad-hoc signing + SHA-256 checksums + honest Gatekeeper text | Gatekeeper copy must state what the owner actually has to do |
| D6 | **Updater stays disabled in 2.0.0**; manual DMG install | Updater transaction work is design-only, off the critical path (§6) |
| D7 | No publish / upload / retag / delete / modify of the existing `v1.0.0` release without explicit authorization | `v1.0.0` and its 388 MB public runtime asset are frozen; nothing in this plan touches them |
| D8 | No destructive or irreversible operations without approval | |
| D9 | No paid services without approval | |
| D10 | The owner's local checkout, personal data and unrelated work are untouched | All work runs in isolated clones under `/private/tmp`; `/Users/roham/RetouchStudio` (HEAD `40b157f`, dirty with the owner's own files) is never written |
| D11 | **No launching the application or opening GUI windows** until the owner authorizes a bounded acceptance session | Caps what can ever reach VERIFIED before §9 (§11) |
| D12 | Preserve the existing Better Harness workflow; no new plugins/infrastructure without demonstrated need | No new CI platform, no new runner, no new tooling layer |

---

## 2. Free-model definition applied everywhere

**Free = zero purchase price AND an explicit grant for commercial use in a public MIT-licensed application.** Code licence, weights licence and training-data terms are evaluated separately, and an inferred repo-level licence is never recorded as an author's weights grant.

> **SUPERSEDED 2026-11-22 by Addendum O.** The owner replaced the use class: the app is free and
> intended for public **non-commercial** use, with no intention to commercialise. The sentence
> above is kept verbatim because every verdict recorded between 2026-11-21 and 2026-11-22 was
> produced under it, and the record must stay re-derivable. The gate that replaces it — including
> what it unblocks and what it deliberately does not — is §12 Addendum O.

Source of the per-model evidence: `/private/tmp/rs-model-licences/MODEL_LICENSES.md` (Researcher, 2026-11-21, 355 lines, Appendix A logs 32 URL reads with timestamps). Its licence statements are the research baseline; the two catalogue facts in §8c of that dossier were **contradicted by the repository** and are corrected in §12 Addendum A.

---

## 3. Readiness gates

### Release-blocking gates

| ID | Gate | Status today | Evidence / what would change it |
|---|---|---|---|
| G-INT | **Model integrity is fail-closed** (mandate §4) | **NOT VERIFIED — defect confirmed** | Measured fail-open sites: `worker/retouch_ai_worker/catalog.py:330` (`if spec.bytes is not None and …`), `:358` and `:418` (`if spec.sha256 is None: continue`), `:401`. A model whose pin is absent is therefore *trusted*, not refused. Fix + negative tests + independent adversarial review required. Owner: Full-stack Engineer, then Code Reviewer. |
| G-CAT | Catalogue carries auditable licence evidence (`weightsLicenseUrl`, `weightsLicenseReadOn`, `commercialOk`, `noticeText`, `explicit`, `verdict`) | **NOT VERIFIED — absent** | Measured: `Sources/RetouchStudio/Models/ModelCatalog.swift:96-115` stores exactly `codeLicense`, `weightsLicense`, `licenseEvidenceUrl` — no date, no notice text, no verdict. Worker side stores only `license_id` + `commercial_ok` (`catalog.py:45-46`). |
| G-UI | Model consent UI shows licence evidence, not just SPDX names | **NOT VERIFIED** | Measured: `licenseEvidenceUrl` is decoded (`ModelCatalog.swift:108`) and validated https (`Tests/ModelStoreTests.swift:546`) but **never rendered** (grep over `Sources/` → single hit). Consent sheet shows `host · code / weights · SHA-256 <16>` (`Views/ModelManagerView.swift:607-611`). The visible result is additionally **BLOCKED** by D11 (no GUI). |
| G-SEP | Model-weight notices are not delegated to `worker/THIRD_PARTY_NOTICES.md` | **VERIFIED as a documentation fact; the enforcement gap is NOT VERIFIED** | Measured: the worker notices file states weights are not part of the repo or bundle and carry their own licence. There is no check that keeps that separation true — see G-PKG. |
| G-NOC | No NC-licensed model or weight is selectable | **VERIFIED** | Measured today: `grep -rniE 'gfpgan|codeformer|restoreformer|lama|modnet|birefnet|realesrgan|swinir' Resources Sources worker/retouch_ai_worker Windows` → **no matches**. The shipped catalogue contains exactly four entries: `flux2-klein-4b-q4`, `sam2.1-hiera-tiny`, `swin2sr-x4`, `migan` (`Resources/model-catalog.json`). |
| G-PKG | The app bundle ships MIT licence + third-party notices, validated by checks that can actually fail | **PARTIALLY VERIFIED** | PR #111 (`407c6fd`, `w5-license-notices`, CI green) puts `LICENSE` + `THIRD_PARTY_NOTICES.txt` into `Contents/Resources`; a hand-assembled 13-file bundle passes `Tools/validate-bundle.sh` (exit 0) and the missing/empty negatives fail (exit 1). **Independent adversarial evidence** (`/private/tmp/rs-111-evidence/REPORT.md`) also proves three checks that **cannot fail**: an un-attributed pinned distribution (N3), an empty helper notice (N4), 3-of-4 fonts removed (N5) and uppercase `ALL RIGHTS RESERVED` (N6) all exit 0. Closing those is a follow-up on the same workstream. |
| G-BLD | A release bundle is built and validated end-to-end from the final head | **BLOCKED (D11)** | `build.sh` executes the built binary: `build.sh:229` (`--selftest`) and `:244` (Rosetta slice); `RETOUCH_SKIP_WORKER=1` does not skip it (measured `build.sh:170-176`). Until the owner grants one bounded exec of `Contents/MacOS/RetouchStudio --selftest`, no bundle-level claim can be made by anyone on this team. |
| G-VER | Version stamping says **2.0.0** in both sources | **NOT VERIFIED — currently 1.0.0** | Measured: `Resources/Info.plist:22` = `1.0.0`, `:24` = `1`; `Tools/check-versions.sh` asserts `Info.plist` == `Windows/Directory.Build.props` == the tag, and `release.yml:174-175` runs it before publishing. Mechanism **VERIFIED**; the bump is a two-line change to be made on the RC branch. |
| G-QA | Core editing/export behaviour verified on the release artefact | **BLOCKED (D11)** | Regression baseline exists (24 core flows PASSed in the 2026-11-21 Wave-1 live audit) but was measured on an *older* build, not on a 2.0.0 artefact. Re-measurement needs the owner's session. |
| G-UPD | The updater is provably disabled in the shipping build | **VERIFIED at the configuration level; NOT VERIFIED in the UI** | Measured today: no feed URL is compiled in — `UpdateController.feedURLs` (`UpdateController.swift:159-162`) reads only the Info.plist keys `RSUpdateFeedURLs` / `RSUpdateFeedURL`, and `Resources/Info.plist` defines **neither** (grep for feed/update keys → no match). So `performCheck()` takes the empty branch and reports `updateFeedMissing` = "This build has no update feed configured." (`:66-69`, `Localization.swift:884`, `PersianL10n.swift:857`). A user therefore cannot install an update from a 2.0.0 build. The rendered About panel is **NOT VERIFIED** (D11), and this inertness depends on the plist staying empty — it is a configuration guarantee, not a code flag, so it must be re-checked on the RC bundle. |
| G-WIN | Windows release evidence | **AUDITED — see Addendum D for the current status of each sub-gate** | The earlier row here was wrong in both directions and is superseded. Windows CI does install/upgrade/uninstall the MSI and drive the app through 14 UIA passes (`ci.yml:531-545`, run `44936922862`), but **all four catalogue models are `macos-arm64` and every Windows `job.submit` is refused `-32020`: there is no AI on Windows**, and no Windows evidence exists from a real desktop. The 2.0.0 claim is therefore scoped to a first-class **light editor** with AI explicitly absent. Open sub-gates: G-WIN-1 look guard (fix in flight), G-WIN-2 package attribution, G-WIN-3 `README.md:47` false "not a shipping target", G-WIN-4 no Windows bundle validator, G-WIN-6 ONNX licence not independently read. |
| G-110 | Worker CI fail-closed hardening (PR #110) merged after independent review | **NOT VERIFIED** | Head `c72a0f418…` is open, `MERGEABLE/CLEAN`, all five required contexts SUCCESS (measured via `gh pr view`). **No review and no comment exists on the PR** (measured: empty reviews and comments lists) → the owner's "independent review before merge" gate is unmet. Three documentation corrections are also outstanding (§5). |
| G-107 | Runtime extraction without quarantine (PR #107) | **IN PROGRESS** | Head `2c95eb798…`, no longer draft, `mergeStateStatus=BLOCKED` only because *macOS Integration* and *Windows App* were still running at audit time. Must be re-read at the final head; its `--noqtn` claim covers **extracted runtime files only**, never the downloaded `.app` (§7). |

### Gates that must exist but do not yet have an owner-visible artefact

| ID | Gate | Status |
|---|---|---|
| G-RN | 2.0.0 release notes + installation/Gatekeeper instructions (EN/FA) | **NOT VERIFIED** — to be produced with the RC. |
| G-SUM | SHA-256 checksums generated **and independently re-checked** | **NOT VERIFIED** |
| G-LOG | Build logs and test reports preserved with the RC | **NOT VERIFIED** |
| G-ACC | Owner acceptance session (§9 checklist) | **BLOCKED (D11)** — by design the last step before publication approval. |
| G-PUB | Publication | **NOT AUTHORIZED** — out of scope by D7; the deliverable ends at "RC + approval request". |

---

## 4. Model catalogue: per-model position for 2.0.0

Measured from `Resources/model-catalog.json` at `cd5741b76` and `worker/retouch_ai_worker/catalog.py:119-200`.

| Model | In product | Code licence | Weights licence | Dataset note | Commercial position for 2.0.0 |
|---|---|---|---|---|---|
| `swin2sr-x4` (upscaler, installed) | selectable | Apache-2.0 (mv-lab/swin2sr) | Apache-2.0 tag on the HF repo that holds `pytorch_model.bin` — **repo-level grant, not a sentence about the weights** | training set not stated by the model card; DIV2K is research-only at the dataset level | **Ship with conditions**: disclose code + weights + evidence URL at consent time. Not an unconditional approval. |
| `sam2.1-hiera-tiny` | **catalogued but download-refused** | Apache-2.0 | **Apache-2.0 stated explicitly for the checkpoints** (SAM 2 README) | n/a for the grant | Licence is the cleanest of the set. The blocker is a **missing runtime package**, not metadata: `sam2` is absent from `worker/requirements.lock` and is recorded only as git checkout `@2b90b9f` in `Docs/AI_RUNTIME.md` §6. |
| `migan` (heal) | selectable | MIT (Picsart) | **MIT, explicit `LICENSE-WEIGHTS`** | Places2 terms NOT CONFIRMED (host unreachable on the audit day) | Ship. Strongest position in the catalogue. |
| `flux2-klein-4b-q4` (generative) | selectable in catalogue | Apache-2.0 | Apache-2.0, "open weights available for commercial use" | — | Licence OK; **excluded on this hardware** (measured 16.7 GB peak on M3 16 GB). Not a 2.0.0 feature claim. |
| GFPGAN, CodeFormer, DFDNet | **absent** | — | — | — | **Excluded by licence** (NVIDIA §3.3 non-commercial, S-Lab 1.0, CC BY-NC-SA). Verified absent from every shipped surface (G-NOC). |
| RestoreFormer++, MODNet | absent | Apache-2.0 (placeholder copyright) | no explicit weights grant / Drive-only artefacts | FFHQ = CC BY-NC-SA | Do not ship. Face restoration is off the 2.0.0 roadmap. |
| Real-ESRGAN, SwinIR (Enhancer candidates) | absent | BSD-3-Clause / Apache-2.0 | repo licence only (inferred) | DIV2K/DF2K | Post-2.0.0; needs `realesr-general-x4v3` size+hash recorded and a mirror decision before entering the catalogue. |
| BiRefNet | absent | MIT | **MIT on the HF repo holding `model.safetensors`** | DIS5K | Post-2.0.0 candidate for matting/selection, subject to artefact + memory verification. |

**SAM2 pin status — corrected.** The checkpoint identity is already recorded and is *not* outstanding work: size `156,008,466` B and SHA-256 `7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69` are present in `Resources/model-catalog.json:77`, mirrored in `worker/retouch_ai_worker/catalog.py:160`, and asserted by `Tests/ModelStoreTests.swift:596` and `worker/tests/test_catalog.py:80`. The pin landed in commit `624d963` ("record SAM 2.1 tiny's measured size and digests"). What remains is (a) an independent, dated re-verification of the artefact against its authoritative source, and (b) the `sam2` runtime dependency, which is the actual reason the entry carries `unverifiableReason` and refuses download.

---

## 5. Existing workstreams: reconciliation against the live state

Measured today with `gh`; no claim below is inherited from a member report.

| PR | Branch / head | Draft | Mergeable | Required CI | Independent review | Verdict / next action |
|---|---|---|---|---|---|---|
| **#110** Worker gates fail-closed | `w5-worker-gates-failclosed` / `c72a0f41864273e82238ad44304b5e544c6e4871` | no | CLEAN | all 5 SUCCESS | **none** (empty reviews + comments) | Apply the three corrections below, then full-diff independent review, then merge + fast-forward `develop`. |
| **#111** Notices in the app bundle | `w5-license-notices` / `407c6fd0ebd7ae04688f757dc587162450b4c62a` | no | CLEAN | all 5 SUCCESS | **none** | Independent review is in flight, using `/private/tmp/rs-111-evidence/REPORT.md` as the adversarial evidence. Merge decision must separate "ships the licence files" (supported) from "the checks can fail" (three cases unsupported). |
| **#107** `--noqtn` runtime extraction | `w5-17/quarantine-extract` / `2c95eb79866c78cb1e5e3bfe7505d1c771a32f31` | **no** (was draft) | BLOCKED (2 contexts running) | 9 SUCCESS / 2 running | none | Re-read at the final head; confirm the claim is scoped to extracted runtime files only. |
| **#99** Wave-1 UI truthfulness + Persian (D2,D3,D4,D6,D7) | `w5-14/wave1-a11y` / `277cf50088a5509317d9d77752ab2692d0f06f5b` | **yes** | BEHIND | — | review done earlier (task #70) | Rebase onto main, close the review findings, keep it staged for the owner's acceptance session. Live acceptance is **BLOCKED (D11)**. |
| **#102** Post-release roadmap docs | `docs/post-release-roadmap` / `e361772b` | no | BEHIND | — | in flight | Docs only; must not conflict with this file's `Docs/` additions. |
| Issue #64 | — | — | — | — | Registered: cold `com.apple.metal` cache makes the first export differ by ≤1 LSB; pre-existing at `44647b0`, P3, not a 2.0.0 gate. |

**The three #110 corrections carried forward from the earlier review, restated against the current head:**

1. Only **Worker Payload Bundle** uses `continue-on-error: true`. *Worker Lock Closure* is advisory because its context is not required. The PR text must not claim both are `continue-on-error`, and **`continue-on-error` must not be added to Worker Lock Closure**.
2. The adversarial matrix must match the tests that exist: fix the D5b exit-status mismatch, add a test that rejects **broadened** `mflux` wording, and either automate A4 resolver exact/extra + Count Divergence or classify them explicitly as manual measurements.
3. The test-count sentence in the PR documentation is wrong; `W5_UPSCALER_ACCEPTANCE.md` keeps its historical text and gains a **dated clarification** rather than a rewrite.

---

## 6. Updater (mandate §6)

**NOT APPLICABLE to 2.0.0.** The updater ships disabled (D6); manual DMG installation is the supported path, so the two release-blocking transaction-safety defects (stranded swap between the two renames; no launch validation before the last-known-good is deleted) cannot be reached from a shipped build.

Preserved design-only artefacts (uncommitted, outside the repo):
- `/private/tmp/rs-upd-design/UPDATER_TRANSACTION_DESIGN.md` — the full proposal (failure-state matrices, journal v2 schema, compatibility matrix, state diagram, 26 adversarial cases, CI proposal, U1–U12 unverified list).
- `/private/tmp/rs-upd-feasibility/FEASIBILITY.md` — the two accepted architectural constraints: the probe seam is `SelfCheck.runIfRequested()` at `App.swift:188`, and **journal v2 must be inert to a v1 reader, not decodable by it** (separate `update-journal.v2.json` filename, v1 key names absent).
- `/private/tmp/rs-int-1795217340/Docs/UPDATER_TRANSACTION_SAFETY.md` — the original defect record.

Independent design review is queued for the Code Reviewer **after** the release-critical reviews; it gates any future implementation PR, never this release. No feed URL, no LaunchAgent, no background helper, no automatic update behaviour enters 2.0.0.

---

## 7. macOS distribution reality under permanent ad-hoc signing (D4/D5)

| Claim | Status | Basis |
|---|---|---|
| The app is ad-hoc signed and will remain so | **VERIFIED as a decision; NOT VERIFIED as an artefact** (no 2.0.0 bundle built, G-BLD) | D4; `build.sh` signing path |
| `--noqtn` fixes quarantine for **extracted runtime files** | **IN PROGRESS (#107)** | Measured separately: `ditto -x -k` propagates `com.apple.quarantine` to every extracted file; the runtime is exactly the tree that then gets `exec`'d. |
| `--noqtn` fixes Gatekeeper for the **downloaded `.app`** | **FALSE — must never be claimed** | Different path: the `.app` itself carries the quarantine xattr from the browser and is evaluated by Gatekeeper/AMFI at first launch. |
| Gatekeeper instructions in the release notes are truthful | **NOT VERIFIED** | Depends on a real first launch of a real downloaded DMG = owner session (§9). |
| SHA-256 sidecars are produced and independently re-checked | **NOT VERIFIED** | To be produced with the RC. |
| Non-notarised builds still run on a second Mac | **NOT VERIFIED** — local success is not cross-machine success | Explicitly barred by mandate §8 from being inferred from a local build. |

---

## 8. Testing and review record (what was actually run)

| Evidence | Date | Covers | Does not cover |
|---|---|---|---|
| `ci.yml` contexts on #110/#111 heads (all SUCCESS, read via `gh pr view`) | 2026-11-21 | StudioCore boundary/conformance, macOS Integration, Windows StudioCore, Windows App, worker advisory jobs | Any app bundle build, any GUI behaviour, any packaging assertion (the new bundle tests are not registered in CI) |
| `/private/tmp/rs-111-evidence/` (`make-fixture.sh`, 9 fixtures, `logs/`) | 2026-11-21 | Hand-assembled light bundle inventory; `validate-bundle.sh` exit codes; 8 adversarial mutations | The real `build.sh` path, the 1.4 GB helper payload, rendered UI |
| `/private/tmp/rs-model-licences/MODEL_LICENSES.md` Appendix A (32 timestamped URL reads) | 2026-11-21 | Licence text provenance for every candidate | Runtime behaviour, peak memory, artefact hashes not already on disk |
| `/private/tmp/rs-upd-feasibility/decode.swift` (headless decoder replica) | 2026-11-21 | The three v1 journal decode cases and their indistinguishability | Anything about a running app |
| `/private/tmp/rs-upd-lab/` (standalone Swift harness + `runs/`) | 2026-11-21 | `renamex_np(RENAME_SWAP)` behaviour on this APFS volume | Non-APFS volumes |
| Wave-1 live audit (24 core flows PASS) | 2026-11-21 (earlier session, GUI authorized then) | Regression baseline of the editing/export core | The current heads, and any 2.0.0 artefact |

---

## 9. Owner acceptance session — prepared, not started (mandate §9)

**BLOCKED by D11.** Nothing here may be marked VERIFIED by the team. Checklist to hand over when the owner opens the session:

1. First launch from the downloaded 2.0.0 DMG (fresh download, not a local copy).
2. Actual Gatekeeper behaviour under ad-hoc signing, with the exact dialog text compared against our published instructions.
3. Launch + core editing workflow (open → edit → export) and export correctness on a real photo.
4. Model/runtime install, verification and refusal paths, including the licence evidence visible in the consent sheet.
5. One representative AI operation end-to-end.
6. English **and** Persian text, digits and units (`MB` stays `MB`; one bidi-isolated run).
7. Error handling with a model deliberately unavailable.
8. Confirmation that the updater is disabled and says so honestly.

Prerequisite: every automated gate that does not need the GUI must be VERIFIED first, so the session tests only what genuinely needs a human.

---

## 10. Release-candidate production checklist (mandate §10)

Executable headlessly except where noted:

- [ ] Merge order settled: #110 → #111 → #107 → #99 → model-integrity PR(s).
- [ ] `develop` fast-forwarded to `main` after each merge.
- [ ] Version bump to **2.0.0** in `Resources/Info.plist` and `Windows/Directory.Build.props`; `Tools/check-versions.sh 2.0.0` passes. Build number chosen.
- [ ] Clean RC build (`RETOUCH_VERSION=2.0.0 RETOUCH_BUILD=<n> ./build.sh release`) — **BLOCKED by D11** because `build.sh` execs the binary. Needs one of: the owner's narrow exec authorization, or a `RETOUCH_SKIP_SELFTEST` code path agreed as non-weakening (it must keep running in CI, only skip locally).
- [ ] `Tools/validate-bundle.sh` + `Tools/audit-bundle-notices.sh` pass on the RC bundle, **and** the N3/N4/N5/N6 negatives are made to fail.
- [ ] SHA-256 for every artefact, regenerated from the artefact by a second process and compared.
- [ ] Model manifests re-read against the catalogue; integrity enforcement negative tests green.
- [ ] Release notes + installation/Gatekeeper instructions (EN/FA) drafted, with no claim this record marks NOT VERIFIED.
- [ ] Build logs and test reports archived alongside the RC.
- [ ] Final dossier = this file, closed out with verdicts.
- [ ] Owner approval requested for publication. **No tag, no release, no upload before that approval.**

---

## 11. Standing constraints in force during this work

- **No GUI.** No application window, no `.app` launch, no `Contents/MacOS/RetouchStudio` execution by any member. Verification is headless or static. (Owner ruling 2026-11-21, reaffirmed as D11.)
- **No process-killing automation.** The 2026-11-21 incident that SIGKILLed ~25 processes retired that mechanism permanently; constraints are enforced by not acting, never by a watchdog.
- The owner's checkout (`/Users/roham/RetouchStudio`, HEAD `40b157f`, dirty) and `~/Library/Application Support/RetouchStudio` are read-only to this team; large downloads are not performed on his machine without authorization.
- No commit/push to release channels, no tag, no publication, no modification of `v1.0.0` or its assets.
- Golden-corpus fixtures are never regenerated; private test portraits are never committed.

---

## 12. Addenda (append-only)

### Addendum A — 2026-11-21, correction to the model-licence dossier §8c

The dossier states that `Resources/model-catalog.json` sets `sizeBytes: null` and `sha256: null` for `sam2.1-hiera-tiny`, and that its SHA-256 is "first recorded, this task". **Both statements are false at `cd5741b76`.** Measured today: the file carries size `156,008,466` and SHA-256 `7402e0d8…be69` at `Resources/model-catalog.json:77`, the same digest at `worker/retouch_ai_worker/catalog.py:160` with an in-code note that it was measured three independent ways on 2026-11-18, plus assertions at `Tests/ModelStoreTests.swift:596` and `worker/tests/test_catalog.py:80`; the pin landed in commit `624d963`. The dossier's remaining conclusion stands and is the correct one: the reason `sam2.1-hiera-tiny` cannot be downloaded is its `unverifiableReason` — the **`sam2` runtime package is missing from `worker/requirements.lock`** — not missing metadata. Consequence for the plan: mandate §3.8 (record the pin) is already **VERIFIED** and drops out of the critical path; §3.9 becomes a dated re-verification of an existing pin; §3.10 (the runtime dependency) is the only sam2 item left and is the one that can regress. The licence verdicts in §2–§6 of the dossier are unaffected and are used as the baseline.

### Addendum B — 2026-11-21, independent verification of PR #111
The Test Engineer's adversarial run confirmed the packaging claim and refuted part of the "the check can fail" claim (N3 un-attributed pinned distribution, N4 empty helper notice, N5 three of four fonts absent, N6 uppercase `ALL RIGHTS RESERVED` — all exit 0). Root cause measured: `Tools/audit-bundle-notices.sh` never opens `requirements.lock` or `.dist-info/METADATA` and owns `Contents/Resources/Worker/*` by directory pattern (`:53-54`). None of the new tests is registered in CI. Recorded as a follow-up on G-PKG; it does not retract what #111 delivers.

---

## 13. Decisions taken by the Release Manager (owner instruction 2026-11-21: *"khodet hamechio handle kon, montazere nazare man nabash"*)

The owner's ruling is that the standing mandate **is** full permission, and that the Release Manager must not queue routine questions. The three items I had listed as "owner decisions required" are resolved here. D7 (no publication without explicit approval) and D11 (no GUI launch) are the owner's own reserved rulings, so they are not mine to take — the way to honour them is to stop asking about them and remove them from the critical path instead.

| # | Question as I had posed it | Decision now | Consequence |
|---|---|---|---|
| DR-1 | When is the acceptance session? | **Not scheduled by me, and no longer a blocker on any engineering task.** The session is the last step of §10, not an input to it. | Everything that can be evidenced headlessly gets evidenced first; the session pack (§9) ships already written, so the owner's only job is to execute 8 steps. |
| DR-2 | May large runtimes/models be downloaded on the owner's Mac? | **No. CI and isolated scratch space only.** Applies to every member without asking again. | Model/runtime verification work must be designed to run in CI; on this machine only metadata reads (HEAD/API) and fixtures made of synthetic bytes are allowed. Recorded as a constraint, not a question. |
| DR-3 | Publication? | **Reserved by D7. The deliverable ends at a defensible RC + approval request.** | No further question about it until the RC exists. |
| DR-4 *(new, resolves G-BLD without a GUI exception)* | `build.sh` cannot run while the GUI ban holds, because `:229`/`:244` exec the built binary for `--selftest`. | **Do not request an exception. Add an explicit opt-out that only ever affects local runs: `RETOUCH_SKIP_SELFTEST=1` prints a loud "self-test SKIPPED — not for release use" line and continues. It must be *unset* everywhere CI and `release.yml` build, so the release path keeps executing the self-test.** | Unblocks bundle builds, DMG creation and bundle-level validation for the whole team, and cannot weaken CI. Acceptance test: with the flag set, `build.sh` completes without any `exec` of `Contents/MacOS/*`; with it unset, behaviour is byte-identical to today. |
| DR-5 *(new)* | sam2 stays download-refused while the runtime dependency is unresolved. | **Keep the refusal.** The entry is honest today (`unverifiableReason` explains why). Removing it is a consequence of DR-2 work landing, never a prerequisite for it. | Prevents the failure mode where the catalogue promises a model the shipped runtime cannot load. |
| DR-6 *(new)* | Merge order when several gates are green at once. | **#110 → #111 → #107 → #99 → integrity/licence PRs, with `develop` fast-forwarded after each.** Version bump to 2.0.0 happens only after #111 merges, because both touch `Resources/Info.plist`. | Avoids two branches rewriting the same plist — the exact coupling that produced past conflicts. |

No item above changes a licence position, a target platform, or any owner boundary. They are engineering calls, and they are made.

### Addendum C — 2026-11-21, authority scope confirmed by the owner

Owner: *"afarin, are to full authority dari roo kole proje, ke tamoomesh koni"* — full authority over the whole project until it is finished. Accepted. Practical consequence: every gate in this document is mine to close, every merge order and interface contract is mine to set, and no engineering question is queued to the owner again.

One boundary is **not** an engineering question and I am holding it deliberately, because the owner's own mandate §1 states it in his words: **no public release, publishing, uploading assets, retagging, deleting releases or modifying `v1.0.0` without explicit owner authorization.** "Full authority" over the project does not read as "publish now" — publication is the one irreversible, externally visible act, and it will be requested once, at the end, with the release candidate already built, validated and independently reviewed. Everything up to and including the RC is executed without further asking.

Two more items resolved under this authority, not asked:

- **DR-7 — Remaining open defect tickets are triaged against the release, not carried indefinitely.** The Wave-1 truthfulness fixes that touch `Localization.swift` / `PersianL10n.swift` (watermark wording, cancelled-batch wording, ICC wording, cold-Metal 1-LSB disclosure) are **sequenced after #99 merges**, because #99 owns those two files and parallel edits would overwrite each other. They are 2.0.0-relevant only insofar as they change what the product claims; each is re-checked against the ledger before the release notes are written, and any that stays NOT VERIFIED will simply not be claimed in them.
- **DR-8 — `develop` is a mirror, not a lane.** It is fast-forwarded to `main` after every merge and never receives its own commits; if it is ever found divergent, that is a defect to correct immediately.

### Addendum D — 2026-11-21, Windows evidence audit closes G-WIN (and corrects two of my own rows)

Source: `/private/tmp/rs-win-200/WINDOWS_READINESS.md` (read-only audit of `cd5741b76`; no build, no execution, no Windows desktop involved). I re-read the load-bearing claims myself and **two things changed**: one finding was more severe than I had recorded, and one was less.

**G-WIN is now much stronger than the ledger said — my earlier row understated CI.** Measured from the workflow and an inspected run:

| Fact | Status | Evidence |
|---|---|---|
| The Windows CI jobs build **and install, upgrade and uninstall the MSI**, and **run the app** with a window marker plus 14 UIA interaction passes | **VERIFIED** (hosted runner) | `.github/workflows/ci.yml:531-545` pins five app verdict lines, each `found:` line inspected in the log of run `44936922862` (job `136945472595`) |
| `WINDOWS HOST TESTS: PASS (396 checks)` | **VERIFIED as CI output** | same run. **NOT REPRODUCED statically** — counting `Check(` plus its loops gives 380, so the 396 figure is trusted only as far as the runner printed it |
| Portability suite verdict pinned | **VERIFIED** | `ci.yml:464-471` |
| Version sources agree | **VERIFIED** | `Windows/Directory.Build.props` `<Version>1.0.0</Version>` == `Resources/Info.plist`, forced by `Tools/check-versions.sh:22-37` |
| An actual Windows install has run on a real desktop | **NOT VERIFIED** | every artefact of Windows evidence is from a GitHub-hosted runner. Under mandate §8 this alone bars the words "ready" without qualification |

**The substantive product fact: Windows has no AI at all, and it fails closed.** All four catalogue entries are `macos-arm64`; the Windows host reports zero supported capabilities; every `job.submit` is refused with error `-32020` and a reason, over a real pipe, and there is no Python on Windows. That is the honest shape of "Windows first-class" for 2.0.0, and I am scoping the claim rather than blocking the release on it:

> **Decision (mine, under the owner's standing authority):** 2.0.0 ships Windows as a **first-class light editor** — WIC decode/encode, crop, orientation, nine global sliders, shared project files, history, MSI install/upgrade/uninstall — with **AI tools explicitly absent on Windows and refused with a stated reason**, not degraded silently. Any release note, README or About text that implies otherwise is a defect to fix, not a nuance to keep. Release-blocking gate G-WIN-CLAIM added below.

**Findings, with my own severity ruling after re-reading the code:**

| ID | Finding | My verdict | Basis |
|---|---|---|---|
| G-WIN-1 | The unsupported-edits guard names `lookID` but never `lookStrength` (`Windows/RetouchStudio.Core/Project/DocumentModel.cs:274`), so a document carrying a look grade with no id gets no prompt and silently drops the grade — while the guard's own comment (`:247`) promises "every other amount macOS writes is named here". | **Real invariant gap; severity LATENT, not live — downgraded from the audit's HIGH.** | `EditorModel.swift:657-664` (`setLook`) zeroes `lookStrength` when the look becomes `.none`, so the UI cannot produce the mismatched pair. Whether a crafted or legacy project file can arrive that way is being established on the fix branch before anything is claimed. One-clause fix + host tests, PR in flight (`w5-200-windows-look-guard`). |
| G-WIN-2 | The Windows package attributes only ONNX Runtime. Nothing in the package carries the app's own MIT text, the ~142 redistributed Swift runtime DLLs, or the .NET/WPF runtime. PR #111 excludes Windows by design. | **RELEASE-RELEVANT compliance gap.** | An MIT application redistributing Apache/BSD/MIT dependencies owes the notices; the macOS side now has them and the Windows side does not. Queued; must reuse the notice design the #111 review settles rather than inventing a second one. |
| G-WIN-3 | `README.md:47` states Windows "has no published artifact, installer…", "passes its 55 headless host checks" and "is **not** a shipping target" — all false today, and the last one contradicts the 2.0.0 claim it would sit next to. | **RELEASE-BLOCKING truthfulness defect.** | Understating a shipped capability is still a false claim, and it is in the first file a distributor reads. Fix must be a dated correction, matching the project's append-only style. |
| G-WIN-3b | The audit also flagged `Docs/RELEASING.md:187` as stale. | **REFUTED by me.** | That item already carries an inline dated correction (2026-11-15) stating that a zip and MSI are built on CI and that install/upgrade/uninstall ran in `43563787267`. The stale lead sentence survives *with* its correction attached, which is exactly the policy. No change needed; README is the one that lacks it. |
| G-WIN-4 | No Windows equivalent of `Tools/validate-bundle.sh`. | **Open, Medium.** | Packaging correctness is asserted by the installer succeeding, not by a content check. |
| G-WIN-5 | A tag-driven release has never published Windows; the one Release inspected skipped the Publish step. | **Open, informational.** | No 2.0.0 publication happens without owner approval anyway (D7). |
| G-WIN-6 | ONNX Runtime 1.32.0 is pinned and its nupkg is hash-refused on mismatch; MIT is **asserted, not independently verified**. | **NOT VERIFIED** | Cheap to close from the nupkg `LICENSE`; folded into G-WIN-2's evidence pass. |

## Addendum E — 2026-11-22 (four delegated results landed and integrated)

Append-only. §3/§5/§8/Addendum B-D above stay as written; where a row is now
dormant it is named in the delta table (E.7).

### E.1 #110 — the three mandate corrections landed; the reviewer's blocker did not

Engineer pass at head `c3bdced3338ff89b8ed4110a37f482c74c4e93c1` (commits
`468f61e`, `c3bdced`), CI run `44942178586` with all seven contexts success, PR
`MERGEABLE`/`CLEAN`, suite line `Tests/expected-worker-tests.txt` `188 → 190`.
Locally measured by him: `Ran 190 tests`, exit 0
(`/tmp/run-worker-final.log`).

The independent review of #110 came back **BLOCK**, but it was produced against
the previous head `c72a0f4` (the reviewer states this in his own
`git ls-remote` evidence). I reconciled the two reports myself rather than
trusting either:

```
git diff --name-only c72a0f4..c3bdced -- worker/tools/   → 0 files
git show c3bdced:worker/tools/lock_closure.py | grep -n google → 60:    "google": "protobuf",
git show c3bdced:Docs/WORKER_CI_VALIDATION_PLAN.md | grep -n continue-on-error
   → 11:`Worker Payload Bundle` remain `continue-on-error: true` and are not required
```

So of the reviewer's findings, **F2 is only half fixed** (the PR body is
correct, the sentence inside the repository doc is still wrong) and **F1 — the
main blocker — is untouched**: a top-level-name alias map means
`import google.auth` or `import google.cloud.storage` reports
`violations == []` / `resolved == {'google': 'protobuf'}`, so an unpinned
dependency escapes both the closure audit and the import smoke test. That is
exactly the escape the owner's criterion #1 asks to be *proven impossible*, so
**G-110 is NOT MET** and #110 stays unmerged. Re-dispatched with the
reproduction, plus F4 (`judge(1, CLEAN+GAP)` returns `[]`), F5 (a guard that
leaks through a nested `def`) and F6 (a wrong line citation). Merge order DR-6
is unchanged; everything downstream waits.

Reviewer findings that the Engineer's landed commits DO close: D5b
exit-status/test mismatch, missing broadened-`mflux` negatives, A4
resolver/Count-Divergence automation, and the append-only count addendum
(`Docs/W5_UPSCALER_ACCEPTANCE.md` §13, history untouched).

### E.2 #111 — independent verdict: MERGE AFTER FIXES

Head confirmed by `git ls-remote` as `407c6fd`; 9 files, +306/-7; all required
contexts green; zero reviews; `mergeStateStatus = CLEAN`. The reviewer
independently reproduced the tester's negative fixtures (`audit`/`validate`
exit 0 on `pin-unnamed.app`, `worker-notice-empty.app`, `one-font.app`,
`worker-no-lock.app`, and `validate-bundle.sh` exit 0 on
`upper-rights.app`), and confirmed `Tools/test-bundle-notices.sh` 7/7 and the
67/67 pin-name coverage. He also corrected one overstatement in the tester's
report: N6 defeats the *guard*, not the PR's literal wording.

Must-fix list before merge: **MF1** `Resources/THIRD_PARTY_NOTICES.txt:8` says
"this bundle contains **one** third-party component" while `build.sh:157-162`
copies the same file into helper-bearing builds; **MF2** `Docs/RELEASING.md:49`
and the PR body claim the audit "fails on any bundle file the notice does not
account for", which `audit-bundle-notices.sh:32-33,53-54` does not do; **MF3**
helper notice content is unmeasured (existence only, `:76-81`); **MF4** the
"notice names an absent component" rule only covers the whole-Vazirmatn case.

Severity ruling, mine: **none of the five N-cases corrupts the artefact 2.0.0
would ship today**, because `.github/workflows/release.yml:25,55` builds both
macOS jobs with `RETOUCH_SKIP_WORKER=1` — the shipping DMG is the light bundle,
which passes. They become release-blocking the moment a helper-bearing DMG is
published, and MF1 is a false statement in a shipped file in every local
helper build. Merge is still gated on MF1/MF2 because they are text defects,
not coverage debt.

Second, independent confirmation of **G-WIN-2**: `Windows/installer/Product.wxs`
has no licence/notice reference and `Tools/package-windows-msi.ps1:68` just
heats the publish folder, so the Windows MSI carries neither `LICENSE` nor the
OnnxRuntime attribution MIT requires. Not a #111 blocker; **a blocker for
publishing any Windows artefact**, which 2.0.0 intends to do.

### E.3 G-INT — the integrity defect is wider than the mandate states

`/private/tmp/rs-integrity-matrix/MATRIX.md`, measured at `cd5741b76`
(12 cases, `python3 matrix.py` exit 1 = 5 FAIL-OPEN, 2 NO-CODE-PATH). Beyond the
mandate's null-skip premise:

- Only **one of four** engine load paths hashes at all: `engine.py:882` uses
  `require_verified`, while `:936`, `:949`, `:969` use size-only `require`. A
  same-size tampered `migan` or `flux2` file is accepted **today** (cases 5, 10).
- `health()` reports all four models healthy when built from **zero files**.
- Case 2's fail-open is *pinned as intended behaviour* by
  `test_an_entry_without_a_recorded_digest_loads_on_size` — the fix must change
  an assertion, not just add ones.
- Malformed digests are not normalised: an uppercase pin permanently rejects a
  correct file.
- **New finding, not in the mandate:** `AIWorker.swift:573-592`
  (`workerEnvironment`) does not strip `RETOUCH_AI_EVAL_MODELS`, while
  `AIRuntimeValidation:211` does — an exported shell variable opens the
  `commercial_ok` licence gate in a real app→worker launch.
- The app/Swift side is already fail-closed for install/adopt/activate; the gap
  is worker-side. Hash cost measured: flux2 2.19 s / 4.6 GB, sam2 0.07 s,
  swin2sr 0.02 s, migan 0.01 s — so verify-once-and-cache, never per poll.

Implementation dispatched on `w5-200-integrity-failclosed` with the mandate's
nine rejections, the env-var strip, negative + positive automated tests, and
explicit preservation of optional-unavailable vs untrusted. Per §4 an
independent adversarial review of that diff is mandatory before it can be
counted.

### E.4 G-SAM2 — correction accepted, provenance measured, route decided

The Researcher verified my correction and recorded the root cause: his reading
was from `/Users/roham/RetouchStudio` at `40b157f` (2026-11-17), **38 commits
behind** `origin/main`, where the fields really are `null`. At `cd5741b76`
`Resources/model-catalog.json:76-77` carries `156008466` and
`7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69`, the same
digest is in `catalog.py`, and it is asserted by
`Tests/ModelStoreTests.swift:596` and `worker/tests/test_catalog.py:80`; it
reached `main` by merge `44647b0`. Dossier lines 38, 108, 257, 260, 262 are
superseded. **No digest contradiction is to be recorded:** the value at line 82
is the *entry-level manifest* digest, a different object from the file digest.

Provenance today: HF API (size + LFS sha256 + `apache-2.0` tag), Meta CDN
`HEAD` (200, `content-length: 156008466`, single-byte `Range` → 206), HF
`resolve` (`x-linked-etag: "7402e0d8…"`), and the installed copy all agree. The
CDN object's *content* hash remains **INFERRED** — its ETag
`2a9d5f6d…-19` is a 19-part multipart MD5, not a SHA-256 — and closing that
last leg costs one 156 MB download, which DR-2 keeps off this machine.

Runtime gate: `sam2` exists only as `facebookresearch/sam2` (no Meta wheel on
PyPI; the PyPI `sam2` project is an unaffiliated re-upload and must not be
used). All nine of its transitive requirements are already pinned, zero new
distributions, zero CUDA wheels, ~+0.5 MB payload, and the `_C` extension is
video-only so this app's path never imports it. **But** the lock tooling of
#110 rejects any `http/https/git+/file:` line and `--require-hashes` rejects an
unpinned git source, so a git pin cannot pass the gates we are hardening.

**DR-9 (my decision, no owner input needed):** integrate SAM 2.1 by vendoring
the ~0.38 MB package with an recorded checksum, not by a URL or git pin — the
vendor route is the only one that is simultaneously git-reproducible,
hash-compatible with `--require-hashes`, and free of third-party re-uploads.
Remaining open item is behavioural, not clerical: **NOT CONFIRMED** that sam2 1.0
runs under locked torch 2.15.0 on Python 3.13/MPS; that needs a real CI
execution, and `unverifiableReason` stays until then. Shipping without sam2
stays honest in the meantime (`engine.py:919-932` refuses `mask.click` with
`UNSUPPORTED`, `state: blocked`).

### E.5 Training-data terms — measured, and how they are recorded

Three register items closed from primary sources: **Places2** archived download
page requires "non-commercial research and educational purposes" and forbids
redistribution; **Swin2SR** README states the real-world x4 model was trained
mainly on DIV2K + Flickr2K and the DIV2K page says "academic research purpose
only"; **realesr-general-x4v3** is size-verified at 4,885,111 B from two sources
but publishes no author checksum (a mirror's sha256 is usable only as a
post-download cross-check). Per-checkpoint mix for Swin2SR stays NOT CONFIRMED.

**DR-10 (my decision):** the catalogue records these separately —
`weightsLicense` / `commercialOk` describe the *artefact's* grant by its rights
holder, and `datasetRestrictions` records what the authors trained on. Because a
research-only training mix is not something we can license away, `swin2sr-x4`
and `migan` keep `verdict: conditional` with the restriction text in
`noticeText`, and are **never** written up as unconditionally commercially
approved. This is the mandate's "do not silently convert" rule made concrete,
and it is the honest position: the artifact licence says Apache-2.0/MIT, the
dataset terms say otherwise, both go in the record.

### E.6 G-WIN-1 — closed by measurement at Low, not High

PR **#113**, head verified by `git ls-remote` as
`0caf9a739d791032d4bf9fa5be2d8dbc37803634`; `Windows App` job
`136970631752` reports `WINDOWS HOST TESTS: PASS (401 checks)` — exactly 396 + 5
new — plus `WINDOWS APP BUILD: PASS`; `macOS Integration` was still pending at
the time of writing, so #113 is `BLOCKED` and unmerged. Fix:
`DocumentModel.cs:274` now reads
`if (ReadAdjustmentString("lookID") is { Length: > 0 } || AnyAmount("lookStrength"))`.

The implementer's reachability measurement moved my severity from LATENT to
**Low**: `lookStrength` is decoded with no cross-field clamp
(`Sources/StudioCore/Adjustments.swift:855-856`), `SelfCheck.swift:549` is
presets-only, and conformance only range-checks the value — so the mismatch is
real — but it is reachable only from a crafted or externally written project
file. The strength slider *is* live with no look selected
(`InspectorView.swift:501-505`), yet `LookEngine.swift:321` returns the image
untouched for `.none`, so macOS drops no pixels either. The defect is the
guard's overclaimed invariant comment, not user-visible data loss. `dotnet` is
absent on this machine, so CI is the only compile evidence — recorded as such.

### E.7 Status deltas (the table rows above keep their text; these are current)

| Gate | Was | Now |
|---|---|---|
| G-110 | corrections requested | **NOT MET** — landed at `c3bdced`, but reviewer F1 escape still in `worker/tools/lock_closure.py:60` and `WORKER_CI_VALIDATION_PLAN.md:11`; merge order DR-6 holds everything behind it. |
| G-PKG (#111) | tester PARTIAL FAIL | **MERGE AFTER FIXES** — MF1/MF2 are text defects; N-cases confirmed not to affect today's light DMG (`release.yml:25,55`). |
| G-INT | matrix requested | **Matrix delivered, implementation in flight**, defect confirmed wider (3 of 4 load paths never hash) + `RETOUCH_AI_EVAL_MODELS` env leak. Adversarial review still owed. |
| G-CAT | fields proposed | implementation in flight (`w5-200-licence-evidence`). |
| G-SAM2 | pin missing (dossier) | **Pin present and 4-way corroborated**; route decided DR-9; runtime compatibility NOT CONFIRMED; `unverifiableReason` stays. |
| G-WIN-1 | LATENT, fix in flight | **Low, fixed as #113** (401 host checks); `macOS Integration` pending, not merged. |
| G-WIN-2 | open | **confirmed independently**; blocker for publishing a Windows artefact, not for #111. |
| G-UPD | VERIFIED (config) / NOT VERIFIED (UI) | independent design review now running (§6 permits it because the reviewer is free); cannot block 2.0.0. Inertness re-confirmed at `c3bdced`: `RSUpdateFeedURL` appears only in `UpdateController.swift:156-162`, never in `Resources/Info.plist`. |

Nothing in this addendum was published, tagged, merged or deployed, and
`/Users/roham/RetouchStudio` was not modified.

### E.8 Correction to E.7 (2026-11-22, same day) — the updater design review did not happen

The G-UPD row above says "independent design review now running". That was wrong
and is retracted: the host confirmed the reviewer's session had already died
before submitting, and its report never arrived. So for 2.0.0 the updater's
**independent design review of `Docs/UPDATE_SYSTEM.md` is NOT DONE**, and the
only evidence backing G-UPD is my own measurement, restated with its limit:
`git grep -n RSUpdateFeedURL c3bdced` matches only
`Sources/RetouchStudio/Core/UpdateController.swift:156-162` (the comment plus
the two read sites) and never `Resources/Info.plist`, therefore no feed is
configured — but the claim that no code path can reach a user-writable location
that a local attacker could poison with no feed configured remains **NOT
VERIFIED**, because the reviewer's half of that question died with the session.
Per mandate §6 this cannot block 2.0.0; the updater ships disabled and the
subsystem stays unaudited-but-inert-by-configuration, which is what the row
should have said.

Two consequences of the same incident, recorded so nobody repeats my inference
error:

1. **Review counts are not a liveness signal.** `gh pr view <n> --json reviews`
   hides PENDING reviews, so an empty list proves nobody *submitted*, never that
   nobody started — and conversely a pending review that dies is silently
   discarded. Measured now: PR #110 shows zero submitted reviews at head
   `c3bdced`. Liveness is tracked from branch heads and diffs only.
2. Two merged gates in the shipping path have **never had an independent read**:
   the runtime package gate (PR #85 @ `71881f7`) and AI jobs retention/locking
   (PR #84 @ `48bb3db`). A read-only review of both is now running, asked for a
   yes/no with the deciding line on "is the runtime 2.0.0 executes
   integrity-sealed on the shipping path?" This is the same family as the open
   runtime-integrity-seal ticket, and it is the last unreviewed piece of the
   download→verify→execute chain.

Reconciliation snapshot at the time of writing (`git ls-remote` / `gh pr list`):
`main` still `cd5741b76`; `w5-worker-gates-failclosed` still `c3bdced` (the
#110 fixer has not pushed yet); open PRs 113 `0caf9a7`, 112 `67a21f3`, 111
`407c6fd`, 110 `c3bdced`, 107 `2c95eb7`, 102 `e361772`, 99 `277cf50`.
PR #113's `macOS Integration` context was still `pending`, so #113 remains
`BLOCKED` and its 401-check Windows result stands only on the `Windows App` job.

## Addendum F — 2026-11-22: one report refuted, one preserved, one loss prevented

Append-only. Addendum E stands except where this addendum names a row.

### F.1 PR #110 — a second review report contradicted the artefacts, so the artefacts won

The reviewer returned a follow-up asserting that F1 and F2 were already fixed at
HEAD by commit `062f99a`, that the head was `0f5e64f`, that CI run `44942178587`
showed `macOS Integration` **failing** with `Ran 191 tests … (failures=1)`, and
that my own "`0 files` under `worker/tools/`" measurement in E.1 was wrong. I
re-ran everything myself:

```
git ls-remote origin refs/heads/w5-worker-gates-failclosed → c3bdced…  (unchanged)
git rev-parse pr/110                                       → c3bdced…
git cat-file -e {062f99a,e4d81f7,5248764,0f5e64f}           → NOT FOUND (none exist)
gh run view 44942178587                                    → HTTP 404 (does not exist)
gh run view 44942178586                                    → head c3bdced, success, 7 jobs
git diff --name-only c72a0f4..c3bdced                      → 4 files, none under worker/tools/
git show c3bdced:Docs/WORKER_CI_VALIDATION_PLAN.md (lines 10-11)
   "Nothing here changes branch protection. `Worker Lock Closure` and
    `Worker Payload Bundle` remain `continue-on-error: true` and are not required
    contexts"
```

So E.1 stands unchanged: **F1 (the top-level-alias escape) and F2 (that sentence)
are both still live**, the run id is `44942178586`, and nothing was merged or
pushed by the fixer at the time of writing. The fixer's pass that I dispatched on
those findings is the right work, not a duplicate.

Two things from that report were nevertheless useful, and one of them corrects
*me*:

1. **Refuted, no work item:** the claim that `from a.b.c import d` is mis-bound by
   the AST collector. At this head `worker/tools/lock_closure.py:219-224`
   (`visit_ImportFrom`) records both `node.module` **and** `f"{node.module}.{alias.name}"`,
   keyed at the top level, so both import forms are already collected.
2. **My error, recorded:** the head sha `0f5e64f` in my dispatch briefs came from
   my own unverified notes and **does not exist in this repository**. I passed it
   to a reviewer as fact and he reasoned from it. New rule, effective now: every
   sha, run id or PR number in a brief must come from a command I ran in that same
   turn, and every review must open with `git ls-remote` output plus
   `git diff --stat base..head` or its status claims are discarded unread. This is
   the third time this week that a member's *history* narrative failed against a
   `git` command; the *reproductions* in the same reports held up, which is the
   distinction worth keeping.
3. **Boundary re-verified:** `/Users/roham/RetouchStudio` is still `40b157f` with
   exactly the same three pre-existing owner paths
   (`CompareCanvas.swift`, `Tests/ModelTests.swift` modified, `ToastPlacement.swift`
   untracked). Nobody has written to it.

### F.2 G-UPD — design review delivered, but two of its six findings are inventions

The independent read of the updater transaction design came back **ACCEPT WITH
CHANGES** with must-change items U-0…U-5. Two of its headline claims are false
against the code, and I checked the code rather than accepting them:

- "**The feed can be re-enabled by `UserDefaults` / `RSUpdateFeedOverride`, so
  inertness is by absence, not construction.**" There is no such key anywhere in
  the repository. `UpdateController.feedURLs` (`:160-166`) reads **only**
  `Bundle.main.infoDictionary`, and `Resources/Info.plist` sets neither feed key —
  so E.7's inertness statement stands, with its original scope: the shipped build
  cannot be steered to a feed by any input I can find.
- "**Recovery is exposed as a CLI command `--recover-verification <path>`**"
  (which his U-1(b) then used to argue that a v2 journal could be pushed through a
  v1 build). No such flag exists in `Sources`, and `Sources/RetouchStudio/main.swift`
  is not a file in this tree. Recovery is reached on a plain launch through
  `App.swift:38-41` → `offerRecoveryIfNeeded()`, exactly as previously recorded.

The remaining items (U-0 the doc's silence on where the feed comes from, U-1(a)
v1/v2 journal inertness — which he established with a real compiled decode probe,
U-2 a dead cleanup branch at one state, U-3 a missing journal field, U-4 cancel
windows, U-5 an over-broad refuse-launch clause) are **plausible reviewer opinion
about a design document** and stay open as such; they are not release gates
because nothing in them is implemented and the updater ships disabled. Task #111
therefore remains **open**: I do not accept a design review whose factual base
included two invented mechanisms.

**Prevented loss:** that design existed **only** in an ephemeral temp directory and
on no branch — one `rm -rf /tmp` from permanent deletion, which would have voided
mandate §6's "preserve the existing design-only work". It is now
`Docs/UPDATER_TRANSACTION_DESIGN.md`, imported verbatim under a provenance banner
that marks it design-only, records the two refuted claims, and states plainly that
no part of it is implemented.

### F.3 Gate deltas from this addendum

| Gate | Now |
|---|---|
| G-110 | **NOT MET, unchanged** — F1/F2 confirmed live by re-measurement; fixer's pass in flight; #110 stays open and unmerged. |
| G-UPD | **INERT BY CONFIGURATION — confirmed by a second reader's failure to find any other input**; design review incomplete, task open; no release impact because the updater is off (D6/§6). |
| G-RTP (new) | **Open, in review** — the runtime package gate (PR #85 @ `71881f7`) and AI jobs retention/`.lock` sweeping (PR #84 @ `48bb3db`) have never been independently read; a read-only review is running and owns the yes/no on "is the runtime 2.0.0 executes integrity-sealed on the shipping path?", which is the same family as the open runtime-integrity-seal ticket. |

`main` is still `cd5741b76`; `develop` is untouched; nothing published, tagged,
merged or deployed by this addendum.

## Addendum G — 2026-11-22: #110 blocker closed by the author, and two PRs waiting on CI

### G.1 #110 at head `07095d3` — my own re-measurement

```
git ls-remote origin refs/heads/w5-worker-gates-failclosed → 07095d3…
git log --oneline c3bdced..07095d3 → 07095d3 "Stop a shared namespace and a
                definition guard from hiding an import"
```

Both items I confirmed open in E.1/F.1 are addressed, and I read the fix rather
than accepting the report:

- **F1 (the escape).** `worker/tools/lock_closure.py` keeps
  `ALIASES["google"] = "protobuf"` (:60) but adds
  `ALIAS_PREFIXES = {"google": ("google.protobuf",)}` (:69) and a resolver
  (:97-108) that applies an alias **only when every dotted name belongs to that
  distribution's module tree** — the code comment states the rule exactly as the
  reviewer framed it: `import google.protobuf` is protobuf, `import google.auth`
  is an unpinned distribution.
- **F2 (the false sentence).** `Docs/WORKER_CI_VALIDATION_PLAN.md:9-13` now reads
  "Neither worker job is a required context. `Worker Lock Closure` carries no
  `continue-on-error`, so its failure still marks the run red; only `Worker
  Payload Bundle` uses `continue-on-error: true`." That is what the workflow
  actually does, and no key was added to the closure job.
- **F5** (a nested `def` inheriting an `except ImportError` guard) is in the same
  commit's scope, and the single-source count moved `190 → 194` for the new tests.

CI at `07095d3` (run `44947620477`): StudioCore Boundary, Platform-neutral
Conformance, Windows StudioCore, Worker Lock Closure, Worker Payload Bundle and
CodeQL **pass**; **`macOS Integration` and `Windows App` were pending** when I
looked, so **#110 is not yet mergeable evidence** and DR-6 keeps everything
behind it. An independent re-review of the full diff at this head is running
against the reporting discipline introduced in F.1 (open with `ls-remote` +
`diff --stat`, no unreproduced identifiers), with explicit instructions to hunt
sibling escapes of the namespace-alias class — `from google import auth`,
aliases whose submodule is not in the distribution's tree, and any drift between
`lock_closure.py`'s and `import_smoke.py`'s alias handling, since the mandate's
criterion is that an unpinned import escape **neither** check.

### G.2 G-CAT delivered PR #114, but its author session stopped before a safety question was answered

`w5-200-licence-evidence` @ `2656db1`, PR **#114** "record weights-licence
evidence (G-CAT) — data layer only, no behaviour change". Files touched:
`Resources/model-catalog.json`, `Sources/RetouchStudio/Models/ModelCatalog.swift`,
`Tests/ModelStoreTests.swift`, `worker/retouch_ai_worker/catalog.py`, plus
`Docs/MODEL_LICENCE_EVIDENCE.md` and a `Docs/licence-evidence-apply.py`. CI at
the time of writing: Boundary / Conformance / Lock Closure pass, **macOS
Integration, Windows App, Windows StudioCore and Payload Bundle still pending**
(run `44948419985`).

The implementing session then hit its turn ceiling **while asking the one question
that matters here**: whether anything else in the repository reads
`ModelCatalogEntry`'s Codable shape in a way a hand-written `init(from:)` could
disturb. That question is **unanswered**, and this project already has a
documented wire-compatibility constraint (the v3 format uses unkeyed arrays, v4 is
file-only, nested unknown fields are not preserved) plus strict decoding at
`ModelCatalog.swift:37`. Two consequences, both mine to enforce, not the author's:

1. **#114 must not merge on a green check alone.** Its independent review must
   prove that adding the licence-evidence fields cannot change how an existing
   catalogue decodes on either side (Swift and Python), that an older app build
   still reads a new catalogue and vice versa, and that a hand-written
   `init(from:)` did not silently drop or reorder a keyed/unkeyed field.
2. `Docs/licence-evidence-apply.py` is a script that writes catalogue content; its
   review must establish whether the catalogue is regenerated deterministically
   and whether the golden-corpus protection rules were respected (no baseline
   regeneration, no rewritten tracked exports).

The separate **evidence** question — is each recorded licence verdict actually
supported by a primary source, and are code licence, weight licence and
training-data terms kept apart — is queued as its own assignment and is not
covered by a code review of #114.

## Addendum H — 2026-11-22: the §4 integrity implementation was one `rm -rf /tmp` from deletion

The mandate §4 workstream (fail-closed model integrity) reached its turn ceiling
with **1117 lines uncommitted** on a local branch in `/private/tmp/rs-int-200`, no
commit, no branch pushed, no PR. I made a verbatim salvage commit
(`d142257`, message records that it is unrevised salvage, not a verified change)
and dispatched a continuation that is instructed to commit and push incrementally
and to open a draft PR as soon as the tree is coherent.

What the salvage contains, read by me rather than accepted from the report:

- `worker/retouch_ai_worker/catalog.py`: `normalize_digest`, `pin_problem`,
  `_pins_of`, `_pin_data`, `_require_licensed`, `_resolve_under_lease`,
  `_verify_digests` and rewritten `require` / `require_verified` — i.e. the
  admission-time pin validation plus digest normalisation that E.3 asked for, and
  a `_generation()` counter whose invalidation guarantees the continuation must
  prove (a verification cache that cannot survive a replaced file is worthless).
- `Sources/RetouchStudio/Core/AIWorker.swift`: `environment.removeValue(forKey:
  "RETOUCH_AI_EVAL_MODELS")`, closing the licence-gate leak E.3 found — the
  research switch stays deliberately settable on the worker's own command line, it
  is just no longer inheritable from a user's login environment.
- Test files already extended: `test_catalog` (+459), `test_engine` (+143),
  `test_server` (+143), `test_capabilities` (+67), `test_upscale` (+4).

What is **not** there: the session's own last words were *"now add the server-level
(RPC) coverage for the new taxonomy and the kind-only path"*, so the new
rejections are not yet proven to surface as intended RPC error kinds end to end,
the single-source suite count is unreconciled, nothing has been run to my
knowledge, and no independent adversarial review exists — which mandate §4 requires
explicitly before this can count as done. Status stays **NOT VERIFIED**, and DR-6
keeps G-RC behind it.

Process finding, recorded against me and not against the member: two implementation
sessions hit the same ceiling on the same night, and in the first case (G-CAT, F
§G.2) the loss was only an unanswered question while here it was 1117 unsaved
lines. My briefs asked for a final push but never for incremental commits.
Every implementation brief from now on carries commit/push checkpoints and a draft
PR as a deliverable in its own right, and salvage-from-temp-dir is a known failure
mode of this workflow, not a surprise.

## Addendum I — 2026-11-22: the #110 re-review is sound, and it found a regression I reproduced myself

The re-review arrived under the new reporting discipline (it opened with
`git ls-remote` and `git diff --stat`, and pinned itself to the head it actually
reviewed). That immediately mattered: the branch had moved again while the review
ran. **`w5-worker-gates-failclosed` is now `cc1d9f64347fe07e3fa6131a281b7fa3cc9ce86f`**
(`cc1d9f6 "Judge a namespace alias by its dotted names"`), one commit past the
`07095d3` my brief named — the author's session is still landing work, so the
reviewed object was real and current, and the mismatch is my scheduling error, not
his. CI at `cc1d9f6` is run `44948957776`: Boundary, Conformance, Windows
StudioCore, Worker Lock Closure, Worker Payload Bundle and CodeQL pass; **`macOS
Integration` and `Windows App` — both required — were pending**, `mergeStateStatus
= BLOCKED`.

### I.1 The blocker, reproduced by me (not inherited)

`cc1d9f6` closed the original escape but **introduced a sibling one of the same
class, and this one defeats both gates at once.** Calling the shipped resolver
directly at `cc1d9f6`:

```
names=['google']                              -> google            (violation, correct)
names=['google','google.auth']                -> google            (violation, correct)
names=['google.protobuf']                     -> protobuf          (correct)
names=['google','google.protobuf']            -> protobuf   <-- used by BOTH the
                                                          legitimate and the escaping form
names=['google','google._upb._message']       -> google   (false positive: protobuf ships _upb)
```

`worker/tools/lock_closure.py:109` reads `dotted = {name for name in names if
name != module}`, so the bare namespace name is discarded whenever any dotted name
is present. `import google.protobuf` alongside `mod = __import__('google')`
therefore resolves to `protobuf`, is pinned, and produces **zero violations** —
while `import_smoke.py:128` calls the *same* `lock_closure.distribution_for`, so
the payload gate agrees and even executes `importlib.import_module('google')`,
which succeeds because the `google` namespace is importable once protobuf is
installed. The mandate's criterion is that an unpinned import cannot escape
**both** checks; at this head it can. And `07095d3` did fail closed on this shape,
so the newest commit is a **net weakening** relative to its own parent.

The root cause is representational: the collector flattens everything into one set
of names, so `from google import protobuf` (forgivable bare name) and
`import google` / `__import__('google')` (unpinned namespace use) are literally
indistinguishable. Forgiving the bare name to kill the false positive therefore
cannot be done on the flat set — the fix has to record provenance (was the bare
name the `module` of an `ImportFrom` that bound a prefixed name, or was it imported
or fetched directly?). I adopt that as the required shape of the fix, plus P11/P12
as permanent seedings in both tools' test files, and a deliberate decision on
`google._upb` rather than an accidental one.

### I.2 Two mandate-level gaps this review exposed

1. **The adversarial matrix was never committed.** `Docs/WORKER_CI_VALIDATION_PLAN.md:3-4`
   cites seed ids (B1–B4, A1, AC-\*, D1–D5, E3) and the tests echo those labels in
   docstrings, but no table maps seed → test → expected exit → expected problem
   count anywhere in the tree. Mandate correction (2) asked to align the matrix with
   the tests; alignment was verified by reconstruction from docstrings, which is not
   a durable artefact. #110 must commit the table.
2. **The worker suite is not hermetic about its own test lock.** Six test modules
   import numpy/Pillow at module scope, so on a bare interpreter `Tests/run-worker.sh`
   fails as a *count* mismatch (`92 != 194`) rather than naming the missing
   dependency. Fail-closed direction is right; the diagnosis misleads the next
   reader. Separate small ticket, not a #110 blocker.

### I.3 Environment state change to disclose

To run the suite at all, the reviewer installed `numpy 2.5.5` and `pillow 13.0.0`
into the shared scratch interpreter `/private/tmp/rs-worker-venv` (it arrived with
only pip/wheel). That venv now satisfies `requirements-test.lock` **approximately**
(numpy 2.5.5 vs the pinned 2.5.4). Consequence for this release record: any suite
result quoted from it is real but not lock-exact, and from now on every reported
run must name its interpreter and the two dependency versions. Rebuilding the venv
is not worth the loss of the only working local runner; the imprecision is recorded
instead of hidden.

### I.4 Verdict and effect on the plan

**#110 = BLOCK**, by independent review **and** by my own reproduction: I.1 must
land before merge, together with the docstring/comment/code disagreement at
`lock_closure.py:96-100` vs `:104-108` and the matrix table. The three mandate
corrections themselves are otherwise confirmed landed (the `continue-on-error`
prose is now accurate and corroborated against branch protection's five required
contexts; D5b, broadened-`mflux`, A4 and count-divergence are genuinely automated;
the count history is append-only with `188 → 190 → 194` and no rewritten number).
Nothing got weaker except I.1. `main` is unchanged; DR-6 still holds, so #111, #107,
#99, G-INT and G-RC remain sequenced behind a now-longer #110.

Process note against me, second one the same day: I dispatched a review against a
branch whose author was still pushing. A review must be pinned to a frozen head —
either wait for the author's session to finish or state explicitly that the object
is a moving branch and require the reviewer to re-pin and re-run anything that
changes.

## Addendum J — 2026-11-22: the runtime-integrity question answered, and a toolchain fact that changes how the RC must be built

### J.1 G-RTP — is the runtime that 2.0.0 executes integrity-sealed? **No — by design, and it is refused rather than trusted**

Deciding line, read by me at `cd5741b76`:

```
Sources/RetouchStudio/Core/AIRuntime.swift:40
    static var package: Package? { nil }
    // "No official protocol-v2 runtime has been published. Fabricating its
    //  metadata would enable a download the app cannot verify, so this stays
    //  nil and the UI reports the runtime as unavailable."
```

The only cryptographic seal in the pipeline is `AIRuntimeTransaction.verifyArchive`
(`:1095-1106`, size then SHA-256 of the whole archive) and it is guarded by
`if let package` (`:210-212`), so with `package == nil` it is never reached — and
**nothing anywhere in the repository ever verifies a signature over the installed
runtime tree**; the archive hash seals bytes in transit, not the adopted directory.
The companion sentence matters just as much for the release claim: with
`package == nil`, download is refused (`AIWorker.swift:928-930`, `:485`), the UI
reports the runtime unavailable, the shipping DMG is built with
`RETOUCH_SKIP_WORKER=1` (`release.yml:25,55`) and contains no helper, and every
adoption/recovery path re-runs the functional contract before committing
(`AIRuntimeTransaction.swift:875-877` with `runtimeIsValid` →
`AIRuntimeValidation.functional`). So the exposure is **a feature that is off, not
a gate that is open** — which is the accurate 2.0.0 statement.

Three inherited "fail-open" claims about this chain are **refuted**, continuing the
pattern where such claims collapse under a second reader: adoption cannot run an
unverified tree (A3a); there are no CI *signing* checks at all to fail open, and the
verdict assertions that do exist fail closed under `set -euo pipefail` plus an
explicit anti-skip guard (`ci.yml:176`, `:181-187`) (A3c); the `verifyArchive` nil
guard is latent and dead-by-construction once reachable, because the caller already
checks the same digest (`AIRuntimeInstaller.swift:281-303`) (A3b).

### J.2 New real finding: extraction does not contain the archive's own contents

**A6 (Medium, dormant behind the same nil).** Extraction is `/usr/bin/ditto -x -k`
(`AIRuntime.swift:137-158`, args at `:140`) with **no** `--noqtn` and no content
walk. Measured on synthetic archives: ditto reproduces `escape ->
../../../escape_target` and `abs_escape -> /etc` verbatim (exit 0); a `..`-prefixed
*member name* stays contained only because ditto strips leading `/` and re-roots it.
Post-extraction validation (`AIRuntimeValidation.swift:84-121`) checks presence and
executability of a few paths plus symlink-ness at the root only; containment
rejection exists for transaction *directory names*
(`AIRuntimeTransaction.swift:1059-1071`), never for archive *contents*. Required
sequencing decision, mine: **walk-and-refuse on extracted contents must land before
`AIRuntime.Package` is ever given a value**, so whichever change turns the runtime
on inherits a closed gate instead of adding one. Same pass should also fix the
quarantine propagation (`--noqtn`), which is the already-known `#94`/`#107` finding
and is a different property from integrity — the two must not be conflated.

Four smaller items from the same review, ticketed not blocking: **A4** `ci.yml:164-175`
never asserts `MASK QUALITY TESTS: PASS` or `ABI TESTS: PASS` although
`Docs/CI_GATES.md:52-54` says macOS Integration asserts each suite's PASS line, so
deleting either suite keeps CI green; **A2** no check couples a capability's declared
`Spec.packages` to the lock, so `mask.click` could name a package that never ships
(and `import_smoke.py:14` deliberately excludes `sam2`, so this must be a
set-membership assertion, not an import probe); **B1b** the jobs sweep runs only at
launch, disclosed at `Docs/AI_RUNTIME.md:149-156`; **B3b** the acceptance tool
re-declares `.lock` as its own literal instead of importing `server.JOB_LOCK_NAME`.
Retention/locking itself is sound because the claim is a kernel-scoped `flock` on a
descriptor, not a pid or timestamp record — so there is no pid-reuse, boot-time,
clock-skew or host-rename case for the lock, and a crash releases it (measured with a
real child process, `Ran 1 test`, OK).

### J.3 Toolchain reality: this Mac cannot build the app, so the RC must be built on CI

`xcode-select -p` → `/Library/Developer/CommandLineTools`; `swiftc --version` →
Apple Swift 6.4.2; **no `/Applications/Xcode*.app` exists**, and therefore no
`SwiftUIMacros` plugin. Any `@State`-using SwiftUI source cannot be compiled here, so
`Tests/run.sh`-style Swift suites and `build.sh` are both impossible locally — the
same wall the reviewer hit (`error: external macro implementation type
'SwiftUIMacros.StateMacro' could not be found`).

**DR-11 (my decision).** The 2.0.0 release candidate is **built and validated on a
GitHub macOS runner**, not on this machine: GitHub's macOS images carry full Xcode,
`release.yml` already calls `build.sh` (`:38,68`), the version stamping exists
(`build.sh:110-114`, `Tools/check-versions.sh`), and a CI-produced artefact with
CI-computed SHA-256s is better release evidence than a laptop build in any case. Two
consequences recorded honestly: **DR-4's premise is dissolved** — a
`RETOUCH_SKIP_SELFTEST` flag would not unblock anything locally, because the local
build fails long before the self-test; it stays a nicety, not a gate. And every
Swift-side claim in this ledger that says NOT VERIFIED is now explained rather than
merely unproven: it could not have been run here.

### J.4 Runner note

The shared scratch interpreter `/private/tmp/rs-worker-venv` has only pip/wheel, so
six worker test modules fail there with `ModuleNotFoundError` and the suite
misreports it as a count mismatch. A lock-exact runner now exists at
`/private/tmp/rs-rev-gates-venv` (built with `requirements-test.lock
--require-hashes`, all 166 worker tests OK) but it is **Python 3.15.0**, while the
locks target 3.13 — results from it are genuine, and their interpreter version must
be named in every future report.

## Addendum K — 2026-11-22: the integrity gate survives its second near-loss, and two precedence defects are now named

### K.1 State of G-INT, measured rather than reported

The continuation session again stopped with a dirty tree. Salvaged as checkpoint
`0eba5ce` on `w5-200-integrity-failclosed` (5 files, +522/−127), on top of `e901ab8`
and the earlier `d142257`. Against `cd5741b` the branch is now 9 files, +1125/−90
plus that checkpoint. Nothing was lost this time because the checkpoint was committed
before it was analysed.

Real measured state, one command, lock-exact interpreter
(`/private/tmp/rs-rev-gates-venv/bin/python3`, Python **3.15.0** — the locks target
3.13, so this is genuine but off-version evidence):

```
RETOUCH_WORKER_PYTHON=/private/tmp/rs-rev-gates-venv/bin/python3 ./Tests/run-worker.sh
Ran 214 tests ... FAILED (failures=2)
```

The suite grew 166 → 214. Two failures, both in `test_server.py`, both **diagnostic
precedence** defects, not crashes:

| test | currently answers | must answer |
|---|---|---|
| `test_a_named_capability_still_answers_UNSUPPORTED_for_a_bad_pin` | `UNKNOWN_MODEL` (-32016) | `UNSUPPORTED` (-32020), `state = blocked` |
| `test_an_uncleared_model_refuses_the_kind_only_job_before_any_integrity` | `LICENSE_BLOCKED` (-32010) | `CATALOG_INVALID` (-32021), `reason = missing-digest` |

The first is the more serious of the two in product terms: the same process lists that
capability as *blocked* with a "no recorded SHA-256" reason while refusing a job that
names it as *unknown model*. A host that believes "unknown" can offer a download that
repairs nothing, which is exactly the class of false promise §4 exists to remove. The
second is the research switch leaking further than it should: `allow_uncleared` clears
the licence question and must never clear the integrity question.

Both tests encode the intended contract, so the implementation moves and the
assertions do not. Status of G-INT stays **in progress**; the head is not mergeable
and says so in its own commit message.

### K.2 DR-12 — the integrity branch rebases onto `main` after #110, for one reason

`ci.yml:164` hard-pins the worker suite size as the literal `Ran 166 tests`, and PR #110
replaces those literals with `Tests/expected-worker-tests.txt`. That file does not
exist on this branch's base, so an integrity PR opened now would have to edit the five
hand-pinned places that #110 deletes, guaranteeing a conflict on the one line that
decides whether macOS Integration goes green. Ordering is therefore: **#110 lands → this
branch rebases → the suite size becomes a one-line edit in a single file.** No other
workstream changes order because of this.

### K.3 Mapping Addendum J's findings onto existing tickets, and one new one

Not re-ticketed: **A6** (extraction does not walk archive contents) is already tracked as
the S3-security containment ticket, now with the sequencing rule attached — it must land
before `AIRuntime.Package` ever takes a value. **A4** (`MASK QUALITY TESTS` /
`ABI TESTS` asserted in `Docs/CI_GATES.md` but not in `ci.yml:164-175`) is already
tracked as the CI-honesty ticket. **B1b** (jobs sweep runs only at launch) is a
disclosed limitation in `Docs/AI_RUNTIME.md`, not a defect. New ticket opened for
**A2**: nothing couples a capability's declared `Spec.packages` to the lock, so a
capability can advertise a package the shipped payload cannot import — and because
`import_smoke.py:14` deliberately excludes `sam2`, the check has to be set membership
against the lock, not an import probe.

### K.4 Team tooling limitation encountered while dispatching

Re-dispatching the integrity fix to the team's implementation member through the team
delegation tool now fails with `COLLABORATION_MCP_TEAM_LEADER_REQUIRED` on every
attempt, including an empty check-only dispatch, which means the leader binding was not
re-established after this session was resumed. No team-member entry point was used as a
substitute. The work went forward as a local background workstream with the same
brief, so progress is unaffected; but **team-member delegation is currently unavailable
to me**, and independent review requests (the queued licence-evidence and #114 reviews)
stay parked until that binding is restored or I reproduce their evidence myself.

## Addendum L — 2026-11-22: four workstreams land; the worker gates are review-ready, the integrity gate gained a host-side hole

### L.1 PR #110 — my own verification at the final head, not the implementer's report

Head `cc1d9f6`, verified by test merge and direct read rather than by claim:

| claim | my measurement |
|---|---|
| dependency pins untouched | `git diff --stat cd5741b..cc1d9f6 -- worker/requirements.lock worker/requirements-test.lock` → **empty** |
| single suite-count source | `git show cc1d9f6:Tests/expected-worker-tests.txt` → `194` |
| CI green at this head | run `44948957776`, `headSha cc1d9f6`, `conclusion success`, **all seven jobs** success (I read the run object, not the badge) |
| independent review exists | `gh pr view 110` → `reviews = 0`, `reviewDecision` empty — **the §7 gate is still unmet** |

The contested point from Addendum I is now **adjudicated in the implementer's favour, on evidence**. Re-running the real tool at `cc1d9f6` under the lock-exact interpreter (Python **3.13.15**, `/private/tmp/rs-worker-venv2`), after clearing `__pycache__`:

```
['google','google.protobuf']              -> protobuf     (legitimate alias use)
['google','google.auth']                  -> google       (unpinned -> refused)
['google','google._upb._message']         -> google       (unpinned -> refused)
['google']                                -> google       (bare namespace -> refused)
['google','google.protobuf','google.auth'] -> google      (mixed -> refused, no escape hatch)
```

So the escape direction is genuinely shut in both forms: a `google.*` subpackage that no pin provides cannot borrow protobuf's identity, and mixing one legitimate with one unpinned import refuses rather than resolves. My Addendum I reading of `google._upb` as a *false positive* was right about the behaviour and wrong about the severity: the docstring at this head states the rule as it actually behaves — "any other `google.*` import falls back to the canonical top-level name and is reported as unpinned" — the failure is in the safe direction, and no shipped code imports `google._upb`. Conservative-by-design, documented, therefore not a defect. Merges remain gated on the independent verdict, which is now requested against this frozen head.

### L.2 G-INT — the two precedence defects are closed, and the review found me a worse one

Branch `w5-200-integrity-failclosed`, draft **PR #115** @ `65b7d13`. Implementer's diagnosis, which I checked structurally: there was no ordering bug — there were **two admission rules for one question**, the reporting layer scanning per-field nulls while the load layer silently skipped them, so the gate and the loader disagreed. The fix funnels `require`, `require_verified`, `health`, `verify`, `capabilities._inspect` and `plan.manifest` through one rule (`catalog.pin_problem`), ordered licence → pin → lease → size → digest so the research switch clears only the licence question. Measured `Ran 221 tests` `OK`, non-vacuity proved by mutation (reverting `_inspect` fails 4 subtests; removing the pin gate fails 10). Caveats I am carrying rather than laundering: that run is **Python 3.15** on an off-target interpreter, and CI at this head is **not** complete — I read the check rollup and macOS Integration, Windows jobs and Payload Bundle were still unwritten.

Then I checked the claim that matters for users and it is **false today** (`grep -rn "32021" Sources/ Windows/` → zero hits): `protocol.py` asserts "Both hosts map this code to `E_MODEL_UNVERIFIED`", but neither host has the case, so the new integrity refusal — the most important diagnostic this branch adds — surfaces as a generic internal error and can still open the model manager for a defect no download can repair. Ticketed (#130) as a blocker for #115's review, not for #110.

**Process failure I own:** two writers were on this branch within minutes of each other (`0eba5ce` → `f7b70bb` → `e14357c` → `b386f6d` → `65b7d13`), and one of them added the suite-count mechanism that belongs to #110. No files were lost, but it broke my own no-double-booking rule and produced L.3. The earlier ceiling-death notification for the pre-salvage session is the *old* run re-measuring the matrix; its artefact already exists, so nothing is outstanding from it.

### L.3 DR-12 amended — the count collision is now real, measured

`git merge` of #115 into #110 in a throwaway branch: `CONFLICT (add/add)` on `Tests/expected-worker-tests.txt` (**194 vs 221**) and `CONFLICT (content)` on `Tests/run-worker.sh`. GitHub calls both PRs `MERGEABLE` because it only tests each against `main`, so this is invisible in the UI until the second one lands. Resolution: #110 first; #115 then rebases, keeps #115's strictly stronger runner (it adds `grep -qE '^OK$'` so a silently empty run cannot pass), drops its duplicate count file, and **re-measures** the size instead of carrying 221 forward as a guess (#132).

### L.4 The integrity evidence base is worse than the mandate stated — confirmed at the call sites

The acceptance matrix found six fail-open cases and concluded the gap is *wider* than §4 assumed: only **one** of four models ever hashes at load. I verified the sites on `main` directly — `engine.py:653` `require_verified("swin2sr-x4")` versus `:686` `require("sam2.1-hiera-tiny")`, `:701` `require("migan")`, `:717` `require("flux2-klein-4b-q4")` — so a same-size swap of weights for three of the four is accepted by the worker today. Independently found in the same pass: `AIWorker.workerEnvironment` did **not** strip `RETOUCH_AI_EVAL_MODELS` while `AIRuntimeValidation` did, i.e. an exported shell variable could open the licence gate in the real worker — and that is exactly what #115's `AIWorker.swift` change removes, so two workstreams met on the same defect without being told. Also recorded from that pass, still open: an uppercase digest pin permanently rejects a correct file, and an entry with a malformed aggregate digest reports `.ready` while install is disabled. Hash cost for a future verified load was measured (flux2 2.19 s over 4.6 GB), which is why verification belongs at adoption, not in `health()` polling.

### L.5 Licence and model decisions now have evidence behind them

- **DR-9 (vendor sam2) confirmed**, not merely chosen: there is no Meta wheel on PyPI, the PyPI `sam2` is an unaffiliated re-upload, every transitive dependency is already pinned (zero new distributions, zero CUDA wheels), the payload grows ~0.5 MB, and the CUDA `_C` extension belongs to the video path this app never imports. Runtime compatibility of sam2 under the locked torch on Python 3.13/MPS is **NOT CONFIRMED** — nothing was executed.
- **DR-10 is supported by primary text**, and it is load-bearing: swin2sr is trained mainly on DIV2K/Flickr2K, whose terms are academic-use only, and MI-GAN's MIT weight grant does not relicense Places2, whose terms forbid distribution. So `swin2sr-x4` and `migan` **stay `conditional`** — the artefact licence is permissive while the training data is not, and no UI text may collapse that.
- **One claim in my own dossier is downgraded**: the sam2 digest was recorded as "measured three ways". Two legs are publicly re-verifiable (HF LFS id, installed copy); the third — the CDN object's content hash — cannot be proven from headers, because its ETag is a 19-part S3 multipart MD5, not a SHA-256. CDN identity is **INFERRED** from identical length plus provenance. Proving it costs one 156 MB download, which I am not authorizing on this machine. Related: `realesr-general-x4v3` has no author checksum at all, only an opaque ETag.
- The reviewer's correction is accepted: `RETOUCH_AI_EVAL_MODELS` deletion is not the fix, and the worker's null-skip paths survived on `main` at `catalog.py:330`/`:418`, safe only because all four entries happen to be fully pinned today.

### L.6 G-UPD answered, with a residual surface that is not a blocker

Independent design review returned **ACCEPT WITH CHANGES** and, separately, the release question: the updater in a 2.0.0 build is **inert at configuration level** — no feed key exists in `Resources/Info.plist`, `performCheck` returns at the empty-feed guard, the only `swap` call is unreachable, and there is no launch agent, login item or background service anywhere in the sources. I confirmed the mechanism it depends on: `grep -rn "UpdateController(" Sources/` has exactly one hit, `InfoViews.swift:95`, the About view. Two honest qualifications: that is a plist guarantee rather than a code kill-switch, so the RC bundle must be re-checked (#117), and opening About runs `UpdateInstaller.recover` against a **user-writable** journal with no path validation — reproduced headlessly as deletion of an arbitrary victim file. Same-uid confused deputy, no privilege escalation, not a 2.0.0 blocker, but it is now on the record as residual risk, and `Docs/UPDATE_SYSTEM.md` claiming recovery "runs on every launch" is false in a way that matters (#131).

### L.7 Status deltas from this round

| gate | before | now | basis |
|---|---|---|---|
| G-110 | must-fix list open | **ready for independent review** at `cc1d9f6`; F1 adjudicated closed by me | pins zero-diff, count 194, run 44948957776, 0 reviews |
| G-INT | salvage, 2 failures | **implemented, 221 OK off-target**, CI incomplete, **host mapping gap #130 open** | PR #115 @ `65b7d13` |
| G-UPD | unreviewed | **design reviewed; inert YES** with residual journal surface + doc fix pending | reviewer probes + my caller grep |
| G-LIC / G-CAT | conditional verdicts | conditional **confirmed by primary text**; independent adjudication still running | Addendum L.5 |
| G-SAM2 | route undecided | **vendor route evidence-backed**; runtime compat NOT CONFIRMED | L.5 |

## Addendum M — 2026-11-22: the licence record overstated one model, and the UI can print a promise the record does not support

Independent adjudication of every model verdict came back with disagreements. I tested
each one myself before adopting anything; two of their citations were wrong and one
load-bearing claim I could not reproduce, but the central finding is correct and it is
against me.

### M.1 `swin2sr-x4`: `commercialOk: true` is unsupportable — corrected to unknown

Fetched live from Hugging Face for `caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr`
(read 2026-11-22):

```
author/org : caidas
tags       : [..., 'license:apache-2.0', ...]
cardData   : {"license": "apache-2.0", "tags": [...], "inference": false}
files      : ['.gitattributes', 'README.md', 'config.json',
              'preprocessor_config.json', 'pytorch_model.bin']
commits    : 5 ("initial commit" .. "Update README.md"), repo created 2022-12-16
```

There is **no `LICENSE` file** in the repository. The only statement of any licence is
one YAML key in a 19-line model-card front matter, on a checkpoint repo whose owner
(`caidas`) is neither the architecture's author (`JingyunLiang/SwinIR`) nor the code
author (`mv-lab/swin2sr`) — and our own evidence doc already records `explicit: false`
for this row, meaning "we inferred it from a repo-level tag". Under the owner's
definition — zero price **and** explicit permission for commercial use in a public MIT
app — `explicit: false` sitting next to `commercialOk: true` is self-contradiction, not
nuance. **Decision: `commercialOk` becomes `unknown` for this model; the verdict stays
`conditional`; the upscaler still ships as a feature, but no surface may state or imply
that its weights are commercially cleared.** The adjudicator also attributes every
commit there to an Hugging Face staff account rather than the rights holder; I could
**not** reproduce the author identities from the commits API (the response carried no
author objects in the shape parsed), so that specific attribution is recorded as
NOT VERIFIED and is *not* part of the basis for the correction — the absence of a
licence file and the third-party provenance of the card are enough on their own.

Two related corrections to my own record, both adopted: **`migan`** keeps an approved
*weights* position (the author ships a dedicated `LICENSE-WEIGHTS` MIT file whose very
filename scopes the grant to the weights), but omitting the Places2 fact was wrong —
the archived download pages say "use the data only for non-commercial research and
educational purposes. You will NOT distribute", so absence was encoding "unknown" where
the evidence is adverse; it must be recorded as a **disclosed residual risk**, not left
blank. **`RestoreFormer++`** moves from "usable with conditions" to **excluded** (an
Apache code file with an unedited placeholder copyright line, weights reachable only via
Google Drive, and authors stating it was trained on FFHQ, which is CC BY-NC-SA).
**`BiRefNet`** is not `USABLE` yet: the MIT tag is same-author, but there is no pin, the
weight repo carries no `LICENSE` file, and DIS5K terms are contradictory across mirrors
(`openrail` vs `apache-2.0`).

### M.2 The schema cannot express the truth, so the truth gets flattened into "cleared"

`worker/retouch_ai_worker/catalog.py` models this as `commercial_ok: bool` (`:46`) and
constructs **all four shipped entries with `commercial_ok=True`** (`:134`, `:162`,
`:186`, `:209`), then refuses on `if not entry.commercial_ok` (`:293`). There is no
third state for "we could not determine this", and no rule connecting the two axes the
mandate separates — nothing stops `explicit: false` from travelling alongside
`commercialOk: true`, which is precisely how M.1 happened.

**DR-13 (my decision).** The licence record gains a genuine unknown state (`unknown`,
not `false`, because "denied" and "unknown" drive different product behaviour), plus an
enforced invariant — **`explicit == false` implies `commercialOk != true`** — pinned by a
property test over the combination space, and a `datasetRestrictions` field so adverse
dataset terms are *present* in the data rather than representable only by omission.
Note the adjudicator's citation `catalog.py:256-259` for "asserts binary commercial
clearance" was wrong as a location (those lines are `get()`/`require()`); the substance
is right at `:46`/`:134-209`.

### M.3 The consent sheet prints a licence as fact and hides the evidence that qualifies it

Verified by me at `main`: the download-consent body is
`Sources/RetouchStudio/Models/Localization.swift:708-713` (the adjudicator's path omitted
`Models/`) and renders `"Code licence: \(codeLicense). Weights licence: \(weightsLicense)."`
— a bare assertion. `ModelManagerView.swift:389` and `:610` print the same two fields as a
badge line. Meanwhile `licenseEvidenceUrl` exists in the Swift model
(`Models/ModelCatalog.swift:108`) and appears **nowhere else in `Sources/`**: the URL that
carries the qualification is validated and stored, and never shown.

So for `swin2sr-x4` the app tells a user "Weights licence: Apache-2.0" while our own
record says that claim is an inferred tag on a third-party checkpoint repo with no licence
file. **DR-14 (my decision):** no surface may render a weights licence as a bare fact. The
evidence URL, the read date and the explicit/unknown state travel with the string, and a
non-explicit or unknown verdict renders as unresolved rather than as a licence name. The
string lives behind PR #99's files, so the wording waits for that merge (DR-7); the data
and the invariant do not.

### M.4 What is now defensible, stated without inflation

`migan` is the only shipped model with an author-written weights grant, and its training
data carries a non-commercial caveat we must disclose. `sam2.1-hiera-tiny` is licence-cleared
by Meta's own README sentence covering checkpoints, and its feature stays blocked for
runtime reasons — licence and capability must not be conflated. `flux2-klein-4b-q4` is
licence-cleared and hardware-excluded on measured memory, and that stays two separate facts.
`swin2sr-x4` ships as a disclosed-conditional feature pending the owner's written risk
acceptance. DR-9 and DR-10 both survive the adversarial read, and the vendored sam2 size
claim reproduces exactly (`375,194 B` = 0.38 MB at the pinned commit).

**Ledger erratum:** my commit message for Addendum L typed `engine.py:917` where the
verified call site is `:717`; the addendum body is correct. Recording rather than rewriting.

## Addendum N — 2026-11-22: two reviews land, one of them corrects me, and a third same-class Windows defect appears

### N.1 My DR-11 was overstated — Swift verification *is* possible on this machine

Independent review of PR #114/#113 came back having built and run the Swift suite here:
`MODEL STORE TESTS: PASS`, **268 checks, exit 0**, using swiftc against Command Line
Tools. I checked the mechanism myself rather than accept it, and the repository says so in
its own words at `Tests/run.sh:5`:

```
# swiftc against Command Line Tools only (no Xcode), so there is no test runner.
```

with SDKs present including `MacOSX26.5.sdk`. So my Addendum J claim — "zero Swift-side
reproduction is possible here" — was **wrong in scope**. The accurate statement is:
**SwiftUI view code is not compilable here** (no `SwiftUIMacros` plugin for `@State`),
while Foundation-only sources are, and that is most of the core: `grep -cE
"import SwiftUI|@State|@Binding"` returns **0** for `Tests/ModelStoreTests.swift`,
`Sources/RetouchStudio/Models/ModelCatalog.swift` *and*
`Sources/RetouchStudio/Core/WorkerClient.swift`.

Two consequences, both mine to act on. G-RC/#117 still stands — the **app bundle** needs
Xcode, so building the release artefact stays on CI (DR-11 survives narrowed to bundles) —
but the `-32021` host-mapping work (#130) is **locally provable**, so "CI-pending" is no
acceptable label for it. I attempted to send that correction to the member mid-flight and
the team-delegation call failed again with the leader-binding error, so the correction is
recorded here instead and I will verify the suite myself after he reports.

### N.2 PR #114 — ACCEPT WITH FIXES, and one finding collides head-on with Addendum M

Executed evidence, not read-only judgement: the regeneration tool **fails against the
artifact it produced** — `python3 Docs/licence-evidence-apply.py` on `2656db1` dies with
`JSONDecodeError: Extra data` at `:166` (`entry_last_key` picks up the closing `}` of the
block it just appended), i.e. it is not idempotent and cannot be re-run on its own output.
From the pre-change baseline it *is* byte-identical (`OK: 29 keys added, 0 changed,
0 removed`, `cmp` clean, sha256 `c52ed5e6…` on both) — so the provenance is reproducible
once and unrepeatable thereafter, which makes the tool documentation, not a source of
truth. Verdict: **fix required before I call #114 mergeable**, because the whole purpose of
this branch is auditable licence provenance.

The fail-closed behaviour, measured through a five-mutation decoder harness, is genuinely
good: absent evidence stays `nil`, `nil` never becomes approval, and the two contradictions
that *are* caught refuse with named messages. The gap is exactly where Addendum M bit me:
`validate()` cannot express `explicit: false` × `commercialOk: true` — and that is not
hypothetical, it is the **actual shipped row for `swin2sr-x4`** that M.1 just had to
retract. The reviewer independently found the same hole from the code; I found it from the
licence text. That convergence is why DR-13's invariant is a requirement, not a tidy-up.
Also accepted as must-fix-before-trust: `verdict: excluded` + `commercialOk: true` loads,
the worker's `public()` carries only 3 of the 8 recorded fields while the doc says the
evidence is mirrored, and the cross-surface commercial check at
`Tests/ModelStoreTests.swift:2004` is one-directional (flipping the worker to
`commercial_ok=False` produces zero failures).

### N.3 PR #113 — ACCEPT WITH FIXES, plus a new defect of the same class it was written to close

The look fix itself is right and the six input shapes were enumerated: empty `lookID` with
strength, missing `lookID` with negative strength, cleared look, ID-only-with-zero, and
both-halves-once — with **no false refusal** when both are absent. `AnyAmount` ignores sign
and treats zero as "no edit", identically to all 13 sibling groups.

Then the reviewer cross-counted the wire format mechanically: macOS encodes **60** numeric
amount keys, the Windows guard names **50**, and of the ten omissions nine are the correct
renderable set — but **`texturePreserve` is not**. It changes macOS pixels
(`ImageProcessor.swift:800`, `:823`), it is a live slider, it is non-zero in the shared
v4 fixture, Windows never reads it, and the PR's own new test
(`Windows/RetouchStudio.Tests/Program.cs:3909` + `:3913-3914`) now **asserts it is not an
edit** under a label claiming "the nine renderable sliders". That is the identical bug
#113 exists to fix, promoted into an assertion. Ticketed separately so it does not get
absorbed silently into this PR.

Two lower items carried: three assertions hardcode `UnsupportedEdits.Count == 8` instead of
the name set (the mechanism by which an omission survives), and `lookID == "none"` — which
macOS writes when the rail selection is cleared (`EditorModel.swift:657-662`) — would trip
the guard permanently on a document that renders no look. That last one is **INFERRED**,
not executed: `dotnet` is genuinely absent, so the 401-check Windows suite remains NOT RUN.

### N.4 One reviewer claim refuted, in the other direction

The same report states the licence dossier `/private/tmp/rs-model-licences/MODEL_LICENSES.md`
"is gone from this machine", and used that to argue the recorded `readOn` dates cannot be
re-checked. It is **not gone**: `ls -la` shows `MODEL_LICENSES.md`, 39,361 bytes,
mtime Nov 21 21:55. The finding is dropped. The adjacent concern survives on its own
merits, though, and is now ticketed: `Docs/licence-evidence-apply.py:4` cites that **/tmp
path** as the transcription source for values stamped into the shipped catalogue, and a
temporary directory is not provenance — it needs to be imported into the repository with a
hash, the same treatment the updater design document got.

### N.5 Deltas

| item | before | now |
|---|---|---|
| DR-11 / Swift verification | "impossible on this machine" | **bundle-only**; core sources compile and 268 checks run here |
| PR #114 | CI green, unreviewed | **ACCEPT WITH FIXES** — regeneration tool broken on its own output; `explicit`/`commercialOk` invariant missing |
| PR #113 | CI green, unreviewed | **ACCEPT WITH FIXES** — mergeable in substance; `texturePreserve` is a live same-class defect |
| #130 | "CI-pending by definition" | **locally provable** — `WorkerClient.swift` has no SwiftUI dependency |
| licence provenance | thought lost | present on disk; must be moved out of `/tmp` into the repo |

---

## Addendum O — 2026-11-22: the owner replaced the licensing use class and issued full model-ecosystem execution authority

### O.1 What was said, and what it changes

The owner issued a second mandate, "FULL EXECUTION AUTHORITY — RetouchStudio AI Model Ecosystem"
(2026-11-22). It is an execution mandate, and §12 of it is explicit that research, a candidate
list, or catalogue entries are not completion: *"The work is complete only when the selected models
are integrated, their licenses are documented, their integrity is enforced, their inference paths
are tested, and independent reviews have passed."*

The rule in §2 of this document is **replaced** by these owner statements:

- *"RetouchStudio is a free application intended for public non-commercial use."*
- *"There is no intention to commercialize the application in the future."*
- *"Models do not need commercial-use permission if their actual licenses permit the intended
  non-commercial use and distribution."*
- *"Models must have defensible licensing and provenance."*
- *"Free downloads do not automatically mean redistribution is permitted."*
- *"All attribution, dataset, ShareAlike, and other applicable obligations must be respected."*
- *"Do not treat all NC models as automatically approved."*
- MIT stays (§11: *"Change the project's MIT license"* remains outside my authority).

**DR-15 (the gate that replaces the §2 definition).** For every artefact, four separate rights are
now evaluated, each with a primary-source quotation and an access date:

1. **Acquisition** — may the end user pull this exact file from the location we ship?
2. **Install metadata** — may we publish the URL, size and SHA-256 of that file inside a distributed
   app, and is that act itself "redistribution" under the licence?
3. **Use** — does the licence permit *public non-commercial* use, and does it permit the derived
   output the product produces?
4. **Conditions** — attribution, ShareAlike, NoDerivatives, dataset takedown, no-fine-tuning,
   no-dataset-redistribution clauses: each must be technically satisfiable by us, not just noted.

Statuses are now exactly the owner's four: **APPROVED / APPROVED WITH CONDITIONS / UNKNOWN /
EXCLUDED**. Only APPROVED enters the normal distributable catalogue; APPROVED WITH CONDITIONS
enters only when *every* condition is implemented and documented; UNKNOWN and EXCLUDED must not ship.

**What the change does NOT relax**, because the owner restated it in §4 of the new mandate:
*"A repository license does not automatically cover model weights. A Hugging Face metadata tag alone
is not sufficient when the rights holder or authorization cannot be established. A model with unclear
weight permissions must not enter a distributable build. Do not invent permissions or silently infer
them."* DR-13 therefore survives **unchanged in substance** — its invariant was never really about
commerce, it was *"an inference may not be recorded as a grant"* — and its concrete shape changes
from a `commercial_ok` tri-state to a permitted-use record per artefact. **DR-14** (no surface may
render a weights licence as a bare fact without its evidence URL, read date and explicit/unknown
state) is untouched by this and remains the reason the consent sheet is still a must-fix.

### O.2 Provisional consequences for the five verdicts made yesterday

These are **directions of travel, not verdicts**. Each is re-derived from the primary source by the
M1-A audit before anything is written into a catalogue or a document.

| artefact | verdict under the retired commercial rule | what DR-15 changes | status today |
|---|---|---|---|
| `swin2sr-x4` | UNKNOWN (third-party card, metadata tag only, no LICENSE file) | Commercial clearance is no longer the question, but *"a Hugging Face metadata tag alone is not sufficient"* still is: the gap is now **rights-holder authorisation over the weights**, not commerce. The upscaler stays shipping; the licence question keeps the same severity and changes shape. | UNKNOWN, under re-audit |
| `migan` | APPROVED WITH CONDITIONS (author-published MIT-based weights grant; Places2 academic-NC terms) | The use-class conflict disappears — our use **is** non-commercial. What remains is disclosure and attribution, which §O.1 point 4 requires us to implement rather than delete. | strongest surviving candidate |
| `sam2.1-hiera-tiny` | APPROVED pending pin re-verification (Apache-2.0 from Meta, the rights holder) | Unaffected in principle; needs the identity re-check, not a licence rethink. | APPROVED, identity pending |
| `RestoreFormer++` | EXCLUDED (no commercial grant; Drive-hosted weights; placeholder copyright line) | The *commercial* objection falls. The **provenance** objections do not: a mutable Google-Drive payload cannot carry "exact artifact source" + "reproducible installation metadata" (§7), and a placeholder copyright line means the grantor cannot be established (§4). | EXCLUDED on provenance grounds unless re-evidenced |
| `BiRefNet` | UNKNOWN (no pin; no LICENSE in the weights repo; DIS5K terms disagree between mirrors) | Commercial objection falls. Still blocked on pin, rights-holder statement, and a self-consistent dataset licence. | UNKNOWN, re-opened for evaluation |
| `flux2-klein-4b-q4` | carried in catalogue, never adjudicated | Needs a full provenance pass whoever publishes it, plus a hard technical question the mandate's §6 asks: is a 4B generative model usable at all on a 16 GB arm64 laptop and a Windows CPU. | NOT ASSESSED |

### O.3 New obligations on the record itself

1. **Four repository-owned documents** are now required deliverables (§10):
   `Docs/AI_MODEL_SELECTION.md`, `Docs/AI_MODEL_LICENSE_REGISTER.md`,
   `Docs/AI_MODEL_BENCHMARKS.md`, `Docs/AI_MODEL_INTEGRATION_STATUS.md`, and they *"must become
   reproducible, repository-owned sources of truth"*.
2. *"Do not rely on temporary `/private/tmp` files as permanent licensing evidence."* This is the
   owner adopting the finding recorded in N.4. Consequence:
   `/private/tmp/rs-model-licences/MODEL_LICENSES.md` (39,361 B, mtime 2026-11-21 21:55, verified
   present) must be imported into the repository with a recorded hash, and
   `Docs/licence-evidence-apply.py:4` must stop reading a `/tmp` path as the source of values
   stamped into a shipped catalogue.
3. Exact source URLs, artefact identities, licence evidence, **dates, full hashes, conditions and
   review outcomes** are mandatory fields. Where a hash cannot be produced without a large
   download, the honest entry is "must be produced in CI", not a guess.

### O.4 Boundaries the owner re-imposed in the same document (§11)

Unchanged and load-bearing: no licence change away from MIT; no publishing or distribution; no
release creation, asset upload, tag creation or movement; the existing `v1.0.0` release is frozen;
no paid services; no irreversible external-service changes; the owner's personal checkout and data
are off-limits; **no launching the application or opening GUI windows under the standing no-GUI
restriction**; the updater stays unimplemented and disabled; existing release governance and the
Better Harness workflow stay. §6 restates *"do not perform disruptive installations or large
downloads on the owner's personal machine without authorization"* and *"use isolated environments or
CI where possible"* — so benchmark work runs headless in CI or an isolated environment, never as a
multi-gigabyte download into this Mac.

### O.5 Work actually opened by this addendum

| stream | owner | question it answers | state |
|---|---|---|---|
| M1-A | Researcher | code-true AI capability inventory, licence/provenance re-audit of the five artefacts above, the full surface map for a catalogue-semantics change, and rescue of the `/tmp` dossier | assigned |
| M1-B | Research (parallel seat) | best practical candidates for super-resolution, face restoration, deblur, denoise, enhancement, texture preservation under DR-15 | assigned |
| M1-C | Research (parallel seat) | same for background removal, segmentation/masks, object removal/inpainting, portrait/beauty, generative fill — including a hard audit of `flux2-klein-4b-q4` | assigned |
| #115 review | Code Reviewer | independent adversarial review required by §7 and §8 of the mandate (and carried from §4 of the release mandate) | assigned |
| execution evidence | Test Engineer | what the worker and Foundation-only Swift suites actually do at `cc1d9f6` and `75cbb89`, and which rejection classes are provable through the real RPC path here | assigned |
| #114 rework | Full-stack Engineer | schema that can express UNKNOWN, the four review must-fixes (idempotent regeneration, bidirectional cross-check, mirrored fields, excluded-loads), and the dossier imported out of `/tmp` | assigned |

Merge order **DR-6 is unchanged**: #110 → #111 → #107 → #99, then the catalogue/licence and
integrity lines, version bump last. Current facts at the moment this addendum was written: #110 is
green on all five required contexts plus both advisory worker jobs at `cc1d9f6` and is waiting on the
independent verdict, not on CI; #115 carries the two commits that landed the `-32021` mapping on both
hosts (`9b64949`, `75cbb89`), is green on every context read so far **except** `macOS Integration`
which was still running, and still owes the rebase-and-count reconciliation against #110 (#132).
Nothing is merged, tagged or published; the owner's checkout is untouched.

---

## Addendum P — 2026-11-22: DR-16, the decision framework I will apply to every model

The mandate says *"Do not ask the owner to choose between technically equivalent candidates. Make
the decision using evidence."* A decision rule that does not exist yet cannot be applied
consistently, so it is written down **before** the candidate surveys land, and every adoption or
rejection from here on is measured against it. It is a PM decision, not owner policy, and it is
falsifiable: if a rule below makes a good model fail for a silly reason, the rule changes on the
record and the change is dated.

### P.1 Floor — a candidate that fails any of these never enters the catalogue, whatever its quality

| # | Requirement | Why it is a floor and not a preference |
|---|---|---|
| F1 | The exact weight file is fetchable over HTTPS from an **immutable** location: a release tag with a stable asset id, or a Hugging Face revision commit SHA. Not Google Drive, not OneDrive, not a "latest" alias. | §7 demands "exact artifact source" and "reproducible installation metadata". A mutable host cannot satisfy either, so `RestoreFormer++` fails on this axis regardless of licence. |
| F2 | Full SHA-256 and byte size are recorded **from the artefact we will actually load**, and the entry is inactive until they are. | Without a real digest the fail-closed gate (#115) has nothing to enforce. A hash "to be filled in later" is how the last audit found only 1 of 4 models verified at load. |
| F3 | The rights holder — the party that authored the trained weights or is documented as their owner — states the permission. A re-uploader's metadata tag is not a grant. | The owner's §4, restated on 2026-11-22. This is what moved `swin2sr-x4` to UNKNOWN. |
| F4 | Runs inside the locked runtime (`torch 2.15.0`, `torchvision 0.29.2`, `onnxruntime 1.31.1`, `numpy 2.5.4`, `pillow 13.0.0`) **or** arrives with a lock change whose set-membership evidence closes ticket #129. | A model that needs an untracked dependency is a runtime change smuggled in as a feature. |
| F5 | Peak resident memory stays inside the reference envelope: the MacBook Air M3 with 16 GB, sharing the machine with the app. Working target: peak RSS ≤ 8 GB on a 2048×2048 tile, measured headless in the worker, with the number recorded rather than asserted. | §6 lists RAM as an evaluation axis; the upscaler's memory envelope is already the measured reason for the 40 MP ceiling. |
| F6 | A Windows path either exists (CPU/ONNX, demonstrated on a runner) or the capability is recorded as macOS-only in the matrix and the UI says so. | §2 of the mandate allows different models per platform precisely so that "Windows silently loses the edit" is never the fallback — that class of bug is #122/#133. |
| F7 | Every condition the licence imposes is **implemented**, not annotated: attribution present where required, no dataset redistribution where forbidden, no derivative-work claim where ND applies. | "APPROVED WITH CONDITIONS models may be included only when every condition is technically and legally satisfied and clearly documented." |

### P.2 Ceiling — we are not collecting models

- **One primary model per capability.** A second is admitted only with a named, measurable benefit
  (quality delta above the recorded noise floor, a degradation class the primary cannot handle, or a
  platform the primary cannot run on). "It also exists" is not a reason to ship another hundred
  megabytes and another licence surface.
- **No duplicate capabilities.** If two candidates cover one feature, one becomes primary and the
  other is recorded in the selection document as a rejected alternative with the reason — the
  rejection is part of the deliverable, not a footnote.
- **Feature boundary over feature theatre.** Where nothing clears F1–F7, the capability keeps its
  existing UI state and reports truthfully that no verified model is available. The mandate is
  explicit: *"preserve the feature boundary and report the limitation rather than shipping an
  unverified model."*

### P.3 Quality and performance evidence, so a number is never confused with a claim

1. **Protocol first, then run.** Each capability gets a named metric, a named threshold, a named
   fixture set, and the command that produces the number, recorded in
   `Docs/AI_MODEL_BENCHMARKS.md`. The upscaler already has a working precedent: downscale → upscale
   → PSNR against the native high-resolution reference, **≥ 24 dB**, measured on the owner's private
   portrait fixtures. Equivalent protocols are defined per capability before a candidate is called
   better.
2. **Three labels, always distinct:** *MEASURED* (ran here or in CI, artefact retained), *UPSTREAM
   CLAIM* (the paper or README says so), *INFERRED* (my reasoning from architecture or parameter
   count). A candidate selected on an upstream claim is recorded as selected on an upstream claim.
3. **Fixtures stay private.** The portrait test images are never committed; the benchmark document
   records derived statistics and hashes of the derived artefacts, not the photographs.
4. **No large downloads on the owner's machine.** Anything above a few hundred MB is fetched in CI or
   an isolated environment, per §6 of the mandate and DR-2. Where that is impossible, the honest cell
   in the matrix is NOT VERIFIED.

### P.4 Replacement and ejection

- *"Do not preserve an inferior model simply because it is already integrated."* A current entry has
  no standing: it must clear the same floor as a newcomer, and if a better cleared candidate exists
  we swap and record why.
- Ejection keeps the row. A model moved to EXCLUDED or UNKNOWN stays visible in the register and in
  the capability matrix with its reason, so the product says "not available: provenance" rather than
  appearing to have never had the feature.
- One adoption = one PR carrying pin, size, SHA-256, register entry, licence conditions, the negative
  integrity tests, the benchmark row, and the truthful UI state. A code-only model change is the
  pattern that produced yesterday's asymmetry.

### P.5 What I still owe, and the order

Research (M1-A/B/C) → per-capability decision list, one primary + rejected alternatives with reasons →
catalogue and register changes on evidence → integrity and admission tests (#115 plus the Scope-A
invariants) → headless benchmarks in CI or an isolated environment → independent review of licensing,
provenance, catalogue changes, runtime integration, dependency changes, integrity, cross-platform
behaviour and test coverage (§8's list, reviewer ≠ implementer) → RC preparation. Publication,
tagging, release assets, the `v1.0.0` release and any GUI acceptance session remain the owner's.

## Addendum Q — 2026-11-22: three independent verdicts land, one research claim is refuted by my own check, and both review-driven fix passes are dispatched

Everything in this addendum is either a verdict I received with evidence, or a fact I re-measured myself on the
remote. Where I re-measured and the report was wrong, the correction is recorded here rather than propagated.

### Q.1 PR #110 — independent verdict received: PASS-WITH-COMMENTS, and I am not merging it yet

The reviewer who did not write the code re-reviewed `cc1d9f64347fe07e3fa6131a281b7fa3cc9ce86f` (18 files,
+1893/−94) after the earlier BLOCK at `c72a0f4` was closed. Their finding: F1/F2/F5/F6 fully closed, F3 and F4
closed in code and permanent tests, `Ran 194 tests / OK / exit 0` reproduced locally on a lock-exact venv, and
**no check was weakened**. My own check of the remote, independent of both reports: `gh pr checks 110` → all five
required contexts plus both advisory worker jobs plus CodeQL pass at run `44948957776`; `mergeable: MERGEABLE`,
`mergeStateStatus: CLEAN`; zero formal GitHub reviews (the reviewer seat reports to me and does not post reviews,
so the verdict is the record, not the API).

The residual items are claims exceeding tool behaviour, plus one future-facing fail-open:

1. **Medium** — `lock_closure.visit_Call` sees only a positional literal argument to `__import__` and
   `importlib.import_module`, so `from importlib import import_module; import_module('cv2')`,
   `__import__(name='cv2')` and `builtins.__import__('cv2')` escape **both** gates. The tree uses none of the
   three (grep-verified), so today is safe; the sentence "A newly introduced unpinned import therefore cannot
   escape both checks" is nonetheless false.
2. **Low** — the comment "protobuf provides only `google.protobuf`" is false: the pinned protobuf wheel ships
   `google/_upb/_message.abi3.so`, so `import google._upb._message` is rejected as canonical `google`
   (fail-safe direction, wrong docstring).
3. **Low** — the suite-count mechanism pins the *discovered case count*; a rename, a net-zero replacement or an
   added `@unittest.skip` keep it green, so "adding, removing or renaming … cannot pass locally" overstates.
4. **Low** — derived import-smoke targets are top-level only, so a broken pinned submodule (`yaml.nodes`)
   passes both gates.

Decision, because this release track exists precisely to stop governance documents asserting guarantees the tools
do not implement: **items 1, 3 and 4 are fixed in code, item 2 in code and comment, and only then is #110
merged.** Narrowing the text instead of closing the escape would put a permanently false security sentence on
`main`, which every later release review reads. Dispatched as a bounded implementation pass on
`w5-worker-gates-failclosed` with the reviewer's reproduction probes quoted, a no-weakening rule, and the
requirement to quote real exit codes and the CI run id for the new head.

### Q.2 PR #115 — the single red context is the shared-file count pin, and #110 is what removes it

I verified this myself rather than accepting the implementer's account. `gh run view 44952716741 --log-failed`
shows the failing step is `Assert every suite reported a verdict`, whose loop still hard-codes `'Ran 166 tests'`;
`git show origin/main:.github/workflows/ci.yml` line 164 carries that same literal. Every other step of that job
succeeded, including `Ran 221 tests`, `MODEL TESTS: PASS` and the five new routing checks, and **Windows App is
green** with `[H] the catalog defect is not an install`. `git show origin/main:.github/workflows/ci.yml` will lose
that literal the moment #110 merges, because #110 makes the job read `Tests/expected-worker-tests.txt`. So the red
is neither caused by #115 nor fixable inside it; it is ticket **#132** and it resolves by the DR-6 order. The
independent adversarial review of the fail-closed integrity diff (mandate §4/§7, ticket **#128**) is still the open
gate on this branch, not CI.

The `-32021` outcome is worth recording plainly: the class the `protocol.py` comment named did exist on both
hosts as `E_MODEL_UNVERIFIED` (`WorkerClient.swift:40`, `WorkerClient.cs:50`), and the documented definition at
`Docs/W5_IMPLEMENTATION_DECISION_RECORD.md:191` already covers "lacks mandatory metadata". So the fix is a
mapping, not an invention, `opensModelManager` stays `false` by construction, and `E_MODEL_MISSING` — the
installable class — is untouched. The sibling sweep of all 17 protocol codes found `-32021` to be the only
claimed-but-unmapped one; `-32017/-32018` are unmapped but CLI-only and unreachable over the socket, so they are
a latent gap, not a live false promise. What remains **NOT VERIFIED** on this branch is user-visible: the Persian
sentence is blocked by the two localisation files PR #99 owns, and no path from a real `-32021` on the socket to
rendered refusal text has been exercised.

### Q.3 PR #111 — MERGE AFTER FIXES, and the two cases that would become release-blocking later

The reviewer confirmed the shipped macOS artefact is truthful today and that `build.sh` gained only a +16-line
block with the sign → validate → selftest order intact and the copy happening **before** codesigning. Blocking
items: `Resources/THIRD_PARTY_NOTICES.txt:8` says the bundle contains "one" third-party component while the same
file documents an optional helper runtime of ~67 distributions, and `build.sh:157-162` copies that file in **both**
modes; and `Docs/RELEASING.md:49` plus the PR body claim the audit fails on "any bundle file the notice does not
account for" while `audit-bundle-notices.sh:32-33,53-54` blanket-accept `Contents/MacOS/**` and the whole helper
tree (measured: pin-unnamed, empty-helper-notice and no-lock fixtures all exit 0). Dispatched as a bounded pass:
MF1/MF2 text, MF3 per-pin coverage enforcement with negative fixtures, MF4 per-named-font existence, and the
case-insensitive copyright guard.

Severity ruling I am recording, because it changes what blocks 2.0.0: those three bypasses are **not**
release-blocking while `.github/workflows/release.yml:25,55` builds with `RETOUCH_SKIP_WORKER=1` — the shipped
DMG has no `Contents/Resources/Worker` to misdescribe. The day a helper-bearing DMG ships, MF1 plus the three
bypasses become release-blocking together, so the fix must land before that decision, not after.

Also confirmed and out of this PR's scope: `Windows/installer/Product.wxs` references no licence or notice and
`Tools/package-windows-msi.ps1:68` only heat-packs the publish folder, so a Windows MSI would ship neither
`LICENSE` nor the OnnxRuntime notice. MIT's notice obligation covers the Windows build; that belongs to the
Windows packaging ticket, not to #111, and Windows artefact publication is already gated on it.

### Q.4 Updater — G-UPD is answered YES at configuration level, with one residual surface

The independent design review returned **ACCEPT WITH CHANGES** and, for the release gate, an explicit answer:
2.0.0 is inert — no feed key exists in `Resources/Info.plist`, `performCheck` returns at the empty-feed guard,
the only `UpdateInstaller.swap` call sits behind that, and no launch-agent/`SMAppService`/`RunAtLoad` string
appears anywhere in `Sources`, `Resources`, `build.sh`, `Tools` or `.github`. The caveat is stated as the caveat
deserves: that is a **plist-level** guarantee, not a code kill-switch, so it must be re-checked on the RC bundle
(G-BLD is still blocked because `build.sh` execs the binary).

One residual surface was reproduced headlessly, not theorised: with no feed, opening About still constructs
`UpdateController`, whose `init` runs `recover` on the user-writable
`~/Library/Application Support/RetouchStudio/update-journal.json`, and `recover` performs no path validation —
a planted journal deleted an arbitrary victim file. Same-uid confused deputy, no privilege escalation, reachable
only from a UI action, and therefore **not** a 2.0.0 blocker; it is recorded as residual risk against G-UPD, and
it is the reason the review's M1 (anchor path validation to the running bundle, never to `parent(journal.appPath)`)
must precede any move of recovery into `App.init`. Nine must-change items (fallback two-rename window, "v1 reader
is unreleased" being false because 2.0.0 ships it, doc truthfulness, ordering, key-compromise threat model,
no-probe-skip, the missing app-level exchange measurements, post-exchange resource mixing) gate **implementation**,
which is not authorised for 2.0.0. `Docs/UPDATE_SYSTEM.md:128-131` is now known false on two counts — recovery
does not run "on every launch", and in the stranded-bundle state there is no app left to run it — which is ticket
**#131**.

### Q.5 M1-C landed, and its headline unlock is refuted

The semantic/segmentation/generative dossier is delivered (`/private/tmp/rs-models/M1-C.md`, 758 lines, 25
candidate rows with per-artefact rights-holder findings, plus four explicit "no such model exists" statements —
fine matting with a cleared data chain, mask-conditioned generative inpaint/outpaint under a redistributable
licence at ≤4 B parameters, face parsing with a usable grant, and any defensible Windows generative path). Under
DR-16 its two strongest consequences are the FLUX.2 re-record — the pin points at a community **conversion**
whose own card disclaims authorship, its 4.6 GB has no published SHA-256 (the HF tree carries Git blob oids, not
file digests), the repo is mutable, and the conversion omits the tokenizer files the app would need — against
rights-holder evidence that does exist: `black-forest-labs/FLUX.2-klein-4B` ships a 9,584-byte verbatim Apache-2.0
`LICENSE.md` covering the weights, with an out-of-scope-use list and a trademark clause to respect. Background
matting finally has author-granted candidates (BiRefNet_lite 177,634,392 B MIT; MODNet ~25 MB, Apache-2.0 stated
over code **and** models, Windows-CPU viable) and LaMa has one ONNX path with a licence file
(`opencv/inpainting_lama`, 92,591,623 B) whose derivation chain still needs confirming. FastSAM (AGPL), RMBG-2.0
and Qwen2.5-VL (NC), SAM 3/3.1 (download gated behind personal-data acceptance, 3.44 GB) and the CelebAMask-HQ
parsers are excluded or UNKNOWN with reasons.

**But its #1 recommendation is wrong, and I caught it by checking the remote instead of trusting it.** The dossier
says `sam2.1-hiera-tiny` has no `bytes`/`sha256` so `mask.click` is blocked purely for unverifiability
(`catalog.py:143-145`, `capabilities.py:124-127`). `git show origin/main:worker/retouch_ai_worker/catalog.py` says
otherwise at :145-159 — the entry carries 156,008,466 bytes and the digest measured three ways — and
`capabilities.py:124-127` on main is the `_importable` helper, not the unverifiable gate. The blocker is the missing
runtime dependency, exactly as the earlier SAM follow-up report established and as ticket **#116** carries. The
cause is procedural, not intellectual: the owner's checkout sits at `40b157f`, **38 commits behind `origin/main`**,
and the agent read the working tree. This is the second research report this week to be poisoned the same way, so
the standing rule for every future dispatch is now explicit: **read the pinned ref with `git show`/`git ls-remote`,
never the local tree**, and quote the ref in the evidence line.

Disclosure, so the record matches §6: that survey left two RealESRGAN checkpoints (67,061,725 B and 67,040,989 B)
in a scratch directory under `/private/tmp` on this machine — inside the size bound its brief set, outside the
owner's checkout and documents, and redundant with the CI-based benchmark plan. They are not inputs to any merged
change; they will either be consumed by the PSNR harness or deleted, and nothing will be downloaded to this machine
again without a stated reason.

### Q.6 The correction pass on #110 lost its first implementer mid-flight; the count guard reported it

The agent dispatched for Q.1's four items reached its turn ceiling rather than finishing. What it left is recorded
here because the branch remote does not show it: **one commit, local only, never pushed** — `8e9acc5`, adding
`google._upb` to `ALIAS_PREFIXES["google"]` with the comment rewritten and one closure test, on top of `cc1d9f6`,
which is still the remote head of `w5-worker-gates-failclosed`. So the branch state the public record shows is
unchanged, and nothing of this pass is merged or merged-ready yet.

Two things are worth keeping in the record rather than only in the ticket:

1. The commit message claimed a **second** test seed in `worker/tests/test_import_smoke.py`. `git show --stat` lists
   two files, and a grep for `_upb` in that test file returns nothing: the seed does not exist. That is the same
   defect class this addendum exists to eliminate — a claim exceeding the artefact — arriving from my own side of
   the pipeline rather than the codebase's, so the standing rule applies to member and agent reports too: read the
   diff, then believe the message.
2. I ran the suite myself instead of asking: **exit 1**, `AssertionError: 195 != 194 : the discovered suite and
   Tests/expected-worker-tests.txt disagree; update that file to the measured count`, `Ran 195 tests`,
   `FAILED (failures=1)`. That is the single-source mechanism Q.1 item 3 discusses, working as designed — an added
   test without a count bump cannot slip through, locally or in CI.

Re-dispatched as one writer on that branch (no parallel writers on the same files), with the verified starting state
handed over so no budget goes to re-exploration, the four items ordered so each is independently valuable, and an
explicit rule that **every green step is committed and pushed immediately** — partial work that is green and pushed
is an acceptable outcome; a large uncommitted pile is not. #110 still merges only after this lands green on my own
observation of the run, and `develop` stays fast-forward-equal to `main` afterwards.

## Addendum R — 2026-11-22: merge authority exercised, and the model decisions I made under DR-16 without asking

### R.1 Authority and order of operations

The owner authorised the sequence explicitly: when the correction passes on #110 and #111 are green, merge them
myself, fast-forward `develop`, then move to #115 and the model lines. That is a continuation of DR-6, not a change
to it. What "green" means here is bounded on purpose: I observe the CI run for the pushed head myself and confirm
`Tests/expected-worker-tests.txt` agrees with the measured count — a member's report of green is not the gate.
Publication, tags, release assets, the existing `v1.0.0` release, any paid service and any GUI session remain
outside this authority.

Branch state at the moment of writing, from `git ls-remote`: `main` `cd5741b`, `develop` `06e8ac4` (behind, to be
fast-forwarded after the first merge), #110 `ad9483d`, #111 `4973cc3` — both advanced past the heads that were
reviewed, so the reviews below are against the reviewed heads and the new heads still need their own observation.

### R.2 PR #115 — what the diff actually enforces, verified rather than reported

I checked the branch myself before assigning review, because §7's requirements are the ones a comment can fake:
`worker/retouch_ai_worker/engine.py` calls `require_verified` for **all four** models (:884, :938, :951, :971) —
where `main` hashes exactly one, which was the finding that made a same-size byte swap acceptable for three of four.
`worker/retouch_ai_worker/catalog.py` refuses an absent or malformed digest and an absent size at admission (:163-170,
raised at :540/:560/:625) and reports the condition through `health()` (:668) instead of presenting the entry as
loadable. `Sources/RetouchStudio/Core/AIWorker.swift:599` now strips `RETOUCH_AI_EVAL_MODELS`, which was the host
path that could open the licence gate from the environment. So the five fail-opens the acceptance matrix named are
addressed **in code**; whether the code holds against seeded bypasses is exactly what the independent adversarial
review is for, and that review is assigned (mandate §8: the implementer cannot be the sole reviewer). Distinguish
the two states in anything derived from this ledger: *implemented* is not *verified*.

### R.3 The model decisions I made, so the record contains decisions and not only research

Per the mandate's §2 I am not bringing the owner equivalent candidates to choose between. Applying DR-15's four
rights and DR-16's floors F1–F7 to the semantic-track dossier:

- **`sam2.1-hiera-tiny` — retained as the `mask.click` primary, status APPROVED on rights (Meta states Apache-2.0
  for the weights), blocked on packaging only.** Its size and digest are already on `main`; the blocker is the
  missing `sam2` runtime package. Decision unchanged: vendor the ~0.38 MB package rather than loosen the lock gate,
  because a URL or git pin fails the closure tool that #110 just hardened. **I rejected the proposal to switch to
  `hiera-small` as the default** — no measured mask-quality benefit exists, and DR-16's ceiling forbids swapping a
  working model on an upstream size claim. A size change needs a benchmark row first.
- **FLUX generative — the current pin is not distributable as it stands.** It points at a mutable third-party
  conversion whose own card disclaims authorship, whose 4.6 GB has no published digest, and which omits the
  tokenizer files the code would need: that fails F1 and F2 regardless of licence. The rights-holder grant *does*
  exist one level up (`black-forest-labs/FLUX.2-klein-4B`, Apache-2.0 `LICENSE.md` covering the weights), so the
  decision is to **re-record the entry against the upstream revision with the conversion commit and CI-generated
  hashes, and to keep the quantised derivative only if its tokenizer set is pinned too** — and until that lands, the
  generative capability must not be presented as distributable. Its out-of-scope-use clause and trademark
  restriction are product policy, not decoration, and belong in the register.
- **`migan` — APPROVED, retained.** MIT weight grant from the author, ONNX, Windows-viable, smallest footprint of
  anything in the catalogue. Its Places2 training-data caveat stays recorded as a dataset obligation we cannot
  discharge, and `inpaint.spot` stays bounded to its measured mask-fraction limit.
- **Two adoptions opened.** `BiRefNet_lite` (author-hosted, MIT file present) as the `mask.subject` / background
  primary on macOS, self-converted to ONNX in CI rather than taken from a mirror; `MODNet` (~25 MB, Apache-2.0
  stated over code **and** models, CPU-viable) as the portrait matte tier and the Windows candidate. Both are
  APPROVED WITH CONDITIONS: opt-in, dataset provenance recorded, and a segmentation mask never renamed into a matte.
- **`opencv/inpainting_lama` — conditional, not adopted.** An Apache-2.0 licence file in the OpenCV org is a real
  step up from a Drive link, but the artifact descends from a third-party conversion, so the chain
  LaMa → converter → OpenCV zoo has to be established before it enters the catalogue. Adopting it on the repo
  licence alone is precisely the inference DR-13 prohibits.
- **Excluded with reasons recorded, rows kept.** `RestoreFormer++` (mutable payload, unestablishable grantor —
  fails F1/F3 whatever its licence), RMBG-2.0 and Qwen2.5-VL (NC terms whose use class we are not positioned to
  satisfy alongside their obligations), FastSAM (AGPL against an MIT app), SAM 3 / 3.1 (rights-holder grants the
  download behind personal-data acceptance and the artifact is 3.44 GB — not installable by a free app on the user's
  behalf), `jonathandinu/face-parsing` (CelebAMask-HQ research-only), MobileSAM (mixed uploader licences and a
  quality regression, so no reason to take the risk), and every mirror of EfficientSAM, original LaMa and u2net
  (UNKNOWN: the file exists, the grant does not).
- **Four refusals stay refusals.** Fine matting with a cleared data chain, mask-conditioned generative
  inpaint/outpaint under a redistributable licence at ≤4 B parameters, face parsing with a usable grant, and any
  defensible Windows generative path: none exists today. The capability boundary and the honest blocked state stay
  in the product rather than being filled with an unverified model.
- **Sequencing.** Each of the above is one PR carrying pin, size, SHA-256, register entry, conditions, negative
  integrity tests, benchmark row and truthful UI state. Benchmarks run in CI or an isolated environment — not by
  downloading onto this machine — and `swin2sr-x4` stays in service as the upscaler while the restoration survey
  returns measured alternatives, because ejecting the only working upscaler on an unmeasured preference would be
  the same mistake in the other direction.

---

## Addendum S — 2026-11-23: the whole ledger re-checked against the tree, and most of its line-level citations were wrong

### S.0 Why this addendum exists, and what it does not do

Between Addendum R and now, three trains (A, B, C) and PR #121/#122 landed. Every row of this ledger that
describes a *file* rather than a *decision* was written before them, so the record stopped matching the tree
while the decisions in it stayed valid. I ran a ground-truth pass over the whole ledger against `ac18c1a`
(`origin/main`) and re-read each cited site myself rather than accepting the pass's conclusions.

This addendum is **additive**. The rows below correct the record going forward; no earlier text is deleted or
silently rewritten, because those sections are also the log of what was believed when a decision was taken.
Where a citation drifted, the corrected site is given. Where a claim was simply false, it is labelled false, not
stale.

### S.1 Rows that are now closed by merged work

| Gate | What the ledger said | Measured at `ac18c1a` |
|---|---|---|
| G-CAT | licence evidence fields "absent"; `ModelCatalog.swift` stores only three strings, "no date, no notice text, no verdict" | **Closed.** `Sources/RetouchStudio/Models/ModelCatalog.swift:146-147` declares `let readOn: String` and `let verdict: String`, with the admission guard at `:170`. Landed through PR #121 (train C). |
| G-WIN-1 | the Windows look guard names `lookID` but never `lookStrength` | **Closed.** `Windows/RetouchStudio.Core/Project/DocumentModel.cs:419` resolves the guard through `: Amount("lookStrength")` behind the `LookIdentifier()` sentinel test. Verified by reading the guard, not the PR title. |
| G-WIN-3 | `README.md` falsely states Windows is "not a shipping target" | **Closed.** The paragraph dated 2026-11-22 replaced it; `grep -nE "not a shipping target|no published artifact"` over `README.md` returns nothing. |
| Wave-1 localisation cluster (D2/D4/D7) | Persian readout spells zero as "Zero KB"; `faint` fails contrast | **Closed.** `Sources/RetouchStudio/Models/Digits.swift:57` defines `digitized(_:)`, and `Sources/RetouchStudio/Views/Theme.swift:40` is `Color(red: 0.588, …)`. (Note: `Theme.swift` lives under `Views/`, not at the root — a citation several earlier rows got wrong.) |
| §13 "Ran 166 tests" / DR-12 | `ci.yml` hard-pins a literal worker suite count | **Closed by #110.** The pin now reads `Tests/expected-worker-tests.txt` (211 at `ac18c1a`; 279 on PR #115's head). |
| G-SEP, G-PKG N3/N4/N5 | the three bundle-notice checks "cannot fail" | **Mostly closed, one residue.** `Tools/audit-bundle-notices.sh` fails unless the helper carries non-empty `LICENSE` + `THIRD_PARTY_NOTICES.md`, names every `requirements.lock` pin, and matches each font it claims (`:74-75`). **N6 is still real** — see S.2.4. |
| #107, #110, #111, #113, #114, #99 | open / in progress / blocked | **All resolved.** Merged or closed-as-landed; each head is an ancestor of `ac18c1a` (`git merge-base --is-ancestor`). The §5 PR table is a snapshot of 2026-11-22 and should be read as one. |

### S.2 Claims that were false, not stale

**S.2.1 `--noqtn` coverage.** §7 carried "`--noqtn` fixes quarantine for extracted runtime files — IN PROGRESS
(#107)". Two things were wrong there. #107 merged, so the runtime half is done:
`Sources/RetouchStudio/Core/AIRuntime.swift:146` passes `--noqtn`. But `Sources/RetouchStudio/Core/UpdateVerification.swift:122` — the *updater's* extractor —
still read `["-x", "-k", archive.path, workspace.path]`, so any row that implied quarantine handling was settled
for the app's own update path overstated it. PR #122 closes the code (`--noqtn` plus an EngineTests section that
extracts a marked archive twice and fails if the flag is removed) and corrects `Docs/UPDATE_SYSTEM.md` step 6.
The §7 row that must never be claimed remains unclaimed: `--noqtn` does nothing for the downloaded `.app` itself.

**S.2.2 The sam2 blocker.** §8c and later rows described the sam2 obstacle variously as a missing pin, a missing
digest, and a licence question. None of those is true on `main`: the pin, size (`156008466`) and SHA-256
(`7402e0d8…`) are present in `Resources/model-catalog.json` (now at `:118-119`; earlier rows cite `:77`). What is
missing is the **runtime package**: `grep -icE "sam2|facebookresearch" worker/requirements.lock` returns **0**
against 67 pins, and no `sam2` source is vendored under `worker/`. `capabilities.py` still declares
`packages=("sam2",)` and probes it by import at runtime, so the capability reports BLOCKED for a packaging reason
that has nothing to do with its licence verdict. G-SAM2 stays open, correctly scoped.

**S.2.3 Windows "fail-open" look guard.** §9 called the Windows edit-presence guard fail-open in principle. It is
now guarded and tested (S.1), and `texturePreserve` — the same class of defect found later — is inside the skin
group at `DocumentModel.cs:254-255`. What is genuinely open on Windows is packaging, not decoding: see S.3.

**S.2.4 Two packaging/CI claims I could confirm and had not recorded.**

- `Tools/validate-bundle.sh:39` matches `*"All rights reserved"*|*"all rights reserved"*`. A copyright line in
  uppercase — `ALL RIGHTS RESERVED`, the form several vendors actually ship — exits 0. The check is real but
  case-limited; the ledger said "cannot fail", which is a different and weaker statement than the truth.
- `.github/workflows/ci.yml:183-195` enumerates twelve expected verdicts. `Tests/run.sh` nevertheless builds and
  runs two more: `run-abi.sh` (`:42`) and `MaskQualityTests.swift` (`:66`), whose verdict strings
  `ABI TESTS: PASS` and `MASK QUALITY TESTS: PASS` appear in no assertion list. Those two suites can stop
  executing on `main` without turning macOS Integration red. This is the accurate statement of the gap; the
  earlier framing ("`Docs/CI_GATES.md` claims they are asserted") is wrong — CI_GATES quotes historical job logs
  that carry those strings, which is evidence they ran *then*, not a promise CI keeps *now*.

**S.2.5 A claim I set out to correct and could not.** My own worklist for this pass said the ledger asserted
`build.sh` validates `LC_BUILD_VERSION` against `RETOUCH_VERSION`. It does not, and never did: `LC_BUILD_VERSION`
appears nowhere in the repository or in this file. Recording that matters more than it looks — a correction added
without re-reading the source would have put a false statement about a false statement into a decision ledger.
The real build-stamping facts are the opposite of worrying: `build.sh:104-112` compiles, copies the fresh binary,
copies `Resources/Info.plist`, then stamps `CFBundleShortVersionString` with PlistBuddy **before** codesigning, so
there is no stale-binary path. What `build.sh` does do and does not skip is exec the bundled binary
(`:229` arm64, `:244` `arch -x86_64`) with no opt-out switch — which is why G-BLD is still CI-only.

### S.2.6 G-SUM was understated in both directions, so it is restated precisely.

§3 line 88 and §7 line 156 both say the checksums are generated and "independently re-checked — NOT VERIFIED".
Reading the workflow instead of the row separates two facts the ledger had merged:

- **Generation is executed evidence.** `Tools/make-dmg.sh:30` writes the sidecar next to each DMG (`shasum -a 256`,
  the same `<hash>  <path>` form the verifier reads), and the
  `Release` workflow has run three times by `workflow_dispatch` (latest success 2026-11-15 against `main`), in
  which the macOS packaging jobs — the ones that produce the sidecars — completed.
- **The independent re-check is encoded but has never executed.** `release.yml:181-187` re-verifies every
  `*.sha256` inside the `release` job — a different job from the ones that produced them, on a different runner,
  from artifacts it downloaded rather than wrote — and the loop is non-vacuous because an unmatched glob leaves
  the literal `*.sha256` to fail `sha256sum -c`. But that job is gated on `startsWith(github.ref,'refs/tags/v')`
  (`:159-165`), and no tag has ever been pushed. So the honest status is **implemented, CI-enforced at publish
  time, never performed** — not "missing", and not "verified".
- The publish path itself is **not** broken by the Windows gate, contrary to an earlier note: `release.yml:154-165`
  uses `always()` with explicit result tests that accept `windows-app` as `skipped` while `vars.WINDOWS_APP_READY`
  stays unset, and publishing takes `artifacts/*`, so a macOS-only tag publishes correctly. Verified by reading
  the job, not by a run.

One real defect in the same file *was* found and is being fixed separately: the publish step creates the release
with `--generate-notes` (`release.yml:195`), which means the vetted bilingual notes this release is required to
ship (G-RN) would never reach the release body. Auto-generated GitHub notes are not a substitute for a claim the
project has to stand behind.

### S.3 New open items this pass put on the record, with the evidence class stated

| ID | Item | Evidence |
|---|---|---|
| **S-FLUX** | **Two repository-owned records disagree about one shipped artefact.** §R.3 (2026-11-22, my own decision) states the `flux2-klein-4b-q4` pin "is not distributable as it stands… that fails F1 and F2 regardless of licence". PR #121 then wrote `weights=_approved(…, stated_by=STATED_BY_RIGHTS_HOLDER, verdict=APPROVED)` into `worker/retouch_ai_worker/catalog.py:446`, with `evidence_url` at `mflux-community/flux2-klein-4b-mflux-q4` — a mutable third-party conversion whose card disclaims authorship — and a note asserting the grant was read *at that repository*. The grant exists one level up (`black-forest-labs/FLUX.2-klein-4B`, Apache-2.0). The catalogue therefore attributes to the artefact it downloads a statement made about a different artefact. Read in the shipped surface, §7's G-NOC row lists this entry as selectable. Either re-record against the upstream revision with a pinned conversion commit and CI-generated hashes, or set the artefact's verdict to UNKNOWN so the gate refuses it. **Measured at `ac18c1a`; unresolved.** **CLOSED 2026-11-23: the second option was taken (S.8), and the routing residue it left was closed the same day (S.9). This row is kept as written.** |
| **S-WIN-2** | Windows package attribution. `Tools/package-windows-msi.ps1` and `Windows/installer/Product.wxs` contain no licence/notice handling at all (case-insensitive grep: empty), so an MSI carries no MIT text and no third-party notices. Caveat against overstatement: `build-windows.ps1:226` *does* copy ONNX Runtime's own `LICENSE`/`ThirdPartyNotices.txt` into `AI/`, so "nothing" is too strong. **Measured statically; no MSI was built here (`dotnet` absent).** |
| **S-WIN-4** | No Windows counterpart to `Tools/validate-bundle.sh` exists in `Tools/`. | `git ls-tree` at `ac18c1a`. |
| **S-WIN-6** | The ONNX Runtime MIT grant has never been read from the nupkg's own `LICENSE` by anyone in this project; every row asserting it cites an upstream claim. | No in-tree record of the read. **NOT VERIFIED.** |
| **S-VER** | Version identity is still 1.0.0: `Resources/Info.plist:22-24` and `Windows/Directory.Build.props:13`. `Docs/RELEASE_NOTES_2.0.0.md` does not exist; only `RELEASE_NOTES_1.0.0.md`. | Measured. |
| **S-ADVERSARIAL** | The §4 adversarial matrix still has no committed seed→test→exit table; `WORKER_CI_VALIDATION_PLAN` lists seeds with nothing pinning them. | `git grep` at `ac18c1a`. |
| **S-DISK** | The disk probe still conflates "capacity unknown" with "volume full" at five sites, and `Tests/ModelStoreTests.swift` pins `freeBytes: 0` assertions that encode the conflation. | Carried forward from §Phase-1; **re-confirmed open, not re-measured this pass.** |

### S.4 Release readiness, stated as coverage rather than as a number

The mandate forbids a percentage without a defined measurable checklist, so none is given. What can be said
without inflating it:

- **Implemented and locally measured:** the fail-closed integrity gate on PR #115's head (worker suite
  `Ran 279 … OK` through `Tests/run-worker.sh`, with the linked-directory case proved to fail against the
  previous implementation), and the updater quarantine fix on PR #122 (`ENGINE TESTS: PASS`, plus a mutation run
  that turns it into `FAIL (3)` when the flag is removed).
- **Implemented, evidence is CI-only:** every Windows context, the four-arch macOS suites, and the golden-corpus
  protection. `dotnet` is absent on this machine, so nothing Windows was executed here.
- **Not verified at all, and load-bearing for a release:** any first-launch behaviour of a real downloaded bundle
  (G-ACC, D11), the truthfulness of the Gatekeeper instructions in release notes that do not exist yet, any
  cross-Mac launch of a non-notarised build, production of a 2.0.0 artefact (G-BLD — this Mac cannot compile the
  bundle; the CLT toolchain has no `SwiftUIMacros`), and every live inference claim.
- **Blocked on a decision recorded as unresolved:** S-FLUX. It is a §4 provenance item inside the model-ecosystem
  authority, and I am not treating a licence grant held by someone upstream as a grant held by the file we ship.
  **Superseded later on 2026-11-23, by S.8–S.10: the decision was taken (weights verdict `unknown`, so the gate
  refuses the download), the routing consequence of it was fixed and proved in CI, and all of it is on `main` as
  `00aa37f`. Nothing in this bullet is owner-blocked any more.**

G-QA and G-PUB remain **BLOCKED** and **NOT AUTHORIZED** exactly as §9 and §11 define them: the owner runs the
acceptance session, and publication, tags and release assets stay his. `Docs/RELEASE_2.0.0_ACCEPTANCE.md` exists
as a deliberately blank form; it has not been filled because filling it requires the app to be launched.

### S.7 — 2026-11-23: one S.1 row overstated its own evidence, and the overstatement is now measured

The S.1 row titled **"#107, #110, #111, #113, #114, #99 | open / in progress / blocked"** concluded **"All
resolved. Merged or closed-as-landed; each head is an ancestor of `ac18c1a` (`git merge-base --is-ancestor`)."**
That sentence is false for two of the six PRs, and the command quoted to back it is a command that can report
falsehood as fact: against a head object the local clone has never fetched, `git merge-base --is-ancestor` exits
non-zero, which is indistinguishable from "not an ancestor". Re-measured after fetching each head explicitly
(`git fetch origin pull/<n>/head`) against `origin/main` at `49786a0`, and again while this
addendum was being committed:

| PR | State | Head | Ancestor of `main`? | What is actually true |
|---|---|---|---|---|
| #107 | MERGED | `2c95eb7` | yes | Runtime `ditto --noqtn` fix, landed. |
| #110 | MERGED | `830ea3d` | yes | Worker gates and the single suite-count source, landed. |
| #111 | MERGED | `d4e4996` | yes | Bundle notices, landed. |
| #99 | MERGED | `d6fccae` | yes | Wave-1 localisation/contrast batch, landed. |
| **#113** | CLOSED | `c0ccce6` | **no** | **Closed-as-landed, fully.** Exactly one commit is unreachable from `main`:
`c0ccce6` itself, "Merge main into w5-200-windows-look-guard" — a sync commit carrying no content. Every
substantive commit is on `main` through Train A — `0caf9a7`, `eb9f869`, `33809e4`, `6f603d5`, `8406757` and the
review head `7e09a6a`, each confirmed an ancestor of `origin/main`, under merge `bf9a4ca` — and the two files
that PR owned are **byte-identical** between `c0ccce6` and `origin/main`:
`Windows/RetouchStudio.Core/Project/DocumentModel.cs` and `Windows/RetouchStudio.Tests/Program.cs` (compared by
`git rev-parse <rev>:<path>` blob OIDs). So the gate G-WIN-1 is genuinely closed; only the ancestry wording was
wrong, and the correct proof is tree equality, not genealogy. |
| **#114** | CLOSED | `7dec6bf` | **no** | **Superseded, not landed.** Four commits unique to that head never
reached `main`: `2656db1` (docs), `1a74c79` "worker: replace commercial_ok with a four-status permitted-use
record", `f4c4b3e` "app: mirror the permitted-use record and keep evidence in-repo", `7dec6bf` "tests: the host
reads the licence refusal as blocked, not missing". Its `weightsEvidence` schema is absent from the shipped
catalogue — `grep -c weightsEvidence` over `Resources/model-catalog.json` at `origin/main` returns **0**, against
4 `permitted_use` entries. |

### What G-CAT therefore rests on

The gate called G-CAT is closed **on the `permitted_use` schema delivered through PR #121 (Train C)**, not on the
schema #114 proposed, and this row is the record of that substitution. Checked against `origin/main` rather than
inferred:

- The refusal path exists and is named: `worker/retouch_ai_worker/protocol.py:24` defines `LICENSE_BLOCKED =
  -32010`; `catalog.py:986`, `:996`, `:1005` and `plan.py:33`, `:39`, `:47` raise it; `capabilities.py` applies
  the same admission test, so a record that does not admit its weights reports the capability blocked instead of
  selectable.
- Both hosts read that refusal as a licence refusal, which is the half #114 never delivered:
  `Sources/RetouchStudio/Core/WorkerClient.swift:34` maps `-32010` to `E_LICENCE_REFUSED`, and
  `Windows/RetouchStudio.AI/WorkerClient.cs:43` maps it to the same string. `opensModelManager`
  (`WorkerClient.swift:59-64`) does **not** open the manager for `-32010`, so an unadmitted model cannot be
  presented to the owner as "go download it" — which is the behaviour the S-FLUX remedy depends on.
- Asymmetric test coverage worth naming rather than glossing: `-32021` has a host test on
  Windows (`Windows/RetouchStudio.AI.Tests/Program.cs:326-341`); **`-32010` has no test pinning the mapping on
  either host.** The mapping is real and readable in the source; it is not guarded against regression. Ticketed,
  not closed.

### Consequences for the open work

Two rows that read as "all resolved" are not, and both stay open with their evidence class stated:

1. **Task #134 stays open.** #114's regeneration-idempotency and bidirectional cross-check fixes died with that
   branch; the tooling that writes `permitted_use` inherited none of them.
2. **The G-UI half of G-CAT was never delivered by either PR.** Surfacing the grant URL, the read date and the
   verdict in the consent sheet and the model row, in English and Persian, is listed as out-of-scope in #114's
   own description and is not implemented on `main`. It remains task #115, and it needs a design agreement and a
   live session, not a code change alone.

And a process rule this measurement earns: in this ledger, an ancestry claim must name the object it compared
and state whether that object was fetched, because "I could not see it" and "it is not there" produce the same
exit code.

### S.8 — later the same day, 2026-11-23: S-FLUX closes as `unknown`, and the gate now refuses the download

S-FLUX above offered two ways out — re-record against the upstream revision, or set the
artefact's verdict to `unknown`. **Chosen: `unknown`.** Not because the re-record is wrong
but because it is not available under this slice's constraints: it needs 4.6 GB of weight
downloads to verify the published digests, which the model-ecosystem authority forbids on
this machine without authorisation. Recording a permission we cannot evidence would repeat
the mistake S-FLUX describes.

`Docs/MODEL_LICENCES.md` §12 carries the full evidence, the two corrections the research
package needed before it was allowed into the record, and the three ways to close the item
later. In one line: the Apache-2.0 grant is real and is now anchored to a revision
(`black-forest-labs/FLUX.2-klein-4B` @ `e7b7dc27…`, `LICENSE.md` 9,584 bytes, sha256
`ca02bc51900ab07789d1b70283329e7137f5af98f5161c23a1c81fc38a4af1fe`, verbatim, no
field-of-use clause, no NOTICE file), and what cannot be established is the link from that
revision to the pinned community conversion — whose repository ships no licence file at
all, whose head has already moved from `77090341…` to `794cd159…`, and whose card asserts
the lineage without naming a revision.

**What the shipped behaviour becomes** (each row asserted by a test on this branch, none of
it inferred):

| Site | Before | After |
|---|---|---|
| `catalog.py` FLUX weights record | `approved` / `rights-holder` / axes `true` | **`unknown` / `not-established` / axes `null`** |
| `Resources/model-catalog.json` | same claim, regenerated surface | **same claim as the worker, byte-for-byte, via `licence-evidence-apply.py`** |
| `plan.py` `manifest()` | returned a 4.6 GB download plan | **`LICENSE_BLOCKED` (−32010)** |
| `catalog.py` `require_verified()` | loaded | **`LICENSE_BLOCKED` (−32010)** |
| `capability.list` → `generative.edit`, `generative.reimagine`, `inpaint.object` | `requires_model` | **`blocked`**, reason carries "no established permission" and "weights verdict: unknown" |
| `capability.list` → `inpaint.spot`, `upscale.4x` | `requires_model` | **unchanged** — the refusal is entry-scoped, not feature-scoped |
| Both hosts on −32010 | — | **`E_LICENCE_REFUSED`, and `opensModelManager` returns false** (`WorkerClient.swift:34`, `WorkerClient.cs:43`) so a refused licence is not presented as a missing model |

Proven end-to-end against `origin/main`'s own worker code before the branch was cut: a
baseline record loads, the mutated `unknown` record still passes `validate()` (so this is a
licence decision, not a schema violation), and the same mutated record yields −32010 from
both `manifest()` and `load()`.

**Two honest limits on that sentence.** (1) `load()` accepts an `allow_uncleared` escape
hatch, reachable in production only through `RETOUCH_AI_EVAL_MODELS=1`; both launch sites
now strip that variable (`AIWorker.swift:599`, `AIRuntimeValidation.swift:211`), so the
shipped app cannot reach it — but a person starting the worker by hand through
`run-worker.sh` can, and that is a documented operator action, not a guarantee in code.
(2) The −32010 → `E_LICENCE_REFUSED` mapping is **tested only for −32021** on Windows
(`Windows/RetouchStudio.AI.Tests/Program.cs:326-341`); no test pins the −32010 branch or
the `opensModelManager` answer on either host. Tracked as an open item, not closed here.

**Not touched:** `migan` (MIT code *and* `LICENSE-WEIGHTS` — spot healing stays offered),
the §11 `swin2sr-x4` record, every other catalogue entry, the MIT repository licence, and
the FLUX inference code itself. A refused record is a metadata decision; deleting the
loader would destroy the only harness a future re-record can be tested with.

The user-visible consequence for 2.0.0 is what `Docs/RELEASE_NOTES_2.0.0.md` now says in
both languages: generative editing and diffusion-based object removal are not offered.

Closing S-FLUX also moved one host-side pin, and only CI found it. `Tests/RuntimeV2Tests.swift`
probed the capability gate through `generative.reimagine` — whose only catalogue model is this
entry — and asserted the refusal was `-32011 E_MODEL_MISSING`. That assertion was true for a
reason unrelated to what the check exists to prove (the weights simply were not installed), and
the same gate now answers `-32010 E_LICENCE_REFUSED` because the record refuses its own weights.
The check moved to the new code with its name restated, not loosened: it still asserts that
naming a capability makes the helper apply its verdict before a job folder exists, and the
adjacent label-route check still proves the verdict does not silently become the gate (A2). The
worker suite, `ModelStoreTests` and the generator check were all green locally first, so the
record of this slice includes the fact that my local gate set was too narrow to see it. The
corrected check cannot be exercised here at all: this machine has no installed helper runtime,
so `RuntimeV2Tests` reports 4 failures named M, N, O and P, every one of them
`posix_spawn failed (errno 13)` — the helper refusing to start, which is environment and not
catalogue logic. Whether the same four fail at `main` on this machine was **not measured**, so
this suite's verdict is CI-only and is recorded as such rather than claimed.

### S.9 — later the same day, 2026-11-23: S.8's last paragraph claimed a gate behaviour that the head it described did not have

S.8 closed with the sentence "the same gate now answers `-32010 E_LICENCE_REFUSED`". **That was
false at `281f7ae`, and CI is what proved it**: run `45131036490` failed `macOS Integration` at
"Run engine, model and runtime suites" with `RUNTIME V2 TESTS: FAIL (1)`, on exactly the check
that sentence was about —

```
✗ P: naming a capability whose only model is licence-refused stops the job —
  flux2-klein-4b-q4 has no established permission for public non-commercial use
  and distribution (weights verdict: unknown), so this build will not download or run it
```

Writing the assertion was not the same as making it true.

The defect was real and it was in the worker, not in the test. `server.py::_require_capability`
answered *every* non-ready capability state with `-32020 E_UNSUPPORTED` plus
`data.capabilityState = "blocked"`. On the macOS host, `WorkerClient.opensModelManager` returns
true for `-32020` when the state is `blocked` and `missingPackage` is `nil` — a reasonable rule,
because a blocked capability normally waits for the user to do something in the model manager
(adopt a legacy install, install weights, record a run). `missingPackage` is populated only by
the sam2 import path in `engine.py`, never at this gate. So a refusal whose cause was a licence
record opened the model manager with a "waiting for you" sentence, and nothing there settles a
permission. The host already mapped `-32010` to `E_LICENCE_REFUSED` without opening the manager;
the worker was simply not using that class.

**The fix is one source for the answer.** `capabilities.py` now owns
`permission_refusal(entry, catalog)` — excluded terms first, then the not-admitted sentence — and
`report()` builds its `blocked` reason from it instead of carrying two hand-written copies. The
job gate calls `capability_permission_refusal()` before it looks at the capability record and
raises `LICENSE_BLOCKED`, so the report and the refusal cannot disagree about which class a
permission is. A record that fails `validate()` keeps its own code: that is a catalogue defect
(`-32021`), not a licence answer, and the helper returns `None` for it on purpose.

**What was *not* wrong, stated because a review round claimed it was.** The suggestion that jobs
could reach an unverified download — "fail-open at submission" — does not survive reading
`catalog.py`. `_require_licensed()` is the first thing both accessors do (`require()` at
`catalog.py:1163`, `require_verified()` at `:1248`), and its own docstring says the refusal order
is what the host's routing keys on: licence first, so a licence answer never depends on what is on
disk. `plan.manifest()` — the download planner the `model.plan` RPC calls — refuses an excluded
record (`plan.py:36-43`) and a not-admitted one (`:44-47`) before it emits a single URL.
No unadmitted byte was ever downloadable or loadable. Two asymmetries are worth naming rather
than leaving implicit, and this slice changes neither: the Python admission test is the aggregate
`permitted_use.admitted` plus the excluded list, while the Swift host additionally walks each
artefact's own `isAdmitted` (`Sources/RetouchStudio/Models/ModelCatalog.swift`), so a record whose
aggregate claims admission while one artefact refuses it is caught on the host and not by the
worker; and Python's aggregate check honours the `allow_uncleared` escape hatch whereas
`manifest()` does not.

**Test evidence for this round** (each item measured, not inferred):

- Worker suite through `Tests/run-worker.sh` with the working interpreter: `Ran 286 tests … OK`,
  `VERDICT: PASS`, rc 0. Three `test_server.py` assertions moved from `-32020` to `-32010` and
  keep their `state == "blocked"` and reason-text assertions — the class changed, the strictness
  did not. One new test submits `patch_edit` with *no* capability name against the shipping
  catalogue through a real socket, so the kind-only path answers the permission question itself
  (`-32010`, `data.model == "flux2-klein-4b-q4"`, `data.verdict == "unknown"`).
- `Tests/expected-worker-tests.txt` now reads **286**; the count guard fired at `286 != 285` first
  and the source was updated to the measured number rather than the test being dropped.
- `python3 Docs/licence-evidence-apply.py --check`: `OK: catalogue current, sha256 0a5e3386…`.
  Two shipped record strings changed under this round and both went through the generator, never
  by hand: `weights.readOn` moved to `2026-11-23` (the date of the read that produced the verdict —
  §1 defines `readOn` as the rot-detection date, and §10 already moved `swin2sr-x4`'s to
  `2026-11-22` for the same reason), and `code.note` said the grant was read "at this repository",
  which is the attribution §12.5 exists to retract. `Tests/ModelStoreTests.swift` pins both record
  dates, and it caught the first one: the suite failed `flux2-klein-4b-q4/weights was read on its
  pinned date` before the pin moved to the new truth.
- `ModelStoreTests`: `MODEL STORE TESTS: PASS`, rc 0, 449 `✓` lines and the suite's own
  `✓ all model-store checks passed`. **Correction to the first draft of this bullet, which said
  "233 checks, 0 failures": the suite prints no total, so that number was never measured and is
  withdrawn** — the log (`/private/tmp/rs-mst-rebase.log`, and CI's `found: MODEL STORE TESTS:
  PASS`) supports only the figures above. Its shipped-table probe
  no longer assumes `flux2-klein-4b-q4` by name — that entry now derives `admitted = false`, which
  silently converted nine validator-rule checks into assertions about the not-established rule —
  and the probe record is selected from the shipped JSON and pinned by a check that fails if no
  granting record exists.
- The whole app source tree type-checks under the CLT SDK: 0 errors. This caught a real mistake in
  the copy edit below (a Swift-invalid adjacent-string-literal), which the CI-less local gate set
  would otherwise have shipped.
- `RuntimeV2Tests` compiles and aborts at check **M** with `posix_spawn failed (errno 13)` — the
  same installed-helper blocker S.8 recorded. **The rewritten P block, including
  `opensModelManager == false` and the `-32020` contrast leg, therefore never executed here and
  is CI-only.** Its verdict in this ledger comes from CI, not from this machine.

**Surfaces that were still asserting the retired claim, now corrected in the same slice:**
`Docs/W5_IMPLEMENTATION_DECISION_RECORD.md`'s capability matrix called `inpaint.object`,
`generative.edit` and `generative.reimagine` "FLUX.2 klein (shipped)" — the three rows the S-FLUX
decision makes false — and carries a dated correction under the table rather than a silent
rewrite. `Docs/MODEL_LICENCE_EVIDENCE.md`'s own status line still promised "data layer only …
changes no install, download or refusal decision"; it is kept as the decision record with a dated
correction above it. The onboarding tutorial said, in both languages, "FLUX.2 klein, SAM 2.1 and
Swin2SR are Apache-2.0; MI-GAN is MIT" — false for the artefact this build pins — and now says
what the record says. The Model Manager derived its `code / weights` licence tokens from the flat
historical strings, which DR-13 keeps stale by design; those tokens now come from
`permittedUse.…isAdmitted`, with a new bilingual key `modelsLicenceUnestablished`
("licence not established" / «مجوز اثبات نشده»). Measured against the shipped JSON, exactly one
entry changes: `flux2-klein-4b-q4`. `sam2.1-hiera-tiny`, `swin2sr-x4` and `migan` still read
`Apache-2.0` / `MIT` because their records *are* admitted, so the row is a correction and not a
blanket warning.

**Open after this round, with their evidence class:** the `-32010` → `E_LICENCE_REFUSED` mapping
still has no host-side unit test on either platform (macOS is now covered at RPC level by the P
leg, Windows not at all — `dotnet` is absent here); the gate's error payload omits `modelId` and
`package`, so the host's `missingPackage` branch cannot fire from a gated job; the consent sheet
still shows no licence-evidence fields; and no live acceptance of any of it exists, because
launching the app is not authorised. S.4's rule stands: no readiness percentage is given.

### S.10 — later the same day, 2026-11-23: CI supplied the gate verdict, an independent review
found two real asymmetries, and the `Windows App` context became unreliable

**CI proved the behaviour S.9 could only claim.** `macOS Integration` on run `45138992397`
(attempt 1, head `eee3e4b`, log window 08:29–08:56Z) executed the `RuntimeV2Tests` P block that
this machine cannot run, and its runner log prints, verbatim:

```
[P] a labelled job runs where a named capability is refused
  ✓ P: naming a capability whose only model is licence-refused stops the job — flux2-klein-4b-q4 has no established permission for public non-commercial use and distribution (weights verdict: unknown), so this build will not download or run it
  ✓ P: a licence refusal sends the user nowhere the download can settle it — -32010 E_LICENCE_REFUSED opensManager=false
  ✓ P: the gated spelling leaves no job folder
  ✓ P: a capability this job kind does not carry is refused as unsupported — upscale.4x is not a patch_edit capability
RUNTIME V2 TESTS: PASS
```

and the job's own verdict grep prints `found: RUNTIME V2 TESTS: PASS`, so the suite is credited as
having run rather than assumed. Two things follow that S.9 asserted but could not evidence. The
worker's licence sentence reaches the host through the gate — it is the text in the second line —
and the refusal class is attributable to the *record*, not to a blanket "generative is gated"
answer, because the same host, same job kind and same build returns `-32020` for `upscale.4x`.
The P block's evidence class therefore moves from CI-only-in-the-future to **VERIFIED (CI)**; the
live-app surface above that boundary is still NOT VERIFIED.

**Mandate §7 independence was obtained, and it found two asymmetries I had not stated.** A reviewer
with no role in the implementation read `6c6559c`/`1c77072` and the current
`capabilities.py`, `catalog.py`, `server.py` read-only and returned **ACCEPT WITH COMMENTS**. Its
confirmations: the raise sits before any job registration or folder creation
(`server.py:334-345` before `record(...)` at `:346`; dispatch calls `_require_capability` at `:421`
ahead of `manager.submit` at `:422-425`), and no path inside the gate defaults to "allow". Its two
findings are real and stay open as tickets rather than being fixed inside this PR, because each
needs a decision this slice does not own:
1. **A malformed licence record still looks like a missing download.** `permission_refusal`
   (`capabilities.py:218-221`) returns nothing when `entry.validate()` fails, so an invalid record
   falls through to `record(...)` → `-32020 state:"blocked"` with no `package`, and
   `WorkerClient.opensModelManager` (`WorkerClient.swift:62`) *does* open Manage Models for that
   shape. The classified-as-catalogue-defect route is deliberate; the routing consequence was not
   intended and is the same user-visible defect S-FLUX was raised about, on a narrower path.
2. **The eval switch and the manifest disagree.** With `RETOUCH_AI_EVAL_MODELS=1` the gate returns
   no refusal while `plan.manifest` ignores the switch (`plan.py:44`) and still refuses `-32010`, so
   a job can be admitted whose model then cannot be downloaded. This is **not reachable from the
   shipping app**: both launch paths strip the key — `AIWorker.swift:599` and
   `AIRuntimeValidation.swift:211`, and this was re-checked on `origin/main`, not only on this
   branch — so the exposure is test-only. The ledger's own history already says this correctly:
   §E.3 recorded the missing strip as a live defect, and §L.4 and §R.2 recorded `AIWorker.swift:599`
   as the change that removed it, so this finding narrows the leak to the worker's own tests rather
   than contradicting an earlier row.

Three smaller items are recorded without action: the `{"state": "blocked"}` field in the gate's
payload is inert for the macOS host (both of its consumers key on `-32020`,
`WorkerClient.swift:74`/`:87`); the kind-only refusal path carries `{model, license}` but no
`capabilityId`, so the host falls back to the generic `aiLicenseBlocked` string
(`EditorModel.swift:1765`); and `ModelStore.install` gates on integrity alone
(`ModelStore.swift:315-318`, `738-753`) — FLUX stays un-downloadable because of its consent/hash
path, not because of an explicit licence check on the download side. That last one is a fail-open
of a kind §4 cares about, and it is a ticket, not a claim.

**One figure in S.9 was invented and is withdrawn.** S.9 wrote "`ModelStoreTests`: PASS, 233
checks, 0 failures". The suite prints no total, so 233 was never measured. The local log
(`/private/tmp/rs-mst-rebase.log`, re-run against the committed tree) contains **449 `✓` lines, no
`✗`, `✓ all model-store checks passed`, `MODEL STORE TESTS: PASS`, rc 0**, and CI's own grep prints
`found: MODEL STORE TESTS: PASS`. Only those figures are supported; the correction is in the S.9
bullet itself rather than by deleting it.

**`Windows App` went nondeterministic on this head, and this PR was not merged over it while red.**
On head `eee3e4b` the required context failed three attempts with *no change of input*: attempts 1
and 2
(08:29–08:43Z, 08:58–09:11Z) died in UI mode `exportclose` with `UI CHECK FAILED: Unrecognized
error.` — a message that exists nowhere in this repository and is printed verbatim from the caught
exception at `Windows/RetouchStudio.UiTests/Program.cs:153-158` — while the other thirteen legs
passed (`WINDOWS HOST TESTS: PASS (405 checks)`, `AI RUNTIME TESTS: PASS`, `MODEL STORE CHECKS:
PASS`). Attempt 3 (09:15–09:21Z) got *further*: `exportclose` never ran, and AI runtime section
`[C]` failed with `FAIL the helper publishes a ready registry record — (no log)` after exactly 30
seconds, which is a startup timeout in a different suite. For contrast, `Windows App` had succeeded
four times earlier the same day on PR heads `c42bc1d` (05:52–06:09Z and 06:30–06:47Z), `6aa3b22`
(07:02–07:19Z) and `281f7ae` (07:25–07:41Z). The round-2 diff touches no Windows source, and the
one Windows check that reads the shipped catalogue (`[M17]`) passed in every attempt.

That is evidence of runner-level instability, not proof of it, so an earlier private inference in
this round — "the diff cannot break Windows" — is retired as unsupported. Instead a control was
dispatched: branch `w5-flake-control`, commit `405dd7d`, pull request **#127**, which adds exactly
one Markdown file and changes no code, resource, catalogue, test or build script, so its
`Windows App` job measures the runner. The rule agreed before reading its result: if the control
also fails `Windows App`, the environment is shown unreliable and #126 merges on its own green
attempt with this table recorded; if the control passes, that alone does not exonerate #126, which
keeps its gate until one of its own attempts goes green. Under no reading is the context skipped,
and `main`'s protection still requires it.

**Both outcomes arrived, and they say different things.**

- **PR #126, attempt 4** — `Windows App` job `137598827326`, 09:26:36→09:41:48Z, **success** with no
  `FAIL` line anywhere in the log: `WINDOWS HOST TESTS: PASS (405 checks)`,
  `MODEL STORE CHECKS: PASS`, `AI RUNTIME TESTS: PASS`, `WINDOWS APP BUILD: PASS`, fourteen
  `UI HOST TESTS: PASS` markers (both previously failing modes included), and the gate step's five
  `found:` verdicts including `ONNX Runtime 1.32.0 matches the recorded size and SHA-256` and
  `upscale stays blocked without an approved artifact`.
- **The control, PR #127** — job `137599944801`, 09:28:49→09:43:19Z, **success** on the same shape
  of work (405 checks, fourteen UIA modes, 524 `ok` assertion lines) from a commit that changes one
  Markdown file.

Attempt 4 is the decisive measurement, and it is narrower than it looks. A byte-identical head that
failed three times and then passed once proves the three failures were **not a deterministic
property of `eee3e4b`** — which is what the merge gate needed, and it was satisfied by this PR's own
green attempt, not by the control and not by skipping a check. It does *not* show the two
`exportclose` failures were harmless in some deeper sense, and the control passing in the same window
says the runner was not uniformly broken at that moment: the instability is intermittent per job,
which is exactly why it cannot be reasoned about from a single sample.

`Windows App` therefore merged green at attempt 4: PR #126 merged into `main` as `00aa37fc` at
09:47:48Z, and `develop` was fast-forwarded `11a4b8f..00aa37f`. That closed the last open pull
request, so `main == develop == 00aa37fc` with **zero open PRs**. The control PR #127 was closed
unmerged with this outcome recorded on it, and its branch and commit `405dd7d` are kept as the
audit artefact rather than deleted, so the "no-op" claim can be re-checked.

**The flake is itself a release-process risk, and it is recorded as one.** A required context that
needed four attempts to go green is a gate that can only be cleared by retrying, and a retry-until-green
habit is how a genuine intermittent regression gets masked. Two mitigations are now tracked: the
diagnostics gap that made all three failures undebuggable after the fact (`Program.cs:153-158` prints
only `error.Message`, dropping type, HRESULT and stack; the ready-record timeout prints `(no log)`),
and the rule this addendum follows — whenever a required context is retried, the attempt count, the
legs that failed and the verdict lines of the attempt that passed belong in this ledger, not in an
operator's memory. Neither the Windows `-32010` mapping nor any live-app surface gained evidence from
these retries: `Windows App` passing means the Windows build and its fourteen UIA modes are intact,
which is not the same as the licence refusal being tested on that host, and that gap stays open
exactly as S.9 stated it. S.4's rule still stands: no readiness percentage is given.

## Addendum S.11 — 2026-11-23: the release candidate is built by CI from final `main`, and publishing is still the owner's

S.10 left `main == develop == d09ad7b` with zero open pull requests, which was the precondition this
mandate set for the one thing that can only be done last: build the candidate from the exact commit
that will be published. That build has now run, its artefacts have been re-verified from outside CI,
and one property of it needs the owner's attention more than any other entry in this ledger.

**The run.** `Release` (`workflow_dispatch`) at ref `main`, head `d09ad7b`, run `45156446702` — that
workflow's own run number 4 — 10:28:38→10:43:53Z, conclusion **success**. Before dispatching,
`gh pr list --state open` returned `[]`, so the candidate is not "main plus an open branch".

| Job | id | result |
| --- | --- | --- |
| macOS arm64 | `137630514475` | success |
| macOS x86_64 | `137630514641` | success |
| Windows StudioCore | `137630514325` | success |
| Windows x64 application | `137630514039` | success |
| Publish GitHub Release | `137638355037` | **skipped** |

**Publishing was structurally impossible from this trigger, and I checked it twice rather than
trusting the shape of the YAML.** The `release` job is gated at `release.yml:159-166` on
`startsWith(github.ref, 'refs/tags/v')`, and a non-tag build stamps `VERSION="0.0.0-ci"`
(`:34-36`). After the run: `gh api repos/iR0ham/RetouchStudio/tags` still lists exactly one tag,
`refs/tags/v1.0.0`, and the only release is the archived v1.0.0 pre-release of 2026-11-09 with its
8 assets, unchanged. **No tag was created, no release was created, no asset was uploaded, and v1.0.0
was not touched.** Those remain the owner's reserved actions.

### The packages, and what I re-measured rather than copied

| Artefact | Contents | Size | SHA-256 |
| --- | --- | --- | --- |
| `macos-arm64` (id `14807709194`) | `RetouchStudio-0.0.0-ci-arm64.dmg` 4,507,771 B + `.sha256` | 4,486,109 B (zip) | DMG `9ce472b754e56f9b586d52c8c2c3a70d3a0c32690da365a2a1a129e04171e6b1` |
| `macos-x86_64` (id `14809176395`) | `RetouchStudio-0.0.0-ci-x86_64.dmg` 4,729,336 B + `.sha256` | 4,705,846 B (zip) | DMG `86c10e70e13a067c84395f70fef38daa89e59aaf4114709ac0491c0f0eac1031` |
| `windows-x64` (id `14809422769`) | `RetouchStudio-0.0.0-ci-windows-x64.msi` 176,354,224 B, `…-x64.zip` 195,171,886 B, each with `.sha256` | 369,365,433 B (zip) | MSI `b99b247113a6f80bdfa513755a25d9630161b0428bb0aa72c2b25c76d92c5d0b`, ZIP `a1c2bf473d12493a9af9f67681fa25583c630f8b322a25b69eb5c966a958d91c` |

The two macOS artefacts I **downloaded and checked myself** (`shasum -a 256 -c` against the shipped
sidecars): both `OK`. That is the promise a published release makes — the checksum file beside the
image matches the image — verified off-runner. The 369 MB Windows artefact I did **not** download,
under the standing rule against pulling large files onto the owner's machine; its digests above are
the ones the packaging step printed into the sidecars (`rc-windows-x64.log:1677`, `:1690`), which is
the same class of string that a tag build's publish step re-checks with `sha256sum -c`
(`release.yml:181-186`) before it uploads anything. The log also shows the packaging self-test builds
a second MSI, `RetouchStudio-0.0.1-ci-windows-x64.msi` (`:1703-1705`), and then states
`dist holds the one package for this run: RetouchStudio-0.0.0-ci-windows-x64.msi` (`:1711`) — so the
run ships one Windows package, not two. Retention for all three artefacts ends
**2027-02-21T10:28:41Z**; the repository is PUBLIC and an anonymous request for an artefact page
returns 404, but I did not test whether a signed-in non-collaborator can fetch it, so these packages
are "unpublished", not "confidential".

### What is inside them is not the same on each platform, and that is the acceptance-relevant fact

`release.yml` sets `RETOUCH_SKIP_WORKER: '1'` at job level for **both** macOS arches (`:25`, `:55`),
and `build.sh:170-176` honours it by parking the helper instead of shipping it. The build's own
bundle report says so: `· helper runtime not bundled (AI tools unavailable)`. The fallback that would
fetch a runtime is deliberately inert as well — `AIRuntime.package` is `nil` (`AIRuntime.swift:40`),
with the comment recording why: no protocol-v2 package has been published and no URL, size or
checksum is invented to pretend otherwise.

**So a clean install of either RC DMG is the editor alone: no 4× upscale, no enhancer, no click
mask, and no in-app route to obtain them.** That is not a regression introduced by this round — it is
the standing runtime-delivery gap, recorded as such since Milestone R1 and in §8 of the mandate — but
until now it has not been visible in an artefact. An acceptance session run against these DMGs must
expect it, and anyone reading "AI capability matrix: green in CI" alongside "these DMGs cannot run AI"
has to reconcile them the way this paragraph does: the capability code, its gates and its tests are
green; the *shipping macOS package contains no helper to run them*.

Windows differs, and the reason is a real asymmetry rather than a flag: `RETOUCH_SKIP_WORKER` is read
only by `build.sh` (`build.sh:170` is its only consumer outside that file), so its presence on the
`windows-app` job (`release.yml:113`) is **inert**, and
`./Tools/build-windows.ps1 -RequireMsi` publishes the helper anyway — the log shows
`-> publishing the AI worker and its native payload into the app` and
`AI worker, protocol library and ORT CPU payload present` (`rc-windows-x64.log:816`, `:823`). That is
why the MSI is 176 MB against a 4.5 MB DMG. Model weights remain separately consented downloads on
both platforms and are still subject to the licence gate, which is the behaviour S.9 and S.10
verified. **Open question for the owner before any tag:** is "macOS editor-only + Windows with its
helper bundled" the intended 2.0.0 shape, or must a published protocol-v2 runtime land first?

### Version identity, recorded because publishing cannot undo it

The committed sources agree on the short version — `Resources/Info.plist` is `2.0.0` with
`CFBundleVersion 2`, and `Windows/Directory.Build.props` is `<Version>2.0.0</Version>` — and
`Tools/check-versions.sh` is what a tag build runs first (`release.yml:175`) to force tag, plist and
props to agree. It does **not** compare build numbers, and `release.yml` passes
`RETOUCH_BUILD="$GITHUB_RUN_NUMBER"` (`:38`, `:68`) into `build.sh:113-115`, which writes it into
`CFBundleVersion`. The consequence is printed in this very build: `✓ آماده است … نسخهٔ 0.0.0-ci (4)`.
A `v2.0.0` tag built today would therefore ship **`2.0.0 (5)`**, not the checked-in `(2)`, and the
number would keep moving with each release-workflow run. Since `CFBundleVersion` is what macOS uses
to decide whether a package is newer than what is installed, this belongs to the owner's existing
"build stamping" decision rather than to engineering taste, and it is cheaper to settle before the
first 2.0.0 asset exists than after.

### Signing: this build confirms the limit, it does not clear it

Both macOS jobs print `! امضای ad-hoc — فقط برای اجرای محلی؛ امضای انتشار عمومی نیست.` and
`! signature: ad-hoc (runs locally; not a public distribution signature)`, and neither log contains a
notarisation step or a `notarytool` invocation. `signtool` and `Authenticode` appear **zero** times in
the Windows job, so the MSI is unsigned. This matches the owner's 2026-11-21 decision that the Apple
Developer Program is declined and ad-hoc signing is permanent, and it means every installer in this
candidate will meet a Gatekeeper "unverified developer" prompt (Windows: an SmartScreen "unknown
publisher" prompt). The acceptance pack already assumes this; the release notes must not promise
otherwise.

### Evidence ladder after this addendum

**VERIFIED (CI, this run):** the three packaging jobs build from final `main`; the DMG checksum
sidecars match their images when re-checked off-runner; the publish job cannot fire on a dispatch and
did not; the pipeline is re-runnable for a tag with `RELEASE_NOTES_2.0.0.md` (present, 32,015 B) and
`WINDOWS_APP_READY=true` (`release.yml:112`) satisfying its two other gates. And one thing I nearly
missed while writing this addendum, which is why I re-read the job logs instead of trusting my
summary of them: **the Windows package is installed and run by CI.** `rc-windows-x64.log:1692-1711`
records `installed C:\Program Files\Retouch Studio\RetouchStudio.exe as 0.0.0.0`, a window loading
in 1224 ms, an uninstall that leaves no folder, shortcut or Add/Remove entry, and an in-place upgrade
`0.0.0.0` to `0.0.1.0` whose window loads in 1203 ms — on a throwaway runner, not the owner's
machine, so the no-GUI restriction is respected while the evidence is real.

**NOT VERIFIED:** anything a person would notice. No DMG is ever mounted or launched — `hdiutil`,
`attach` and any `open` of the image appear zero times in either macOS job, so the shipped macOS
install path is untested and a broken `.app` inside a valid checksum could pass this gate. The
Windows smoke test stops at "a window appeared": no AI inference was served from the installed
package, and the fourteen UIA modes run against the build directory, not the installed product. The
macOS first-run experience of "AI tools unavailable" is unobserved in a real window. The updater's
inertness with no feed key is argued from code and from no 2.0.0 asset existing, not from a launch.
The whole of `Docs/RELEASE_2.0.0_ACCEPTANCE.md` therefore remains **NOT RUN**, and the gaps S.9
listed (Windows `-32010` mapping, live-app inference, banded-path memory) are unchanged by this
build: CI-built packages are evidence about the *pipeline* and, on Windows only, about *installing*
it — not about the product in use.

Per the rule S.4 restated and S.10 followed, **no readiness percentage is given** — the honest summary
is that every gate inside my control is green and every gate that needs a window or a tag is
untouched.

### What the owner now holds

The candidate is `main == develop == d09ad7b`, zero open pull requests, three downloadable packages
above, and this ledger as its dossier. Reserved to the owner, and none of it done: tagging `v2.0.0`,
creating the release, uploading assets, publishing, and launching the app for the acceptance session.
The decisions stacked in front of that are, in order: (1) the AI-shape question above, (2) build
stamping, (3) accept or reject the candidate, (4) authorise publication, (5) run the bounded
acceptance session, which only he can start.

---

## Addendum S.12 — 2026-11-23: the candidate moved under S.11, the acceptance pack was audited line by line, and the platform AI story was re-measured

**Why this exists.** The owner ordered five preparation tasks after PR #131: review the acceptance pack,
audit the real macOS/Windows AI differences, verify the build-number policy, triage the open work items,
and update this record. Before touching anything the repository state was re-read rather than assumed:
`git ls-remote` gives `refs/heads/main` **and** `refs/heads/develop` at
`5ce98ec2ecf22e4e76e8333a44675db42fd72cea`; `gh pr list --state open` returns `[]`; the tag list is still
exactly one entry, `refs/tags/v1.0.0` (`dde13e5` → commit `d4e7d58`); the only release is still
"Archived — Retouch Studio 1.0.0 (Legacy)", pre-release, 2026-11-09; and the personal checkout at
`/Users/roham/RetouchStudio` is on `develop` at `40b157f`, its two stashes intact, with the same three
pre-existing dirty paths (`Views/CompareCanvas.swift`, `Tests/ModelTests.swift`, untracked
`Views/ToastPlacement.swift`, all mtime 2026-11-17 19:41). Nothing here was staged, stashed, reset or
cleaned. **All four conditions VERIFIED.**

### S.12.1 S.11's packages are already historical, and the reason is my own merges

S.11 recorded the candidate as `main == develop == d09ad7b`. Since then **nine commits landed**, in two
merge commits and one docs merge:

| Commit | What |
|---|---|
| `38400b1` / PR #129 | ledger Addendum S.11 itself (docs only) |
| `9edd774` / PR #130 | `a6164a1` + `874f9f1` — the canvas status-toast placement, ported from the owner's own uncommitted work, plus the peek-badge correction (`labelHeight` 17 → 21, measured) |
| `5ce98ec` / PR #131 | `a4fcc7f` + `06ca664` + `39ae988` — the three should-fixes: non-fatal font measurement, a 120-state geometry mirror test, and gating the hidden measuring twin |

`git diff --stat d09ad7b..5ce98ec` is 4 files, **+1022/−6**: `Docs/RELEASE_2.0.0_READINESS.md`,
`Sources/RetouchStudio/Views/CompareCanvas.swift`, `Sources/RetouchStudio/Views/ToastPlacement.swift` (new
file in-tree at this point) and `Tests/ModelTests.swift`. **`Sources/StudioCore` is untouched**, so the C
ABI, the render contract and every golden image remain valid — this is not an engine change.

The consequence for the release is direct: **the three S.11 artefacts were built from `d09ad7b` and do not
contain the toast work.** They are kept in this addendum as history, not as the candidate. A new
pre-publication build was dispatched from the current head — the dispatch cannot publish, which I re-read
myself rather than inheriting S.11's claim: the `release` job's `if` requires
`startsWith(github.ref, 'refs/tags/v')` (`release.yml:159-166`), a non-tag run forces `VERSION="0.0.0-ci"`
(`:33-37`), and the workflow's top-level `permissions` is `contents: read` with only the publish job
escalating to `write`.

### S.12.2 PR #130/#131: what is implemented, and what is only headless

Landed, with evidence I checked rather than received: five required contexts green on #131's **own first
attempt** at head `39ae988` (no retries, so no flake story), plus the two Worker contexts; local suite
`MODEL TESTS: PASS` at **1252 `✓` / 0 `✗`** at both the pre-amend `b512ffd` and the pushed head; merge tree
byte-identical to `39ae988`.

What the product actually gained is one behaviour: the canvas status pill now reserves the BEFORE/AFTER
tags, the divider's 28 pt grab strip and the zoom dock as hard obstacles, treats the photo as a soft one,
and stops measuring its width against a stage that can never show a toast
(`CompareCanvas.swift`, the `.overlay(alignment: .topLeading)` on `statusPill` now gated by
`model.hasImage || model.isBusy`).

**Implemented is not verified.** All of that is proved only against a *transcription* of the view's own
arithmetic (`testToastObstaclesMirrorTheDrawnChrome`), never in a window — the no-GUI restriction held
throughout. §4b of `Docs/RELEASE_2.0.0_ACCEPTANCE.md` was written for exactly this purpose, so the item now
has an owner-side closure path instead of a silent gap. G-ACC therefore still reads **NOT RUN**, and G-QA on
the release artefact is unchanged.

### S.12.3 Build stamping: the committed number is dead weight, and I advanced it myself

Read from the pipeline at `5ce98ec`, not from the prose:

- `Resources/Info.plist:21-24` carries `CFBundleShortVersionString = 2.0.0` and `CFBundleVersion = 2`.
  `Windows/Directory.Build.props:13` carries `<Version>2.0.0</Version>`.
- `release.yml:38` (arm64) and `:68` (x86_64) run
  `RETOUCH_VERSION="$VERSION" RETOUCH_BUILD="$GITHUB_RUN_NUMBER" ./build.sh release`, and
  `build.sh:105` copies `Resources/Info.plist` into the bundle, `:109` points `PLIST` at **that copy**, then
  `:111`/`:114` `Set` the two keys with PlistBuddy. **The committed plist is a fallback no CI build shows**,
  and no repo file is ever rewritten.
- `Tools/check-versions.sh` compares `CFBundleShortVersionString` against `<Version>` and, when given a tag,
  against the tag. It **never reads `CFBundleVersion`** — so there is no gate on the build number at all.
- Windows is stamped separately and consistently: `-PackageVersion` → `-p:Version=`
  (`Tools/build-windows.ps1:214,221`, whose `-PackageVersion` defaults to that same `<Version>` at `:37-38`),
  and `Tools/package-windows-msi.ps1:25-28` re-formats it to four octets, so a
  `v2.0.0` tag yields assembly `2.0.0` and MSI `ProductVersion 2.0.0.0`.

S.11 observed `0.0.0-ci (4)` from run number 4. **This addendum's own dispatch consumed run number 5**, so a
`v2.0.0` tag built from now on yields **`2.0.0 (6)`** — not the `(2)` in the repo, and the number keeps moving
with every Release run, including ones I start. That is disclosed here because `CFBundleVersion` is what
macOS uses to decide whether a package is newer than the installed one, and because it is the owner's
"build stamping" decision (D-item in #55), not an engineering preference. My recommendation, taking effect
only if he says so: make the tag build derive `CFBundleVersion` from an owned counter (or from the tag
itself) instead of `GITHUB_RUN_NUMBER`, and have `check-versions.sh` assert it — otherwise the first 2.0.0
build number is an accident and the second one is unreproducible.

Two doc corrections fell out of this and are **not** applied here, deliberately: `Docs/RELEASING.md:28` says
"Bump `CFBundleVersion` for every uploaded build", which the pipeline contradicts by overwriting it, and its
§2 example uses `RETOUCH_BUILD=42`. `Docs/RELEASING.md:13` (`Version / build | 1.0.0 / 1`) is **not** stale —
the table header reads "values for the first public release", so it is correct history; I initially recorded
it as a defect and checked the header before writing that claim. The reason no line is inserted:
`Tests/RuntimeTransferTests.swift:245` mirrors `Docs/RELEASING.md:186` as a line anchor, so an edit above it
silently breaks a cited reference. Fix belongs in the same pass that converts that anchor to a symbol.

### S.12.4 AI capability: packaged, wired, and observed are three different claims

Layers: **PACKAGED** = the shipping artefact carries it · **WIRED** = product code can drive it ·
**OBSERVED** = a dated record shows a person-visible success.

| AI operation | macOS RC DMG (`0.0.0-ci`) | Windows MSI (`0.0.0-ci`) |
|---|---|---|
| `upscale.4x` (swin2sr-x4) | WIRED + OBSERVED **once, and only on a locally built bundle** (`Docs/PHASE5_ACCEPTANCE.md` §4: 64×64 → 256×256, device `mps`, 0.46–2.37 s compute, §5.2 records "no second physical Mac") — **not PACKAGED in the RC**: `release.yml:25` sets `RETOUCH_SKIP_WORKER: '1'`, `build.sh:170-176` then prints `helper runtime skipped (RETOUCH_SKIP_WORKER=1)` and `Tools/validate-bundle.sh:118` reports `helper runtime not bundled (AI tools unavailable)` | PACKAGED transport, WIRED-as-refusal: `Tools/build-windows.ps1:238-241` *fails the build* unless `AI/RetouchStudio.AI.Worker.exe`, `AI/RetouchStudio.AI.dll` and `AI/onnxruntime.dll` are in the package ("with no Python"), and `WorkerServer.cs:171-172` routes **every** `job.submit` to `RefuseJob` → typed `-32020` `E_UNSUPPORTED` (`Protocol.cs:19`, `WorkerClient.cs:51`) — **never OBSERVED** |
| `mask.click` (sam2.1-hiera-tiny) | WIRED, refused at the catalogue (`unverifiableReason`, entry shows `Not installable`), **never OBSERVED** | same refusal, by design |
| `inpaint.spot` (migan) | WIRED; `onnxruntime==1.31.1` is locked; weights are an on-demand consented download; **never OBSERVED** | `Unsupported` in the Windows table |
| `generative.*` (flux2-klein-4b-q4) | refused — `permitted_use` is UNKNOWN and S-FLUX/PR #126 made the gate refuse the download | refused |
| `face.analysis`, `enhance.photo`, `restore.photo`, `upscale.2x`, `outpaint` | fixed `UNSUPPORTED`/`BLOCKED` specs; face analysis is host-side Vision, not a worker claim | `Blocked` / `Unsupported` |

**The release-relevant sentence is this one: as CI builds them today, neither package has user-verifiable
AI.** Both jobs set `RETOUCH_SKIP_WORKER: '1'` (`release.yml:25` for arm64, `:112` for `windows-app`), so no
Python helper travels in either artefact; on macOS the remaining gap is that no model load is reachable
without it, on Windows it is worse — the adapter refuses submissions by design, and the models are all
`macos-arm64`. The sixteen ids (`Capabilities.cs:23-31`) share one vocabulary string with the worker, and
`CapabilityAdapter.cs:19,40-44` refuses the report at *runtime* on vocabulary drift, a duplicate id, or a
missing one — a parse guard, not a compile-time one.

Two of my own researcher's conclusions had to be corrected before they entered this record, which is why the
row above cites files rather than a report: it claimed G-WIN's "all four catalogue models are
`macos-arm64`" was refuted because `migan` carries `requiredProvider: cpu`. Reading
`Resources/model-catalog.json` myself: **all four entries do say `platforms: ["macos-arm64"]`**, and
`requiredProvider` is a different field, so the G-WIN wording stands. Its other claim is right and belongs
in the record, because "no AI on Windows" is otherwise read as "no code shipped": the Windows package does
carry `AI/RetouchStudio.AI.Worker.exe`, `AI/RetouchStudio.AI.dll` and `AI/onnxruntime.dll` (the build throws
if any is absent), which is what makes that artefact ~176 MB against 4.5 MB DMGs — the size measures shipped
plumbing and ONNX Runtime, not a working model pipeline.

### S.12.5 G-INT is closed at this head, and the acceptance pack was still promising the opposite

§3's G-INT row (kept as history per the append-only rule) records a measured fail-open:
`catalog.py:330` / `:358` / `:418` with `if spec.sha256 is None: continue`. **That is no longer the tree.**
At `5ce98ec`, `:358` is `REASON_MISSING_SIZE = "missing-size"` and `:418` is a `json.dumps`; the fail-open
shape is gone, and `pin_problem` (`catalog.py:470`) documents itself as "the single admission rule",
returning `missing-digest` / `invalid-digest` / `missing-size` instead of skipping (`:486-494`), consulted
from `catalog.py:1173,1194,1258,1296,1357`, `capabilities.py:150` and `plan.py:56`. The strongest single
piece of evidence is a comment rather than a test: the last defensive branch at `:1190-1192` says it exists
"so no future caller can reinstate the old `if spec.sha256 is None: continue` hole" and raises
`CATALOG_INVALID` — the exact fail-open S.11 measured is now named in the source as forbidden. The load half is closed too:
all four `_ensure_*` paths call `catalog.require_verified` (`engine.py:884,938,951,971`), and
`test_a_same_length_substitution_fails_the_job_over_rpc` (`worker/tests/test_server.py`) pins a same-length
tamper through the RPC, its comment recording that on `cd5741b` "only the upscaler hashed at load". Landed
as PR #115 (`0cf536b`) after the adversarial review this mandate required.

What I did **not** do is call the licence gate closed on the strength of that: `ModelStore.install` still
gates on integrity rather than on the admission decision (open item #157, restated in the acceptance pack as
new limitation 16), so FLUX today is un-downloadable because of its `unverifiableReason` path and the plan
gate, not because the install door asks. I read the function and its call sites; I did not prove exhaustively
that no fourth path bypasses `pin_problem`, so this row says "closed, by these named callers" rather than
"closed, provably complete".

### S.12.6 The acceptance pack re-reviewed (G-ACC), and what was wrong in it

`Docs/RELEASE_2.0.0_ACCEPTANCE.md` was checked mechanically, not by skimming: a script extracted every
`file:line` citation, resolved each path through the tree, and printed the cited line so it could be compared
with the prose. **113 unique citations at `5ce98ec`, 112 valid, 1 drifted** — §6 cited
`Localization.swift:307` for the Batch Export label, which is now `:309` (`batchExportMenu`), the shift caused
by `eee3e4b`/`9e43e14` landing after the pack was written. Corrected, and the same tool re-run over the
revised pack reports **124 citations, 0 suspects** — including every anchor this addendum adds. Three
pre-existing suspects survive elsewhere in *this* ledger (two `AMBIGUOUS` bare filenames and three
`EMPTY`/stale anchors at `InfoViews.swift:95`, `ModelStoreTests.swift:2004`, `RELEASING.md:187`); they sit
inside earlier addenda, so the append-only rule keeps their text and this sentence is the correction record.

Three substantive defects, all fixed in the same PR as this addendum:

1. **§0 assumed an artefact that cannot exist before publication.** The pack told the owner to download the
   RC "from the release page" and to **stop** if About says anything but `2.0.0 (…)`. There is no 2.0.0
   release page — creating one is D7 — and per S.12.3 a CI build says `0.0.0-ci (N)` *by design*. §0 now
   separates the tag case from the pre-publication case, and says plainly that `0.0.0-ci` on an unpublished
   candidate is correct rather than a reason to abort. It also warns that an Actions-artefact zip
   round-trip may not preserve `com.apple.quarantine`, so §1's Gatekeeper answer taken that way is indicative
   only — the prerequisite's cross-reference is fixed to §1, which is the section quarantine actually feeds.
2. **§14.8 told the owner to expect a fail-open integrity defect** that S.12.5 shows is closed — replaced
   with the dated correction and the measurement, and turned into an assertion he can falsify (a
   missing-pin entry must read `Not installable`).
3. **§14.15 still blamed PR #99** for the unrendered licence-refusal sentence. #99 merged as `9e43e14` on
   2026-11-23, and the sentence exists in both tables (`EditorModel.swift:1765` routes `-32010` to
   `aiLicenseBlocked`, `Localization.swift:1368` / `PersianL10n.swift:1240`). What is missing is an eye on
   the rendered alert, not code — so the row now says that, and new §4b carries the toast gap.

The pack's structure, its honesty rule and its 13 sections needed no change: this was a verification pass
that found one drifted anchor and three stale claims, not a rewrite.

### S.12.7 Work items #152 / #156 / #157 / #158, and the freeze I chose

Those four numbers are **this team's internal work items**, not GitHub issues — the repository's highest
number of either kind is 131 (PR #131), so no GitHub-side object exists for them. Triage:

| Item | Still valid at `5ce98ec`? | Class | Recommendation |
|---|---|---|---|
| #152 — untested `-32010 → E_LICENCE_REFUSED` host mapping | Yes. `WorkerClient.swift:46` maps `-32021`, `EditorModel.swift:1765` maps `-32010`, and only the Windows side has a sibling test for `-32021` | SAFE-INDEPENDENT-CODE, test-only, two files | Post-freeze; small, but it invalidates the audited packages for zero user-visible change |
| #156 — gate routing residuals (invalid record reaches Manage Models; kind-only refusal loses `capabilityId`) | Yes, and the eval-mode sub-item is test-only by construction — both launch paths strip `RETOUCH_AI_EVAL_MODELS` | SAFE-INDEPENDENT-CODE, worker-side; **touches the pinned worker-test count** (`Tests/expected-worker-tests.txt`) | Post-freeze, as one slice with a worker test each |
| #157 — `ModelStore.install` admits by hash, not by licence admission | Yes | SAFE-INDEPENDENT-CODE with a real fail-closed consequence, but unreachable from the current catalogue | The only one I would consider **before** a tag, if the owner wants the licence gate advertised as a shipped security property; otherwise 2.0.1 |
| #158 — Windows CI failure diagnostics drop type/HRESULT/stack | Yes | SAFE-INDEPENDENT-CODE, semantics preserved, verifiable only by a Windows CI run | Post-freeze; it reduces the cost of every later Windows flake |
| #55 — owner decision pack | Yes; now carries S.11's AI-shape question and S.12.3's stamping measurement | OWNER-DECISION | Below |

**Decision taken (mine, under the standing authority):** the candidate is **code-frozen at `5ce98ec`**. None
of #152/#156/#158 gates 2.0.0 — they are test-pinning, routing polish on paths the shipping app cannot reach,
and CI diagnostics — and each merged PR makes S.11-style package evidence stale again while advancing
`CFBundleVersion` a further step. #157 stays open with the reason recorded rather than being folded in at the
last minute. If the owner wants any of them in 2.0.0, they land first, and the RC is rebuilt afterwards; the
order matters and I am not making that call for him.

### S.12.8 Evidence ladder after this addendum

**VERIFIED now (my own reading at `5ce98ec`, not inherited):** branch/tag/release/checkout state (§
"S.12.0"); a `workflow_dispatch` cannot publish (`release.yml:159-166`, `:33-37`, permissions); the stamping
mechanism (`build.sh:105-114`, `release.yml:38/68`, `check-versions.sh` source read end to end); the four
catalogue entries' platforms; `pin_problem`'s shape and its seven call sites; the four `require_verified`
load calls; `-32010 → aiLicenseBlocked` existing in both language tables; 112 of 113 acceptance-pack
citations.

**VERIFIED by CI, this round:** `macOS arm64`, `macOS x86_64` and `Windows StudioCore` succeeded on the new
candidate run `45197302277` (head `5ce98ec`, run number 5); the `Publish GitHub Release` job is gated out and
does not run. *(Windows x64 application: result appended when it lands.)*

**NOT VERIFIED, unchanged by anything here:** every user-visible property of either package. No DMG is
mounted or launched in CI, the acceptance pack's 13 sections are **NOT RUN**, the toast placement is
headless-only (§4b), live-app inference and the banded-path memory are unmeasured, the `-32010` host mapping
has no test on either side (#152), the updater's inertness is argued from configuration, and Windows remains
runner-only evidence with no real desktop.

**No readiness percentage is stated**, per S.4: the honest shape is that every gate inside this team's
control is green and every gate needing a window, a tag or the owner's machine is untouched.

### S.12.9 The owner's decision list, reduced to what is genuinely his

Everything else in this addendum was mine to settle. Four things are not, and only the first two block
progress:

1. **The AI shape of 2.0.0** (unchanged question from S.11, now with the S.12.4 evidence): publish with
   "macOS editor-only + Windows carrying an inert helper", or land a published protocol-v2 runtime first?
   This is a product-scope call, and the mandate forbids me changing packaging scope without approval.
2. **Build stamping** (now measurable): keep `CFBundleVersion = GITHUB_RUN_NUMBER`, or take ownership of the
   counter before the first `2.0.0` asset exists. A tag built today prints `(6)`.
3. **Accept or reject `5ce98ec` as the candidate**, then authorise tagging/publishing — the only
   irreversible public actions, all still undone.
4. **Run §4b and the rest of the acceptance pack** in a real window. Nothing I can do closes it, and the
   no-GUI restriction is his to lift.

