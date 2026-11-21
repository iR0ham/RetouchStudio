# Updater transaction design (design-only; the updater is DISABLED in 2.0.0)

> **Provenance and status of this file (added 2026-11-22 by the release PM).**
> Everything below this banner is the design-only record produced before the
> 2.0.0 mandate. It existed **only** in an ephemeral temp directory on
> 2026-11-22 and on no branch, so it was one `rm -rf /tmp` away from permanent
> loss; importing it here is the mandate's §6 instruction to "preserve the
> existing design-only work". It is a **proposal, not shipped behaviour**: no
> part of it is implemented, and `.github/workflows/release.yml` plus
> `Resources/Info.plist` configure no update feed, so nothing in the shipping
> path reads a journal or swaps a bundle.
>
> Two claims made about this design during an independent review were later
> **refuted against the code at `c3bdced`** and must not be repeated: there is no
> `UserDefaults` / `RSUpdateFeedOverride` read anywhere in the repository
> (`UpdateController.feedURLs` reads only `Bundle.main.infoDictionary`, :160-166), and there is no `--recover-verification` command-line entry point and
> no `Sources/RetouchStudio/main.swift` (recovery is reached from `App.swift:38-41`
> on a plain launch). The review's other findings are recorded as open questions
> in `Docs/RELEASE_2.0.0_READINESS.md` Addendum F, not as facts.

---

# Updater transaction safety — complete design

**Status:** design only. Nothing here is implemented. No branch, commit, push or PR exists.
**Date:** 2026-11-21. **Base:** `origin/main` = `cd5741b76`.
**Accepted inputs (append-only, not modified):** `/private/tmp/rs-int-1795217340/Docs/UPDATER_TRANSACTION_SAFETY.md`, `/private/tmp/rs-upd-feasibility/FEASIBILITY.md`.

**Grade tags used throughout:** **MEASURED** = read at the cited file:line, or produced by a headless probe/command I ran; **INFERRED** = follows from code structure or documented platform behaviour but was not observed here; **NOT VERIFIED** = needs a running app, a disposable machine or a CI run.

**Design decisions at a glance**

| Decision | Value |
|---|---|
| Probe flag | `--update-self-check <token>` (space-separated value, new dedicated branch in `SelfCheck.runIfRequested`) |
| Probe success line | `UPDATE-SELF-CHECK OK <token> <bundleIdentifier> <CFBundleShortVersionString> <CFBundleVersion>` |
| Probe exit codes | `0` success; `64` usage; `69` unavailable (bundle info unreadable/empty id); `70` unexpected error; signals mean crash |
| Probe timeout | `UpdateSelfCheck.timeout` = **NOT YET SELECTED** (see §4.3.6 / §7 U1) |
| v2 journal | `~/Library/Application Support/RetouchStudio/update-journal.v2.json` |
| Legacy journal | `update-journal.json` (unchanged) |
| Phases | `prepared` → `swapped` → `validated` → `launched` → `committed`; terminal `rolledBack` |
| Swap primitive | `renamex_np(..., RENAME_SWAP)`; two-rename fallback recorded in the journal |
| Incoming bundle | `/Applications/.Retouch Studio.incoming-<txid>` (dot-prefixed sibling, outside the workspace) |
| Backup | the same path after the exchange; deleted only after the scene marker |
| Recovery triggers | App-init recovery in every v2 build + manual execution of the known-good bundle at the incoming path; no helper, no login item |

---

## 1. Failure-state matrix

### 1.1 Today's code path (MEASURED)

`UpdateController.performInstall` (`UpdateController.swift:114-143`): parent = `Bundle.main.bundleURL.deletingLastPathComponent()` (`:117`); workspace `.retouch-update-<uuid>` (`:118`) removed by `defer` (`:120`); download (`:131`); `UpdateInstaller.unpack` (`:132-135`); journal directory (`:136-137`); `UpdateInstaller.swap` (`:138-139`); `phase = .readyToRelaunch` (`:140`).

`UpdateInstaller.swap` (`UpdateVerification.swift:155-190`): journal written with `Data.write(.atomic)` (`:172-174`); `moveItem(current → backup)` (`:177`); on failure journal removed (`:179`); `moveItem(staged → current)` (`:183`); on failure backup restored and journal removed (`:184-187`); then `try? removeItem(backup)` (`:189`) and `try? removeItem(journal)` (`:190`).

`UpdateInstaller.recover` (`:196-232`): missing journal → `.none` (`:197`); undecodable → `.unreadableJournal` (`:198-200`); current+backup → delete backup, `.completed` (`:210-215`); no current+backup → staged→current else backup→current (`:216-225`); current only → `.cleared` (`:226-230`); neither → `.unrecoverableJournal` (`:232`).

Reachability: `recover` is called only from `UpdateController.init()` (`UpdateController.swift:38`), and `UpdateController()` exists only as the `@StateObject` in `AboutView` (`InfoViews.swift:95`), reachable from the About menu item (`App.swift:210`). `relaunch()` is `NSWorkspace.shared.open(Bundle.main.bundleURL)` then `NSApp.terminate(nil)` (`UpdateController.swift:60-63`), return value discarded.

### 1.2 Interruption matrix, today vs designed

| # | Interruption point | Today: disk state | Today: reachable recovery? | Today's coding of the outcome | Design: disk state | Design: who repairs | Design: guaranteed outcome |
|---|---|---|---|---|---|---|---|
| 1 | Before download | current; no journal | n/a | `:114-120`, workspace removed by `defer` | unchanged; no journal | — | current untouched |
| 2 | During download / hash check | current; workspace with partial zip | n/a | `BoundedDownload` cancels past signed size (`UpdateVerification.swift:314-320`); `defer` (`UpdateController.swift:120`) | unchanged; no journal | — | current untouched; workspace swept |
| 3 | After verify, during `ditto` unpack | current; workspace | n/a | `unpack` (`:115-150`) | unchanged; no journal | — | current untouched |
| 4 | Unpacked, before journal | current; workspace + new app | n/a | `:132-137` | unchanged; no journal; incoming not yet created | — | current untouched |
| 5 | Journal prepared, before incoming placed | current; journal | only from About | `:172-174` | current; v2 journal `prepared` | App-init recovery (§4.5) | journal cleared; current untouched |
| 6 | Incoming placed, before probe | n/a today (no probe) | — | — | current; journal `prepared`; incoming sibling | App-init recovery or next install | incoming deleted, journal cleared; current untouched |
| 7 | Probe returns non-zero / times out / crashes | n/a | — | — | design cancels before any rename | installer in-process | incoming deleted, journal cleared, error surfaced; current untouched |
| 8 | Probe passed, before exchange | n/a | — | — | current; journal `prepared` (probe result recorded); incoming | App-init recovery | incoming deleted, journal cleared; current untouched |
| 9 | Between the two renames (legacy fallback only) | **no current**; backup+staged+journal | **no** — no bundle to launch | `:177` then `:183`; defect A | journal `prepared` with `exchange.primitive = two_rename_fallback` (or `swapped` if the first rename completed); both paths recorded | App-init recovery if current exists; otherwise the known-good bundle at the incoming path or the documented manual `mv` (§4.5 T2) | old bundle restored |
| 10 | Immediately after exchange | n/a today | — | — | `appPath` new, incoming = old, journal `swapped` | App-init recovery (new app reached App.init) | identity check; commit path or rollback |
| 11 | Post-exchange, identity mismatch | n/a | — | — | journal `swapped` | App-init recovery | exchange back, new deleted, `.rolledBack` |
| 12 | Identity OK, before scene marker | n/a | — | — | journal `validated` | App-init recovery (no marker yet) | journal retained; **backup retained** |
| 13 | Scene appears, marker write interrupted | n/a | — | — | journal `validated`; marker write atomic (temp+rename) | App-init recovery | backup retained until a durable marker exists |
| 14 | Marker present, before commit | n/a | — | — | journal `launched` | App-init recovery | transition to `committed`, delete backup, remove journal |
| 15 | During backup deletion | current(new)+partial backup+journal | from About only | `:189`, `:212` | journal `launched` (or `committed` if that write landed first); partial backup | App-init recovery | delete again (idempotent), remove journal |
| 16 | After backup deleted, before journal removal | current+journal | from About only | `:189-190` | journal `committed`; no backup | App-init recovery | validate identity, remove journal |
| 17 | Journal removal interrupted | current+journal | from About only | `:190` | journal `committed`; no backup | App-init recovery | same as 16 |
| 18 | New build cannot launch at all (defect B) | backup deleted, journal deleted, no previous version | **no process exists** | `:189-190`; no launch validation anywhere | pre-exchange probe makes this class non-installable; if it happens after exchange (post-probe corruption) the old bundle is still at the incoming path | manual: execute the known-good bundle at the incoming path (§4.5 T2) or documented `mv` | old bundle restored without reinstalling |

