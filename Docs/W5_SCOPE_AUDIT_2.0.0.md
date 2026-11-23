# W5-1 … W5-5 — commitment versus delivery for Retouch Studio 2.0.0

Added 2026-11-23 after the owner's live acceptance session exposed five AI symptoms in
the release-candidate build and asked what was actually promised in W5-1 … W5-5, what was
delivered, and what is missing. This document does not close any workstream and does not
accept any incomplete work. It records the audit, the root causes and the remediation plan.

## 0. Method, audited tree and constraints kept

Everything below was established read-only.

**Audited code state.** `5ce98ec`, exported as a detached worktree at
`/private/tmp/rs-w5-audit`. That is the commit compiled into the DMG the owner tested
(sha-256 `b3711d0c…2ed2b4`); `0758ad8` and the current tip differ from it only under
`Docs/`. All source citations are to that tree and are given as file plus symbol rather than
line number, because these files keep moving.

**Constraints honoured.** No file in the owner's personal checkout was opened or modified.
No GUI was launched and no acceptance session was run. No tag, release or asset was created
or changed. No model weight was downloaded or installed. No wheel was installed. The only
network calls made were header-only `HEAD` requests against the URLs already pinned in the
catalogue (§12) — no object body was fetched. No new model with an unclear licence was
introduced.

**What was not re-derived.** The five research reports behind this document (W5 commitments,
the model and licence dossier, the macOS execution chain, the Windows package, the MI-GAN 302
forensics) were cross-checked against the tree; the load-bearing claims were re-verified
personally and are the ones quoted with commands in §12. Where a sub-report and the tree
disagreed, the tree won — one citation error was caught this way (`Tools/build.sh` does not
exist; the worker-stamping logic is in the repository-root `build.sh`).

## 1. The answer first

**Promised.** W5 committed to a reproducible local-AI runtime on both platforms, a Model
Manager that obtains weights with consent, truthful per-capability reporting, one
cross-platform capability (4× upscale) with measured quality, and CI that ties every support
claim to a recorded run.

**Delivered.** The worker source, its hashed lockfile and a source-built CPython runtime
exist and completed a real protocol-2 handshake. The Model Manager's store, catalogue,
consent, staging, atomic install, verify, lease and rollback machinery exist and passes its
race suite against a local fixture server on both platforms. The capability vocabulary is
frozen and reported with reasons. The upscaler's quality harness ran real inference on this
Mac's MPS and met the approved 24 dB bar with margin.

**Missing.** Not one platform cell in a shipped artefact has ever produced an inference, and
the release build deliberately contains no helper at all — `Contents/Resources/Worker` is
absent from the DMG that was tested, which I verified by mounting it (§12.1). The model
download path is broken against the real hosts for every catalogue entry, which is a genuine
defect that no document in this repository recorded before this audit (§7.4). And W5-4
remains what its own roadmap status says it is: "W5-4 is NOT complete".

**The structural reason this passed unnoticed.** Each W5 exit criterion is satisfiable by a
worker started from a checkout and a downloader aimed at a local server that answers 200. The
release promise aimed at a bundle and at `huggingface.co`. Between those two frames, three of
the five symptoms the owner saw are correct behaviour of a build that is honestly described in
`Docs/W5_UPSCALER_ACCEPTANCE.md` §10.5 — "It is **not** shipped-build evidence" — and two are
defects: the redirect policy (§7.4) and the fact that this caveat never reached the
release-facing documents (`README.md`, the acceptance pack, the readiness ledger §3).

**Consequence for acceptance.** The AI rows of `Docs/RELEASE_2.0.0_ACCEPTANCE.md` are marked
unavailable because the helper is not in the build. That framing is incomplete: the weight
download is not unavailable-by-design, it fails. A dated correction was added beside §14 of
that pack on the same day, and `README.md`'s "The models are downloaded on request" was
corrected, because the audit refutes it for all four entries.

## 2. Evidence ladder used in this document

| Class | Means | Weight |
|---|---|---|
| SHIPPED-ARTEFACT | Observed inside the built DMG or MSI | Highest — this is what a user gets |
| LIVE-APP | Observed in the running app on this Mac | High |
| DEV-RUNTIME | Executed in the hand-built `AI/runtime` interpreter on this Mac | Medium, transferable only if the pins match |
| HARNESS | Executed by a committed harness or test suite, not through the product path | Medium |
| CI-RUN | Printed by a green job on a hosted runner | Medium; a build is not an inference |
| SOURCE-READ | A code path that exists and is reasoned about | Low |
| PROBE | A measurement taken for this audit, command quoted in §12 | Depends on what it touches |
| NONE | Stated without evidence | Marked explicitly |

A capability is `supported` only at the LIVE-APP or SHIPPED-ARTEFACT class, per the rule at
the head of `Docs/W5_ROADMAP.md` §3 and decision-record §3.3–3.4.

## 3. Commitment versus delivery, W5-0 … W5-5

