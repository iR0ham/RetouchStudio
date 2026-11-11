# StudioCore R4.2 — DocumentSession History Separation

Status: complete; uncommitted for review on branch `r4-2-history-separation`.

Baseline commit: `5e4000bc28f760bd758486d0ae849cbf1c840dca` (`main`, synchronized
with `origin/main`).

Companion documents:

- `Docs/STUDIOCORE_R4_DOCUMENT_MODEL_REVIEW.md` — defines step R4.2 and its
  dependency order.
- `Docs/STUDIOCORE_R4_0_CHARACTERIZATION.md` — the frozen behavior this step
  must preserve.
- `Docs/STUDIOCORE_R4_1_DOCUMENT_STATE_EXTRACTION.md` — the value type this
  history now records.

## 1. What was extracted

`EditorModel` previously kept four history fields and the transitions that
operate on them. Those fields and transitions now live in a value type,
`DocumentSession` (`Sources/RetouchStudio/Models/DocumentSession.swift:14-72`):

```swift
struct DocumentSession {
    static let stepLimit = 100

    private(set) var undoStack: [DocumentState] = []
    private(set) var redoStack: [DocumentState] = []
    private(set) var lastCommitted = DocumentState()
    private(set) var cleanState = DocumentState()
}
```

API, with the exact transitions R4.0 froze:

| Member | Behavior |
|---|---|
| `commit(_:)` | No-op when `current == lastCommitted`; otherwise appends the previous `lastCommitted`, trims to `stepLimit`, clears the redo branch, records `current` |
| `undo(current:)` | Pops the undo stack, pushes `current` onto redo, records the returned state as `lastCommitted`; `nil` when there is nothing to undo |
| `redo(current:)` | Pops the redo stack, pushes `current` onto undo, records the returned state as `lastCommitted`; `nil` when the branch is empty |
| `canUndo(current:)` | `!undoStack.isEmpty || current != lastCommitted` |
| `canRedo(current:)` | `!redoStack.isEmpty && current == lastCommitted` |
| `reset(to:)` | Clears both stacks and makes the given state both the recorded and the clean baseline |
| `markClean(_:)` | Moves only the clean baseline, for save and discard |

The type is a struct: two sessions can never share a stack, and the transitions
are testable without a model, a window or the main actor. It imports only
Foundation and has no UI, timer, Task, file, dialog or rendering dependency.

## 2. What deliberately stayed in the shell

The review scopes R4.2 to history state, not to the workflow around it. The
following remain in `EditorModel`, unchanged:

- the 350 ms coalescing timer (`scheduleCommit`) and its cancellation;
- the `canStart(.load)` guard, busy status and error tokens;
- building `currentState` from the eight published properties;
- applying a returned state to the published properties, refreshing overlays
  and faces, and re-reading pixels after a crop or orientation change
  (`restore`);
- dirty comparison and autosave scheduling (`updateCleanState`);
- status refresh after a history change;
- per-photo history reset wiring (`resetHistory`), while the stacks themselves
  are reset by the session.

The timer did not move because it is a gesture-boundary policy owned by the
editor, not a property of the history value. The session is told about a
boundary explicitly through `commit`, `undo` and `redo`.

## 3. Call-site mapping

Line numbers are from the current tree.

| Location | Before | After |
|---|---|---|
| `EditorModel.swift:316` | four private history fields | `private var session = DocumentSession()` |
| `EditorModel.swift:342` | inline append/trim/clear logic | `session.commit(currentState)` |
| `EditorModel.swift:349-363` | direct stack pops and `lastCommitted` writes | `session.undo(current: currentState)` |
| `EditorModel.swift:365-380` | direct stack pops and `lastCommitted` writes | `session.redo(current: currentState)`, with the same dirty-branch guard |
| `EditorModel.swift:416-419` | inline stack emptiness checks | `session.canUndo/canRedo(current:)` |
| `EditorModel.swift:497-500` | `currentState != cleanState` | `currentState != session.cleanState` |
| `EditorModel.swift:504-510` | inline stack and baseline reset | `session.reset(to: currentState)` |
| `EditorModel.swift:929` | `cleanState = currentState` after discard | `session.markClean(currentState)` |
| `EditorModel.swift:1069` | baseline before `resetHistory` on load | `session.markClean(currentState)` |
| `EditorModel.swift:1077` | forced empty baseline after recovery restore | `session.markClean(DocumentState())` |
| `EditorModel.swift:3147` | baseline after Save Project | `session.markClean(currentState)` |

`restore`, `refreshStatusAfterHistoryChange`, `scheduleCommit`,
`updateCleanState`, reload, autosave and project/export construction are
untouched.

One ordering detail changed internally: the session records `lastCommitted`
before the shell applies the restored value, whereas the old code assigned it
after `restore`. No synchronous behavior depends on the intermediate value:
`updateCleanState` compares `currentState` with `cleanState` only, and
`updateUndoFlags` is republished after `restore` returns, which is the state the
UI renders. There is no Combine subscriber to `canUndo`/`canRedo`; the only
consumers are SwiftUI `disabled`/`enabled` reads at render time.

## 4. Behavior preserved

Everything characterized in R4.0 still holds:

- commit deduplication against the last recorded state;
- 350 ms coalescing; a pending debounce is flushed by undo;
- the 100-step cap, dropping the oldest state first;
- a new commit clears the redo branch;
- redo while dirty commits the new branch instead of replaying;
- crop and orientation restore through the same `restore` path, including the
  pixel re-read with `restoring: true`;
