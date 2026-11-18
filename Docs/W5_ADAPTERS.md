# W5-3 platform adapters and capability reporting

**Status:** implemented 2026-11-17 on top of the merged W5-1/W5-2 work; PR
#69. Hosted CI run 44110079042 is green on head `45e9e30` (macOS Integration,
Windows App, Windows StudioCore, StudioCore Boundary, Platform-neutral
Conformance), after a review of the kind-only job path; run 44095581869 was
green on `cd872e0` before it. Anything that could only be built on a hosted
Windows runner is identified below; nothing here claims physical Windows
hardware validation.

**Scope:** make both platforms answer the frozen W5-0 capability vocabulary
truthfully, and refuse what they cannot run. No new AI capability is added
here; a face, mask, heal, generative or enhancement engine remains out of
scope. Upstream decisions: `Docs/W5_IMPLEMENTATION_DECISION_RECORD.md`
(DR-4 support needs a recorded run, DR-5 unverifiable catalog entries are not
installable or supportable, DR-6 immutable versions, DR-7 OS leases).

## Contract reused, not changed

- Vocabulary `capabilities/1`: the 16 ids in
  `worker/retouch_ai_worker/capabilities.py` and
  `Windows/RetouchStudio.AI/Capabilities.cs`.
- States `supported | requires_model | blocked | unsupported`. Every
  non-`supported` record carries a `reason`; every `supported` record carries
  `evidence`. The hosts reject a report that breaks either rule, omits an id,
  repeats an id, or names a foreign vocabulary.
- Protocol 2, contract version 1, unchanged framing and handshake.
- One additive error code, `-32020 UNSUPPORTED`. The frozen vocabulary has no
  numeric code for "this adapter or platform does not provide it"; both hosts
  map it to `E_UNSUPPORTED`, and an older host sees a worker-range failure.
  This is documented in `Docs/AI_PROTOCOL_V2.md`.

## macOS adapter (`macos-python`)

The existing Python worker answers `capability.list`; the host does not hold a
table of its own.

- **Model resolution** uses the Model Manager store: the active pointer under
  `AI/models/<id>/active.json`, the flat legacy layout, and per-file size. No
  model is taken on lease by the capability query, and nothing is downloaded.
- **States.** A model-backed capability is `requires_model` when nothing is
  installed, `blocked` with an "adopt" reason when only the legacy flat layout
  exists, `blocked` when a file's size does not match the catalog, and
  `blocked` when its catalog entry lacks a size or SHA-256 (DR-5). An installed
  model is only `supported` when the evidence ledger has an entry for that
  exact capability, platform, provider, model id and version. Asked before all
  of that, a capability whose loading package this interpreter cannot import is
  `blocked` with that package named: `mask.click` declares `sam2`, which is in
  neither `requirements.lock` nor the `models` extra, so the weights being
  installed is not enough to make segmentation runnable. `find_spec` answers
  without executing the package, so the query stays cheap and loads no device
  context. The host already made the same distinction its own way: the runtime
  validator probes `sam2` as an optional backend
  (`Sources/RetouchStudio/Core/AIRuntimeValidation.swift:68`) and a recorded
  check asserts a missing optional backend does not invalidate the runtime
  (`Tests/ModelTests.swift:6025`). The worker's `blocked` record and the host's
  `segmentation: false` are the same fact at two boundaries, which is why no
  host change was needed here.
- **Evidence ledger** `worker/retouch_ai_worker/capability-evidence.json`
  contains one recorded run: `upscale.4x` on `macos-arm64` with
  `swin2sr-x4 1.0.0`, citing `Docs/PHASE5_ACCEPTANCE.md` §4 and
  `Docs/PRIVACY_AUDIT.md` §4. A missing or malformed ledger supports nothing.
  `RETOUCH_AI_CAPABILITY_EVIDENCE` points at another ledger for tests only.
- **Refusal.** `job.submit` with a `capabilityId` refuses a capability that is
  not runnable: `-32020` with `{capabilityId, state, reason}`, or `-32011`
  with the missing model for `requires_model`. The macOS host keeps submitting
  by job kind in W5-3, so existing jobs are unchanged; the refusal path is
  covered by worker tests.