| Workstream | Committed exit (source) | State in `5ce98ec` | Best evidence class | Verdict |
|---|---|---|---|---|
| W5-0 Architecture and contract freeze | Decision record §5 complete, owner answers recorded | Done; owner decisions answered 2026-11-16; Windows Swin2SR marked BLOCKED as the exit itself allows | SOURCE-READ | MET |
| W5-1 Reproducible runtime, both platforms | "a fresh checkout starts a real worker process and completes the protocol handshake, with the run recorded", both platforms | True for a checkout: source-built CPython 3.13.15, hashed lock, handshake recorded, CI run 43878989037 on macOS and Windows | CI-RUN plus DEV-RUNTIME | MET AS WRITTEN — and the written exit never required the helper to be inside a shipped bundle |
| W5-1 product promise | "self-contained app runtime, so end users never install Python manually" | The tested DMG contains no `Contents/Resources/Worker`; `AIRuntime.package` is `nil`, so nothing can be downloaded either | SHIPPED-ARTEFACT | NOT MET — a user of this build cannot run AI at all without building the runtime themselves |
| W5-2 Model Manager | Race suite passes both platforms; `E_MODEL_LEASED` on delete during a job; interrupted install leaves no active model; verify catches a mutated file; DR-5 enforced | All five hold against the local fixture server in `Tests/ModelStoreTests.swift`; nothing in the exit exercises a real host | HARNESS | MET AS WRITTEN — the exit is the reason the redirect defect survived (§7.4) |
| W5-2 product promise | Weights obtainable in-app after one consent sheet | Refuted for 4 of 4 entries: 9 of 10 pinned file URLs answer a redirect and the client refuses redirects | PROBE plus LIVE-APP | NOT MET |
| W5-3 Platform adapters and truthful reporting | Both adapters answer `capability.list` with the frozen vocabulary; no `supported` without a recorded run; stopped worker yields `E_WORKER_MISSING` not a timeout; model gap yields `E_MODEL_MISSING` | Implemented on both adapters, with a dated self-correction already recorded in the roadmap; `upscale.4x` reported `blocked` on this Mac because the install was a legacy flat one | CI-RUN plus HARNESS; never SHIPPED-ARTEFACT | MET for the adapters; the shipped build cannot demonstrate it (symptom 5) |
| W5-4 Upscaler 4× cross-platform | Decision-record §4.3 gates per platform; provenance sidecar; tolerance fixed before the run; measured bit depth, memory, wall time; cancel at load, tile and write; "A successful job alone is not the exit" | macOS: real inference on MPS, A1 bar met (min 30.65 dB, control beaten on all eight images), banded-envelope memory measured. Windows: BLOCKED, no conversion evidence adopted. Production adoption and a product-path export were not performed | DEV-RUNTIME plus HARNESS | PARTIAL, self-declared — the roadmap says "W5-4 is NOT complete" and §10.5 says the evidence "is not shipped-build evidence" |
| W5-5 CI and acceptance | Five required checks green on the milestone head; every support claim cites a run; unverified register current | Checks green; but `worker-payload-bundle` is `continue-on-error: true`, uploads no artifact, and asserts only file-set equality plus top-level module imports | CI-RUN | PARTIAL — the register is honest, the gate is soft |

Two further commitments deserve their own line because they are what the owner is actually
missing:

- **A recorded inference reachable from a released bundle.** Never achieved on any platform at
  any commit. `worker/retouch_ai_worker/capability-evidence.json` holds exactly one entry, for
  `upscale.4x`, and the roadmap's own W5-3 status notes that it "names no run id, host or
  artefact hash, so no CI gate re-checks it".
- **`AIRuntime.package` set to a validated package.** Explicitly out of scope in W5-1's
  "Does not" list ("… set `AIRuntime.package` to a downloadable package"), and still `nil`.
  So the runtime-delivery gap was never in W5 at all — it is an unowned product requirement
  that sits between W5-1's exit and the release promise. That is the scope finding: W5 did not
  silently redefine itself; W5 was scoped below the promise the README and the product make.

## 4. Model-by-model research and licensing report

Catalogue identity was read from `Resources/model-catalog.json` in the audited tree; the
licence verdicts and their dates are from the same file's `permitted_use` blocks, whose
provenance is `Docs/MODEL_LICENCES.md` and `Docs/AI_11_MODEL_EVALUATION.md`. Flat
`codeLicense` and `weightsLicense` strings are deliberately kept stale by design, so a document
that reads them instead of `permitted_use` is reading a label, not a decision.

