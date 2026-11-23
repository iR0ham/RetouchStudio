# AI runtime protocol 2

This is the cross-platform contract between the macOS/WPF host and an AI worker.
`Tests/Contract/protocol2.json` is the shared machine-readable fixture; both the
Swift and C# suites read it. A worker that merely opens a socket or pipe is not
supported: the host accepts it only after the versioned handshake and identity
checks below.

## Transport and framing

- JSON-RPC 2.0, UTF-8, exactly one JSON object per line (`\n`).
- Maximum frame: 1 MiB (1,048,576 bytes) before parsing.
- `contractVersion` is the string `"1"` on every request and response. A
  mismatch is refused with `-32600` and no state change.
- `protocolVersion` is the integer `2`.

macOS uses a Unix domain socket under the support directory. Windows uses a
named pipe for the same frames. The pipe name is not part of this contract.

## Launch handshake

The host starts the worker with:

```
--protocol-version 2
--helper-generation <uuid>
--launch-nonce <uuid>
--registry <absolute path to the host registry file>
--usage-fd <inherited descriptor>     # macOS only; optional
--socket <path> --jobs <dir> --models <dir> --allow-root <dir>
```

The worker must:

1. Refuse an unsupported `--protocol-version`.
2. Require both a generation and a nonce, each a UUID, or neither.
3. Take the registry's `flock` before writing, never replace or follow a
   symlinked/foreign-owned record, and write only the exact schema-2 keys.
4. Publish `state: "starting"` before listening and `state: "ready"` after the
   socket/pipe is accepting, with its own pid and start identity.
5. Publish `state: "failed"` with `last_error` if startup fails.

The host waits for a ready record with the generation, nonce and pid it
launched, then verifies the peer pid, start time and executable against the
recorded helper before accepting `health`. A stale record is not readiness.

Registry record (exact keys, schema 2):

```json
{
  "schema": 2,
  "protocol_version": 2,
  "generation": "uuid",
  "launch_nonce": "uuid",
  "revision": 2,
  "state": "starting|ready|failed",
  "parent": {"pid": 1, "start_seconds": 0, "start_microseconds": 0, "executable": "/path"},
  "helper": {"pid": 1, "start_seconds": 0, "start_microseconds": 0, "executable": "/path"},
  "socket": "/path",
  "created_at": 0,
  "updated_at": 0,
  "shutdown": null,
  "clients": [],
  "last_error": null
}
```

## Methods

Every response echoes `contractVersion: "1"`.

| Method | Required result fields |
|---|---|
| `hello` | `contractVersion`, `protocol` (`"2"`), `protocol_version` (2), `worker`, `pid`, `helper_generation`, `launch_nonce`, `providers` |
| `health` | `contractVersion`, `protocol`, `protocol_version`, `pid`, `helper_generation`, `launch_nonce`, `providers` |
| `provider.list` | `contractVersion`, `providers`: array of `{id, state, execution_providers}`, plus `reason` when nothing initialised |
| `capability.list` | `contractVersion`, `vocabulary` (`"capabilities/1"`), `platform`, `provider`, `capabilities` |
| `ping` | `pong: true` |
| `shutdown` | `stopping: true` |

`helper_generation` and `launch_nonce` may be `null` when the worker is started
outside the host (developer shell), but the host never accepts that process.

`state` is `available` or `unavailable`. `execution_providers` names only a
provider that actually initialised in this process — `CPU` on Windows once the
ONNX Runtime execution provider is up, `mps` or `cpu` on macOS once a loader has
used one — not a library that is merely present or importable. Before any model
has loaded, the record is still returned with `state: "unavailable"`, an empty
`execution_providers` and a `reason` saying so. DirectML is optional on Windows
and is never required for startup.

## Capability reporting

`capability.list` answers with the frozen W5-0 vocabulary `capabilities/1`: one
record per id, each carrying `capabilityId`, `state`
(`supported` | `requires_model` | `blocked` | `unsupported`), `provider`, and
either `evidence` (required for `supported`) or `reason` (required for every
other state). `modelId` and `modelVersion` accompany model-backed records.

The answer is built from what the adapter can actually run — installed and
verified models, an initialised provider, and recorded run evidence — never
from an interface or a catalog entry existing. `supported` is bounded by a
recorded run (decision record DR-4); an entry whose size or checksum cannot be
verified is not installable or supportable (DR-5). See
`Docs/W5_ADAPTERS.md` for the per-platform answer and its evidence.

`job.submit` accepts an optional `capabilityId`. When a caller names one, a job
for a capability that the adapter cannot run is refused before any work starts:
`-32020` with a queue verdict, or `-32011` with the missing model when the
capability is only `requires_model`. It is never accepted and silently dropped.
The `-32020` error data has three shapes, each emitted by a different check:
the queue verdict carries `{capabilityId, state}` and states the reason in the
error `message`; a `capabilityId` that is not a capability of that job kind
carries `{capabilityId, kind}` and no `state`; and the engine's refusal of a
mask job whose runtime package cannot be imported carries
`{capabilityId, state: "blocked", package, reason}`. A host must not assume a
`reason` member is always present. The macOS host names the capability for `upscale` (W5-4) and
still submits the older job types by kind alone, so those take the unchanged
path; the refusal is the contract for hosts that name capabilities (the Windows
adapter requires the id).