- **The kind-only path enforces the runnable checks itself.** Every job
  resolves its weights through `Catalog.require`, so a kind-only submission
  still fails before loading on a missing model (`-32011`), an uncleared
  licence (`-32010`) or a file whose size differs from the catalog record
  (`-32019`, `E_MODEL_UNVERIFIED`). The size check was added after review: the
  report already called a truncated install `blocked`, but the load path only
  checked existence, so the kind path could load it. A refused model releases
  its lease. Qualification states — no recorded run, legacy flat layout, a
  DR-5 entry without size or SHA-256 — stay runnable on purpose: they describe
  what may be *claimed*, and running them is how evidence gets recorded. The
  missing package is not one of those states: `_ensure_sam` refuses with
  `-32020` and `{capabilityId, package}` before `Catalog.require` takes a lease,
  which is also why a `mask.click` evidence run cannot be recorded from a
  lock-reproducible runtime — nothing there can import `sam2`.
- **Cancel latency.** The worker records when a cancel was first requested and
  reports `cancelLatencyMs` in the job result. It does not claim instant
  cancellation; the value is what actually happened.
- **Host.** `Sources/RetouchStudio/Models/AICapability.swift` validates the
  report before use. A `-32011` refusal opens the model manager sheet
  (`EditorModel.showModelManager`), where the capability list and its reasons
  are displayed from the worker's answer
  (`Sources/RetouchStudio/Views/ModelManagerView.swift`).

## Windows adapter (`windows-onnxruntime`)

`Windows/RetouchStudio.AI/Capabilities.cs` builds the report, and
`WorkerServer` answers `capability.list`. No capability is `supported`:

- Every record is `blocked` or `unsupported` with the recorded reason
  (face decision pending F1, W5-4's ONNX artifact not approved, diffusion
  generation outside the CPU baseline, ...).
- If `Providers.Ensure()` did not initialise the CPU execution provider, every
  capability is `blocked` with the provider error, whatever its fixed reason.
- `job.submit` requires a `capabilityId`. An unknown id is `-32602`; a known
  one is refused with `-32020` and the record's state and reason. Nothing is
  accepted and dropped.
- `Windows/RetouchStudio.AI/CapabilityAdapter.cs` fetches and validates the
  report from the host side; a stopped pipe surfaces as `E_WORKER_MISSING`
  instead of waiting for a job timeout. `WorkerClient` also maps every
  worker-specific code to its W5-0 typed name.
- The Windows worker still does not load model weights. W5-4 Windows (the
  Swin2SR x4 ONNX path) remains blocked until the owner approves a recorded
  conversion and validation.

## Tests

- Worker: 140 tests in `worker/tests` (`Tests/run-worker.sh`). W5-3 shipped 88
  of them; W5-4 Slice 1 adds 12, the §3.6 publication work adds 15, the
  gate's admitting half adds 1, the independent review's fixes add 4, the
  submission-boundary pins add 2, W5-5 adds 2 (the acceptance harness
  itself, driven end to end against a deterministic fake engine — see the
  addenda), the A1 edit-provenance work adds 9 (seven at the publication
  boundary in `test_engine`, two at the envelope in `test_server`), the
  jobs-root claim adds 2 (a running job's `<workdir>/.lock` refused to a second
  descriptor and to a real child process, and `provenance.reconcile` leaving
  that file alone), the SAM 2.1 tiny catalog pin adds 2 (its measured size
  and digest, and DR-5's branch kept alive with the digests taken back out of
  an entry) and the runtime-package condition adds 3 (the gate refuses a bound
  model, the ungated report tracks this interpreter, and a mask job with no
  `sam2` refuses by name before any lease). 14 of the W5-3 tests are for
  the vocabulary, state rules, evidence handling, legacy layout, size and DR-5
  blocks, the server-level refusals (`-32020`, `-32011`, mismatched kind), a
  kind-only job that must not load a size-mismatched model (`-32019`), and the
  numeric cancel latency. Locally three `test_engine` composites error
  because this machine has no OpenCV; CI installs the hashed worker venv.
- macOS: 29 new checks in `Tests/ModelTests.swift` decode and reject reports,
  keep `requires_model` spelling, and check the typed names (11 from W5-3),
  adopt or refuse an upscale artifact against its provenance sidecar (9, W5-4)
  and adopt or refuse an *edit* pair the same way (9, A1). The full `MODEL
  TESTS` suite passes locally on arm64 and x86_64. The live-helper
  suite `Tests/RuntimeV2Tests.swift` carries the crossings a host-only test
  cannot: section N adopts a pair a real shipped worker published, section O
  pins `job.submit`'s field names against the helper's own signature, and
  section P (A1) shows a `requestedCapability` label records and runs where the
  same id named as a gate refuses.