### 1.3 Next-process-start matrix (the recovery half)

| On-disk state at any app start | Today | Design |
|---|---|---|
| No journal files | `UpdateController.init` → `.none` (`:197`) — only when About opens | App-init hook: nothing to do; zero writes |
| Legacy journal only | `.none` for a 1.0.0 build (no reader); `.completed`/`.rolledBack`/`.cleared`/throw for an unreleased v1-reader build (`:210-232`) | §3.3 table: adopt, identity-gate, never delete the last known-good |
| v2 journal only | invisible to a 1.0.0 build; undecodable+swallowed for an unreleased v1-reader build (`UpdateController.swift:38`) | §3.2/§4.6 recovery per phase |
| Both files | n/a | §3.4 rules: consistent pair, contradictory pair, staleness |
| Corrupt/truncated v2 | invisible/undecodable | §3.5: quarantine, zero deletions |

**Design invariant (the sentence the implementation must preserve):** *no code path deletes the **last known-good** bundle unless (a) the journal is decodable, (b) the path equals the journal's own recorded `backupPath`/`incomingPath` under the app's parent, and (c) the installed bundle's identity matches `expected` **and** the durable scene marker exists. Deleting the **new** bundle is permitted only in an explicit cancel (before the exchange) or rollback (the exchange was reversed) state.*

---

## 2. Journal v2 schema

### 2.1 Files and location

| File | Purpose | Written by |
|---|---|---|
| `~/Library/Application Support/RetouchStudio/update-journal.v2.json` | v2 transaction record | v2 builds only |
| `~/Library/Application Support/RetouchStudio/update-journal.json` | legacy v1 record; never written by v2 | unreleased v1-reader builds only; read by v2 |
| `update-journal.v2.rejected-<uuid>` | quarantined v2 record | recovery, on any undecodable/contradictory state |
| `update-journal.rejected-<uuid>` | quarantined legacy record | recovery |

Directory creation already exists (`UpdateController.swift:136-137`). The v2 file lives beside the legacy one so a single directory fsync covers both names.

### 2.2 Fields

| Field | Type | Presence | Meaning |
|---|---|---|---|
| `schema` | `Int` | always | `2`. Readers must refuse anything else (quarantine). |
| `transactionID` | `String` (UUID string) | always | Identity of this transaction; the scene marker must match it. |
| `generation` | `Int` (ms since epoch at write) | always | Advisory ordering only. Never authorises deletion. |
| `phase` | `String` enum | always | `prepared`, `swapped`, `validated`, `launched`, `committed`, `rolledBack` — meanings in §2.3. |
| `createdAt` | `String` (ISO-8601 UTC) | always | When the transaction began. |
| `writerPID` | `Int32` | always | Diagnostic only (which process last wrote). |
| `appPath` | `String` | always | Absolute path of the installed bundle (`/Applications/Retouch Studio.app`). |
| `incomingPath` | `String` | always | Absolute path of the incoming sibling; after the exchange it holds the **old** bundle. |
| `backupPath` | `String` | always | Equal to `incomingPath` in the exchange design; recorded separately so a fallback path can name a different location. |
| `expected.bundleIdentifier` | `String` | always | From the signed manifest/plan and the unpacked Info.plist (`UpdateVerification.swift:142-145`). |
| `expected.shortVersion` | `String` | always | `CFBundleShortVersionString` (`:146-148`). |
| `expected.build` | `String` | always | `CFBundleVersion` of the incoming bundle. |
| `expected.executableSHA256` | `String` (lowercase hex) | always | SHA-256 of `Contents/MacOS/RetouchStudio`, computed with the existing `AIRuntime.sha256`. |
| `probe.token` | `String` | after a probe attempt | The token passed to `--update-self-check`. |
| `probe.exitCode` | `Int` | after a probe attempt | `0` on success; the deliberate code otherwise. |
| `probe.finishedAt` | `String` (ISO-8601) | after a probe attempt | When the probe process was reaped. |
| `exchange.primitive` | `String` | after the swap | `renamex_swap` or `two_rename_fallback`. |
| `launch.attempts` | `Int` | from `swapped` onward | Incremented durably at App init when the running bundle is `appPath`. Used for the unmarked-launch policy (§4.6). |
| `launch.markerAt` | `String?` | after the scene marker | Presence is the VC3 proof; absent means "not yet shown a window". |
| `host.volumeIdentifier` | `String?` | best effort | `.volumeIdentifierKey` of `appPath`; matches the existing `sameVolume` check (`:235-241`). |

**Forbidden keys:** the strings `"current"`, `"staged"` and `"backup"` must not appear as **object keys at any nesting level** (see §3.1). The only nested objects are `expected`, `probe`, `exchange`, `launch` and `host`, whose keys are `bundleIdentifier`, `token`, `primitive`, `attempts`, `volumeIdentifier`, etc. — none of which is a v1 key name. A unit test must serialise the encoder output and assert those three strings never occur as a JSON key at any depth.

### 2.3 Phase meanings (exhaustive)

| Phase | Entered when | What is true on disk | Allowed transitions |
|---|---|---|---|
| `prepared` | Immediately before the incoming bundle is created; journal durable first | `appPath` untouched; `incomingPath` may or may not exist | → `swapped` (after probe + exchange); → terminal (probe failed or cancel: delete incoming, remove journal) |
| `swapped` | Immediately after a successful exchange | `appPath` = new bundle; `incomingPath`/`backupPath` = old bundle | → `validated` (identity match); → `rolledBack` (identity mismatch) |
| `validated` | `appPath` identity equals `expected` | Same as `swapped`; identity proven in place | → `launched` (scene marker written by the running app); → `rolledBack` (unmarked-launch policy); → `committed` only via `launched` |
| `launched` | The installed app wrote `launch.markerAt` from `EditorView.onAppear` | Editor scene was created at least once | → `committed` (delete backup, then remove journal) |
| `committed` | After backup deletion is authorised and attempted | Backup gone (or being deleted); journal is the only remnant | → terminal: remove journal |
| `rolledBack` | The exchange was reversed | `appPath` = old bundle; `incomingPath` = new bundle | → terminal: delete new bundle, remove journal |

`prepared` is a single state whether or not the incoming copy exists yet; the reader decides from the file system (existence of `incomingPath`), not from a second phase. This avoids the v1 mistake of trusting a phase over disk state (`UpdateVerification.swift:193-194` documents the intent).

### 2.4 Encoding