| Model | Role | Format and size | Code licence | Weight licence | Acquisition permitted | Redistribute permitted | Inference evidence |
|---|---|---|---|---|---|---|---|
| `swin2sr-x4` | `upscale.4x` | pytorch, 48,461,065 B | Apache-2.0, approved 2026-11-21, rights-holder | Apache-2.0, approved-with-conditions 2026-11-22, rights-holder | yes | yes | DEV-RUNTIME and HARNESS, one recorded run; never SHIPPED |
| `migan` | `inpaint.spot` | onnx, 28,079,181 B | MIT, approved 2026-11-21 | MIT (`LICENSE-WEIGHTS`), approved 2026-11-21 | yes | yes | none recorded in the evidence file |
| `sam2.1-hiera-tiny` | `mask.click` | pytorch, 156,008,466 B | Apache-2.0, approved, pin `@2b90b9f` | Apache-2.0, approved by the README's separate checkpoint grant | yes | yes | never, on any platform, in any environment |
| `flux2-klein-4b-q4` | `inpaint.object`, generative | safetensors-mlx, 4,608,176,697 B | unknown, `statedBy: not-established`, read 2026-11-21 | unknown, `statedBy: not-established`, read 2026-11-23, superseding the earlier approved record | not established | not established | none; measured 16.7 GB peak on a 16 GB machine |

Catalogue presence is not the same as suitability. Per model:

**`swin2sr-x4`** is the best-supported choice in the set. Selection evidence is real: the
quality corpus was measured on this Mac, the A1 bar was met with a 30.65 dB per-image minimum,
the bicubic control was beaten on all eight images, and determinism reproduced at 0.00 dB
spread. Two selection criteria remain weak: the earlier §7.6 combined harness verdict was
`fail` on the control condition and §8 recorded a replacement adversarial gate as FAIL before
§9 and §10 resolved that the bar alone decides. Platform compatibility is macOS-arm64 only by
record; the ONNX conversion needed for Windows was deliberately not adopted (§3 of
`Docs/W5_UPSCALER_ACCEPTANCE.md` §6). Size is modest. Model size and hash are pinned; the
runtime that would load it is not in the shipped build.

**`migan`** was chosen for spot healing because it is a small MIT ONNX export by the rights
holder, which satisfies every licence criterion the dossier uses. Its selection was not
benchmark-backed: there is no quality run for it in any document, and its capability
`inpaint.spot` has no entry in `capability-evidence.json`. The owner's live session is the
first real-world exercise of its acquisition path, and it failed (§7.4).

**`sam2.1-hiera-tiny`** is a licence-clean, size-reasonable choice whose runtime was never
admitted. Its catalogue entry carries an explicit `unverifiableReason`: downloading is refused
because `sam2` is in neither `worker/requirements.lock` nor the worker's `models` extra, so a
machine that fetched the weights would have nothing to load them with. `Docs/MODEL_LICENCES.md`
§11.5 restates this as "a missing runtime, correctly reported". So the entry is honest and the
capability is honestly `blocked`. What is *not* honest-by-construction is that `mask.click` is
advertised in the UI as a capability of a model the user can see and, in this build, cannot
even be told the reason for correctly — see §7.3.

**`flux2-klein-4b-q4`** is the entry the dossier should have stopped, and on 2026-11-23 it did:
`permitted_use.weights.verdict` is `unknown` with `statedBy: not-established`, superseding the
`approved` record PR #121 had written, because the converter repository
(`mflux-community/flux2-klein-4b-mflux-q4`) ships no licence copy of its own — the only bridge
from those bytes to Black Forest Labs' grant is a tag name. That is a correct application of
DR-15 and DR-16. Two facts make it worse than "not yet approved": the 4.6 GB of pinned weight
bytes are not distributable by us, and the measured 16.7 GB peak exceeds the owner's 16 GB
machine. Generative edit and object removal therefore have **no** licensed, no available and
no measured implementation on any platform. Any document that lists them as product features is
over-claiming; `README.md` did, in its feature bullet ("reimagine the frame from a prompt"), at the audited
commit, and that is a documentation defect rather than a scope decision — the same change that adds this
document corrects the bullet.

Candidates researched and rejected, with the criterion that rejected them: RestoreFormer++
(excluded — licence), the community Swin2SR ONNX conversions (unverified provenance, refused by
W5-4's own BLOCKED condition), and the 2× upscale candidate (measured and hash-verified but not
yet benchmarked in CI, tracked outside W5). None of them is a licence-blocked commercial-use
question any more: since 2026-11-22 the admission class is *non-commercial use permitted plus
defensible provenance*, which is why `flux` can be refused on provenance alone.

## 5. The macOS execution path, traced stage by stage

The chain is: bundle worker → runtime discovery → process launch → protocol handshake →
capability discovery → model loading → inference. Each stage below was traced in the audited
tree and evaluated against the DMG the owner tested.