`job.submit` also accepts an optional `requestedCapability`, which is a record
name and not a gate. The helper writes it into the §3.6 provenance of the
artifacts it hands back, and it never refuses a job because of it: four
`patch_edit` capabilities share one job kind, so only the host knows which tool
the user pressed, and the models behind two of them carry no recorded run (DR-4)
while shipping anyway. Turning that label into a verdict is a separate product
decision, not this field. A name the job kind cannot carry is `-32602` with
`{capabilityId, kind}`, so a typo is a refused submission rather than a record
that would misdescribe an edit. When both fields are present the gated answer
wins the record and no origin label is written; a record that names a host
assertion the worker did not adjudicate carries `"capabilitySource":
"host-asserted"`, and one the worker chose from the job kind itself carries
`"worker-derived"`. A record the worker's own verdict approved carries no
`capabilitySource` at all.

A submission that names only `kind` is still checked by the worker's own catalog
before any weights load: a missing model is `-32011`, an uncleared licence is
`-32010`, and a file whose size differs from the catalog record is `-32019`
(`E_MODEL_UNVERIFIED`), the same condition `capability.list` reports as
`blocked`. The kind path deliberately does not refuse the `blocked` states that
describe a *claim* (no recorded run, legacy flat layout); those keep
already-installed models usable, and running them is how the evidence for a
support claim gets recorded.

> **Addendum, 2026-11-23 (mandate §4, PR #115).** A catalog entry without a size
> or SHA-256 **no longer belongs to that list**, and `-32019` now covers two more
> install shapes. Both were measured fail-opens: the sentence above is what the
> code did, not what it does.
>
> * An entry whose pin set is absent, incomplete, malformed or whose file list is
>   empty is refused by **every** path — load, `health`, `models verify`,
>   `capability.list` and `models.plan` — with `-32021 CATALOG_INVALID` and a
>   `reason` from the same taxonomy (`missing-size`, `missing-digest`,
>   `invalid-digest`, `incomplete-entry`, `unsafe-path`). A bad pin is a defect in
>   this build, not a property of the user's download, so no download can repair
>   it and no layer may call such an install healthy.
> * `-32019 CHECKSUM_MISMATCH` is now also emitted for `reason: "unsafe-path"` (a
>   listed weight that is a symlink) and `reason: "unlisted-file"` (a payload file
>   the catalog does not name, reported by relative path in `data["files"]`). The
>   second closes the substitution a per-file digest pass cannot see: a
>   convention-following loader prefers an unpinned `model.safetensors` to the
>   pinned `pytorch_model.bin` sitting beside it, so every pin reads correct while
>   different bytes reach the runtime.
> * The three reporting surfaces refuse exactly what the load path refuses. That
>   agreement, not the individual check, is the contract: a model manager that
>   says "verified" over an install the worker will not load is a false promise to
>   the user. Pinned by `test_the_report_paths_refuse_what_the_loader_refuses` and
>   `test_the_report_refuses_the_shapes_the_loader_refuses`.

## Errors

Standard JSON-RPC codes: `-32700` parse, `-32600` invalid request
(including contract/version mismatch), `-32601` method not found, `-32602`
invalid params, `-32603` internal. Worker-specific codes keep their existing
meanings (`BUSY`, `PATH_DENIED`, `LICENSE_BLOCKED`, `BUDGET_EXCEEDED`, ...).
`-32020` `UNSUPPORTED` is additive in contract 1: the frozen vocabulary has no
numeric code for "this adapter or platform does not provide it", and both hosts
map `-32020` to `E_UNSUPPORTED`. A host that only knows the older codes sees a
worker-range error and treats the job as failed, which is safe.

`-32021 CATALOG_INVALID` is the integrity-family code added with the fail-closed
gate above: the *record* is unusable, so the answer is a build fix, never a
re-download. Both hosts map it to `E_MODEL_UNVERIFIED` — deliberately the same
label as `-32019`, because the user-visible action ("this model cannot be
trusted; it is not your fault and re-fetching will not help") is identical, while
`data["reason"]` keeps the two classes separable for logs and tests. A host that
has seen the code MUST NOT offer a download button for it.

Errors never include absolute user paths or model weights. Logs stay on the
worker's inherited stderr; the host does not parse them for protocol state.

## Shutdown, cancellation, crashes

- `shutdown` stops accepting new jobs and exits; the host waits for the process
  and removes the socket. A second call while stopping is idempotent.
- `job.cancel` is acknowledged immediately and takes effect at the worker's
  next safe point. The response never claims instant cancellation. Safe points
  are not only the gaps between inference tiles: the macOS upscale job also
  checks before it loads the model and again after it has encoded the staged
  output but before publication, so a cancel at the write leaves neither an
  artifact, nor a staging file, nor a provenance sidecar. Publication itself is
  deliberately uninterrupted: the sidecar lands first and the artifact rename
  is the commit point, so a request that arrives there finishes a complete,
  self-consistent pair rather than tearing an artifact away from its
  provenance. Two renames are not one atomic act — see
  [W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
  §3.6 for what a host must therefore refuse.
- On Windows the worker is in a Job Object with kill-on-close. On macOS the
  host tracks process identity, not just pid. A worker crash is a failed
  runtime, never a silent fallback to another protocol.
- A worker that dies after `ready` leaves its record; the host rechecks
  liveness and start identity before reusing or cleaning it.

## Conformance

Both platforms must prove, from a fresh checkout:

1. A real worker process starts from the repository sources.
2. It publishes a ready record with matching generation/nonce/pid.
3. `health` and `hello` answer every required field with the same identity.
4. `provider.list` reports an execution provider only after that provider
   initialised, and says why when none has.
5. `shutdown` exits the process and leaves no live socket/pipe.
6. The shared fixture's required methods all answer.
7. `capability.list` answers every frozen id with a state and an
   evidence/reason; no `supported` record lacks a recorded run.
