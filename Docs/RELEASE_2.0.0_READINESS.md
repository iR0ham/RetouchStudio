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