- One JSON object, UTF-8, no trailing whitespace requirements, keys sorted for deterministic bytes (`JSONEncoder.outputFormatting = [.sortedKeys]`).
- Decoding is strict for required fields and tolerant of **additional** keys (forward compatibility): a newer writer adding a field must not break an older v2 reader.
- Any decode error (missing field, wrong type, truncated, unknown `schema`) → **quarantine, zero writes to bundles** (§3.5).

### 2.5 Durable write protocol (replaces `Data.write(.atomic)` at `UpdateVerification.swift:174`)

1. `open(temp, O_WRONLY|O_CREAT|O_EXCL, 0600)` where `temp = update-journal.v2.json.tmp-<uuid>` in the same directory.
2. `write` the whole payload; loop on partial writes; on any error, unlink temp and abort.
3. `fcntl(fd, F_FULLFSYNC)`; then `close`.
4. `rename(temp, update-journal.v2.json)`.
5. `open` the containing directory `O_RDONLY` and `fsync` it (this is what makes the rename itself survive power loss).
6. Read back and decode once; if the read-back fails, treat the transaction as not started and abort.

Ordering rule: the journal naming a destructive step's source and destination is made durable **before** the step; the phase is advanced **after** the step. Recovery never trusts the phase over disk state.

### 2.6 The workspace `defer` trap (must be designed around)

`UpdateController.performInstall` installs a `defer { try? removeItem(workspace) }` (`UpdateController.swift:120`) that runs when `performInstall` returns. With the exchange primitive, the **old** bundle ends up at the incoming path. If the incoming path were inside the workspace (e.g. the current unpack location, `:132-133`), the `defer` would delete the last known-good bundle on every successful update. Therefore the incoming path is a sibling of the app bundle, outside the workspace (§4.4), and the workspace only ever holds the archive and the unpacked copy before it is renamed out.

---

## 3. Compatibility matrix

### 3.1 Why v1 inertness is a hard safety boundary (evidence)

- MEASURED: the shipped `v1.0.0` tag (`d4e7d58`, 2026-11-09) contains no updater: `git ls-tree v1.0.0 Sources/RetouchStudio/Core/` has no `Update*` file and `git grep UpdateJournal v1.0.0 -- Sources` is empty. `UpdateVerification.swift` entered at `13eefcb` (2026-11-13). **So the v1 reader in this matrix is an unreleased-branch reader (any build between `13eefcb` and the v2 change), not a shipped-build hazard.**
- MEASURED: that unreleased reader hard-codes `update-journal.json` (`UpdateController.swift:25-33`) and decodes `{current, staged, backup}` (`UpdateVerification.swift:60-64`).
- MEASURED by a headless replica (compiled in `/private/tmp/rs-upd-feasibility`): a JSON object without those three keys throws `DecodingError.keyNotFound(current)`; truncated JSON throws `dataCorrupted`; both become the same `try?` nil and the same `unreadableJournal` throw (`:198-200`).
- MEASURED: the only call site discards the error (`try?` at `UpdateController.swift:38`), and all disk mutation in `recover` begins after the decode (`:202` onward). Therefore a v1 reader facing an undecodable journal performs **zero writes** — it neither deletes nor moves anything.
- CONCLUSION: v2 must not contain the v1 key names. "Compatibility" here means **inertness, not decodability**: a decodable v2 journal would activate the v1 rules at `:212` (delete backup when current+backup) and `:229` (remove journal when current-only), which are exactly the rules that destroy the last known-good (defect B) and the transaction record.

### 3.2 Reader × file matrix

| Reader | Files on disk | Decode result | Actions | Effect on the last known-good |
|---|---|---|---|---|
| 1.0.0 shipped build | any | no updater code at all | none | untouched (it has no update feature) |
| Unreleased v1 reader | v2 only | no reader for that name; `update-journal.json` missing → `.none` | none | untouched |
| Unreleased v1 reader | legacy only | v1 decode | v1 rules (`:210-232`) | at risk per §3.1 — the reason v2 must not be readable as v1 |
| Unreleased v1 reader | both | reads legacy only; ignores v2 | v1 rules on legacy | v2 record preserved (different file name); legacy rules still apply to legacy state |
| v2 reader | v2 only | v2 decode | §4.6 | protected by identity + marker gating |
| v2 reader | legacy only | v2 decode fails; legacy decode succeeds | §3.3 adoption table | never deletes without identity evidence |
| v2 reader | both | both decode | §3.4 | quarantine on contradiction; nothing deleted |

### 3.3 New reader × legacy v1 states

The legacy record can only be produced by an unreleased v1-reader build mid-swap (`:172-190`). The five legitimate states, plus one tampered row, and what v2 does with each:

| Legacy state | What it means | v1 action (`:210-232`) | v2 action (identity-gated) | Why the valid bundle survives |
|---|---|---|---|---|
| Current only (`current` exists, no backup) | Journal written, first rename not done, or entire swap finished and journal left behind | remove journal, `.cleared` (`:226-230`) | If `current` is an application bundle: remove legacy journal only. If it is not: quarantine. Never touch `staged`. | No deletion of any bundle |
| Current + backup | First rename done **and** second rename done (post-swap), or an unrelated backup | delete backup, `.completed` (`:210-215`) | Convert to a v2 record: `appPath=current`, `incomingPath=backupPath=backup`, `expected`=identity of `current` read from disk, `phase=validated`, `launch.markerAt` **absent**. No launch evidence is presumed: the backup is deleted only on a later recovery that sees the VC3 marker, and R2 probes the installed copy if the running bundle is the old one. Require the backup path to match the v1 naming pattern `.<app>.backup-<uuid>`; otherwise quarantine and delete nothing. | Backup deleted only after VC3, under identity-gated rules |
| No current, backup + staged | Defect A state (killed between renames) | move staged→current, delete backup, `.completed` (`:216-220`) | **Deliberately different from v1:** restore the **old** bundle (backup→`appPath`) because only it is provably the known-good; delete nothing else; leave `staged` in place for diagnosis; record `rolledBack`. | The old bundle is restored; the unvalidated staged bundle is not promoted |
| No current, backup only | Killed between renames, staged gone | backup→current, `.rolledBack` (`:222-224`) | restore backup→`appPath`, remove journal, `.rolledBack` | Old bundle restored |
| Neither current nor backup | Unrecoverable | throw `.unrecoverableJournal` (`:232`) | quarantine the legacy journal, report unrecoverable, delete nothing | Nothing left to destroy |
| Decodable but paths outside the app parent / not `.app` | Tampered or foreign | Code would act on arbitrary paths | quarantine, never touch those paths | Path validation precedes all moves |

**Identity-gated deletion rule:** the v2 reader deletes a backup only when the installed bundle's `bundleIdentifier`, `shortVersion`, `build` and executable SHA-256 match `expected` **and** `launch.markerAt` exists (v2 record) or the process currently running is that bundle (legacy adoption above).

### 3.4 Both journal files present