- Windows: `RetouchStudio.AI.Tests/Program.cs` now checks
  `capability.list` over a real worker pipe (16 ids, no support, reasons),
  the `-32020`/`-32602` refusals, that a kind-only `job.submit` is refused
  (`-32602`, so the Windows adapter has no legacy path), the host adapter
  parse, and the stopped-pipe `E_WORKER_MISSING` timing. Run 44095581869 on the
  hosted `windows-2025` runner reports `AI RUNTIME TESTS: PASS` and
  `WINDOWS APP BUILD: PASS`.

## Limitations, stated plainly

- `supported` is limited to the exact tuple in the evidence ledger — one
  recorded run of `upscale.4x` on `macos-arm64` with `swin2sr-x4 1.0.0` — and
  that run is not claimable on this Mac as it stands. A read-only
  `capability.list` inspection on 2026-11-17 against
  `~/Library/Application Support/RetouchStudio/AI/models` reported
  `upscale.4x` as `blocked` with "swin2sr-x4 is installed without a version;
  adopt it in the model manager before a capability can bind it", because the
  installed folder is the legacy flat layout. The capability is therefore
  **not** reported `supported` by a live worker on this machine until that
  install is adopted. Installed-but-unproven models are reported `blocked`, not
  supported.
- Windows behaviour is host-runner evidence, not physical Windows hardware or
  GPU evidence. DirectML, GPU and Windows ML are NOT VERIFIED.
- The macOS capability panel was type-checked and its decode logic tested, but
  not exercised in a live UI session in this worktree (the owner's running app
  is left untouched).
- Capability-based refusal is enforced when a caller sends `capabilityId`, and
  the kind-only macOS path still enforces presence, licence and integrity in
  the worker. It does not refuse the `blocked` claim states (no evidence,
  legacy layout, DR-5 metadata): `mask`, `patch_edit` and the other job kinds
  still send no id, so they keep that property. `upscale` names its id since
  Slice 2 below, which has a user-visible consequence on this Mac: the install
  there is the legacy flat layout the bullet above records, so a 4× pass is
  refused with `E_UNSUPPORTED` until the owner adopts it in the model manager.
  The refusal is the contract's answer, not a defect — but it does mean the
  feature that ran through the kind path stops running until that one tap. The macOS provider
  record was static (`available`) in W5-3. Since W5-4 Slice 1 it is
  evidence-based: `execution_providers` is empty with `state: "unavailable"`
  and a reason until a loader names the device it used, so a worker that never
  initialised a runtime no longer claims one, and a missing MLX/torch still
  fails the job with `E_INTERNAL` rather than reporting a provider.

## Addendum (2026-11-17, W5-4 Slice 1)

Four things changed in the macOS adapter after this document was written. None
of them makes a new capability claim.

- **Provenance sidecar.** A successful `upscale` job writes
  `retouchstudio.ai.provenance/1` beside its artifact
  (`<name>.png.provenance.json`, `worker/retouch_ai_worker/provenance.py`) and
  returns the path as `provenance`. The record binds the job id, capability id,
  model id/version/format, the file digests, the provider, the parameters, and
  input/output geometry measured from the bytes the publishing rename moves.
  Decision record §3.6 is the contract; nothing in it was invented here.
- **Publication is ordered, not atomic.** The first draft of this work
  published the artifact and then wrote its sidecar, which left a real failure
  window: a record that could not be serialised, or a folder that could not be
  written, produced an artifact with no provenance for a host to adopt. No two
  renames can be made atomic on these filesystems, so `provenance.publish`
  lands the sidecar first and treats the artifact rename as the commit point,
  withdraws the sidecar if that rename fails, and re-reads the pair afterwards
  to remove it whole if the digests disagree. The state a crash between the two
  renames can leave is therefore a sidecar with no artifact — inert, because
  there is nothing to adopt — which `provenance.reconcile` clears when the
  worker starts and no job is in flight. An artifact without provenance is the
  state this path cannot produce. A host that adopts must still verify the pair
  itself; `provenance.verify` is the same check, and a reader that skips it is
  trusting a claim it can measure.
- **Load-time integrity.** `upscale` now resolves its weights through
  `Catalog.require_verified`, which hashes each file the catalog gives a SHA-256
  for and fails with `-32019` while releasing the lease. The check runs once per
  process on a 48 MB checkpoint — 0.036 s measured for its 48,460,141-byte
  `pytorch_model.bin` on this M3/16 GB Mac on 2026-11-17 — not on every tile,
  and not on the multi-gigabyte models; see the trade-off in `worker/README.md`
  invariant 10. The same measurement found all three live `swin2sr-x4` files
  matching their catalog digests, so the gate does not refuse the owner's
  existing install.
