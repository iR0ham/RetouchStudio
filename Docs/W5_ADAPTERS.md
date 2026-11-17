# W5-3 platform adapters and capability reporting

**Status:** implemented 2026-11-17 on top of the merged W5-1/W5-2 work; PR
#69. Hosted CI run 44095581869 is green on head `cd872e0` (macOS Integration,
Windows App, Windows StudioCore, StudioCore Boundary, Platform-neutral
Conformance). Anything that could only be built on a hosted Windows runner is
identified below; nothing here claims physical Windows hardware validation.

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

- Worker: 85 tests in `worker/tests` (`Tests/run-worker.sh`). 11 are new for
  the vocabulary, state rules, evidence handling, legacy layout, size and DR-5
  blocks, plus server-level refusals (`-32020`, `-32011`, mismatched kind) and
  the numeric cancel latency. Locally three `test_engine` composites error
  because this machine has no OpenCV; CI installs the hashed worker venv.
- macOS: 11 new checks in `Tests/ModelTests.swift` decode and reject reports,
  keep `requires_model` spelling, and check the typed names. The full
  `MODEL TESTS` suite passes locally on arm64.
- Windows: `RetouchStudio.AI.Tests/Program.cs` now checks
  `capability.list` over a real worker pipe (16 ids, no support, reasons),
  the `-32020`/`-32602` refusals, the host adapter parse, and the stopped-pipe
  `E_WORKER_MISSING` timing. Run 44095581869 on the hosted `windows-2025`
  runner reports `AI RUNTIME TESTS: PASS` and `WINDOWS APP BUILD: PASS`.

## Limitations, stated plainly

- `supported` is limited to the single recorded `upscale.4x` run on this Mac
  class. Installed-but-unproven models are reported `blocked`, not supported.
- Windows behaviour is host-runner evidence, not physical Windows hardware or
  GPU evidence. DirectML, GPU and Windows ML are NOT VERIFIED.
- The macOS capability panel was type-checked and its decode logic tested, but
  not exercised in a live UI session in this worktree (the owner's running app
  is left untouched).
- Capability-based job refusal is enforced when a caller sends `capabilityId`;
  the macOS production job path still sends job kinds in W5-3.
