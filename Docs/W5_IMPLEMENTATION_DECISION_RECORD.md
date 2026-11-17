# W5 Implementation Decision Record — Multi-Platform AI (W5-0)

**Status:** W5-0 decision record after the owner review of 2026-11-16. The
owner decisions in §7 are answered (§7 states each outcome); the contract
sections remain PROPOSED and freeze on final approval of this PR. It changes
no application code, project schema, catalog or release artifact, and
authorizes no download.
**Date:** 2026-11-16 (revised after the owner review).
**Base:** `main` at `8000c9d` (PR #65 merge, 2026-11-16).
**Authority:** the product-owner decisions of 2026-11-16, recorded in §7 and
[AI_11_MULTI_PLATFORM_ADDENDUM.md](AI_11_MULTI_PLATFORM_ADDENDUM.md) §1, over
the AI-01 research where they differ. Master Execution Plan V4's text is
unchanged; A1/A2 approval and its exact consequences are recorded in the
addendum §4.
**Companions:** [AI_11_MULTI_PLATFORM_ADDENDUM.md](AI_11_MULTI_PLATFORM_ADDENDUM.md),
[W5_ROADMAP.md](W5_ROADMAP.md),
[AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §6,
[AI_11_MODEL_EVALUATION.md](AI_11_MODEL_EVALUATION.md),
[AI_RUNTIME.md](AI_RUNTIME.md).

## 1. Scope and reading rules

W5 is an implementation milestone for both platforms. W5-0 is its
architecture and contract freeze: shared vocabulary, job semantics, catalog,
provenance, model-store rules, adapter shape and the owner decisions that must
exist before runtime work starts. This record is the W5-0 artifact set; it is
implemented by W5-1 onward ([W5_ROADMAP.md](W5_ROADMAP.md) §3).

It does not implement, download, benchmark or adopt any model. It does not
change schema v5, the C ABI, the 1.0/1.1 release architecture or the current
macOS worker.

Evidence labels follow AI-01: **VERIFIED** (source or recorded run),
**MEASURED** (a number with cited context), **ESTIMATE** (basis stated),
**RECOMMENDATION** (proposed decision), **NOT VERIFIED** (not proven here).

Decision status vocabulary:

| Status | Meaning |
|---|---|
| **FROZEN (on approval)** | W5-1..W5-5 implement it; a later change needs a dated revision of this record. |
| **PROPOSED** | Recommended here; final approval freezes it. |
| **DECIDED (owner)** | Answered by the owner; the outcome is in §7 and it no longer blocks W5-0. |
| **DEFERRED** | Deliberately after a measurement or licence step; not dropped. |

**Delivery exception.** [WORKFLOW.md](WORKFLOW.md) discourages documentation-only
PRs. The owner instructed one coherent W5-0 documentation PR as the review
package for this freeze; it is an explicit exception, not a new default.

## 2. Platform shape

| Layer | macOS | Windows |
|---|---|---|
| Host | SwiftUI editor (existing) | WPF .NET host (existing) |
| AI orchestration | Thin host layer: capability discovery, submit, cancel, progress, consent UI | Same contract, C# implementation |
| Worker | Existing Python worker for 1.1, made reproducible; native Core ML/MLX only behind a measured gate | Separate C# worker process; ONNX Runtime CPU EP mandatory; DirectML optional; no Python sidecar |
| Model store | Per-user, existing `AI/models` beside the runtime tree (`AIWorker.modelsDirectory`) | Per-user local application data, same relative layout |
| Transport | Adapter-specific (existing local socket) | Adapter-specific (named pipe recommended) |
| Frames | The shared AI contract v1 | The shared AI contract v1 |

**DR-1 (PROPOSED → FROZEN on approval) — Shared is data, not code.** The two
hosts share the contract document, the capability vocabulary, the catalog
schema, the provenance schema and the conformance fixtures. They do not share
an implementation library, and no AI type enters `StudioCore` or the C ABI.
The existing 13 JSON-only C ABI exports stay untouched. Each host implements
the contract natively.

**DR-2 (DECIDED 2026-11-16) — macOS keeps the Python worker for 1.1, with its
source in this repository.** This follows AI-01 ADR-4. Rewriting a measured
worker for an unmeasured one adds no capability. The owner's preferred option,
chosen on 2026-11-16, is to bring the complete worker source into the
repository, preserving its licence and dependency notices, with every
dependency pinned by version and hash. An external mutable branch or an
unverified download is not used. W5-1 makes the worker reproducible and fixes
the protocol-2 mismatch; it does not change the inference stack.

**DR-3 (DECIDED 2026-11-16) — Windows uses a separate C# worker with ONNX
Runtime CPU.** The worker is its own process so an ONNX Runtime fault cannot
kill the WPF host; it is contained by a job object that kills it on host exit.
The CPU execution provider is the only mandatory provider; DirectML may be
enabled when present and measured, and its absence must never fail a job or a
capability claim. No GPU performance claim is made without native hardware
validation. A Python sidecar is rejected as the default: it adds a
1.29 GiB-class runtime, interpreter lifecycle and a second scripting surface
for no measured capability that a C# ORT adapter cannot provide. Reopening
this decision requires measured evidence and named alternatives, per the
owner direction. The owner approved ONNX Runtime CPU and its required native
payload as a Windows application dependency on 2026-11-16. The binding
version, the payload size and its hash are still **NOT VERIFIED** in this
repository; selecting and pinning them is W5-1 work.

## 3. Contracts frozen at W5-0

### 3.1 Contract envelope and versioning

- JSON-RPC 2.0, one request per line, over an adapter-specific local
  transport. The transport is not part of the contract; the frames are.
- Every request and result carries `contractVersion: "1"`. Additive optional
  fields are allowed inside v1; adapters must ignore unknown optional fields.
  A breaking change bumps the major version and must be implemented on both
  platforms before either reports it.
- Capability vocabulary is versioned separately: `capabilities/1`.
- No pixel buffers cross the contract. Inputs and outputs are file paths plus
  metadata, exactly as AI-01 §6 requires.

### 3.2 Capability vocabulary

A capability ID names a product offer; a job kind names the wire operation.
They are not interchangeable.

| Capability ID | Product capability | Job kind(s) | macOS path today | Windows path (follow-on unless in W5) |
|---|---|---|---|---|
| `face.analysis` | Detection, landmarks, regions (AI-01 A) | `analysis` | Vision (shipped) | F1 model decision, then W3 |
| `face.parsing` | Learned face-region classes | `analysis`, `segmentation` | none | follow-on F2, after F1 |
| `mask.subject` | Subject/background segmentation (B) | `segmentation` | Vision person segmentation (shipped for backdrop) | follow-on W3/S1 |
| `mask.click` | Promptable mask (B) | `mask` | SAM 2.1 box (shipped) | follow-on S2 |
| `matte.fine` | Hair/fine matte (B) | `matte` | none (licence gate) | follow-on S2 (licence gate) |
| `inpaint.spot` | Spot removal (D) | `inpaint` | MI-GAN (shipped) | follow-on H1; ONNX port unverified |
| `inpaint.object` | Object removal (D) | `inpaint`, `generative_edit` | MI-GAN / FLUX.2 klein (shipped) | follow-on H1/G1; needs a CPU-viable engine |
| `generative.edit` | Masked prompt edit (F) | `generative_edit` | FLUX.2 klein (shipped) | follow-on G1; CPU-viable or optional-GPU engine |
| `generative.reimagine` | Whole-frame reimagine (F) | `generative_edit` | FLUX.2 klein (shipped) | follow-on G1; CPU-viable or optional-GPU engine |
| `generative.outpaint` | Outpainting (F) | `generative_edit` | refusal (no licensed engine) | follow-on G1; refusal until licensed |
| `background.replace` | Backdrop replacement (E), composed | `segmentation` + composite + optional `matte` / `generative_edit` | shipped over `mask.subject` (coarse edges) | follow-on B1 |
| `upscale.2x` | 2× output (G) | `upscale` | not implemented | follow-on U1 |
| `upscale.4x` | 4× output (G) | `upscale` | Swin2SR x4, export-time (shipped, measured) | **W5-4**, Swin2SR x4 ONNX on CPU |
| `enhance.photo` | AI Enhancer, same size (H) | `enhance` (+ `restore` stages) | none (classical only) | follow-on E1 |
| `restore.photo` | Restoration, same size (H) | `restore` | none | follow-on E1 |
| `portrait.ai` | AI portrait augmentation (C) | `enhance`, `inpaint` | none; classical stays default | follow-on P1 |

A follow-on milestone is a concrete path with named gates, not a parity claim
or a support claim. `background.replace` is a product-level composite over a
capability; it is not a model job. `enhance.photo` is the user-facing AI
Enhancer over `enhance` and `restore` stages; it is never an alias for
`upscale.*` and never changes dimensions.

### 3.3 Capability states and truthful reporting

Each adapter answers `capability.list` with one record per capability:

| Field | Meaning |
|---|---|
| `capabilityId` | From the vocabulary above |
| `state` | `supported`, `requires_model`, `blocked` or `unsupported` |
| `provider` | Adapter/provider identity, e.g. a CPU execution provider |
| `modelId`, `modelVersion` | Present when a model is required |
| `evidence` | The run or measurement that justifies `supported` |
| `reason` | Mandatory for every state other than `supported` |

**DR-4 (PROPOSED → FROZEN) — `supported` is bound evidence.** A capability
may report `supported` only when all of the following hold: the adapter is
present; where the capability needs a catalog model, a model for it is
installed and verified (capabilities backed by an OS framework such as Vision
record the framework as their provider instead); and a recorded run on that
platform, provider, model id and model version produced a valid artifact.
Installing a model, shipping an interface, compiling a class or merging a PR
is not evidence. Any model version change resets the capability to
`requires_model` until the run is repeated.

- `blocked` means the platform could provide an approved capability, but a
  licence, an unmade model decision or an unapproved dependency currently
  prevents it (for example outpainting, or Windows face analysis before F1).
- `unsupported` means this platform, adapter or contract version does not
  provide it now and will not in this release (for example Intel Macs without
  the arm64 worker, or diffusion-class generation on the CPU-only Windows
  baseline).
- Unsupported operations are refused with a typed error and surfaced in the
  UI. They are never silently dropped: the Windows export guard must keep
  naming preserved AI/mask/heal records until a real render path exists.

### 3.4 Job lifecycle, progress, cancellation and errors

States: `queued → loading → running → writing → completed`, with `failed` and
`cancelled` reachable from every non-terminal state. The host owns the queue;
a worker runs one heavy job at a time.

| Concern | Frozen semantics |
|---|---|
| Progress | Monotonic `{completed, total, unit}` where `unit` is `tiles`, `steps` or `items`; `total: null` is allowed and rendered as indeterminate. Never fabricate a total. |
| Cancel | Host sends `job.cancel` and stops waiting; the adapter drops the job, deletes its working files and reports `cancelLatencyMs`. A native call that cannot be interrupted must say so; no instant-stop claim. |
| Timeout | Per-kind defaults (existing: 300 s patch, 1500 s upscale) plus an optional request deadline; a timeout is a cancel plus `E_TIMEOUT`. |
| Adoption | Artifacts are adopted atomically only after a completed result; a cancelled, failed or timed-out job changes no document and leaves no artifact. |
| Worker crash | The job fails with `E_WORKER_CRASH`; the document is unchanged; restart happens on the next explicit action. Windows containment is a job object; macOS uses the existing process lifecycle. |
| Concurrency | One heavy job per worker; small analysis jobs may interleave only after a measurement, not by default. |

Typed errors (stable codes; UI copy may differ):

| Code | Meaning |
|---|---|
| `E_WORKER_MISSING` | No worker/runtime installed |
| `E_MODEL_MISSING` | Capability needs a model that is not installed |
| `E_MODEL_UNVERIFIED` | Installed model failed integrity or lacks mandatory metadata |
| `E_MODEL_LEASED` | Model deletion or update refused while a lease is held |
| `E_LICENCE_REFUSED` | Licence gate or worker refusal |
| `E_INVALID_INPUT` | Unreadable input, bad geometry or unsupported size |
| `E_OUT_OF_MEMORY` | Refused before load or allocation failure |
| `E_TIMEOUT` | Deadline exceeded |
| `E_CANCELLED` | User or host cancellation |
| `E_UNSUPPORTED` | Capability not provided by this adapter/platform |
| `E_ARTIFACT_MISSING` | Referenced artifact is gone |
| `E_WORKER_CRASH` | Worker exited mid-job |
| `E_INTERNAL` | Anything else; never a silent success |

Wire mapping (W5-3): the hosts derive these names from the worker's numeric
codes (`-32011`/`-32016` → `E_MODEL_MISSING`, `-32012` → `E_MODEL_LEASED`,
`-32013` → `E_TIMEOUT`, `-32014` → `E_CANCELLED`, `-32019` →
`E_MODEL_UNVERIFIED`, `-32000` → `E_WORKER_MISSING`, `-32020` →
`E_UNSUPPORTED`). `-32020` is additive in contract 1: the frozen registry never
assigned a numeric code to "not provided by this adapter", and an older host
that does not know it still fails the job rather than treating it as success.
No other code or field changed.

### 3.5 Job request and result fields

Request: `contractVersion`, `jobId`, `capabilityId`, `kind`, inputs (image
path, optional mask path, points/box in a declared source-normalized top-left
space), parameters (strength, steps, patch size, seed, feather/dilate with
units, prompt), constraints (output size, tile limit, deadline), and a
provenance request. The adapter chooses the model and returns its identity.

Result: artifact paths (patch/alpha, whole image, mask, upscaled image), the
authorized rectangle in source-normalized top-left space,
`outsidePixelsIdentical` where the engine can promise it, model identity and
weight digests, provider, seed/parameters, elapsed time, cancellation latency
and typed errors. Coordinates follow schema v5 §4; adapters translate at their
edge.

### 3.6 Artifact and provenance contract

- Artifacts stay beside the edit id in the existing edit store; the project
  body gains no keys (AI-01 ADR-2/ADR-5).
- Each adopted artifact has a sidecar `*.provenance.json` with
  `schema: "retouchstudio.ai.provenance/1"`, `contractVersion`,
  `capabilityId`, `jobId`, `createdAt`, model `{id, version, format,
  provider, files[].sha256}`, adapter `{platform, version}`, parameters,
  seed, input/output SHA-256 and dimensions and bit depth, the authorized
  rectangle, `outsidePixelsIdentical`, elapsed time and result state.
- Bit depth and colour space are recorded as measured, not assumed. An 8-bit
  round trip may not be reported as 16-bit.
- A missing or unreadable artifact is reported as `E_ARTIFACT_MISSING` and
  the edit is shown as missing, never drawn blank or stale.
- Provenance is written atomically with adoption; a job that does not adopt
  writes none.

### 3.7 Model catalog

One bundled, versioned catalog per app build. A remote catalog fetch is out of
scope for W5 and would need an owner decision; the catalog is reviewed with
the code that reads it.

Every entry carries: `id`, display name, `capabilities[]`, immutable
`version`, `format`, `files[]` with `sizeBytes` and `sha256`,
`sourceUrl` (official source), licence for code and a separate licence for
weights with evidence, supported platforms and required provider, minimum
contract version, preprocessing identifier/version, determinism flag and
notes. A URL, hash or size is never invented; an entry without them is
`unverifiable`.

**DR-5 (PROPOSED → FROZEN) — unverifiable entries are not installable.** An
entry missing size or SHA-256 cannot be downloaded, installed or reported as
supported; it may be listed with the reason. This closes the SAM 2.1 tiny gap
recorded in [AI_RUNTIME.md](AI_RUNTIME.md) §6.3 and
[AI_11_ARCHITECTURE.md](AI_11_ARCHITECTURE.md) §2.2.

**DR-6 — version immutability and update.** A new model build is a new entry
version. An update installs the new version beside the old, verifies it, then
switches the active pointer atomically. The previous version is retained for
rollback and shown in the model manager; it is deleted only by explicit user
action or as part of removing the model. Rollback is a pointer switch, not a
download.

### 3.8 Model store, installation, deletion and cleanup

Relative layout under the per-user model root (macOS: the existing
`AI/models`; Windows: the host's per-user local application data):

```
models/<model-id>/<version>/          verified payload + manifest.json
models/<model-id>/active.json         atomic active-version pointer
models/.staging/<uuid>/               download in progress
models/.quarantine/<uuid>/            deletion in progress
models/.locks/<model-id>-<version>    OS lock file
```

| Operation | Frozen rule |
|---|---|
| Install | Download into `.staging/<uuid>`; verify every file's size and SHA-256 against the catalog; write the version manifest; atomic rename into `<version>`; then write `active.json` atomically. A crash before the rename leaves only staging (cleaned later); a crash after it leaves a complete, inactive version the user may activate. |
| Verify on load | Manifest hash, presence and sizes are checked quickly; a full re-hash runs on the existing "Verify" action and on any integrity error. |
| Consent | Per model version, before any byte: name, size, licence, source and hash prefix. No download at launch, no silent fetch, no background retry that changes version. |
| Delete | Requires exclusive access. Remove the active pointer atomically, rename the version into `.quarantine`, then delete. A crash after the pointer removal leaves a complete inactive version, listed and removable; a crash after the rename leaves quarantine for startup cleanup. A pointer that dangles for any other reason reads as unavailable. |
| Startup cleanup | Removes staging and quarantine entries older than a documented grace period (default 24 h) that are not locked; never removes a valid version, the active version or a locked directory. Extends the existing export-temp sweep idea to the model store. |
| Disk budget | The manager reports per-model and total size; a download that cannot fit is refused before bytes. |

### 3.9 Leases and safe deletion

**DR-7 (PROPOSED → FROZEN) — leases are OS locks held by the process that has
the model open.** A worker holds a shared lock on `.locks/<model>-<version>`
while a model is loaded or a job runs; the host holds one during install,
verify and delete. Deletion needs exclusivity and is refused with
`E_MODEL_LEASED` while any reader exists. On macOS an exclusive `flock` is
released by the OS when the process dies; on Windows an open handle without
delete sharing produces the same refusal and is released on process death. A
lock registry in memory is not authoritative; a crash must not leave a
permanent lock.

This closes the current gap where `ModelManager.remove` takes no lease and
does not consult `ModelActivity.isRunning` before deleting
(`Sources/RetouchStudio/Models/ModelManager.swift:196-207`, VERIFIED at
`8000c9d`).

Required W5-2 race tests: delete during a running job; delete during a
download; two processes downloading the same version; crash between verify and
rename; crash between rename and pointer switch; crash between pointer removal
and quarantine; update while the old version is leased; rollback while a job
runs; startup cleanup with a live lock, a stale lock and a stale staging tree.

### 3.10 Consent and network policy

- No network in the job path. The privacy property recorded by
  [PRIVACY_AUDIT.md](PRIVACY_AUDIT.md) applies to both platforms and must be
  re-audited when an adapter or model is added.
- The only requests are consented downloads of a specific catalog entry from
  its recorded HTTPS source. TLS is not a substitute for hash verification;
  the hash is the authority.
- No telemetry, no cloud inference, no weights bundled or redistributed.
- A failed or cancelled download leaves no installed model; a retry is the
  same consented version.

### 3.11 Conformance fixtures

A new additive fixture set, valid on both hosts with test doubles: one request
and result per job kind, invalid-input and typed-error cases, capability
reports for each state, provenance examples and tiny deterministic images.
Existing golden exports and baselines are never regenerated. Fixtures live
under a new versioned directory; the exact path is chosen in W5-1, not frozen
here.

## 4. Platform-specific decisions

### 4.1 macOS

- The worker source is brought into this repository with its complete licence
  and dependency notices; every dependency is pinned by version and hash. No
  external mutable branch and no unverified download is used. The existing 60
  worker regression tests under `Docs/worker-regressions` must run from a
  fresh checkout.
- W5-1 ships a reproducible, source-built runtime. The build produces a
  self-contained app runtime, so end users never install Python manually. No
  package URL, size or hash is invented; packaging and signing are finalized
  with verified build artifacts.
- The protocol-2 handshake currently expected by the host
  (`HelperRegistry.protocolVersion = 2`, `WorkerClient` check at
  `Sources/RetouchStudio/Core/WorkerClient.swift:296`, VERIFIED) must be
  proven against a real helper process started by the build. This is W5-1's
  macOS exit.
- Capability discovery replaces hard-coded UI offers; no capability is offered
  because a button exists.
- `AIRuntime.package` stays nil in W5-1: a source-built runtime is not a
  downloadable package (`Sources/RetouchStudio/Core/AIRuntime.swift:34-41`,
  VERIFIED at `8000c9d`). A downloadable package is not part of W5-1; packaging
  and signing are finalized with verified build artifacts.

### 4.2 Windows

- A separate C# worker executable, per-user model store, named-pipe transport
  recommended, same JSON frames.
- ONNX Runtime CPU EP is the baseline and must work on the `windows-2025`
  runner with no GPU and no Python. The owner approved ONNX Runtime CPU and
  its required native payload as a Windows application dependency on
  2026-11-16, including its presence in the MSI.
- DirectML is optional: detected, reported and used only when present and
  measured; never a requirement and never the source of a capability claim.
  No GPU performance claim is made without native hardware validation.
- The WPF host currently has no package dependency by design. Adding the ORT
  binding and its native payload is now an approved dependency; pinning its
  version, size and hash is W5-1 work.
- The Windows export guard keeps naming preserved records until a real render
  path exists; a `supported` capability must render and export, not merely
  record.

### 4.3 First cross-platform capability — Upscaler 4x

`upscale.4x` is the W5-4 acceptance capability. Swin2SR x4 is chosen because
it is already measured on the M3, its weights licence is Apache-2.0, and the
product behavior (export-time, fixed 4×, 1500 s timeout, tile progress,
40 MP output ceiling) already exists. Acceptance gates:

1. **Correctness.** Output dimensions are exactly 4×; the artifact decodes;
   the export path applies callouts/watermark after the upscale, as macOS does.
   For this job the authorized rectangle is the full frame and
   `outsidePixelsIdentical` is not claimed.
2. **Quality.** A fixed, owner-approved corpus; macOS and Windows outputs are
   compared with a tolerance fixed before the run. No tolerance is weakened to
   pass. A quality claim needs the comparison; a successful job alone is not
   one.
3. **Windows CPU performance and memory.** Measured on the Windows runner and
   labelled as an observation, not a benchmark; CPU-only CI never proves GPU
   speed.
4. **Bit depth.** Input/output bit depth is measured. 16-bit upscaling is
   claimed only if more than 8 bits survives the round trip; otherwise the
   product says 8-bit.
5. **Cancellation.** Cancel during load, tile loop and write leaves no
   artifact and no temp; latency is reported.
6. **Provenance.** Every artifact carries the sidecar with model id, version,
   file hashes, provider and digests.
7. **Truthful reporting.** Until the acceptance run records an artifact,
   Windows reports `requires_model` or `blocked`, never `supported`; after a
   passing run the state may become `supported` with that run as its evidence.
   macOS keeps `supported` only for the measured arm64 build.
8. **Model provenance.** The Windows Swin2SR ONNX artifact's conversion source,
   file size and SHA-256 are recorded in the catalog. The official Swin2SR
   release is a PyTorch checkpoint. The owner did not approve an unverified
   community ONNX conversion (2026-11-16); adoption requires a reproducible
   conversion procedure, the source checkpoint, the opset, the output
   artifact, its size, its SHA-256, licence evidence and quality validation.
   Until that evidence is reviewed and approved, **Windows W5-4 is BLOCKED**.
   W5-1, W5-2 and W5-3 continue independently.

## 5. W5-0 exit criteria

W5-0 closes when all of these are true:

1. This record and the addendum receive final owner approval. A1/A2 was
   approved on 2026-11-16 and its exact consequences are recorded in
   [AI_11_MULTI_PLATFORM_ADDENDUM.md](AI_11_MULTI_PLATFORM_ADDENDUM.md) §4;
   Master Plan V4's text is unchanged.
2. The capability vocabulary, states and job lifecycle (§3.2–3.4) are frozen.
3. The catalog, provenance and model-store rules (§3.6–3.9) are frozen. The
   Swin2SR x4 Windows ONNX entry has no approved source, size, SHA-256 or
   licence evidence yet, so **Windows W5-4 is explicitly BLOCKED** pending
   that review; W5-1–W5-3 proceed.
4. The Windows dependency policy is decided: ONNX Runtime CPU and its native
   payload are approved (2026-11-16); DirectML stays optional.
5. The worker-source publication decision is made: the complete source enters
   this repository with notices and pinned, hashed dependencies.
6. Every owner decision has an answer or an accepted deferral with the
   affected milestone named (§7).

No runtime implementation starts before this list is complete.

## 6. W5 sequence

| Step | Deliverable | Exit evidence |
|---|---|---|
| W5-0 | This freeze | Owner decisions resolved; final document approval |
| W5-1 | Reproducible runtime, both platforms | Fresh checkout builds; real process starts; protocol handshake on macOS and Windows; worker source and dependencies pinned |
| W5-2 | Model manager, both platforms | Consent, hash verification, stage/rename, update/rollback, leases, delete and cleanup; race tests |
| W5-3 | Adapters and capability reporting | Capability list derived from adapter; unsupported refused and named; no interface-only support |
| W5-4 | Upscaler 4x acceptance | macOS run, quality/tolerance, cancel, memory, bit depth, provenance; Windows run only after the ONNX artifact is approved |
| W5-5 | CI and acceptance | Contract tests in existing contexts; CPU correctness separated from hardware/performance evidence |

Detailed deliverables, capability preservation and follow-on milestones:
[W5_ROADMAP.md](W5_ROADMAP.md).

## 7. Owner decisions (answered 2026-11-16)

The owner reviewed W5-0 on 2026-11-16 and answered every decision below. The
five decisions that blocked W5-0 are resolved; the remaining blockers are
evidence-bound work items, not open product-direction questions.

| # | Decision | Owner outcome (2026-11-16) | Remaining work / effect |
|---|---|---|---|
| 1 | V4 amendment A1/A2 | **Approved.** A1 moves the Windows "AI edits" completion criterion from stage 4 to W5 completion for the W5-adopted set. A2 lets W5-0/W5-1/W5-2/W5-3 proceed after W4 while W3 proceeds independently. W3 still precedes any Windows face, landmark or mask support claim. No other V4 sequencing changes. | V4 text stays unedited by owner instruction; the approval and its consequences are recorded in the addendum §4. No owner action remains. |
| 2 | Windows runtime dependencies | **Approved.** ONNX Runtime CPU and its required native payload are a Windows application dependency. DirectML stays optional. No GPU performance claims without native hardware validation. | Pin the binding version, native payload size and hash in W5-1; size the MSI in W5-2. |
| 3 | macOS worker source | **Decided.** The owner's preferred option: bring the complete worker source into this repository; preserve its licence and dependency notices; pin every dependency by version and hash; no external mutable branch and no unverified download. | Import the source and prove the 60 regressions from a fresh checkout in W5-1 (macOS). |
| 4 | macOS runtime distribution | **Decided.** W5-1 ships a reproducible, source-built runtime. The build produces a self-contained app runtime; end users never install Python manually. Do not invent package URLs, sizes or hashes. Packaging and signing are finalized with verified build artifacts. | `AIRuntime.package` stays nil in W5-1; a downloadable package's metadata is finalized with verified build artifacts. |
| 5 | Windows face analysis, landmarks and masks | **Decided.** They remain mandatory product requirements. The exact Windows landmark model is deferred to F1. Offline inference and cleared commercial distribution rights for the weights are required. No Windows face/mask capability is marked supported before real Windows validation. This does not block unrelated W5 infrastructure or Upscaler work. | F1 chooses and licenses the model; W3 needs it before Windows face/mask claims. W5-1–W5-4 do not wait on it. |
| 6 | Windows ONNX artifact for Swin2SR x4 | **Decided.** An unverified community ONNX conversion is not approved. Adoption requires a reproducible conversion procedure, the source checkpoint, the opset, the output artifact, its size, its SHA-256, licence evidence and quality validation. Windows W5-4 stays **BLOCKED** until that evidence is reviewed and approved. W5-1–W5-3 continue independently. | Submit the artifact evidence for owner review; only then can W5-4 Windows start. |
| 7 | Model hosting | **Decided.** Official model sources only for W5. | The catalog records the official source; no mirror. |
| 8 | Bit-depth advertising | **Decided.** Measure the round trip before advertising; 16-bit only if it survives. | W5-4 measures; 8-bit is the default claim. |
| 9 | DirectML / GPU direction | **Decided.** DirectML remains opportunistic. No GPU performance claims without native hardware validation. | Never mandatory; never a capability-claim source. |
| 10 | Follow-on weight grants (fine matte, LaMa, outpainting) | **Deferred.** The licence decisions remain in their respective follow-on milestones. | B1, H1 and G1 each carry their own grant gate. |
| 11 | AI Enhancer presets and quality corpus | **Deferred.** AI Enhancer retains its separate E1 milestone and its own quality corpus. | E1 defines the presets and corpus; never aliased to Upscaler. |

**What still blocks a step.** Windows W5-4 waits on decision 6's evidence;
Windows face, landmark and mask support waits on F1 (decision 5); the ORT
binding pin (decision 2) is W5-1 engineering work; runtime package metadata
(decision 4) is needed only for a later downloadable distribution. Nothing in
this table blocks W5-1, W5-2 or W5-3.

## 8. NOT VERIFIED register

- ONNX Runtime integration, the binding version, native payload size and CPU
  performance inside the Windows host and MSI. The dependency itself is
  approved (2026-11-16); the specific pin is not yet verified.
- The Swin2SR x4 ONNX artifact: export source, opset, file size, SHA-256 and
  numerical parity with the macOS checkpoint. No conversion is approved;
  Windows W5-4 is blocked on this evidence.
- Windows CPU latency, peak memory, thermal behavior and quality for every
  model.
- DirectML availability, behavior and performance on any hardware; Windows ML
  / vendor execution providers and their OS requirements.
- Windows named-pipe worker transport, job-object containment and crash
  recovery.
- Whether more than 8 bits survives the upscale round trip on either platform.
- The worker source's internal behavior, catalog, preprocessing and job
  routing. The source is being brought into the repository in W5-1 and remains
  unverified here until it lands.
- C# protocol-parity of the contract frames (only fixtures can prove it, in
  W5-1).
- Windows ARM64 and any non-x64 Windows target: out of scope and unmeasured.

## 9. Non-goals

No code, tests, catalog entries, schema keys, C ABI exports, model downloads,
runtime package, MSI payload, GPU claim, release or tag is added by this
record. The ONNX Runtime dependency is approved for W5-1, not added here. No
capability is declared supported. No approved capability is removed; all
follow-on milestones are retained in [W5_ROADMAP.md](W5_ROADMAP.md) §4.