- **Cancel points.** The upscale job checks for a cancel before it loads,
  between tiles, and after the staged PNG is written but before publication
  begins, so a cancelled write leaves neither artifact, nor temp file, nor
  sidecar. Inside publication nothing is checked: a cancel that arrives there
  completes the pair rather than tearing it, which is the whole point of the
  ordering above.
- **Truthful provider.** `Engine.execution_providers` reports the device a
  loader actually used; before the first model, `provider.list` and `health`
  report no execution provider with `state: "unavailable"` and a reason.
  `Tests/RuntimeV2Tests.swift` asserts that pre-load shape, and the Windows
  suite keeps reporting `CPU` because `Providers.Ensure()` genuinely
  initialises it at worker start.

Still true after Slice 1: Windows claims nothing (`upscale.4x` is `blocked`
there with the artifact-approval reason, and the Windows worker loads no model
weights), the Windows CI job is host-runner evidence, and no macOS 4× run has
been re-recorded since Slice 1 — the acceptance gates in decision record §4.3
that need a real inference run are open, so W5-4 is not complete.

## Evidence scopes (2026-11-17)

Four kinds of "verified" get mixed together in this program. This is what each
statement about the upscaler is actually backed by, in descending strength.
Nothing here has been established by real inference on either platform in this
workstream.

**Physically measured on the reference Mac (the strongest evidence here).** The
`swin2sr-x4` checkpoint digest and size, the 0.036 s cost of hashing its
48,460,141-byte `pytorch_model.bin`, the legacy flat layout of the installed
store, and the `blocked` verdict `capability.list` returns for `upscale.4x` on
this machine. These were read from the live store and the live worker with
read-only commands on 2026-11-17. The older 4× inference measurements this
document quotes are recorded elsewhere, not re-run here:
`worker/retouch_ai_worker/capability-evidence.json` binds `upscale.4x` on
`macos-arm64` to a real 4× job that produced a 256×256 artifact from a 64×64
input on the M3 using `mps` in 5–7 s for the whole job (its cited source is
`Docs/PHASE5_ACCEPTANCE.md` §4), and `Resources/model-catalog.json` carries the
6.2 s per 256² tile figure in the `swin2sr-x4` notes. Both predate Slice 1 and
neither has been re-measured since.

**CI-proven on macOS** (run `44145839011`, `macOS Integration`, 17m1s): the
worker suites pass on the pinned source-built 3.13 runtime created by
`Tools/setup-worker-venv.sh`, StudioCore passes 288 checks, the C ABI passes
104, and the Swift runtime suite asserts the provider shape a fresh worker
reports before any model loads. This proves the protocol and the adapters'
code paths that the tests exercise — not that a 4× job ran.

**CI-proven on Windows** (same run, `Windows App`, 14m16s, and `Windows
StudioCore`, 3m33s): the .NET host builds against the Swift C ABI, the AI
worker and ONNX Runtime payload match their recorded size and SHA-256, the
host's own AI tests pass, and `upscale.4x` is refused with the
artifact-approval reason. That refusal is the Windows upscaling verdict:
**a green Windows App check establishes that the generic host works and that
inference is not offered, nothing more.** These are GitHub-hosted runners —
no physical Windows device, no GPU, and no DirectML claim is in evidence.

**Unit-tested only, with a fake engine.** The provenance sidecar fields, the
ordered publication and every failure window inside it (serialisation, create,
write, both renames, verification), the load-time digest gate and its
`-32019`, the cancel points and the startup orphan sweep. They run against a
numpy stand-in for torch and a fake model, on purpose: they prove the
worker's own bookkeeping, and they are not evidence that the real network
produces a good image. No test in this repository uses fake inference to claim
real inference works, and none may start. Also in this class: the host's
adoption rule. The `MODEL TESTS` checks write real files and hash them, so the
digest comparison is proven inside one process; `Tests/RuntimeV2Tests.swift`
sections N and P run a shipped helper, adopt what it published and read its
record back on both sides of the socket. Neither drives a real model: every
pair they adopt is published over stand-in pixels, so they prove the bytes and
the vocabulary cross correctly, not that an edit looks right.

**Not verified at all.** Anything about output quality, bit depth, ICC
behaviour, alpha behaviour, orientation, peak memory, wall-clock time, tile
counts or cancellation latency under a real 4× job; the ONNX artifact questions
on Windows; and a real upscale round trip in which the host names
`upscale.4x`, the worker publishes the pair and the host adopts it. Those are
the open W5-4 gates, and the acceptance harness in Phase 4 exists to make them
measurable once the owner authorises a real run.

