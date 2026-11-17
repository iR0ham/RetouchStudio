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
  exact capability, platform, provider, model id and version.
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
  what may be *claimed*, and running them is how evidence gets recorded.
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

- Worker: 100 tests in `worker/tests` (`Tests/run-worker.sh`). W5-3 shipped 88
  of them; W5-4 Slice 1 adds 12 (see the addendum). 14 of the W5-3 tests are for
  the vocabulary, state rules, evidence handling, legacy layout, size and DR-5
  blocks, the server-level refusals (`-32020`, `-32011`, mismatched kind), a
  kind-only job that must not load a size-mismatched model (`-32019`), and the
  numeric cancel latency. Locally three `test_engine` composites error
  because this machine has no OpenCV; CI installs the hashed worker venv.
- macOS: 11 new checks in `Tests/ModelTests.swift` decode and reject reports,
  keep `requires_model` spelling, and check the typed names. The full
  `MODEL TESTS` suite passes locally on arm64.
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
  legacy layout, DR-5 metadata): doing so would stop the existing mask, heal
  and upscale jobs and the runs that produce evidence. The macOS provider
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
  input/output geometry measured from the published bytes. `state` and the
  sidecar are written once, after the rename adopts the artifact, so a job that
  does not publish writes no provenance. Decision record §3.6 is the contract;
  nothing in it was invented here.
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
  between tiles, and after the staged PNG is written but before it is renamed
  into place, so a cancelled write leaves neither artifact nor temp file.
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