| Case | Detection | Action | Result |
|---|---|---|---|
| Consistent pair (legacy paths equal the v2 record's `appPath`/`incomingPath`; legacy names a subset of the v2 transaction) | Compare absolute paths | Handle legacy first (it is the older, phaseless record), then re-evaluate v2 | One transaction finalised; the other removed |
| Contradictory pair (paths disagree, or legacy names a bundle the v2 record does not) | Path comparison | Quarantine **both** journals (`*.rejected-<uuid>`); never move or delete any bundle; surface a diagnostic; the app starts normally | Both records preserved for diagnosis; last known-good untouched |
| v2 older than v1 | Legacy has no timestamp; compare file mtimes (`stat`) and `createdAt` when parseable | Treat the older record as stale: quarantine the older only | The newer transaction is finalised; nothing deleted on the older record's authority |
| Different transaction identities (v2 `transactionID` vs legacy path set) | Path/timestamp comparison | Same as contradictory: quarantine both | Manual review |

Because legacy and v2 live in different files, a v1 **writer** (`:174`) cannot overwrite a live v2 record, and a v2 writer never writes the legacy name.

### 3.5 Journal anomalies (one row each)

| Anomaly | Detection | Conservative action | Why a valid bundle survives |
|---|---|---|---|
| Truncated v2 / invalid JSON | Decode throws `dataCorrupted` | Rename to `.rejected-<uuid>`; inspect disk only (no bundle moves) | No decodable instruction exists, and no deletion is performed without one |
| Missing required field / wrong type | `keyNotFound` / `typeMismatch` | Same as truncated | Same |
| Unknown `schema` (e.g. 3) | Integer check | Quarantine; the process continues normally | Forward compatibility without acting on unfamiliar semantics |
| Stale (`generation` older than a completed transaction's record, or mtime older than the app's install date) | Compare `generation`/mtime | Quarantine, delete nothing | Staleness never authorises deletion |
| Partially committed (`phase=committed`, backup missing, journal present) | File-existence check | Verify `appPath` identity; if it matches, remove journal; if not, quarantine | Identity decides, not the phase |
| Phase names a path that does not exist | Existence check | For `prepared`: delete nothing, remove journal if `appPath` is valid; for `swapped`/`validated`: restore from whichever of `appPath`/`incomingPath` is a valid bundle; else quarantine | Only a valid application bundle is ever moved into place |
| Hostile journal naming arbitrary paths | Path must equal `parent(appPath)` + expected naming pattern | Quarantine, never touch those paths | Path validation is a precondition for every move/delete |
| `transactionID` mismatch with the running bundle's marker | Marker carries the ID | Ignore the marker; treat the journal as not launched | A marker from another transaction cannot commit this one |

### 3.6 Writer exclusion (what each build must refuse)

- A v2 build **must refuse to begin** a new transaction while a legacy journal exists: it first adopts it per §3.3, and only then writes a v2 record.
- A v2 build **must refuse to begin** while its own v2 journal exists in any phase other than absent: it runs recovery first; if recovery quarantines, it refuses and surfaces the diagnostic.
- A v1 build cannot be changed. It will happily start its own update over a live v2 transaction: it writes `update-journal.json`, renames the current app to its own `.backup-<uuid>`, then installs its staged app. Consequences when v2 next runs: `appPath` identity no longer matches `expected`, so v2 **must not delete anything**; it quarantines its record and defers to the legacy record (§3.4 contradictory/consistent rules). Residual hazard is confined to unreleased builds that predate v2; it cannot be retrofitted. Documented as a known limitation, not a defect of this design.

### 3.7 Idempotency

Every recovery path ends in one of: journal removed, journal renamed to `.rejected-*`, or journal rewritten to a new durable phase. After any terminal action, a second recovery sees no `update-journal.v2.json` and returns `.none` with zero writes. For states that cannot be resolved (neither bundle present), the quarantine rename makes the second run a no-op as well. **There is no state in which running recovery twice repeats a destructive action**, because the destructive action is always paired with a journal change in the same ordered sequence (step 1–6 of §2.5), and the second run cannot see the old instruction.

---

## 4. Transaction state machine

### 4.1 Diagram (durable states)

```
                      probe OK + exchange
 [no journal] --write prepared--> prepared -------------------> swapped
        |                            |                             |
        |                     probe fail/cancel          identity OK | identity mismatch
        |                            v                             v            v
        |                 [delete incoming, remove journal]   validated     rolledBack
        |                                                          |            |
        |                                        scene marker (VC3) |            v
        |                                                          v     [delete new bundle,
        |                                                       launched   remove journal]
        |                                                          |
        |                                                next durable step
        |                                                          v
        |                                                     committed --> [delete backup,
        |                                                                     remove journal]
        |
        +-- any undecodable/unrecoverable/contradictory --> quarantined (journal renamed; no bundle touched)
```

### 4.2 Transitions, writer, durability, idempotency

| # | Transition | Written by | Durable artefact before the step | fsync | Idempotent on retry |
|---|---|---|---|---|---|
| T0 | Begin → `prepared` | `UpdateController` | v2 journal (§2.5) | file `F_FULLFSYNC` + dir `fsync` | yes: re-running sees `prepared` and reconciles from disk first (R1), then deletes any incoming copy and clears |
| T1 | Download + verify | `UpdateController` (`:127-131`) | none (no journal yet) | n/a | yes: workspace is disposable |
| T2 | Unpack + identity read | `UpdateInstaller.unpack` (`:115-150`) | none | n/a | yes |
| T3 | Move unpacked app → `incomingPath` | `UpdateController` | journal names `incomingPath` and `expected` | rename + dir fsync | yes: journal already names the path |
| T4 | Probe `--update-self-check` on `incomingPath` | child process (no journal writes) | `probe.token` recorded before spawn | file + dir | yes: a probe has no side effects |
| T5 | Record probe result | `UpdateController` | journal phase stays `prepared` | file + dir | yes |
| T6 | Exchange (`renamex_np` or fallback) | `UpdateController` | journal `prepared` durable | rename (atomic) | yes: recovery sees `prepared`/`swapped` and reconciles from disk |
| T7 | → `swapped` | `UpdateController` | exchange complete | file + dir | yes |
| T8 | Identity check of `appPath` | reader (no writes) | journal `swapped` | n/a | yes |
| T9 | → `validated` | `UpdateController` or App-init recovery | identity matches `expected` | file + dir | yes |
| T10 | Scene marker + → `launched` | running app, `EditorView.onAppear` (`App.swift:200`) writes `launch.markerAt` + `transactionID` and advances the phase in one durable write | journal `validated` durable | file + dir | yes (marker rewrite is the same value; phase only moves forward) |
| T11 | Read `launched` | reader | marker + phase durable | n/a | yes |
| T12 | Delete backup, → `committed` | App-init recovery or `UpdateController` | journal `launched` durable | delete then file+dir write | yes: deleting an absent backup is a no-op |
| T13 | Remove journal | same | `committed` durable | unlink + dir fsync | yes |
| T14 | Rollback: exchange back | reader | journal `swapped`/`validated` durable | rename | yes |
| T15 | → `rolledBack`; delete the new (failed) bundle | reader | `rolledBack` durable | file + dir, then delete | yes |
| T16 | Cancel before exchange (only after R1 proves no exchange happened) | `UpdateController`/reader | journal `prepared` durable | delete incoming, then journal | yes |
| T17 | Quarantine | reader | none (journal is being renamed) | rename + dir | yes (second run sees no journal) |
| T18 | Probe-on-installed-copy (R2) | running old bundle at `incomingPath` | journal `swapped`/`validated` durable | spawn + `waitpid`; no journal write from the child | yes: the probe has no side effects; a repeat decision starts from the same disk state |

### 4.3 Probe contract

#### 4.3.1 Placement and argument grammar

Implementation shape (design, not code): inside `SelfCheck.runIfRequested()` (`SelfCheck.swift:13`), before the existing `--selftest`/`--memcheck` decode:

1. If `arguments` contains `--selftest` or `--memcheck` → run the existing body **unchanged**, including its parsing and `exit()` codes. This guarantees byte-for-byte preservation for `build.sh:212-213`, `build.sh:228` and `Docs/RELEASING.md:46`.
2. Otherwise, if any argv element starts with `--update-self-check` → run the probe branch below (the exact token is accepted; any other prefix form exits 64) and exit.
3. Otherwise → return (normal GUI launch).

Grammar for the probe flag:

| Rule | Behaviour |
|---|---|
| Exact token | `--update-self-check` (case-sensitive, no `=` form; `--update-self-check=<token>` is rejected) |
| Value | The immediately following argv element, required |
| Token charset | `[A-Za-z0-9._-]{1,64}`, must not begin with `-` |
| Occurrences | Exactly one required. No flag at all → not a probe (normal launch). A bare flag followed by nothing → exit 64 |
| Repeated flag | exit 64, stderr `UPDATE-SELF-CHECK: duplicate flag` |
| Empty / malformed / absent value | exit 64, stderr `UPDATE-SELF-CHECK: usage` |
| `=` form (`--update-self-check=<token>`) or any argv element that starts with the flag but is not the exact token | exit 64 — an unrecognised prefix must never fall through to a GUI launch |
| Unknown additional tokens alongside it | ignored (forward compatibility) |
| Any other argv position (e.g. `foo --update-self-check t`) | accepted: the flag is searched by `contains` + `firstIndex`, matching the existing style (`SelfCheck.swift:15-19`) |

#### 4.3.2 Exit codes

| Code | Meaning | Nature |
|---|---|---|
| `0` | Probe passed; the single success line was written to stdout | success |
| `64` | Usage error (missing/empty/malformed/duplicated flag, `=` form) | deliberate non-zero, **not** a crash |
| `69` | Probe could not read `Bundle.main` (no `Info.plist`, empty `CFBundleIdentifier`, unreadable version/build) | deliberate non-zero |
| `70` | Unexpected error inside the probe | deliberate non-zero |
| `128+N` | Killed by signal N | crash; not a defined code |
| `137` | `SIGKILL`, the observed result when AMFI refuses an ad-hoc binary at exec (MEASURED in the earlier quarantine experiment: 9/9 quarantined runs ended 137; artefact `/private/tmp/upd-qtn`) | crash-equivalent; never accepted as success |

#### 4.3.3 Success output

Exactly one line, newline-terminated, no other output:

```
UPDATE-SELF-CHECK OK <token> <bundleIdentifier> <CFBundleShortVersionString> <CFBundleVersion>
```

The parent compares the last three fields with the manifest/`expected` values, so a bundle that swapped its Info.plist after signing cannot pass silently. The token proves the responder is this binary (it echoes input), not a shell or a stale file.

#### 4.3.4 What the probe verifies, verbatim source-comment contract

```
/// Verifies EARLY PROCESS STARTUP ONLY: exec, dyld, code-signature
/// acceptance by the kernel (AMFI), framework load (AppKit, SwiftUI,
/// CoreImage), Bundle.main resolution of this bundle, Info.plist parse,
/// and App.init up to this point.
/// It does NOT verify Scene construction, EditorModel initialisation,
/// window display, or any later behaviour. Failures in that class are
/// not covered by any automated check; see U3 in the
/// updater transaction design §7.
```

#### 4.3.5 Why the exit point precedes the UI

MEASURED: `SelfCheck.runIfRequested()` is called at `App.swift:188`, inside `RetouchStudioApp.init()` (`:186-192`), before `NSApplication.shared.setActivationPolicy(.regular)` (`:190`) and `activate` (`:191`). `body` is a **computed property** (`App.swift:194`), and the only window is declared inside it (`:197-207`); a computed property cannot be evaluated while `init()` is on the stack, so no scene is described before the exit.
INFERRED (design premise, not observed here): the `@StateObject private var model = EditorModel()` (`:184`) is not realised before SwiftUI first needs it, so no model is constructed in probe mode. See §7 U7 for the experiment that settles it.
MEASURED: `AppDelegate.attach(model:)` — which starts the AI self-test, model cleanup and the recovery prompt (`App.swift:15-43`) — is called only from `EditorView.onAppear` (`App.swift:200`), so none of those side effects can run in probe mode.
MEASURED: `@NSApplicationDelegateAdaptor` may construct `AppDelegate`, whose `init` is trivial (stored properties only, `App.swift:7-13`); no lifecycle callback is implemented (`applicationWillFinishLaunching` / `applicationDidFinishLaunching` do not exist).
**NOT MEASURED: whether a Dock tile or a window becomes visible for the duration of the probe.** `Resources/Info.plist` has no `LSUIElement` or `LSBackgroundOnly` (plutil), and the bundle default is a regular app; activation policy is raised only after the exit point, but AppKit may register the process earlier. No measurement exists, so this document makes no invisibility claim (§7 U2).

#### 4.3.6 Timeout

No startup-latency measurement exists in the repository: `Docs/` contains no `--selftest` or startup timing figure (searched), `build/` is absent in the clone, and the only measured CI number is job duration (macOS Integration: 12:16:08 → 12:41:09 = 1,501 s in run `44903017542`), which is a job cost, not a process-start latency. Therefore:

- The constant is named `UpdateSelfCheck.timeout` and its value is **NOT YET SELECTED**. It must not be committed with a guessed number.
- Measurement procedure (must run before the timeout is committed): on the target Mac and on the CI runner, execute the bundled binary with the probe 30 times warm and 30 times after a cold cache (`sudo purge` on a disposable machine, or a freshly booted runner); record wall-clock time from `posix_spawn` to `waitpid`; take the p50 and p99; set the timeout to `ceil(3 × p99)`, capped at the smallest value that still tolerates a cold launch. Until then the parent uses `waitpid` with a sentinel that blocks the feature from shipping (a unit test asserts the constant is not the sentinel).

### 4.4 Where the incoming bundle lives

**Decision:** `incomingPath = parent(appPath)/.Retouch Studio.incoming-<txid>`, where `parent` is the installed bundle's parent (`UpdateController.swift:117`). The unpacked app is moved there (one same-volume rename) before the probe, so the probe exercises the exact path that will be exchanged.

Analysis of the dot-prefixed sibling (all platform behaviour INFERRED unless stated):

| Question | Finding |
|---|---|
| `Bundle.main` for a directly-exec'd Mach-O | Resolved from the executable path (`.../.X.incoming-<txid>/Contents/MacOS/RetouchStudio` → that bundle's `Contents/Info.plist`). Direct `exec` does not consult LaunchServices. NOT VERIFIED on this OS; §6 job settles it. |
| LaunchServices registration of a dot-prefixed bundle | LaunchServices and Finder skip hidden items when scanning; the bundle is not listed, not double-clickable, and not a second "app" the user sees. NOT VERIFIED; settle with `lsregister -dump | grep` (§7 U4). |
| `open` by explicit path | Still works if something names the path. Not user-reachable by browsing. INFERRED. |
| Path-dependent resources | All app resources resolve through `Bundle.main` (`AIWorker.swift:470,552`; `ModelCatalog.swift:63-66`; `UpdateController.swift:160`; `DeveloperProfile.swift:25`; `Recovery.swift:162`), so they resolve inside the sibling while it is probed. MEASURED code sites; runtime result NOT VERIFIED. |
| Bundle translocation | Applies to quarantined apps launched through LaunchServices (Gatekeeper). The updater's download acquires no quarantine by URLSession on this OS (MEASURED in the earlier quarantine investigation), and the probe is a direct `exec`, not a LaunchServices open. NOT VERIFIED for the `.incoming` path. |
| Product consequence of a **non-hidden** sibling | A second `Retouch Studio.app` in `/Applications` is visible in Finder and Spotlight, can be double-clicked mid-update, and would register with the same `CFBundleIdentifier` as the installed app. Unacceptable. |