## Addendum (2026-11-17, W5-4 Slice 2 — the host names the capability and checks the pair)

Two integration points closed, both inside the macOS host, neither a contract
change.

`ExportService.upscale` now submits `capabilityId: "upscale.4x"`, so the worker
applies its own verdict before it loads 48 MB of weights: a model that is
missing, unverified or unproven is refused with `-32011`/`-32020` instead of
running on the kind path's weaker checks. The wire contract is untouched —
`capabilityId` was already optional, `Tests/Contract/protocol2.json` is
unchanged, and mask and patch jobs still submit by kind alone.

It then refuses to decode the artifact until `AIProvenance.verifiedArtifact`
matches the sidecar beside it: the path the job returned, the
`retouchstudio.ai.provenance/1` schema, and the recorded `output.sha256` against
the digest of the bytes the host is about to show. A pair that does not agree
ends the pass with the usual failure message; a refusal never deletes anything,
because the artifact belongs to the worker's job folder and its own recovery
rules.

The consequence recorded under *Limitations* is real and intended: on this Mac
the installed `swin2sr-x4` is still the legacy flat layout, which
`capability.list` reports as `blocked`, so a 4× pass now stops at the gate until
the owner adopts it. The worker gained one test for the other half of that gate
— that a **supported** capability is still admitted — because every refusal test
in the file would stay green while the feature became unreachable.

## Addendum (2026-11-19, the shipped catalog stops claiming MI-GAN on Windows)

A verified false-capability claim was corrected in `Resources/model-catalog.json`.
Nothing in this section was measured; it records a metadata correction against
code that already existed.

**The defect.** The `migan` entry advertised `capabilities: ["inpaint.spot",
"inpaint.object"]` and `platforms: ["macos-arm64", "windows-x64"]`. Both values
were wrong on the evidence this document already carries:

- Object removal does not route to MI-GAN. `worker/retouch_ai_worker/capabilities.py:64`
  binds `inpaint.object` to `flux2-klein-4b-q4`, and
  `worker/retouch_ai_worker/engine.py:350,543-547` sends a `patch_edit` hole
  above `INPAINT_MAX_FRACTION` (0.25 of the frame, `engine.py:34`) to FLUX as
  well. The macOS host had already agreed: `Sources/RetouchStudio/Models/QuickEdit.swift:154`
  submits healing to `.migan` and object removal to `.flux`.
- No Windows runtime executes a model job. `Windows/RetouchStudio.AI/WorkerServer.cs:171-172`
  answers every `job.submit` with `RefuseJob`, and the Windows adapter reports
  no `supported` capability at all (see the Windows adapter section above). A
  `windows-x64` label therefore described something no Windows build can do,
  and it contradicted this document's own W5-2 honesty gate ("any unapproved
  ONNX artifact stay out of the catalog", `Docs/W5_MODEL_MANAGER.md:206`).

**The change.** `migan` is now `capabilities: ["inpaint.spot"]`,
`platforms: ["macos-arm64"]`, and its `notes` say what is true: spot healing
only, on macOS only, holes above 25 % of the frame refused, object removal
routed to `flux2-klein-4b-q4`, and no Windows job execution path. The entry's
files, sizes, digests, licences, provider and preprocess id are untouched, so
its manifest digest is unchanged. `catalogVersion` moved from `2026-11-16.1` to
`2026-11-19.1` because the shipped data changed.

**What flips in the suites.** The two assertions that encoded the falsehood are
inverted, not deleted: `Tests/ModelStoreTests.swift` (catalog/platform facts)
and `Windows/RetouchStudio.AI.Tests/ModelStoreChecks.cs` (case `[M17]`) now
require `MI-GAN is not advertised on Windows`, and each suite gained one check
that the entry advertises `inpaint.spot` alone. The label mapping is unaffected
because `inpaint.spot` still maps to the Healing task
(`Sources/RetouchStudio/Models/Localization.swift:782`); the Model Manager row
reads "Healing" on macOS and MI-GAN no longer appears as an installable Windows
model.

**What this does not change.** No worker code, routing, capability ledger,
manifest digest, store layout or lease was touched, and `inpaint.object` remains
a real capability bound to FLUX — only MI-GAN's claim to it is withdrawn.
`Docs/CI_GATES.md:687,719` quote the superseded platform list as part of a
past run's evidence; they are history and are left as written.
