# W5-2 — Cross-platform Model Manager

**Status:** implemented for W5-2 on both hosts (PR #68). It follows the frozen
decisions in [W5_IMPLEMENTATION_DECISION_RECORD.md](W5_IMPLEMENTATION_DECISION_RECORD.md)
§3.7–3.10 and does not change them.
**Date:** 2026-11-17 (W5-2 review remediation, including the final
concurrency and error-contract review).
**Platforms:** macOS Swift host + Python worker; Windows C# host + C# worker.

## 1. Owned artefacts

| Artefact | Location |
|---|---|
| Bundled catalog | `Resources/model-catalog.json` (copied into the macOS bundle and the Windows app folder) |
| Shared test catalog | `Tests/Fixtures/model-store/catalog-fixture.json` and `catalog-fixture-v2.json` |
| Store roots | macOS: `~/Library/Application Support/RetouchStudio/AI/models`; Windows: `%LOCALAPPDATA%\Retouch Studio\AI\models` |
| Worker access | The worker reads only the active version of each model; a legacy flat install is read under a shared lease on `.locks/<id>@legacy`. |

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
supported (DR-5).

As of 2026-11-18 every shipped entry satisfies the metadata half: SAM 2.1
tiny's checkpoint carries a measured size (156,008,466 bytes) and SHA-256, and
its manifest digest is the value the rule above derives from them — the same
rule that reproduces FLUX, Swin2SR and MI-GAN byte for byte, which
`Tests/ModelStoreTests.swift` now asserts for all four. SAM 2.1 tiny is still
listed with an `unverifiableReason`, and it is the only field this schema has
for refusing a download, so it now carries the reason that applies: the `sam2`
package is absent from `worker/requirements.lock` and from the `models` extra,
so a Mac that fetched those weights would have nothing able to load them. What
the recorded metadata does unlock is everything that is already on disk: `Verify`
compares the file, `require` checks its length before a submission loads it, and
a flat install can be adopted into a version.

Source rules: HTTPS only; the file URL must use the same scheme and host as
the entry's recorded source; no credentials or fragments; the default port
only in production. A test may opt into loopback HTTP, and that exception also
covers the ephemeral port of the local fixture server; a non-default port is
never accepted in production, even on loopback. W5-2 initially treated every
3xx as a non-200 failure. **R1 correction (2026-11-24):** automatic redirects
are disabled; the downloader handles 301, 302, 303, 307 and 308 itself, for at
most three hops. Each `Location` must resolve to an HTTPS destination whose
exact host and path prefix appear in the catalog's redirect allow-list; an
unlisted, unsafe, unreadable or over-budget redirect is refused before any
payload file is written. Local HTTP is accepted only by tests through an
injected flag. Only URLs already recorded from the official source may appear;
none is invented.

## 3. Store layout

```
models/<model-id>/<version>/          verified payload + manifest.json
models/<model-id>/active.json         atomic active-version pointer
models/.staging/<uuid>/               download in progress
models/.quarantine/<uuid>/            deletion in progress
models/.locks/<model-id>-<version>    OS lock file for a versioned model
models/.locks/<model-id>@legacy       OS lock file for a flat install
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
- Legacy flat installs have no version, so they use the distinct identity
  `.locks/<id>@legacy` on every host. `@` is not a legal character in a model
  id or version, so this cannot collide with a versioned lock. The Python
  worker takes it shared while reading a flat model and holds it for the
  process lifetime; otherwise it takes the versioned lock. Adoption takes the
  same file exclusive before hashing or moving anything, so it fails with
  `E_MODEL_LEASED` while a worker reads the flat install. Killing either
  process releases the lease.

A worker resolves the layout, takes the lease for that layout, and resolves
again under the lease. Adoption can finish while the worker waits on the flat
lease, so the lease then describes a flat directory that no longer exists; the
worker follows the new `active.json` to the versioned directory, takes that
version's lease and releases the flat one. It never keeps using a stale flat
path, and it never reports a missing model for one that adoption just
installed. If the lease still cannot be taken after 5 s of waiting, the worker
returns the JSON-RPC `BUSY` code (-32012) with
`{"model": <id>, "reason": "leased"}` — a retryable busy condition, not
`MODEL_MISSING`; the macOS host shows its "in use" sentence for it. The 5 s
wait is a bound on how long a job may block on a competing install or delete,
not a cancellation of the job.

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

The worker speaks JSON-RPC, not the store codes. Its wire mapping is: a lease
it cannot take within 5 s is `BUSY` (-32012) with data
`{"model", "reason": "leased"}` (plus `"version"` for a versioned lease); a
file that is absent or a pointer that resolves nowhere is `MODEL_MISSING`
(-32011); a licence refusal is `LICENSE_BLOCKED` (-32010). The host maps
-32012 to a "model in use, try again" sentence and -32011 to "not installed".
The string `E_MODEL_LEASED` is the store's code and is never sent over the
worker wire.

## 8. Tests

`Tests/Fixtures/model-store` is shared by both hosts. The fixture server serves
deterministic bytes; the tests substitute `{base}` with a local listener. Both
suites cover: consent refusal before bytes, SHA-256 mismatch, size mismatch,
missing metadata, HTTP/off-host/traversal rejection, non-default file port,
file scheme mismatch, file credentials, file fragments, production rejection
of loopback HTTP and test-mode acceptance of it, cancelled download, network
interruption, insufficient space, corrupt manifest, missing/dangling active
pointer, two concurrent installs, atomic pointer replacement, retry after
failure, startup cleanup, and the OS lock races from decision-record §3.9
(delete during a lease, delete during a download, two processes installing,
update/rollback with a live lease, stale/live locks). Every rejected URL case
is a shared fixture loaded by both suites. Locks and crash recovery are
exercised with real child processes, not mocks.

Legacy flat leases are tested with a real process on each host: a shared
holder blocks adoption with `E_MODEL_LEASED`; an exclusive adoption lease makes
the reader refuse; killing the holder releases the kernel lease and adoption
then succeeds; a refused adoption leaves the flat files untouched. On macOS
the shared holder is the actual Python worker; on Windows it is a child process
holding the same `ModelLease.AcquireLegacy` file, because the Windows worker
does not load weights yet (W5-3).

The complete path-resolution race is deterministic on macOS. The real
`migrateLegacy` is paused after hashing while it holds the exclusive flat
lease; a real Python worker is started, prints the flat path it resolved, and
blocks on the lease; adoption is then allowed to move the files and publish
the pointer. The worker must return the versioned directory, not the removed
flat one. The refusal path asserts the wire code: `BUSY` (-32012) with
`{"model", "reason": "leased"}`. The worker unit suite
(`worker/tests/test_catalog.py`) covers the same two transitions in-process
with a real `flock` holder, without spawning a process.

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
| Worker | `worker/retouch_ai_worker/catalog.py` resolves `active.json`, re-resolves under the lease, and holds a shared `flock` | worker model loading arrives with W5-3; the shared lease API is `ModelLease` |
| Tests | `Tests/ModelStoreTests.swift` | `Windows/RetouchStudio.AI.Tests/ModelStoreChecks.cs` |

Both stores implement the same order: validate → prepare layout → install gate
→ version lease → disk check → download to `.staging` → per-file size and hash
→ manifest → one directory move → one pointer move. Adoption inserts the
exclusive legacy lease between the install gate and the version lease, before
hashing. `active.json` is written by a same-directory rename (`rename(2)` on
macOS, `File.Move(..., true)` on NTFS). Leases are `flock` on macOS and
share-mode handles on Windows; both are released by the kernel when the holder
dies.

Crash injection is compiled only into the macOS test binary
(`-D RETOUCH_TESTING`) and, on Windows, requires the test process's
`RETOUCH_MODEL_TESTING=1` plus a named `RETOUCH_MODEL_TEST_CRASH` value. The
production app never sets either variable. Children die with a real `_exit` /
`Environment.Exit(86)`; download kills use `SIGKILL` / `Process.Kill`.

Legacy adoption reads the pre-versioning flat layout only after hashing every
file against the catalog, while holding the exclusive `.locks/<id>@legacy`
lease. Hashing is local; the files are moved, not copied, and a mismatch or a
lease conflict moves nothing. The Python worker keeps reading the flat layout
until an `active.json` exists, under the same shared lease, so an
already-installed model keeps working while the manager offers adoption.

Windows specifics:

- The manager root is `%LOCALAPPDATA%\Retouch Studio\AI\models`; the catalog is
  copied next to the executable at build time.
- `ModelLease` opens the lock file with `FileShare.None` for install/delete and
  `FileShare.Read` for readers. A second shared reader is allowed; an
  exclusive holder blocks both.
- A junction or symlink at `.staging`/`.quarantine`/`.locks` is refused before
  any write.
- The Windows worker does not load model weights yet (W5-3 owns inference).
  The shared-lease API (`ModelLease.Acquire`, `ModelLease.AcquireLegacy`) and
  the host-side race tests, including the legacy flat lease, are in place;
  worker-side inference lease evidence on Windows is therefore **NOT VERIFIED**
  in W5-2.

## 11. Test map

The following required cases are exercised by both suites unless noted:

| Case | macOS section | Windows section |
|---|---|---|
| Consent refusal before bytes / no network at startup | 2, 3 | M2, M3 |
| SHA mismatch, size mismatch, missing metadata | 4 | M4 |
| Unofficial HTTP source, off-host file, traversal | 1 | M1 |
| File non-default port, scheme mismatch, credentials, fragment; production HTTP vs test loopback | 1 | M1 |
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
| Legacy flat lease: worker/adoption conflict, death release, files intact | 18 | M18 |
| Adoption finishing during the worker's lease wait: re-resolve, no stale path | 18 | host-side lease only (worker loads no weights until W5-3) |
| Worker lease timeout is `BUSY` -32012 with typed data, not `MODEL_MISSING` | 18 | n/a (no Windows worker model loading yet) |
| Shared catalog / DR-5 / platform facts | 1 | M17 |
| Worker reads `active.json`, flat installs and waits on either lease | 17, 18 | W5-3 (not yet loading models) |
| Redirect hop follows the catalog host-and-path-class allow-list only | none — no macOS redirect regression check exists | **none on `main`** — `[M19]`, tracked on PR #139, **not merged** |
| Redirect `Location` is gated on the raw wire text, not a canonicalised copy | none — no macOS redirect regression check exists | **none on `main`** — `[M19b]`, tracked on PR #139, **not merged** |

**Redirect rows: tracked, not yet on `main` (2026-11-26).** The last two rows
must not be read as part of the M1–M18 set that the paragraphs below cite. They
are Windows-only checks that exist exclusively on the unmerged draft branch
`w5-r1-redirect-cancel` at head `3bb8e69606074cfe5086ce0cbdaa74ea44b059d7`
(PR #139, open and marked draft): `[M19]` is
`Windows/RetouchStudio.AI.Tests/ModelStoreChecks.cs:863`
(`"[M19] redirects follow the catalog's host-and-path-class allow-list only"`) and
`[M19b]` is the same file at `:1791`
(`"[M19b] the Location gate reads the wire text, not a canonicalised copy"`). At
`main` `5aac9c3a` the mechanism they test is absent: `ModelCatalog.cs` defines no
`RedirectAllowList` and no `ModelRedirectRule`, the Windows download's entire
redirect posture is `Windows/RetouchStudio.AI/Models/ModelStore.cs:276`
`AllowAutoRedirect = false`, and `grep -c M19` over main's copy of that test file
returns 0 (its highest labels are `[M18]` and `[M17]`). So no `[M19]`/`[M19b]`
verdict may be cited against `main`, and because those case names do not exist
there, no Windows CI run at `main` can even print such a line.
**NOT VERIFIED on `main`.**

**Security properties of that branch's redirect gate (2026-11-26, read from the
branch sources; NOT VERIFIED on `main`).** Two of them are worth stating now,
because they are the reason the relaxation is acceptable and both are code-visible
rather than asserted only by a test name:

- The raw `Location` text is validated **before** normalisation can erase
  anything. The hop loop reads the unparsed header copy first
  (`ModelStore.cs:719-729`, `response.Headers.NonValidated`), rejects anything
  unsafe with `ModelCatalogRules.IsSafeRawRedirectLocation(raw)` at `:694`, and
  only then builds the absolute `Uri` at `:706`. A second verbatim cross-check runs
  at `:703-704` against `ParsedLocationText`, which returns
  `response.Headers.Location?.OriginalString` (`:738-748`), and the helper's own
  contract is stated verbatim at `:683-685`: "The raw path is checked before Uri
  can erase literal dot segments; absent, repeated, unreadable or unsafe values all
  fail closed". Absent, repeated or unreadable values yield `null`, which
  `RefuseRedirect` turns into a refusal (`:765-767`), never into permission.
- A signed query never reaches a refusal or audit path. Hugging Face's XET
  `Location` carries a signed query string, so the only type that leaves the
  redirect logic — `ModelRedirectHop` (`:83-97`) — stores `StatusCode`, `Host` and
  `Path`, where `Path` is filled from `uri.AbsolutePath` (`:95`) and no field
  carries `Query` or `OriginalString`; its `Display` is `Host + Path` (`:89`).
  Every refusal message interpolates `HopDisplay(target)` (`:770`, `:774`) and the
  audit line does the same (`:782-786`), so no query component is printable from
  the redirect code. The recorded over-budget behaviour is also deliberate: once
  the 3-hop budget is exhausted the code stops resolving a new `Location` rather
  than resolve it just to refuse it (`:614-618`, `MaxRedirectHops = 3` at `:572`).

macOS local evidence: `RETOUCH_ARCH=arm64 ./Tests/run.sh` passes the model-store
suite (157 checks, 18 sections) and the existing engine/model/runtime-process
suites on this machine; the runtime-v2 suite needs `worker/.venv`, which CI
creates. The model-store suite includes the real-Python worker legacy lease
races and the deterministic adoption-during-wait re-resolution. The worker's
own suite (`python -m unittest discover -s tests`, 69 tests) passes with the
new lease-code and re-resolution tests. `RETOUCH_SKIP_WORKER=1 ./build.sh
release` validates the bundle and its catalog copy.

Cross-check evidence for the C# implementation was also run on this macOS
host with .NET SDK 10.0.404: `RetouchStudio.AI.Tests` reported
`MODEL STORE CHECKS: PASS` for M1–M18 (the [C] worker-handshake check needs the
Windows worker executable, which only the Windows job builds). The WPF host
compiled with `-p:EnableWindowsTargeting=true`. That exercises Unix paths and
Unix file sharing, not Windows path syntax or Windows share modes; the hosted
`windows-2025` job is the authoritative Windows evidence.

Windows evidence is hosted-runner CI; it is not native-hardware evidence and is
labelled as such in the W5-2 report.

Hosted CI run 43989762475 on head `2c19fff` was green for all five jobs. The
macOS Integration job (133727043623) logged `Ran 69 tests` for the worker,
`ABI TESTS: PASS (104 checks)`, `ENGINE TESTS: PASS`, `MODEL TESTS: PASS`,
`MODEL STORE TESTS: PASS` (the 157-check suite, including `[18]` with
`the worker used the active version, not its stale flat path` and
`the worker reports retryable busy, not a missing model — {"code": -32012,
"data": {"model": "migan", "reason": "leased"}}`) and
`RUNTIME V2 TESTS: PASS`. The Windows App job (133727043560) logged `[M18]`
with its legacy-lease checks, `MODEL STORE CHECKS: PASS`,
`AI RUNTIME TESTS: PASS`, and `WINDOWS APP BUILD: PASS` after building,
upgrading and smoke-loading the MSI. These are hosted macOS/Windows runners,
not the owner's hardware.

An earlier run on code head `0e718dc` (43986718664) passed every suite but
failed the macOS verdict gate because the workflow still expected
`Ran 67 tests`; commit `2c19fff` updates that count to 69.