**Tradeoff:** the dot prefix is concealment, not a security boundary — it is visible in Terminal and via "Go to Folder" — but it removes the user-visible duplicate and the accidental double-launch. It changes nothing about the exchanged content. Rejected alternative: probing inside the workspace (`.retouch-update-<uuid>/payload/…`) and exchanging from there; with an exchange, the old bundle would land inside the workspace and the `defer` at `UpdateController.swift:120` would delete the last known-good (§2.6). Also rejected: a non-hidden sibling (duplicate app).

### 4.5 Recovery triggers — comparison and choice

| Trigger | How it runs | Covers | Cost / limitation |
|---|---|---|---|
| **T1. App-init recovery in every v2 build** | One call in `RetouchStudioApp.init()` before the UI (same place as `SelfCheck.runIfRequested()`), reading both journals | Every state where the installed bundle reaches `App.init`: `prepared`, `swapped`, `validated`, `launched`, `committed`; also increments `launch.attempts` | Cannot help if the installed bundle cannot exec at all; adds one file-existence check to launch. Must run **after** the probe branch and must not run in probe mode (probe is side-effect free). |
| **T2. Execute the still-intact known-good bundle at `incomingPath`** | Manual: the user/terminal runs the old bundle directly (no `open`); its own T1 recovery sees the v2 journal, probes the installed candidate (R2) and either finalises or rolls back | The installed bundle cannot start after the exchange | The outgoing bundle must contain v2 code. On the **first** v2 rollout it is a v1 build and cannot repair; the documented fallback is a single `mv` of the backup over the app path (§7 U6). From the second v2 rollout onward it is self-service. Shows a window (it is the working app) — acceptable for a last resort. |
| **T3. Helper outside the bundle + LaunchAgent** | Login item repairs at the next login | Everything, including "installed bundle cannot exec" | Rejected: adds a background login item the owner did not ask for, a second signed/notarised executable, TCC edge cases, and delays repair to the next login. |
| **Probe (§4.3)** | Pre-exchange child process | Prevents installing a bundle that cannot reach `App.init` | Not a recovery mechanism; a prevention mechanism. |

