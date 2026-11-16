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
| `provider.list` | `contractVersion`, `providers`: array of `{id, state, execution_providers}` |
| `ping` | `pong: true` |
| `shutdown` | `stopping: true` |

`helper_generation` and `launch_nonce` may be `null` when the worker is started
outside the host (developer shell), but the host never accepts that process.

`state` is `available` or `unavailable`. A provider may report `CPU` only when
the execution provider actually initialised, not because its library is
present. DirectML is optional on Windows and is never required for startup.

## Errors

Standard JSON-RPC codes: `-32700` parse, `-32600` invalid request
(including contract/version mismatch), `-32601` method not found, `-32602`
invalid params, `-32603` internal. Worker-specific codes keep their existing
meanings (`BUSY`, `PATH_DENIED`, `LICENSE_BLOCKED`, `BUDGET_EXCEEDED`, ...).

Errors never include absolute user paths or model weights. Logs stay on the
worker's inherited stderr; the host does not parse them for protocol state.

## Shutdown, cancellation, crashes

- `shutdown` stops accepting new jobs and exits; the host waits for the process
  and removes the socket. A second call while stopping is idempotent.
- `job.cancel` is acknowledged immediately and takes effect at the worker's
  next safe point. The response never claims instant cancellation.
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
4. `provider.list` reports `CPU` only after that provider initialised.
5. `shutdown` exits the process and leaves no live socket/pipe.
6. The shared fixture's required methods all answer.