| # | Stage | Code that decides it | In the shipped DMG | Evidence class |
|---|---|---|---|---|
| 1 | Bundled worker | `build.sh` honours `RETOUCH_SKIP_WORKER` by moving `Contents/Resources/Worker` out of the bundle into `build/Worker.cache`; `.github/workflows/release.yml` sets `RETOUCH_SKIP_WORKER: '1'` for all three macOS jobs | **Absent.** Resources contain only `AppIcon.icns`, `Fonts`, `LICENSE`, `THIRD_PARTY_NOTICES.txt`, `model-catalog.json`; the app is 10 MB | SHIPPED-ARTEFACT, §12.1 |
| 2 | Runtime discovery | `AIWorker.repositoryRoot()` prefers a bundled helper, then a downloaded protocol-v2 runtime, then a source checkout above the executable; `AIRuntime.package` is `nil`, so no download is offered | All three lookups fail on a clean install of this DMG: no bundle, no `AI/runtimes/protocol-v2`, no `worker/retouch_ai_worker` ancestor | SOURCE-READ, confirmed by the owner's LIVE-APP state |
| 3 | Process launch | `AIWorker.start` guards `guard let python = interpreter(), let root = repositoryRoot() else { throw startRefused(.noHelperOnDisk) }` | Refused with `.noHelperOnDisk`, not a timeout — the correct typed failure | SOURCE-READ, LIVE-APP symptom 1 |
| 4 | Handshake | `WorkerClient` plus the readiness registry, `Docs/AI_PROTOCOL_V2.md` | Never reached; a handshake was recorded only from a checkout or the dev runtime | CI-RUN, DEV-RUNTIME |
| 5 | Capability discovery | `capabilities.py` report, surfaced as `capability.list` | Unreachable, so the Model Manager shows "The local AI helper is not running, so the capability list cannot be read." — which is the truthful sentence for this build | LIVE-APP symptom 5 |
| 6 | Model loading | `ModelStore.install` for acquisition; `engine.py::_ensure_swin`, `_ensure_sam`, `_ensure_migan` for load; `-32019` `E_MODEL_UNVERIFIED` refuses a size- or hash-mismatched install | Loading code is wired and unit-tested; acquisition is broken (§7.4); adoption of the flat `swin2sr` install happened once in the dev environment | HARNESS, DEV-RUNTIME |
| 7 | Inference | `engine.py` plus the provider report | Achieved once, for `upscale.4x`, in a hand-built runtime on this Mac; never from a shipped artefact | DEV-RUNTIME |

Three consequences follow. First, symptoms 1, 2 and 5 have a single cause: the release build is
a light build by design, and the design is documented — `README.md` and the acceptance pack §9
both say no runtime card appears. Second, the light build is *internally* consistent: it refuses
with typed errors rather than hanging, which is exactly what W5-3 promised. Third, the light
build is not what the feature bullets in `README.md` and `Docs/RELEASE_NOTES_2.0.0.md` describe,
and that is the discrepancy the owner hit.

## 6. The Windows path

Windows was audited from the same tree, and the owner's warning is right: a green Windows CI leg
is a build, not an inference.

- `Windows/RetouchStudio.AI/WorkerClient.cs` carries the typed code table and the job-object
  containment; `Capabilities.cs` blocks `upscale.4x` explicitly; `Windows/RetouchStudio.App`
  wires the Model Manager window. The AI runtime tests pass on `windows-2025`, including ONNX
  Runtime 1.32.0 CPU initialisation **without a model**, the ready-registry record, the
  protocol-2 handshake, foreign-contract refusal, shutdown exit and the protocol-1 refusal.
- **No Windows code path has ever loaded model weights.** `Docs/W5_ROADMAP.md` states it plainly
  in W5-3's status and in W5-4's BLOCKED condition; `Docs/RELEASE_2.0.0_READINESS.md` §3 G-WIN
  records 396 host checks with the same limit.
- The Windows download client has the same fail-closed posture as macOS: `ModelStore.cs` builds
  its `HttpClient` on `SocketsHttpHandler { AllowAutoRedirect = false, … }`, so all nine
  `huggingface.co` file URLs fail there too. W5-2's exit was met on Windows against the same
  class of non-redirecting fixture.
- Packaging: `Tools/build-windows.ps1` produces an MSI, and the ~176 MB helper payload it can
  carry is not referenced by the macOS-style consent flow that exists on macOS; `WINDOWS_APP_READY`
  is `true`, which means a `v*` tag would publish the Windows artefact as if it were equivalent.
  It is not equivalent, and this document keeps that as an owner decision rather than a silent
  inclusion.

## 7. Root cause of every observed symptom

### 7.1 "Local AI helper is not running"

**Immediate cause:** no helper exists in the bundle and none can be downloaded.
**Root cause:** a deliberate, documented product decision — `RETOUCH_SKIP_WORKER: '1'` in
`.github/workflows/release.yml` plus `AIRuntime.package` hard-coded `nil` because "No official
protocol-v2 runtime has been published". **Not a defect.**
**Real defect behind it:** the scope of 2.0.0 was described to the owner in terms of AI features
while its build shape was editor-only. The gap lives in the release-facing prose, not in the
code.

### 7.2 "Swin2SR is installed but cannot run"