Ordering rules for T1: it runs in `RetouchStudioApp.init()` **after** the probe branch (the probe must be side-effect free and never repairs), and it replaces the current call at `UpdateController.swift:38` — that call must be removed, so recovery runs once per launch and never from opening About mid-session.

**Choice: probe (prevention) + T1 (automatic) + T2 (manual last resort). T3 rejected.** Justification: the requirement forbids depending *exclusively* on launching the potentially broken replacement. Here the replacement is proven to reach `App.init` **before** it is installed, T1 repairs everything that fails after that point but before the scene, and T2 repairs the residual exec-level failure even when the new bundle cannot run — with the honest limitation that on the very first v2 rollout T2's tool does not exist in the outgoing bundle, so the residual is a documented manual `mv`.

### 4.6 Validation contract (what gates backup deletion)

The backup is deleted only when **all** of the following hold:

- **VC1** — the pre-exchange probe returned `0` with the expected token line (recorded in `probe.*`).
- **VC2** — `appPath` identity equals `expected` (bundle id, version, build, executable SHA-256).
- **VC3** — a durable scene marker exists: `launch.markerAt` written by the running installed app from `EditorView.onAppear` (`App.swift:199-200`), carrying the matching `transactionID`.

This is the answer to defect B: no backup is deleted "because a current exists" (`:210-215`, `:226-230`); it is deleted because the replacement was proven to start (VC1), is the expected binary (VC2), and actually brought its editor scene up (VC3). A build that dies in scene construction never writes VC3, so the backup survives and the old bundle at `incomingPath` can restore.

#### 4.6.1 Phase-lag reconciliation and the probe-on-installed-copy rule

Two disk states can contradict the recorded phase, and recovery resolves both from the file system before acting:

- **R1 — exchange completed before the phase write.** Journal says `prepared`, but `appPath` identity equals `expected` and `incomingPath` holds an application bundle. Treat as `swapped`; never take the `prepared` cancel path (which would delete the old bundle and leave the new one installed).
- **R2 — the old copy is running and the new one is unvalidated.** If `Bundle.main.bundleURL` equals `incomingPath`, the journal phase is `swapped` or `validated` without a marker, and `appPath` exists, then **execute `appPath/Contents/MacOS/RetouchStudio --update-self-check <token>`**:
  - exit `0` with the expected identity line → record `validated`, keep the backup; the new bundle is known to reach `App.init`, and VC3 will follow on its next normal launch.
  - any non-zero exit, signal or timeout → roll back (`renamex_np` exchange back), record `rolledBack`, delete the failed new bundle, keep the old one installed.

R2 is the reason recovery is not exclusively dependent on launching the replacement: the known-good bundle can test the installed candidate without trusting it to stay up, and it acts on the result. It requires the running bundle to contain this recovery code (the same limitation as T2).

**Unmarked-launch policy (a product constant, not a measurement):** at App init, if the running bundle is `appPath` and the journal phase is `swapped`/`validated` with no marker, `launch.attempts` increments durably. If the running bundle is `incomingPath` (the old copy) and `launch.attempts ≥ 2` with no marker, recovery rolls back (exchange back, delete the new bundle). `maxUnmarkedLaunches = 2` is a policy value chosen for review, not derived from a measurement; it is listed in §7 U5 as adjustable.

### 4.7 What covers the deeper failure class

Nothing automated covers a bundle that reaches `App.init`, passes the probe, is installed, and then fails in Scene construction or `EditorModel` initialisation. The mitigation chain is: VC3 withholds the backup, T1's unmarked-launch counter triggers rollback, and T2 can restore manually. The design states this plainly rather than implying the probe validates the UI. §7 U3 defines the experiment that measures the gap (a deliberately broken scene build must still pass the probe).

---

## 5. Adversarial test plan

### 5.1 Seam

Mirror the existing `AIRuntime.InstallHooks` pattern (`AIRuntime.swift:67-91`): introduce `UpdateInstallHooks` with injectable operations `move`, `exchange`, `remove`, `writeJournal`, `fsyncDirectory`, `probe`, and a `crash(at:)` that is inert in production. Production defaults use `FileManager`, `renamex_np(…, RENAME_SWAP)`, the §2.5 writer, `posix_spawn` of the bundle binary, and no crash.

### 5.2 Real termination harness

`Tests/EngineTests.swift` already re-executes itself through `Process` for other suites (`ModelStoreTests.swift:233`, `RuntimeProcessTests.swift:171`) and uses `Process` + `waitUntilExit` (`EngineTests.swift:1992-1996`). The updater cases extend the `[U]` section (`EngineTests.swift:1743`) and, for each case, spawn the test binary with an environment variable naming the kill step; the child builds a fixture tree, runs the production install path through the seam until the named step, then `_exit(99)`. The parent waits, then spawns a **second fresh child** that performs recovery against the on-disk state (a real next launch, not a same-process call), asserts the result, spawns a third child that runs recovery again and asserts a no-op.