- failed loads preserve the previous document and its history;
- the clean baseline moves on load, Save Project and discard; a recovery restore
  starts from the empty baseline and stays dirty until the working slot is
  written;
- history belongs to one photo and is reset on a new load;
- dirty tracking still excludes export, auto-strength and view preferences;
- project v3 serialization, `makeProject`, `RecoverySnapshot` and export
  snapshots are untouched.

## 5. Test evidence

### Added tests

`Tests/ModelTests.swift:4629-4716`, `testDocumentSessionHistoryValue`
(16 checks), pins the value directly:

- a fresh session offers no history and treats the empty state as recorded and
  clean;
- an uncommitted change is undoable; a commit records the previous state;
- a repeated commit adds no step;
- undo returns the previous state, keeps the branch, and redo replays it;
- a new commit discards the redo branch;
- 105 commits retain exactly the last 100 steps, and the oldest retained step is
  the expected value;
- undo past the cap returns `nil` and offers no undo;
- `markClean` moves only the baseline; `reset(to:)` starts a new document;
- a copied session owns its own stacks.

The R4.0 model-level tests, the R4.1 value-semantics test and the existing
self-test history block ran unchanged and passed, which is the behavioral
evidence that the extraction did not change the editor's steps.

### Gates and actual results

| Gate | Command | Result |
|---|---|---|
| Focused R4.2 checks | `./Tests/run.sh` (model suite) | 16/16 pass |
| Full suite, arm64 | `./Tests/run.sh` | exit 0; ENGINE, MODEL, RUNTIME PROCESS and RUNTIME V2 all PASS; 964 checks, 0 failures |
| Full suite, x86_64 under Rosetta | `RETOUCH_ARCH=x86_64 ./Tests/run.sh` | exit 0; all four suites PASS; 964 checks, 0 failures. This is Rosetta-translated x86_64, not native Intel hardware |
| StudioCore, arm64 | `./Tests/run-studiocore.sh arm64` | 117 checks passed; Foundation-only boundary check unchanged |
| StudioCore, x86_64 | `./Tests/run-studiocore.sh x86_64` | 117 checks passed |
| R1 conformance | `./Tests/Conformance/run-conformance.sh` | PASS: 21 fixtures (15 valid, 6 invalid), corpus lock 12 fixtures / 78 cases / 21 references / 11 exports, canonical JSON SHA-256 verified, 17 render stages |
| C ABI smoke | same command | `studioscore abi=1 status_count=20 error_codes=20` |
| Golden corpus | `./Tests/run-corpus.sh` | 376 checks, 0 failures |
| macOS build + self-test | `RETOUCH_SKIP_WORKER=1 ./build.sh release` | exit 0; universal bundle (`x86_64 arm64`); processing self-test passed natively and on the Intel slice |
| Self-test history block | `build/selftest*/selftest.log` | pending drag undone, settled edits step back one at a time, a new edit clears the redo branch, preset applies as one undo step — all pass on both slices |
| Whitespace | `git diff --check` | exit 0, no output |

No Windows or Linux compatibility is claimed or was tested.

### Corpus protection

- All 46 tracked `Tests/Corpus` files were hashed before running the harness.
- The harness rewrote exactly four tracked exports: `F01_export_256.png`,
  `F01_export_256.tif`, `F08_export_256.png`, `F11_export_256.png`.
- Only those four were restored from `HEAD`; no fixture or baseline was
  regenerated.
- All 46 hashes were re-verified against the pre-run snapshot and match byte for
  byte.

## 6. Remaining dependencies and next candidates

R4.2 stops at history separation; it does not claim portability. The session
still stores `DocumentState` values whose field types live in the application
layer, and it is constructed by the shell from published properties. The R4
review's next step, R4.3 (project codec and source-resolution port), is not
started.

A future session could be moved toward StudioCore only after the document value
and its geometry are independently portable. The history transitions themselves
are already free of platform dependencies, so that move would be a type and
module decision rather than a behavior rewrite.

## 7. Rollback procedure

No persistent data or serialization is involved:

1. delete `Sources/RetouchStudio/Models/DocumentSession.swift`;
2. in `EditorModel.swift`, restore the four private history fields and the
   inline transitions shown in section 3, and revert `session.markClean`,
   `session.reset`, `session.canUndo`/`canRedo` and `session.lastCommitted` to
   their previous forms;
3. remove `testDocumentSessionHistoryValue` and its runner line if the type no
   longer exists.

Restoring `EditorModel.swift` from `HEAD` and deleting the new file is the exact
code reversal; the tests and this document can be reverted independently. No
project, recovery, corpus or fixture file was modified.

## 8. Scope statements

- Scope is history only: undo, redo, coalescing boundaries, the 100-step cap,
  commit and restore wiring.
- `RetouchProject`, its decoder/encoder, serialized names and v3 wire shape:
  untouched.
- Geometry, image processing, the 17-stage pipeline, AI worker behavior:
  untouched.
- Autosave and recovery behavior: untouched.
- No History UI redesign, no DocumentCodec, RecoveryPolicy, ExportPlanner or
  BatchPlanner extraction; R4.3 is not started.
- No new dependency, package manager or build-system change.
- No commit, stage, push, PR or merge; all changes are left uncommitted for
  review on `r4-2-history-separation`.