**Immediate cause:** with no helper, nothing can run. Independently, the store's flat install has
no version binding, which the roadmap's own dated correction records as `upscale.4x` → `blocked`
("swin2sr-x4 is installed without a version; adopt it in the model manager before a capability
can bind it").
**Root cause:** adoption was deliberately withheld — `Docs/W5_UPSCALER_ACCEPTANCE.md` §7.7 says
"Production adoption: not performed" because the control condition was not green, and §10.5 adds
that the bundle used for the adoption test "carries no worker runtime".
**Verdict:** correct behaviour of an unfinished workstream, faithfully recorded in the workstream's
own document, and not surfaced in the acceptance pack.

### 7.3 "SAM2 is not installable because the bundled worker lacks the runtime package"

**Immediate cause:** the catalogue entry's own `unverifiableReason` refuses the download.
**Root cause:** `sam2` was kept out of `worker/requirements.lock` and out of the `models` extra,
as a design choice, not an oversight. Two supporting findings from this audit: (a) it *is* present
and importable in the hand-built `AI/runtime` interpreter as a git checkout with no dist-info,
which is precisely why it cannot go into a `--require-hashes` lock that a payload verifier compares
name-and-version against a `RECORD`; (b) `_ensure_sam` resolves
`configs/sam2.1/sam2.1_hiera_t.yaml` relative to that checkout, a path that no shipped artefact
would contain. So the refusal is correct and, for the shipped build, the only honest answer.
**Verdict:** not a defect; a tracked dependency gap, and its UI explanation is the part worth
improving (§9 R5).

### 7.4 "MI-GAN download fails with HTTP 302" — the one genuine new defect

**Immediate cause:** `ModelStore`'s delegate implements
`urlSession(_:task:willPerformHTTPRedirection:completionHandler:)` and answers
`completionHandler(nil)`, above the comment "A redirect is a different source than the one the
owner approved." Cancelling the redirect leaves the 302 as the final response, and the completion
handler then fails with `the model source answered HTTP \(statusCode)` — which is verbatim what the
owner saw. Windows mirrors the policy with `AllowAutoRedirect = false`.
**Root cause:** Hugging Face moved file serving to its XET CDN. Every
`huggingface.co/…/resolve/main/…` URL now answers `302` to `us.aws.cdn.hf.co` (binary files) or
`307` to an in-host cache path (config files). The consent model assumed one host per file: the
sheet names a source, the client pins a size and a SHA-256, and the fetch is therefore allowed to
stay on that one origin. Under the new topology that assumption is unsatisfiable, so the client is
fail-closed against the entire catalogue.
**Scope of the defect:** all 10 pinned file URLs were probed. Nine redirect. The one that does not
(`sam2.1_hiera_tiny.pt` on `dl.fbaipublicfiles.com`, `200`, `content-length: 156008466` — matching
its pin) is separately refused by §7.3. **Therefore no catalogue entry is obtainable through the
app on either platform.**
**Why it survived every gate:** the weights on this Mac arrived by manual placement plus the
adopt/migrate route (`ModelStore`'s migrate path), so the downloader was essentially never aimed at
a real host; `Tests/ModelStoreTests.swift` exercises it against a local fixture server that answers
200 and never redirects; and W5-2's exit criterion names no real-host condition. Checksum validation
is *not* implicated — the failure happens before any byte is hashed.
**Severity:** the promise "The models are downloaded on request" in `README.md` was false at the audited
commit (corrected by R9, in the same change as this document), and the error text is misleading: it tells the
user the source "answered HTTP 302" as if the host refused, when our own policy refused.

### 7.5 "AI capability discovery cannot read the worker capability list"

**Immediate cause:** stage 3 of §5 refuses before any socket exists, so `capability.list` is never
asked. **Root cause:** same as §7.1.
**Verdict:** correct, and the displayed sentence is accurate. The related gap is that the Model
Manager's own capability block cannot distinguish "no helper on this machine" from "helper present,
capability blocked", which §9 R5 addresses.

## 8. Platform matrix

Every cell names its evidence class. A dash means nothing at that class exists — it is not a pass.

| Aspect | macOS arm64 (tested DMG) | macOS Intel | Windows x64 (MSI) |
|---|---|---|---|
| Helper in the shipped package | ABSENT — SHIPPED-ARTEFACT | ABSENT by the same flag — SOURCE-READ | An unreferenced helper payload may be carried — CI-RUN; whether the app can use it is UNPROVEN |
| Runtime download offered | NO, `package == nil` — SHIPPED-ARTEFACT | NO | Not applicable — no Python path by design |
| Weight download works | NO for 4 of 4 — PROBE plus LIVE-APP | NO | NO — same `AllowAutoRedirect = false` |
| `capability.list` reachable | NO — LIVE-APP | NO | Never exercised through the product path |
| Handshake | Recorded from a checkout and CI — CI-RUN | Worker disabled on Intel | Recorded, no model — CI-RUN |
| Model loaded | Dev runtime only — DEV-RUNTIME | n/a | NEVER |
| Real inference | Dev runtime only, `upscale.4x` — DEV-RUNTIME | n/a | NEVER |
| User-visible AI feature working | NONE | NONE | NONE |
| Editor, analysis, export, batch, recovery, bilingual shell | Working, accepted by the owner's session — LIVE-APP | Working — CI-RUN | Builds and passes 396 host checks — CI-RUN; not owner-accepted |

**There is no SHIPPED-WORKING AI cell on any platform at `5ce98ec`.**

## 9. Remediation plan

Priority is by what blocks a truthful release. Each item lists the change, the concrete test that
proves it, and the acceptance criterion that closes it. Nothing here authorises a download, a
bundle change, a tag or a release; the owner's approval gates R2, R6 and R8.

**R1 — Make the download path work against the real topology, then prove it.** *(defect fix, no
product-scope change; highest priority because it invalidates a user-facing promise)*
- Change: replace the unconditional redirect refusal with a **pinned-host redirect allow-list**:
  follow a redirect only when the target host is in an explicit set recorded beside the entry
  (`huggingface.co` → `us.aws.cdn.hf.co`, `cdn-lfs.hf-mirror…`, `dl.fbaipublicfiles.com`), keep
  `SHA-256` and byte-size validation as the actual integrity gate, and show the terminal host on
  the same consent sheet that shows size and licence.
- Tests: a `URLProtocol` or fixture-server route that returns `302` to a second local route, then
  (a) allowed host → install succeeds and the hash is verified, (b) disallowed host → refused with a
  message that names the refusal as ours, (c) redirect to an identical host with a different path →
  behaviour stated by test, not by accident. Mirror cases in the Windows suite. Add a
  `check-versions`-style static gate that every `sourceUrl` host in the catalogue has a declared
  redirect-host set, so a future CDN change fails the build instead of the user.
- Acceptance: with the fixture server redirecting, `Tests/ModelStoreTests.swift` reaches
  `installed` for a fixture entry; the refusal test prints a sentence containing "redirect"; both
  hosts green in their own CI legs; a documented manual probe against one real HF file records the
  terminal host and the verified SHA-256 **without downloading the weight body** (a `HEAD` plus
  first-byte range is sufficient, and is the only network the plan needs).
- Does not authorise: relaxing hash verification, adding a remote catalogue, or downloading weights
  outside the consent flow.

**R2 — Decide the AI shape of 2.0.0, in writing.** *(owner gate; blocks every release-facing claim)*
- Options: **(A)** ship the light build and make the documentation say "no AI in this build", with
  the feature bullets removed; **(B)** light build plus a working download path and a documented
  "AI arrives when the runtime is approved", with no AI claim in the feature list; **(C)** hold
  2.0.0 until R3 lands a helper in the bundle and R4 records a shipped-build inference.
- Acceptance: the chosen option is recorded in `Docs/RELEASE_2.0.0_READINESS.md` as a dated addendum
  and `README.md`, `Docs/RELEASE_NOTES_2.0.0.md` and the acceptance pack agree with it in all three
  languages of surface (English, Persian, in-app strings). A/A/B are compatible with releasing now;
  C is not.
- Recommendation: **B now, then C as the 2.1 milestone.** A 2.0.0 that is an honest editor is a
  smaller claim and a true one; a 2.0.0 that claims AI without a shipped inference repeats the
  present discrepancy.

**R3 — Put a real helper in a built artefact.** *(large; depends on the runtime-delivery gate)*
- Change: either bundle the source-built protocol-v2 runtime (the `RETOUCH_SKIP_WORKER=1` flag is
  removed once the archive is signed, hash-sealed and size-banded per DMG) or set
  `AIRuntime.package` to a published, validated archive. The quarantine finding — `ditto -x -k`
  propagates `com.apple.quarantine` to every extracted file unless `--noqtn` is used — must be
  closed first, and the payload must be hermetic (no Homebrew paths leaking into `sys.path`).
- Tests: a build-time assertion that the bundle contains a sealed runtime whose manifest hash the
  app verifies before executing anything; the existing `verify_payload.py` identity check promoted
  from advisory to required; a launch test from a clean macOS VM or a fresh user account.
- Acceptance: on that artefact, `AIRuntime.showsRuntimeCard` is true or the bundle carries a helper,
  a handshake completes from the installed app, and the run is recorded with a DMG sha-256 and a
  host name — not only a test count.
- Cost: 1.5 GB-class source runtime, signing limits under ad-hoc identity, and per-arch DMGs far
  larger than the 10 MB bundle measured in §12.1.

**R4 — One shipped-build inference, recorded to the ladder.** *(the actual W5-4 exit; depends on R1
plus R3)*
- Change: none beyond wiring; run the committed harness against the installed bundle, not a checkout.
- Tests: `worker/tools/upscale_acceptance.py` driven through the product's own
  `ExportService.upscale` path; `adoptRunningHelper` exercised through the real bundle rather than
  `RETOUCH_AI_SOCKET`; cancel-at-load, cancel-at-tile, cancel-at-write each proven on a real job.
- Acceptance: `capability-evidence.json` gains a second entry whose `evidence` string names the
  artefact sha-256, the app build, the host, the timestamp and the measured bit depth, peak memory
  and wall time; the capability flips to `supported` **only** for that platform, and the CI gate
  that greps the verdict prints it. Until then `upscale.4x` stays `blocked` in any release.

**R5 — Make the Model Manager say the true reason.** *(small, high value, no scope change)*
- Change: distinguish three states in the capability block — helper absent from this build, helper
  present but the capability's runtime package missing, and weights present but not yet adopted —
  and give the `sam2` entry an inline, localized explanation instead of a bare refusal.
- Tests: string-level assertions in the existing suite for each of the three states; a fixture that
  seeds each state.
- Acceptance: for each state, the visible English and Persian sentences differ and each names the
  next action the owner can take; no sentence claims the model is broken when the runtime is missing.

**R6 — sam2 admission decision.** *(owner gate for a ~156 MB weight plus a source-only package)*
- Change, if admitted: add `sam2` to the `models` extra and to the lock with a hash, which requires
  either publishing or vendoring a wheel-with-metadata (a bare git checkout has no `RECORD` and
  breaks `verify_payload.py`), ship or own the config YAML that `_ensure_sam` resolves relative to
  the checkout, then clear the entry's `unverifiableReason`.
- Tests: the declared-`Spec.packages`-versus-lock gate (tracked as the open A2 item) becomes
  executable rather than advisory, so an admitted package that drifts out of the lock fails CI.
- Acceptance: `mask.click` reports `supported` only after a recorded inference; a lock install under
  `--require-hashes` from a fresh checkout succeeds; `pip check` stays clean.
- Alternative: keep the refusal and remove `mask.click` from any user-facing capability list. Doing
  neither is what produced symptom 3.

**R7 — Harden the CI gates that let this through.**
- Promote `worker-payload-bundle` from `continue-on-error: true` to required, and make it upload the
  payload and its log so the proof survives the run.
- Extend `import_smoke.py` from top-level modules to the symbols actually used:
  `Swin2SRForImageSuperResolution`, `Flux2KleinEdit`, `ModelConfig.flux2_klein_4b`,
  `ort.InferenceSession`. The dev interpreter resolves all three today, which means the pins work —
  and the payload CI never checks them, which means nothing proves it survives a version bump.
- Add the redirect fixtures from R1 to the required set, and couple each capability's declared
  packages to the lock by set membership.
- Acceptance: a deliberately broken symbol import turns the payload leg red on its own PR; an
  undocumented catalogue host turns the catalogue check red.

**R8 — Windows distribution honesty.** *(owner decision, already separate)*
- Either mark the Windows artefact clearly as editor-only in `Docs/RELEASE_NOTES_2.0.0.md`, the
  release body and `WINDOWS_APP_READY`, or land a Windows inference under the same ladder as R4.
- Acceptance: no published surface implies Windows AI parity; the ~176 MB helper payload question is
  answered in the ledger with a size and a reason.

**R9 — Fix the specific documents this audit refuted, and keep the history.**
- `README.md`'s "The models are downloaded on request" and its AI feature bullets; the acceptance
  pack's framing that the AI rows are unavailable only because the helper is absent; the ledger's §3
  G-AI rows. All three get dated corrections beside the original text, never rewritten over it.
- Acceptance: a grep for the refuted sentence returns only the corrected form plus its dated marker.

## 10. What this changes about the acceptance decision

The owner's session did not fail because the app is broken at its core; it succeeded as an editor
and it exposed that the AI scope was never delivered as a *shipped* capability. Accordingly:

- W5-1, W5-2 and W5-3 remain **met as written**, and this audit states plainly that as written they
  did not include shipping a helper or downloading from a real host. Saying otherwise would be
  redefining the original scope backwards.
- W5-4 is **partial and self-declared incomplete**; it must not be counted as accepted, and its own
  documents already forbid that reading.
- W5-5 is **partial**: green checks, but two of them are advisory (`continue-on-error`, module-level
  import smoke) and the evidence file is not machine-checked.
- One new **defect** is filed by this audit: R1, the redirect policy against the XET CDN topology,
  which makes every catalogue entry unobtainable and makes a README promise false.

No W5 workstream is marked complete that is not. No incomplete work is accepted by this document.

## 11. NOT VERIFIED register (AI scope, current state)

1. Any inference from a released bundle, on any platform. **NOT VERIFIED.**
2. `AIRuntime` install path end-to-end with a real published package. **NOT VERIFIED** — there is no
   package.
3. Whether the CI payload reproduces the dev runtime's symbol-level imports. **NOT VERIFIED.**
4. Whether the payload is hermetic on a clean machine (Homebrew leakage into `sys.path`). **NOT
   VERIFIED** and suspected.
5. Quarantine behaviour of an extracted runtime on a fresh account. **NOT VERIFIED.**
6. The Windows ONNX Runtime path with an actual model file. **NOT VERIFIED.**
7. Whether the dev interpreter can still load `sam2` after a payload-style install with metadata.
   **NOT VERIFIED** — today it imports only as a metadata-less git checkout.
8. Quality of `migan` inpainting and of any generative path. **NOT VERIFIED** — no corpus exists.
9. FLUX suitability. **REFUSED at the licence gate**, not merely unverified; 16.7 GB measured peak on
   a 16 GB machine.
10. The 2× upscale candidate and any Windows Swin2SR conversion. **NOT VERIFIED / BLOCKED.**

## 12. Provenance of the probes in this document

### 12.1 Shipped artefact inspection

```
$ shasum -a 256 ~/Downloads/rs-rc-0758ad8/RetouchStudio-0.0.0-ci-arm64.dmg
b3711d0ce222aa03bddc41dbbf85c4c18a453431c9944a528c385dfe9d2ed2b4  RetouchStudio-0.0.0-ci-arm64.dmg
$ hdiutil attach -readonly -nobrowse ~/Downloads/rs-rc-0758ad8/RetouchStudio-0.0.0-ci-arm64.dmg
/dev/disk8s1        	41504653-0000-11AA-AA11-0030654	/Volumes/Retouch Studio 0.0.0-ci 1
$ ls "/Volumes/Retouch Studio 0.0.0-ci 1/Retouch Studio.app/Contents/Resources/"
AppIcon.icns	Fonts		LICENSE		THIRD_PARTY_NOTICES.txt	model-catalog.json
$ ls -d "/Volumes/Retouch Studio 0.0.0-ci 1/Retouch Studio.app/Contents/Resources/Worker"
ls: …/Contents/Resources/Worker: No such file or directory
$ /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" "…/Contents/Info.plist"
0.0.0-ci
5
$ du -sh "/Volumes/Retouch Studio 0.0.0-ci 1/Retouch Studio.app"
 10M
```

The image was detached after the listing. Build stamping resolved as a side effect: the RC's
`CFBundleVersion` is **5**, which is `GITHUB_RUN_NUMBER` of the fifth `release.yml` run (run
`45197302277`, `workflow_dispatch`), not the repository-wide run id; the repository default in
`Resources/Info.plist` is `2.0.0` plus build `2`. A tagged release is stamped from the tag name, so
this build reporting `0.0.0-ci` is correct behaviour and not a mis-stamp.

### 12.2 Catalogue file URLs, header-only

`HEAD` requests, `--max-time 20`, no object body fetched. Redirect target host recorded because that
is what the client's policy compares against.

| Entry | File | Answer | Redirect host |
|---|---|---|---|
| `flux2-klein-4b-q4` | `text_encoder/0.safetensors` | 302 | `us.aws.cdn.hf.co` |
| `flux2-klein-4b-q4` | `text_encoder/1.safetensors` | 302 | `us.aws.cdn.hf.co` |
| `flux2-klein-4b-q4` | `transformer/0.safetensors` | 302 | `us.aws.cdn.hf.co` |
| `flux2-klein-4b-q4` | `transformer/1.safetensors` | 302 | `us.aws.cdn.hf.co` |
| `flux2-klein-4b-q4` | `vae/0.safetensors` | 302 | `us.aws.cdn.hf.co` |
| `sam2.1-hiera-tiny` | `sam2.1_hiera_tiny.pt` | 200, `content-length: 156008466` | — |
| `swin2sr-x4` | `config.json` | 307 | `huggingface.co` (cache path) |
| `swin2sr-x4` | `preprocessor_config.json` | 307 | `huggingface.co` (cache path) |
| `swin2sr-x4` | `pytorch_model.bin` | 302 | `us.aws.cdn.hf.co` |
| `migan` | `migan_pipeline_v2.onnx` | 302 | `us.aws.cdn.hf.co` |

Two observations that matter for R1. The SAM 2 size in the response header equals the catalogue pin,
so that entry's integrity data is right and only its runtime is missing. And the `307` on the two
config files is a *same-host* redirect to a different path, which today's policy also refuses — so a
fix that only allow-lists hosts would still fail those two files; the rule has to be "allowed host,
allowed path class", with the hash as the final gate.

### 12.3 Import and lock facts

A read-only `python3 -c` import probe was run against the interpreter that already exists on this Mac
at `~/Library/Application Support/RetouchStudio/AI/runtime/bin/python3`. It reported CPython 3.13.15,
transformers 5.22.1, torch 2.15.0, onnxruntime 1.31.1, mflux 0.24.0, and resolved
`Swin2SRForImageSuperResolution`, `ModelConfig.flux2_klein_4b`, `Flux2KleinEdit`, `ort.SessionOptions`
and `sam2.build_sam` — that is DEV-RUNTIME evidence for the pins and explicitly not payload evidence,
because `worker/tools/import_smoke.py` imports top-level modules only. `sam2` imports there yet has no
package metadata, which is the practical form of §7.3. `worker/requirements.lock` contains 67 pins and
no `sam2`, and nothing couples a `Spec.packages` tuple to that lock.

Commands executed by this audit, exhaustively: `grep`, `sed`, `ls`, `du`, `find`, `wc`, `cat`,
`git worktree add`, `git status`, `git log`, `git diff`, `git rev-parse`, `git fetch`, `gh run list`,
`hdiutil attach` and `detach`, `shasum`, `PlistBuddy`, `python3 -c` import probes, and `curl -I`
against the URLs listed in §12.2. Nothing was written except this document and the dated corrections
listed in R9.