Placement: `[U]` prints under the existing `ENGINE TESTS: PASS` banner, which `ci.yml:167` asserts with **no numeric pin** (MEASURED). It must not print a `Ran N tests` line (`ci.yml:164` asserts the worker's `Ran 166 tests`) and must not touch the `AI FAILURE TAXONOMY` pin (`ci.yml:173`).

### 5.3 Cases

Every case ends with: assert the on-disk paths, assert the installed bundle is launchable-by-identity, assert recovery's result, assert the second recovery is a no-op, and assert no stray `*.incoming-*`, `*.backup-*`, `*.tmp-*`, or journal files remain.

| # | Setup | Kill point | Expected disk after kill | Expected recovery | Idempotency assertion | Headless today? |
|---|---|---|---|---|---|---|
| U-1 | No transaction | before download | current only | `.none`, no writes | second run `.none` | yes |
| U-2 | Download in progress | mid-download | current; workspace; no journal | `.none`; workspace swept by installer | second run `.none` | yes |
| U-3 | Incoming staged | after `prepared`, before probe | current; incoming; journal `prepared` | delete incoming, remove journal | second run `.none` | yes |
| U-4 | Probe fails | probe returns non-zero | current; incoming; journal `prepared` | same as U-3; error surfaced | second run `.none` | yes |
| U-5 | Probe timeout | probe hangs; parent kills after timeout | current; incoming; journal `prepared` | same as U-3 | second run `.none` | yes (timeout constant must be set first) |
| U-6 | Probe passes then kill | after `probe.*` recorded, before exchange | current; incoming; journal `prepared` | delete incoming, remove journal | second run `.none` | yes |
| U-7 | Exchange completes then kill | immediately after `renamex_np` returns, before phase write | current=new; incoming=old; journal `prepared` (phase lag) | detect exchange from disk (appPath identity = expected), advance `swapped`→`validated`, **keep backup** (no VC3) | second run no-op | yes |
| U-8 | Kill after `validated` | before any marker | current=new; incoming=old; journal `validated`, no marker | keep both; increment attempts; no deletion | second run repeats exactly | yes |
| U-9 | Kill after marker | after `launch.markerAt` write, before commit | journal `validated` + marker | advance, delete backup, remove journal | second run `.none` | yes |
| U-10 | Kill during backup delete | between delete and journal write | current=new; no backup; journal `launched` | validate identity, remove journal | second run `.none` | yes |
| U-11 | Kill after backup delete, before journal removal | — | same as U-10 | same | second run `.none` | yes |
| U-12 | Rollback interrupted | after exchange-back, before `rolledBack` write | current=old; incoming=new; journal `swapped`/`validated` | identity of appPath = old; complete rollback: delete new, remove journal | second run `.none` | yes |
| U-13 | Unmarked launches | two starts at `appPath` with no marker, then a start from `incomingPath` | journal `validated`, attempts=2 | rollback as U-12 | second run `.none` | yes |
| U-14 | **Defect A regression (legacy)** | kill between the two renames of the fallback | no current; backup+staged+journal | restore backup (v2 rule) or staged (v1 rule) per §3.3; assert appPath exists and is the old identity | second run `.none` | yes |
| U-15 | **Defect B regression** | install a bundle whose scene never appears; no marker write | current=new; incoming=old; journal `validated` | **backup must still exist after recovery** | second run no-op | yes |
| U-16 | Legacy current-only journal | v1 record with only `current` | current; legacy journal | clear legacy journal only; touch no bundle | second run `.none` | yes |
| U-17 | Legacy current+backup | v1 post-swap record | current (running test's fixture); backup | adopt as `validated` + marker evidence; delete backup only with identity match | second run `.none` | yes |
| U-18 | Legacy no-current+backup+staged | v1 mid-swap | as U-14 | restore backup, leave staged, `.rolledBack` | second run `.none` | yes |
| U-19 | Both journals, consistent | legacy paths ⊆ v2 record | both files | finalise legacy then v2 | second run `.none` | yes |
| U-20 | Both journals, contradictory | disjoint paths | both files | quarantine both; no bundle touched | second run `.none` | yes |
| U-21 | Corrupt/truncated/malformed v2 | — | journal invalid | rename `.rejected-*`; no writes to bundles | second run `.none` | yes |
| U-22 | Hostile journal | paths outside parent or not `.app` | journal names arbitrary paths | quarantine; those paths untouched | second run `.none` | yes |
| U-23 | Neither bundle present | — | no current, no incoming | quarantine; report unrecoverable | second run `.none` | yes |
| U-24 | v1 inertness | a v1 reader is simulated against a v2 file | v2 file only | decode fails; zero writes (assert no mtime changes) | n/a | yes |
| U-25 | **R2 rollback** | old bundle running from `incomingPath`; installed copy is a fixture whose probe exits `70` | journal `validated`, no marker | probe the installed copy → `70` → exchange back, `.rolledBack`, failed new deleted | second run `.none` | yes |
| U-26 | **R2 success** | same, but the installed fixture's probe exits `0` | journal `validated`, no marker | stays `validated`; backup **retained** until VC3 | second run repeats identically | yes |

**Not testable headlessly:** whether the probe process shows a Dock tile or window (U2), whether the installed bundle passes LaunchServices registration (U4), whether `/Applications` replacement triggers App Management consent (out of scope), and real latency (U1). These are covered in §6/§7.

---

## 6. CI integration proposal

### 6.1 Starting facts

- MEASURED: `ci.yml` macOS Integration runs on `macos-15`, `timeout-minutes: 60` (`ci.yml:110-112`), and executes the worker suites, StudioCore gate and `Tests/run.sh` (`:143-158`). It does **not** build or run the app bundle.
- MEASURED: `Tests/run.sh:31-35` deliberately excludes `App.swift` ("it launches the UI") and `SelfCheck.swift` from the test link, so probe coverage cannot live in the existing suites.
- MEASURED: `ci.yml:167` asserts `ENGINE TESTS: PASS` with no numeric pin; `:173` pins `AI FAILURE TAXONOMY TESTS: PASS \(71 checks\)`; `:164` asserts the worker's `Ran 166 tests`. The probe step must print none of these.
- MEASURED: the only full-CI run inspected, `44903017542`, had macOS Integration at 12:16:08 → 12:41:09 = 1,501 s; the cost of adding a build is therefore measured against a 25-minute job inside a 60-minute budget.
- MEASURED: `build.sh` produces the bundle, ad-hoc signs unless `RETOUCH_SIGN_IDENTITY` is set (`build.sh:177-189`), validates the bundle (`:207-208`) and already runs the existing self-test on the bundled binary (`:212-220`), plus the Intel slice when Rosetta is present (`:225-237`).

### 6.2 Proposed job (additive; a separate job for failure isolation)

```yaml
  updater-probe:
    if: github.event_name == 'pull_request'
    runs-on: macos-15
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v7
      - name: Record toolchain
        run: |
          set -euo pipefail
          uname -m; swiftc --version
      - name: Build a light bundle
        env:
          RETOUCH_ARCH: arm64
          RETOUCH_SKIP_WORKER: "1"
        run: |
          set -euo pipefail
          ./build.sh release 2>&1 | tee "$RUNNER_TEMP/updater-probe.log"
      - name: Probe contract
        run: |
          set -uo pipefail
          BIN="Retouch Studio.app/Contents/MacOS/RetouchStudio"
          TOKEN="$(uuidgen)"
          OUT="$("$BIN" --update-self-check "$TOKEN" 2>&1)"; CODE=$?
          echo "exit=$CODE"; echo "$OUT"
          [ "$CODE" -eq 0 ] || exit 1
          case "$OUT" in
            "UPDATE-SELF-CHECK OK $TOKEN app.retouchstudio.mac "*) ;;
            *) exit 1 ;;
          esac
          # Negative matrix: each must exit 64 and print the usage line.
          for args in "--update-self-check" "--update-self-check=" "--update-self-check --update-self-check $TOKEN"; do
            "$BIN" $args >/dev/null 2>&1; [ $? -eq 64 ] || exit 1
          done
      - name: Upload log
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: updater-probe-log
          path: ${{ runner.temp }}/updater-probe.log
          if-no-files-found: ignore
```

What it builds: the real app bundle from the PR's source, arm64 only, worker skipped (`build.sh:154-160`), ad-hoc signed (`:185-187`), version 1.0.0 unless stamped. The existing `--selftest` gate inside `build.sh:212-220` runs unchanged and keeps its exit semantics — this step adds coverage, it does not replace or alter it.

What it executes: the bundled binary with the probe flag, capturing exit code and the single success line; then the negative matrix. It never uses `open`, LaunchServices, `osascript`, or any window API.

What it uploads: the combined build + probe log (always, so a failure is diagnosable), and the probe stdout/exit code inside that log.

What it must NOT do: print `Ran N tests`; print or alter `ENGINE TESTS: PASS`/`AI FAILURE TAXONOMY` banners; run `--selftest` a second time; assert window/Dock visibility (unmeasurable in a race against a fast process); upload the bundle; modify or replace the release pipeline; require Developer ID; run on push to `main` outside the repository's pull_request-only practice.

### 6.3 Runner capability and honesty about it

| Question | Answer |
|---|---|
| Window server / GUI availability | GitHub `macos-15` runners are VMs with a logged-in runner session and a WindowServer; GUI apps can start. INFERRED; NOT VERIFIED from this repository (nothing here launches a GUI in CI). |
| Ad-hoc signing on the runner | `codesign --force --sign -` works offline; `build.sh` already depends on it. INFERRED; the CI step itself is the first execution and will verify it. |
| Universal build on an arm64 runner | The x86_64 slice needs Rosetta; `build.sh:225-226` skips the Intel self-test when `arch -x86_64 /usr/bin/true` fails. The CI job uses `RETOUCH_ARCH=arm64` deliberately, so the probe does not depend on Rosetta. |
| Cost | Full app build time is **not measured** (no CI job builds it today, and I did not run `build.sh`). The 1,501 s measurement is the existing job, not the build. §7 U1 covers measuring the build. |
| Is the runner artefact what we ship? | No. It is ad-hoc signed (`build.sh:185-187` vs `:179-183`), single-architecture (`RETOUCH_ARCH=arm64`), worker-less (`:154-160`), and unstamped. It proves source behaviour, not the notarised release. |
| Contention | `ci.yml` and `Tests/run.sh` are owned by other PRs (e.g. PR #110 changes the worker count). This job must land after those, as an additive block, or it will conflict. |

---

## 7. Explicit unverified behaviours

| ID | Assertion | Status | How to settle it |
|---|---|---|---|
| U1 | Probe startup latency (and therefore the timeout) | NOT VERIFIED — no repository or CI figure exists; the 1,501 s CI job duration is not a startup latency | 30 warm + 30 cold runs of the bundled binary with the probe; record p50/p99; set `UpdateSelfCheck.timeout = ceil(3 × p99)`; record the machine and OS |
| U2 | A probe run creates no window and no Dock tile | NOT MEASURED — no invisibility claim is made anywhere | On a disposable Mac, poll `CGWindowListCopyWindowInfo` and the Dock's app list during a run; or `lsappinfo` before/after; repeat 20 times |
| U3 | The probe cannot catch Scene/`EditorModel` failures | INFERRED (the exit precedes `body`) | Build a variant with a `fatalError` in `EditorView.init` on a disposable runner; the probe must still exit 0 — this documents the gap, and VC3/T2 are the mitigations |
| U4 | `.Retouch Studio.incoming-<txid>` is not registered by LaunchServices, does not appear in Finder/Spotlight, and `Bundle.main` resolves correctly from it | NOT VERIFIED — platform behaviour inferred | On a disposable Mac: create the sibling, `lsregister -dump | grep` it, `mdls` it, run the binary with `--update-self-check` and inspect the echoed bundle id |
| U5 | `maxUnmarkedLaunches = 2` is the right rollback policy | Design value, not measured | Product review; adjustable without schema change |
| U6 | On the first v2 rollout the outgoing bundle is a v1 build, so T2 cannot repair; the fallback is a manual `mv` | MEASURED for the current state (v1.0.0 has no updater) | Documented procedure; verify once a v2 build is the outgoing bundle |
| U7 | `@StateObject` is not realised before `body`; therefore no model side effects in probe mode | INFERRED from SwiftUI semantics (the brief states it as a premise) | Add a temporary `print` in `EditorModel.init` in a disposable build and run the probe; the line must not appear |
| U8 | `renamex_np(RENAME_SWAP)` on non-APFS volumes | NOT VERIFIED — measured only on this APFS volume | Create an HFS+ disk image on a disposable machine and exchange two directories |
| U9 | `/Applications` replacement triggers App Management consent | Out of scope by instruction; NOT VERIFIED | Owner-run manual test on a clean account |
| U10 | The fallback two-rename path's crash window (defect A) is fully covered by §3.3/§4.6 | INFERRED from the state tables | U-14 exercises the disk state; no automated test can kill a syscall in production |
| U11 | `Bundle.main` resource lookups inside the sibling return the sibling's files | INFERRED from the `Bundle.main` code sites | U4's run with `--update-self-check` can print `Bundle.main.resourceURL` in a temporary diagnostic build |
| U12 | A v1 reader performs zero writes on an undecodable journal | MEASURED for the decode (`keyNotFound`, `try?` swallow) and INFERRED for "zero writes" from the code order (`:202` onward) | U-24 asserts no file mtimes change |

---

## Appendix A — Requirement traceability

| Requirement | Where answered |
|---|---|
| A. Probe uses the existing `SelfCheck` seam | §4.3.1, §4.3.5 |
| A. Dedicated, uniquely named token; grammar; repeats; unknown tokens | §4.3.1 |
| A. Existing `--selftest`/`--memcheck` byte-for-byte | §4.3.1 rules 1–2; §6.2 keeps the build gate |
| A. Deterministic exit codes; non-zero-but-not-crash | §4.3.2 |
| A. Exit precedes UI; `body` computed; `@StateObject` deferred | §4.3.5 |
| A. Timeout only from measurement | §4.3.6, §7 U1 |
| A. `.incoming-<txid>` analysis and recommendation | §4.4 |
| A. Probe contract comment; deeper failure class coverage | §4.3.4, §4.7 |
| A. No invisibility claim | §4.3.5, §7 U2 |
| B. Separate file name; no v1 keys; inertness argument | §2.1, §2.2, §3.1 |
| B. Legacy v1 states and identity-gated deletion | §3.3 |
| B. Writer exclusion and both-present rules | §3.4, §3.6 |
| B. Truncated/malformed/stale/partial rows | §3.5 |
| B. Idempotency proof | §3.7 |
| B. v1.0.0 has no updater; label the reader as unreleased | §3.1, §3.2 |
| C. All durable transitions | §4.1, §4.2 |
| C. Last known-good until validation | §4.6 |
| C. Out-of-band triggers compared and chosen | §4.5, §4.6.1 |
| D. Headless CI build + execute + exit code + timeout | §6.2 |
| D. No workflow builds the app; `run.sh` excludes App.swift | §6.1 |
| D. Runner capabilities and honesty | §6.3 |
| E. Scope exclusions | §6.2 "must NOT", §3.1 (no `--noqtn`/verifyArchive work) |

## Appendix B — What was and was not executed

**Read (MEASURED):** `App.swift`, `SelfCheck.swift`, `UpdateVerification.swift`, `UpdateController.swift`, `ChildProcess.swift`, `build.sh`, `Tests/run.sh`, `Tests/EngineTests.swift`, `ci.yml`, `Resources/Info.plist`, `Views/InfoViews.swift`, `Models/*.swift` bundle sites, the `v1.0.0` tag tree. **Ran:** `gh run view 44903017542` (job timings) and the earlier headless decode replica in `/private/tmp/rs-upd-feasibility` (also recorded in the accepted FEASIBILITY.md). **Not run:** the app, any built bundle, `build.sh`, any CI job. No window was opened. No repository file, branch, commit, push or PR was created; `/Users/roham/RetouchStudio` and the other members' workspaces were not touched.
