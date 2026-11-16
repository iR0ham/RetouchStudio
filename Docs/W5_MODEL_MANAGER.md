# W5-2 — Cross-platform Model Manager

**Status:** implemented for W5-2 on both hosts (PR #68). It follows the frozen
decisions in [W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
§3.7–3.10 and does not change them.
**Date:** 2026-11-16.
**Platforms:** macOS Swift host + Python worker; Windows C# host + C# worker.

## 1. Owned artefacts

| Artefact | Location |
|---|---|
| Bundled catalog | `Resources/model-catalog.json` (copied into the macOS bundle and the Windows app folder) |
| Shared test catalog | `Tests/Fixtures/model-store/catalog-fixture.json` and `catalog-fixture-v2.json` |
| Store roots | macOS: `~/Library/Application Support/RetouchStudio/AI/models`; Windows: `%LOCALAPPDATA%\Retouch Studio\AI\models` |
| Worker access | The worker reads only the active version of each model. |

The catalog is data, not a remote feed. No build fetches it and no launch
refreshes it. A new catalog ships with the application build.

## 2. Catalog entry fields

Every entry carries `id`, `name`, `capabilities[]`, immutable `version`,
`format`, `files[]` (each with `path`, `sizeBytes`, `sha256`, `sourceUrl`),
`sizeBytes`, `sha256`, `sourceUrl`, `codeLicense`, `weightsLicense`,
`licenseEvidenceUrl`, `platforms[]`, `requiredProvider`,
`minimumContractVersion`, `preprocess {id, version}`, `deterministic`, `notes`
and, when it cannot be installed, `unverifiableReason`.

`sha256` is the **manifest digest**: SHA-256 over each file's
`path + "\n" + sizeBytes + "\n" + sha256 + "\n"`, sorted by path. It identifies
the exact file set the owner consents to; each file additionally carries its
own digest. The UI shows the digest prefix, source and licences in the consent
sheet; every per-file digest is checked after download.

Valid metadata requires all of: non-empty `files`, every file's `sizeBytes` and
`sha256`, and no `unverifiableReason`. An entry without them may be listed with
its reason but cannot be downloaded, installed, activated or described as
supported (DR-5). SAM 2.1 tiny is listed that way today: the repository has no
recorded size or SHA-256 for its checkpoint, and the SAM runtime package is not
installed in the bundled worker.

Source rules: HTTPS only; the file URL must use the same host and scheme as the
entry's recorded source; no credentials, fragments or non-default ports in
production. Redirects are not followed: an HTTP 3xx is a non-200 failure, so a
download cannot silently move to another host. Local HTTP is accepted only by
tests through an injected flag.
Only URLs already recorded from the official source may appear; none is
invented.

## 3. Store layout

```
models/<model-id>/<version>/          verified payload + manifest.json
models/<model-id>/active.json         atomic active-version pointer
models/.staging/<uuid>/               download in progress
models/.quarantine/<uuid>/            deletion in progress
models/.locks/<model-id>-<version>    OS lock file
```

`manifest.json` records the schema, model id, version, catalog version, the
catalog manifest digest and the exact file list. It is written inside staging
before the atomic rename.

`active.json` records the model id, version, catalog digest and activation
time. It is replaced by writing a sibling temporary file, flushing it and
renaming it over the old pointer. A missing or dangling pointer reads as
"no active version"; it is never repaired by downloading.

## 4. Install, update, rollback

Install validates the entry, rejects unverifiable metadata and unsafe URLs,
checks free disk space for the full payload plus a 32 MiB reserve, takes an
**exclusive** lease on `<id>-<version>`, downloads every file into staging,
checks exact size and SHA-256, writes the manifest, fsyncs and renames the
staging directory to `<version>`. Only then is `active.json` replaced
atomically. A failure or cancellation removes staging and leaves no active or
partial version.

Update is an install of a new immutable version followed by a pointer switch.
The old version directory is never overwritten and stays installed for
rollback. Rollback verifies the target version fully, then switches the
pointer; it never downloads. A running job that still uses the old version is
not disturbed: its files are not moved or rewritten.

## 5. Leases

The OS is the authority; an in-memory registry is not.

- macOS: `flock` on `.locks/<id>-<version>`; shared for readers (worker while a
  model is loaded, host during verify), exclusive for install, delete and
  activation. The kernel releases it when the process dies.
- Windows: a `FileStream` on the same lock path. Readers open with
  `FileShare.Read` (other readers allowed, delete denied); exclusive access
  uses `FileShare.None`. Delete/rename of the directory fails while a reader
  holds the handle, and the handle closes on process death.

Delete order: take exclusivity (refuse with `E_MODEL_LEASED` when any reader
exists), replace/remove the active pointer atomically, rename the version into
`.quarantine/<uuid>`, then delete it. A crash after the pointer removal leaves
a complete inactive version listed as removable. A crash after the rename
leaves quarantine for startup cleanup. Delete never touches a locked directory.

## 6. Startup cleanup

Cleanup runs at most once per launch, without network access. It removes
staging and quarantine directories older than **24 hours** only after taking
their exclusive lease; a live or stale lock that cannot be taken is skipped.
Active and installed versions, and any directory without a valid identity
record, are never removed. Decisions are logged with the directory name and
reason, never with file contents.

## 7. Errors

`E_MODEL_LEASED`, `E_MODEL_MISSING`, `E_MODEL_UNVERIFIED`, `E_LICENCE_REFUSED`,
`E_INVALID_INPUT`, `E_CANCELLED`, `E_INTERNAL` are the model-store subset of
the frozen codes. Insufficient disk space and unsafe sources are
`E_INVALID_INPUT` with a human-readable reason; a failed hash or size check is
`E_MODEL_UNVERIFIED`.

## 8. Tests

`Tests/Fixtures/model-store` is shared by both hosts. The fixture server serves
deterministic bytes; the tests substitute `{base}` with a local listener. Both
suites cover: consent refusal before bytes, SHA-256 mismatch, size mismatch,
missing metadata, HTTP/off-host/traversal rejection, cancelled download,
network interruption, insufficient space, corrupt manifest, missing/dangling
active pointer, two concurrent installs, atomic pointer replacement, retry
after failure, startup cleanup, and the OS lock races from decision-record
§3.9 (delete during a lease, delete during a download, two processes
installing, update/rollback with a live lease, stale/live locks). Locks and
crash recovery are exercised with real child processes, not mocks.

## 9. Honesty gates

- macOS evidence runs on this machine; Windows evidence is hosted-runner CI
  unless stated otherwise.
- No model weights are downloaded during development or CI; only fixture bytes.
- No remote catalog, telemetry, background refresh or automatic update exists.
- Windows Swin2SR and any unapproved ONNX artifact stay out of the catalog.

## 10. Implementation map (2026-11-16)

| Area | macOS | Windows |
|---|---|---|
| Catalog | `Sources/RetouchStudio/Models/ModelCatalog.swift` | `Windows/RetouchStudio.AI/Models/ModelCatalog.cs` |
| Store / leases / download | `Sources/RetouchStudio/Models/ModelStore.swift` | `Windows/RetouchStudio.AI/Models/ModelStore.cs` |
| App-facing manager | `Sources/RetouchStudio/Models/ModelManager.swift` | `Windows/RetouchStudio.App/ModelManagerWindow.xaml(.cs)` |
| UI | `Sources/RetouchStudio/Views/ModelManagerView.swift` | the same window |
| Startup cleanup | `AppDelegate.attach` (`App.swift`) | `App.OnStartup` |
| Worker | `worker/retouch_ai_worker/catalog.py` resolves `active.json` and holds a shared `flock` | worker model loading arrives with W5-3; the shared lease API is `ModelLease` |
| Tests | `Tests/ModelStoreTests.swift` | `Windows/RetouchStudio.AI.Tests/ModelStoreChecks.cs` |

Both stores implement the same order: validate → prepare layout → install gate
→ version lease → disk check → download to `.staging` → per-file size and hash
→ manifest → one directory move → one pointer move. `active.json` is written
by a same-directory rename (`rename(2)` on macOS, `File.Move(..., true)` on
NTFS). Leases are `flock` on macOS and share-mode handles on Windows; both are
released by the kernel when the holder dies.

Crash injection is compiled only into the macOS test binary
(`-D RETOUCH_TESTING`) and, on Windows, requires the test process's
`RETOUCH_MODEL_TESTING=1` plus a named `RETOUCH_MODEL_TEST_CRASH` value. The
production app never sets either variable. Children die with a real `_exit` /
`Environment.Exit(86)`; download kills use `SIGKILL` / `Process.Kill`.

Legacy adoption reads the pre-versioning flat layout only after hashing every
file against the catalog. Hashing is local; the files are moved, not copied,
and a mismatch moves nothing. The Python worker keeps reading the flat layout
until an `active.json` exists, so an already-installed model keeps working
while the manager offers adoption.

Windows specifics:

- The manager root is `%LOCALAPPDATA%\Retouch Studio\AI\models`; the catalog is
  copied next to the executable at build time.
- `ModelLease` opens the lock file with `FileShare.None` for install/delete and
  `FileShare.Read` for readers. A second shared reader is allowed; an
  exclusive holder blocks both.
- A junction or symlink at `.staging`/`.quarantine`/`.locks` is refused before
  any write.
- The Windows worker does not load model weights yet (W5-3 owns inference).
  The shared-lease API and the host-side race tests are in place; worker-side
  lease evidence on Windows is therefore **NOT VERIFIED** in W5-2.

## 11. Test map

The following required cases are exercised by both suites unless noted:

| Case | macOS section | Windows section |
|---|---|---|
| Consent refusal before bytes / no network at startup | 2, 3 | M2, M3 |
| SHA mismatch, size mismatch, missing metadata | 4 | M4 |
| Unofficial HTTP source, off-host file, traversal | 1 | M1 |
| Atomic install and pointer; idempotent retry | 3 | M3 |
| Cancelled download, network interruption, safe retry | 5, 6 | M5, M6 |
| Insufficient disk | 7 | M7 |
| Symlink/junction staging escape | 8 | M8 |
| Delete during a job; OS death releases the lease | 9 | M9 |
| Delete during a download; delete updates the pointer | 10 | M10 |
| Update beside a leased old version; rollback with a job | 11 | M11 |
| Two processes installing the same version | 12 | M12 |
| Crash after verify, after rename, after pointer removal, during download | 13 | M13 |
| Cleanup grace, live lock, stale lock, unidentifiable tree | 14 | M14 |
| Atomic pointer replacement; dangling pointer | 15 | M15 |
| Legacy flat adoption without network | 16 | M16 |
| Shared catalog / DR-5 / platform facts | 1 | M17 |
| Worker reads `active.json` and waits on the lease | 17 | W5-3 (not yet loading models) |

macOS local evidence: `RETOUCH_ARCH=arm64 ./Tests/run.sh` passes the model-store
suite (129 checks) and the existing engine/model/runtime-process suites on this
machine; the runtime-v2 suite needs `worker/.venv`, which CI creates. The
model-store suite was re-run standalone after the last store change and passed.
`RETOUCH_SKIP_WORKER=1 ./build.sh release` validates the bundle and its catalog
copy.

Cross-check evidence for the C# implementation was also run on this macOS
host with the .NET 10 SDK: `RetouchStudio.AI.Tests` (M1–M17) passed, and the WPF
host compiled with `-p:EnableWindowsTargeting=true`. That exercises Unix paths
and Unix file sharing, not Windows path syntax or Windows share modes; the
hosted `windows-2025` job is the authoritative Windows evidence. On that job
the model-store checks reported PASS before the unrelated UI smoke check caught
the top-bar layout regression, which was fixed by moving the manager entry to
the status bar.

Windows evidence is hosted-runner CI; it is not native-hardware evidence and is
labelled as such in the W5-2 report.

Hosted CI run 43932552840 on head `094e9df` was green for all jobs. The macOS
Integration job (133528747939) logged `MODEL STORE TESTS: PASS` and
`RUNTIME V2 TESTS: PASS`; the Windows App job (133528748314) logged
`MODEL STORE CHECKS: PASS`, `AI RUNTIME TESTS: PASS`, built the MSI and passed
the GUI smoke check. These are hosted macOS/Windows runners, not the owner's
hardware.


