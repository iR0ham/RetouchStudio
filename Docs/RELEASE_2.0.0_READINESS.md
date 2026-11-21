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
| G-WIN | Windows release evidence | **NOT VERIFIED** | Windows CI (`.github/workflows/ci.yml`: *Windows StudioCore*, *Windows App*) is green on all open heads, and 396 host checks exist. Not established: the Windows AI/runtime path, MSI packaging of the notices surface (PR #111 explicitly excludes it), and any run of the built Windows app. Per mandate §8, no "Windows ready" claim may be made until those are named and closed. |
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
