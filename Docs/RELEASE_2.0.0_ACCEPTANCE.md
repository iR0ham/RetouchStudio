# Retouch Studio 2.0.0 — owner manual-acceptance session pack (G-ACC)

> **HONESTY RULE — read this first.**
> A step is **PASS** only if you saw the stated result with your own eyes in the running app.
> Anything else is **NOT RUN**. "It should work", "the code says so" and "CI is green" are not PASS.
> This document is a **blank form**. It asserts no result, contains no verdict and states no
> readiness opinion. Every evidence cell below is empty on purpose and stays empty until you fill it.
> When you finish, the filled form is the evidence; this file un-filled proves nothing.

---

## 0. What is being accepted, and how to confirm you are testing the right build

**Scope of this session:** the macOS arm64 `2.0.0` release-candidate bundle only — the light
editor, its optional local AI helper path, and the bilingual shell. The Windows host is explicitly
out of scope for this session (§13).

**Build identity — check before anything else.** The version string shown in the app comes from the
bundle's `Info.plist`, which `build.sh` stamps from environment variables:

| Fact | Where it is defined | How to read it |
|---|---|---|
| Version + build displayed by the app | `Resources/Info.plist:21-24` (`CFBundleShortVersionString`, `CFBundleVersion`) → rendered as `DeveloperProfile.versionLine` = `"version (build)"` (`Sources/RetouchStudio/Models/DeveloperProfile.swift:19-21`) | In-app: menu **Retouch Studio → About Retouch Studio**, or **Settings (⌘,) → DEVELOPER → Version** (`Sources/RetouchStudio/Views/SettingsView.swift:261`). |
| How the RC gets its number | `build.sh:110-117` writes `RETOUCH_VERSION` / `RETOUCH_BUILD` into the plist via PlistBuddy | `./Tools/check-versions.sh 2.0.0` must agree with the tag (ledger §3 G-VER). |
| The DMG under test | `Tools/make-dmg.sh:11-18,27-31` names it `RetouchStudio-<version>-<arch>.dmg` and writes `<name>.dmg.sha256` (`:31`) | `shasum -a 256 -c "RetouchStudio-2.0.0-arm64.dmg.sha256"` before mounting. |

**Write the identity here before starting:** version `(build)` observed in About: `__________` ·
DMG sha-256 match: `__________`.

**Note on the source default, corrected 2026-11-23.** `Resources/Info.plist` carries `2.0.0` / build `2`
in the source, but **no CI build has ever shipped that pair, and none will.** `release.yml` injects both
values (`:38` and, on the Intel job, `:68`):
`RETOUCH_VERSION="$VERSION" RETOUCH_BUILD="$GITHUB_RUN_NUMBER" ./build.sh release`, where `VERSION` is
the tag minus `v` on a tag run and hard-coded `0.0.0-ci` otherwise (`:33-37`). Only the bundle copy is
rewritten — `build.sh:105` copies `Resources/Info.plist` into the `.app`, then `:109` points `PLIST` at
that copy and `:111`/`:114` `Set` the two keys with PlistBuddy — so the committed plist is a fallback a CI
build never shows. And nothing guards the build number: `Tools/check-versions.sh` compares
`CFBundleShortVersionString` against `Windows/Directory.Build.props`' `<Version>` and the tag, and never
reads `CFBundleVersion` at all (ledger §3 G-VER describes the same mechanism).

**Which artefact is this session allowed to run against?** Two cases, and conflating them would invalidate
every row below, so pick one and write it in the identity line:

- **Tag build** — only possible after the owner tags `v2.0.0` and publishes (ledger D7 reserves it). About
  must then read `2.0.0 (<that run's number>)`, the image must be `RetouchStudio-2.0.0-<arch>.dmg`, and it
  must answer `shasum -a 256 -c "RetouchStudio-2.0.0-arm64.dmg.sha256"`. Anything else means you are not
  holding the artefact you think you are: **stop**.
- **Pre-publication candidate** — what actually exists as of 2026-11-23. The packages come from a
  `workflow_dispatch` run of the `Release` workflow, so they are named
  `RetouchStudio-0.0.0-ci-<arch>.dmg` and the bundle's `Info.plist` carries
  `CFBundleShortVersionString = 0.0.0-ci` with `CFBundleVersion` equal to the run number — that pair was read
  directly out of the arm64 image of run `45197302277` (ledger Addendum S.12.10), so About should read
  `0.0.0-ci (5)`; **the rendered string itself is still unobserved, because no window has been opened.**
  **That label is correct for an unpublished candidate, not a defect** — do not stop the session over it;
  record the exact pair and the run number, and quote the run number in every FAIL block (§15). Two honest
  consequences: the download comes from the *Actions run* page rather than a release page, and a GitHub
  artefact is a zip round-trip that may not preserve `com.apple.quarantine`, so §1's Gatekeeper outcome
  taken from that path is **indicative only** — a truthful §1 verdict needs the published image. The
  readiness ledger's Addenda S.11 and S.12 record which run was built and which head it used.

**Before you start, confirm the source agrees:** `./Tools/check-versions.sh 2.0.0` must pass. It cannot
tell you the build number, and it never will — that is the owner's open "build stamping" decision, not a
gap in this checklist.

### Prerequisites (all must be true before minute 1)

1. The RC DMG was downloaded fresh over HTTPS — from the release page for a tag build, or from the
   `Release` workflow run's Artefacts list for a pre-publication candidate (§0) — into a normal browser
   download folder, **not** copied from a local build directory (a local copy carries no quarantine
   attribute and would make §1 meaningless). If you obtained it from an Actions run, say so in §1's note
   cell, because that zip round-trip weakens the Gatekeeper conclusion.
2. You have: one portrait photo where a face is clearly visible, one large landscape photo with no
   face, and a free folder for exports.
3. You have at least **75 minutes** of uninterrupted time — the budget below sums to 72 minutes and the
   note-taking is what makes a FAIL row usable; the AI sections assume the network works once.
4. macOS 14 or later on Apple silicon (`Resources/Info.plist` `LSMinimumSystemVersion` = `14.0`; the
   helper is Apple-silicon-only — `Localization.swift:849` in English, `PersianL10n.swift:818` in
   Persian). The shipped build has no helper at all, so an Intel Mac simply has the editor.
5. Note the current state of the helper before you start, because **§9** has two branches (its heading says
   "helper absent vs installed"):
   `ls ~/Library/Application\ Support/RetouchStudio/AI/runtimes` → helper absent / present: `______`.

### Time budget

| Section | Topic | Min |
|---|---|---|
| 1 | First launch + Gatekeeper | 5 |
| 2 | Build identity + updater honesty | 5 |
| 3 | Import a photo | 3 |
| 4 | Non-AI edit + export | 5 |
| 4b | Canvas toast vs compare chrome (PR #130/#131) | 4 |
| 5 | Watermark size-percentage path | 5 |
| 6 | Batch export + cancel | 5 |
| 7 | Project save → quit → restore + recovery | 8 |
| 8 | Undo/redo across an AI edit | 4 |
| 9 | AI consent sheet + Model Manager states | 8 |
| 10 | Upscale a large image + ETA wording | 6 |
| 11 | Disk-nearly-full behaviour | 4 |
| 12 | Persian locale pass | 8 |
| 13 | Windows statement (no execution) | 2 |

---

## 1. First launch from the downloaded DMG (ad-hoc signing truthfulness)

**Flow.** Mount the checksummed DMG, drag **Retouch Studio.app** to **Applications** (the image
ships an `Applications` symlink — `Tools/make-dmg.sh:24`), then launch it the way a new user would.

**Click path.** Double-click the app once. Then, whatever Gatekeeper says, follow what our own
release notes instruct: right-click the app → **Open** → confirm.

**Expected observable result.** Ledger §7 records that the published Gatekeeper copy is
**NOT VERIFIED**, and warns that `--noqtn` never applies to the downloaded `.app` itself. So the
test is not "does it open" but "**does the dialog text match what we told users to do**". Write the
dialog wording verbatim into the note cell. If double-click opens the app with no prompt at all,
record that too — it changes what the release notes must say.

| # | Evidence (PASS / FAIL / NOT RUN + note) |
|---|---|
| 1.1 First double-click outcome (quote the dialog) | |
| 1.2 Right-click → Open reaches the editor window | |
| 1.3 Second launch needs no override | |

---

## 2. Build identity and the disabled updater

**Flow.** Confirm the RC number, then confirm the updater cannot install anything and says so.

**Click path.**
1. Menu **Retouch Studio → About Retouch Studio** (`App.swift:210` → `InfoWindows.showAbout()`).
2. In the About window press **Check for Updates** (`Views/InfoViews.swift:200`, label
   `Localization.swift:878`).
3. Separately: **Settings (⌘,) → DEVELOPER** row **Version** (`SettingsView.swift:242-262`).

**Expected observable result.** About and Settings show the same `2.0.0 (build)`. Pressing
**Check for Updates** ends in a failure line built from `updateFailed` + `updateFeedMissing`
(`UpdateController.swift:66-69`, `Localization.swift:883-884`):
`The update check failed: This build has no update feed configured.` No download starts, no
network request appears in Activity Monitor, and no **Install** button ever replaces it. Ledger §3
G-UPD marks the *rendered* panel **NOT VERIFIED** — this step is what closes it.

| # | Evidence |
|---|---|
| 2.1 Version/build matches the RC | |
| 2.2 Check-for-Updates refuses with the no-feed sentence | |
| 2.3 No update was installed or downloaded | |

---

## 3. Import a photo

**Flow.** Two entry points must both work: the toolbar/menu opener and a Finder drop.

**Click path.**
1. With no photo open: bottom-left card **Open** (`ToolPanel.swift:434-441`, label
   `Localization.swift:24`, help `openHelp` = `Open an image (⌘O)` at `:29`), or menu **File →
   Open Image…** (`App.swift:243`, ⌘O). Choose the portrait.
2. Drag a second photo from Finder onto the canvas area.

**Expected observable result.** The top bar shows the file name and the pixel readout
`W × H px` appears under the face-status chip (`EditorModel.imageInfo`, `EditorModel.swift:3148-3151`).
Face detection reports a count through the status chip; a faceless photo instead shows
`No face found — only the Color & Light tools apply.` (`Localization.swift:219-221`). A browser
drag (no file behind it) is ignored rather than crashing (`EditorView.swift:74-91`).

| # | Evidence |
|---|---|
| 3.1 ⌘O / Open loads the portrait, name + px readout correct | |
| 3.2 Finder drop loads the second photo | |
| 3.3 Face count / no-face message matches the photo | |

---

## 4. Non-AI edit and export

**Flow.** One measured slider, then a full-quality export to disk.

**Click path.**
1. Tool pills in the top bar (`TopBar.swift:53-58`): click **Skin** (shortcut `1`) and raise
   **Skin Smoothing**; or click **Color & Light** (`6`) and move Exposure.
2. Press the chartreuse **Export** pill at the trailing edge of the top bar
   (`TopBar.swift:146-166`, label `Localization.swift:25`), or ⌘E.
3. In the Export sheet: pick **JPEG** from the format row (`EditorView.swift:135-139`, `formatPicker` defined at `:472-500`, titles from
   `Sources/StudioCore/RenderContract.swift:11-16`), set **Quality**, optionally change **Long edge**
   (`Original` / `4096` / `2048` / `1080`, `EditorView.swift:101,166-192`), then press **Save…**
   (`EditorView.swift:273-288`, label `Localization.swift:521`).
4. In the save panel (message `Choose where to save the retouched image`,
   `Localization.swift:1261`) choose the export folder and save.

**Expected observable result.** The status line reads `Rendering full-quality export…`
(`Localization.swift:242`), then `Saved <name>` (`:246`). The file exists, opens in Preview, and
differs from the original. Choosing the **source photo itself** as the destination must refuse with
`That is the photo you are editing. Choose a different name or folder.` (`:248-250`) and leave the
original bytes untouched. Colour expectation is governed by `Docs/OUTPUT_COLOR_POLICY.md`: output is
declared sRGB, macOS JPEG/PNG carry no embedded ICC profile, and wide-gamut colours are clipped —
that is policy, not a defect.

| # | Evidence |
|---|---|
| 4.1 Slider visibly changes the canvas | |
| 4.2 Export writes the file and reports `Saved <name>` | |
| 4.3 Long-edge choice is honoured in the written file's dimensions | |
| 4.4 Exporting onto the source is refused, source intact | |

---

## 4b. The canvas status toast never hides behind the compare chrome *(added 2026-11-23)*

**Why this section exists.** PR #130 (`9edd774`) and PR #131 (`5ce98ec`) moved the status pill so it
reserves the BEFORE/AFTER tags, the divider's grab strip, and the zoom dock as hard obstacles and the photo
as a soft one, and PR #131 gated the hidden measuring twin behind `model.hasImage || model.isBusy`
(`CompareCanvas.swift`, the `.overlay(alignment: .topLeading)` on `statusPill`). **All of that is verified
only headlessly** — `testToastObstaclesMirrorTheDrawnChrome` sweeps 120 zoom/pan/split states against a
transcription of the view's own arithmetic, and the suite prints `MODEL TESTS: PASS` at 1252 `✓` — so how
it looks and moves in a real window is still NOT VERIFIED. This section is the only thing that can close
that. The code under test is `ToastPlacement.frame(in:toast:obstacles:)` reached from
`CompareCanvas.statusToast(canvas:)`, and the obstacle set comes from
`ToastObstacles.compareWorkspace(…)` fed by `model.compareEnabled`, `model.comparePosition`,
`model.isPeekingOriginal`, `model.toolOwnsCanvas` and the measured dock.

**Flow.** Keep a status message on screen (any long-running action prints one — an export, an upscale
attempt, a save) and drive the chrome around it. The pill appears only while
`model.hasImage && !model.status.isEmpty && model.status != model.faceStatusText`, so a standing face count
is not a toast; trigger real actions to keep one visible.

**Click path.**
1. **Menu / toolbar Compare** (`Localization.compare` = **Compare**, help text `compareHelp` =
   "Show the before/after comparison (hold Space to see the original)") on the portrait.
2. Drag the divider to its two ends, then start an export so a toast is live while you watch it.
3. Zoom to 4× and pan the photo well off-centre (⌘+/scroll and drag), still with a toast visible.
4. Hold **Space** (peek the original), then release; repeat while compare is on.
5. Enter **Crop** (⇧⌘X), **Heal** and the mask picker — each sets `model.toolOwnsCanvas`
   (`EditorModel.swift:1422`) and drops the compare reservations.
6. Quit back to the empty stage, then press ⌘O and watch the **first** toast that appears after the load.
7. Repeat 2–6 with the shell in Persian (**Retouch Studio → Language → فارسی**), where the tags read
   «قبل» / «بعد» (`PersianL10n.swift:497-498`).

**Expected observable result.** The pill stays fully inside the visible stage and every word stays readable:
never under the 28 pt divider strip, never behind a tag, never behind the zoom dock, and never clipped by
the stage edge when the photo is panned off-stage. During the Space peek the BEFORE badge keeps its corner
and the pill moves clear of it rather than of the compare chrome it no longer draws. In tool mode the pill
may sit where the compare strip would have been — the reservations are deliberately dropped — but it must
not sit under a tool's own overlay. On the very first toast after a load, expect the pill to be sized from
the deliberate 200 pt default for a single frame before the measured width arrives; that is the intended
fallback from PR #131, not a bug. **What to write in the note cell for each row:** which edge or control the
pill came within a few points of, whether any text was unreadable, and whether the pill moved smoothly
(`Motion.snappy`) or jumped.

| # | Evidence |
|---|---|
| 4b.1 Divider at both extremes: pill clear of the strip and both tags | |
| 4b.2 Zoomed and panned off-stage: pill stays on the stage, unclipped | |
| 4b.3 Space peek: badge keeps its corner, pill clears it | |
| 4b.4 Crop / Heal / mask: no reservation artifacts, pill readable | |
| 4b.5 First toast after ⌘O is not mis-placed for a visible beat | |
| 4b.6 Persian tags «قبل»/«بعد» never overlap the pill | |
| 4b.7 Motion: the pill animates rather than teleporting between obstacles | |

---

## 5. Watermark and the size-percentage path

**Flow.** Sign an export and prove the two watermark sliders move in the units they claim.

**Click path.** In the Export sheet, turn on the **WATERMARK** switch (`EditorView.swift:404-419`,
section label `Localization.swift:526`). Then: type into the text field (placeholder
`Name or ©`, `:528`), pick one of the six position chips (`Top left` … `Center`, `:534-543`), and
drag **Opacity** (`:529`) and **Size** (`:530`).

**Expected observable result.**
- Opacity spans `0.05…1` in **0.05 steps** and its readout is a whole percent
  (`EditorView.swift:112-113`, `Components.swift:243-262`). The released 1.0.0 defect was a 1-point
  step collapsing this range to 0 and 1 — a mid-range value such as `65%` must be reachable and must
  persist.
- Size spans `1…10` **percent** in 1-step increments with default `3` (`EditorView.swift:115-116`),
  i.e. glyph height as a percentage of the frame, not pixels.
- Hovering a row reveals its reset arrow (`Components.swift:319-327`).
- The note says the mark is drawn on saved copies only
  (`watermarkNote`, `Localization.swift:531-533`): the editor preview stays clean while the exported
  file carries the mark.

| # | Evidence |
|---|---|
| 5.1 Opacity stops at intermediate values (e.g. 65%), not only 0/100 | |
| 5.2 Size reads as a percent in 1…10 and changes glyph size proportionally | |
| 5.3 Position chip lands the mark where it claims | |
| 5.4 Preview clean, exported file watermarked | |

---

## 6. Batch export and cancelling a batch

**Flow.** Start a multi-file batch, stop it partway, then let one finish.

**Click path.** Menu **File → Batch Export…** (⇧⌘E, `App.swift:277-278`, label
`Localization.swift:309`). Two panels open in order: **Choose photos to export** (multi-select,
images only — `EditorModel.swift:3585-3590`) then **Choose a folder for the exported photos**
(`:3592-3597`). The **Batch Export** sheet then shows `N selected` (`EditorView.swift:531`,
`Localization.swift:326`) with two switches — **Healing stamps and stickers** and **Analysis
overlay** (`:329-334`) — and a **Start Export** button (`:335`, `EditorView.swift:556-557`).

**Expected observable result.** While running: a linear progress bar, `Exporting X of Y` style
progress text (`batchProgress`, `Localization.swift:311`) and a percent readout
(`EditorView.swift:583-601`). Press **Cancel** (`EditorView.swift:546` →
`EditorModel.cancelBatchExport()`, `:3616-3621`): the run stops, the sheet switches to the report,
and the status line reads `Batch export cancelled.` (`Localization.swift:324`). Files already
written stay written; no partial file appears for the interrupted one. Starting a second batch while
one runs is impossible — the menu item is disabled (`App.swift:278`). Finishing normally reports
`Batch export finished: …` with saved/skipped/failed counts (`Localization.swift:314-322`).

| # | Evidence |
|---|---|
| 6.1 Both selection panels behave as described | |
| 6.2 Progress advances and per-file output appears | |
| 6.3 Cancel stops cleanly and reports cancellation | |
| 6.4 Re-run without cancel completes and reports counts | |

---

## 7. Project save → quit → restore, including recovery candidates

**Flow.** Save a project, verify round-trip; then separately verify the crash-recovery candidate.

**Click path.**
1. Make edits → menu **File → Save Project** (⌘S, `App.swift:267-268`) — first time it becomes
   **Save Project As…** and a panel titled by `chooseProjectLocation` = `Choose where to save the
   project` opens (`Localization.swift:272`, `EditorModel.swift:3457-3467`). The file is
   `.<retouch>` (`Sources/StudioCore/ProjectDocument.swift:14`).
2. Status should read `Saved project <name>` (`Localization.swift:273`).
3. Quit (⌘Q) and relaunch → **File → Open Project…** (⇧⌘O, `App.swift:246`) → pick the project.
4. Now the recovery branch: open a photo, make an edit, and **do not save**. Quit the app. Because a
   clean quit clears the working copy (`settingsRecoveryNote`: "Cleared as soon as the photo is saved
   or exported", `Localization.swift:624-626`), exercise the real path by forcing a quit — Apple
   menu → **Force Quit**, or kill the process by hand. Relaunch.

**Expected observable result.** Step 3 restores every slider, healing stamp, crop and orientation
and reports `Project restored.` (`Localization.swift:275`). Step 4 raises the modal
**Reopen unsaved work?** with buttons **Restore Edits / Cancel / Discard**
(`Localization.swift:934-942`, built in `EditorModel.recoveryChoice`, `:3100-3130`). **Escape or
closing the alert means Cancel — only the third, destructive button may delete the copy**
(`:3113-3123`). After Restore, the working copy is written and verified before the candidate is
removed (`finishRestore`, `:3058-3077`); if removal fails you get
`The recovered photo is saved, but its old recovery copy could not be removed.`
(`Localization.swift:296-298`) and the candidate is re-offered next launch. If the source photo moved,
the first prompt is **Locate Photo / Cancel / Discard** (`:280`, `missingSourceChoice` `:3083-3091`).
The recovery toggle itself lives in **Settings → RECOVERY** (`SettingsView.swift:213-236`).

| # | Evidence |
|---|---|
| 7.1 Save Project writes the file and reports it | |
| 7.2 Reopen restores all edits | |
| 7.3 Force-quit leaves a candidate; relaunch prompts | |
| 7.4 Escape/Cancel preserves the candidate (re-prompts next launch) | |
| 7.5 Restore Edits replays the work and the prompt does not repeat | |
| 7.6 Missing source offers Locate Photo and relinks | |

---

## 8. Undo / redo across a risky operation

**Flow.** Prove history survives an operation that touches both the mask store and the layer list —
an AI quick edit — not just a slider drag.

**Click path.**
1. Move any slider; wait ~1 s so the debounce commits (`commitAdjustments`, `EditorModel.swift:380-384`).
2. Click the **arrow.uturn.backward** icon in the top bar (`TopBar.swift:23-25`, tooltip
   `Undo (⌘Z)`, `Localization.swift:192`) → the slider returns.
3. Click **arrow.uturn.forward** (`TopBar.swift:26-29`, `Redo (⇧⌘Z)`) → it goes forward again.
4. Now the risky part: in the **AI Edit** card (`ToolPanel.swift:109`, section label
   `Localization.swift:1292`) run one quick edit, then undo it with ⌘Z. Redo with ⇧⌘Z.
5. Cross-check the dedicated control: after an AI edit the card also offers
   **Remove the last AI edit** (`ToolPanel.swift:160-163`, `Localization.swift:1378`), whose doc
   comment states undo can bring it back (`EditorModel.swift:1901-1909`).

**Expected observable result.** `addAIEdit` commits history *before* appending and then refreshes the
toolbar flags explicitly (`EditorModel.swift:1913-1925`), so the undo arrow must be enabled
immediately after an edit finishes — without touching a slider first. Undo removes exactly the last
edit; redo restores it; **Remove the last AI edit** followed by ⌘Z must bring the layer back. During
any running job the arrows go dead and the status says
`Another operation is still running — try again when it finishes.` (`isHistoryBlocked`
`EditorModel.swift:299`; `operationBusy` `Localization.swift:253-255`). Editing after an undo starts
a new branch and drops the old redo chain (`:405-408`).

| # | Evidence |
|---|---|
| 8.1 Slider undo/redo round-trips | |
| 8.2 Undo arrow live immediately after an AI edit | |
| 8.3 Remove-last-AI-edit is itself undoable | |
| 8.4 Arrows disabled during a running job, busy message shown | |

---

## 9. AI consent sheet and Model Manager states — helper absent vs installed

**Entry point (both branches).** **Settings (⌘,) → AI MODELS → Manage Models…**
(`SettingsView.swift:184-207`, label `Localization.swift:640`). The sheet header is **AI Models**
with the line `Models run on this Mac. Nothing is uploaded, and no model is downloaded without your
approval.` (`ModelManagerView.swift:167-183`, `Localization.swift:641-644`) and a **Done** chip
(`modelsClose`, `Localization.swift:673`).

**Branch A — helper absent (this is the shipped light-build state).**
- `AIRuntime.package` is hard-coded `nil` (`Sources/RetouchStudio/Core/AIRuntime.swift:40`), so
  `showsRuntimeCard` is false (`ModelManagerView.swift:146-148`) and **no runtime card and no
  "Download runtime" button appear at all**. Record that explicitly: `Docs/AI_RUNTIME.md` §2 step 3
  and `Docs/RELEASING.md:179` both assert this, and neither is marked verified anywhere.
- The **AI CAPABILITIES** block instead shows the helper-stopped note
  `The local AI helper is not running, so the capability list cannot be read.`
  (`capabilityHelperStopped`, `Localization.swift:653-655`, wired at `ModelManager.swift:100`).
- Model rows still list the four catalogue entries with chips from `statusChip`
  (`ModelManagerView.swift:529-560`): `Not installed`, and — if weights were ever downloaded —
  `Installed · can't run` plus the warning line `modelsInstalledNoRuntimeNote` (`:662-664`).
  Installing, verifying and removing must still work in that state.
- The disk line `On disk: X · Free: Y` (`modelsDiskUsage`, `:736-738`) must render real numbers, or
  `Size unknown` when capacity is unreadable (`ModelManagerView.swift:186-198`).

**Branch B — helper installed / bundled.** Repeat the same checks and additionally confirm the
capability grid renders one row per capability with a chip among **Ready / Needs a model / Blocked /
Not available** (`capabilityReady`…`capabilityUnavailable`, `:646-650`) and that a blocked row prints
`Waiting for: <reason>` underneath (`capabilityWaitingFor`, `:652`, rendered
`ModelManagerView.swift:273-279`).

**Consent sheet (either branch, if a download is offered).** Click **Download…** on a row
(`modelsDownload`, `Localization.swift:669`). The alert title is `Install <name>, version <v>?` and its body must show,
verbatim, the file count, total size, source host, **code licence**, **weights licence** and a
16-character SHA-256 prefix, ending with `This is the only step that uses the internet. Nothing is
installed unless every file matches its size and checksum.`
(`modelsConsentBody`, `Localization.swift:726-735`; assembled `ModelManagerView.swift:89-104`).
Ledger §3 **G-UI** records that `licenseEvidenceUrl` is decoded but **never rendered** — so expect
SPDX names only, with **no clickable licence link**. Confirm whether that is acceptable to you as a
user-visible fact, and record what you actually see.

Also observe: **Verify** reports `Checksums match.` or `Checksum mismatch: <file>`
(`:676-677`); **Remove…** warns `The model files are deleted from this Mac. You can download them
again later.` (`:690-692`); a cancelled download says `Download cancelled. Nothing was installed.`
(`:687`); an unverifiable entry reads `Not installable: <reason>` (`:705`) — `sam2.1-hiera-tiny` is
expected to show this.

| # | Evidence |
|---|---|
| 9.1 Branch A: no runtime card, no Download-runtime button | |
| 9.2 Branch A: capabilities show the helper-stopped note | |
| 9.3 Row chips match the real on-disk state | |
| 9.4 Consent sheet shows count/size/host/licences/SHA-16 | |
| 9.5 No licence URL is presented (G-UI as recorded) | |
| 9.6 Verify + Remove behave as worded | |
| 9.7 Branch B (only if a helper is present) | |

---

## 10. Upscale with a large image and the ETA wording

**Flow.** Drive the 4× path and check the promise the sheet makes before it runs.

**Click path.** Open the **large** photo. Press **Export** and set **Long edge** to a value *above*
the photo's own longest side (`exportEnlargementRequested`, `EditorModel.swift:3153-3157`). The
**AI upscale 4×** row then appears (`upscaleSection`, `EditorView.swift:310-344`; toggle label
`Localization.swift:498`). Read the description, switch it on, press **Save…**, and watch the status
line while it tiles.

**Expected observable result.**
- Available case: the row reads `Adds detail with the local Swin2SR model, then trims to the chosen
  edge. Nothing leaves this Mac.` followed by `About N min on this Mac.`
  (`exportUpscaleDetail` + `exportUpscaleEstimate`, `Localization.swift:499-508`). **N is rounded to
  whole minutes with a floor of 1** — the estimate is `12 s + 9.0 s per output megapixel`
  (`Sources/StudioCore/RenderPolicy.swift:46-55`), a developer-machine measurement, so compare the
  wall clock against it and record the difference rather than assuming it is a guarantee.
- Over-ceiling case: with a photo past the 40 MP output ceiling the row stays visible but the toggle
  is **off** and the text becomes `This photo is too large for a 4× pass. The limit is 40 MP of
  output, about 2.5 MP in.` (`exportUpscaleTooLarge`, `:502-504`).
- During the run the status reads `Upscaling X of Y tiles…` (`upscaling`, `:243-245`).
- Refusal cases: no helper → `AI upscale could not run, so nothing was exported. … turn off AI
  upscale to save the photo without it.` (`:512-514`); helper ran but failed →
  `AI upscale failed before any file was written. Nothing was exported; …` (`:517-519`). Either way
  **no file may appear on disk**.

| # | Evidence |
|---|---|
| 10.1 Estimate shown; measured wall time: ______ | |
| 10.2 Tile progress reported while running | |
| 10.3 Output file at the requested long edge, sharper, no artifacts you'd file | |
| 10.4 Too-large photo shows the ceiling text and disables the toggle | |
| 10.5 A refusal writes nothing | |

---

## 11. Export when the disk is nearly full — scoped honestly

**What the source actually contains.** There is **one** capacity gate in the app, and it belongs to
the **AI runtime installer**, not to export: `AIRuntimeInstaller.insufficientDiskFailure(required:)`
compares `volumeAvailableCapacityForImportantUsageKey` against the reservation and, when short,
fails the phase with `Not enough free disk space: installing the AI runtime needs about X free to
download and unpack, and Y is available. Nothing was installed.`
(`Sources/RetouchStudio/Core/AIRuntimeInstaller.swift:166-173`, `:626-632`; text
`Localization.swift:757-759`). It re-checks before verify and before install (`:288`, `:327`), and a
disk that fills *during* unpack surfaces as `The disk filled up while installing the AI runtime.
Nothing was installed.` (`aiRuntimeDiskFull`, `:763-765`) or the ENOSPC mapping in
`AIRuntimeInstallPhase.swift:152-212`.

**Export has no capacity preflight.** `ExportService.swift` contains no space/capacity check, and
`EditorModel.exportPreflight` (`:3431-3438`) only asks the *helper* whether the upscale may run. The
Model Manager's `Free:` figure (`ModelManagerView.swift:191-193`) is display only.

**Therefore:**
- **IN SCOPE (11A):** if a runtime download is offered on your build (§9 Branch A says it will not
  be on the light build), fill the volume near capacity and confirm the refusal text and that nothing
  was installed.
- **OUT OF SCOPE (11B):** "export refuses gracefully when the disk is nearly full" — there is no
  implemented preflight to accept. Do not test it, do not fail it, and do not let anyone write that
  2.0.0 handles low disk space during export. If you want it, it is a feature request, not a defect.

| # | Evidence |
|---|---|
| 11A Runtime-install refusal (skip if no runtime is offered) | |
| 11B Explicitly out of scope — no export capacity preflight exists | |

---

## 12. Persian (Farsi) locale pass

**Flow.** Switch the whole shell to Persian and re-read the numbers.

**Click path.** Menu **Retouch Studio → Language → فارسی** (`App.swift:212-228`), or the language
segment at the top of **Settings**. Then walk: status card → Export sheet → watermark rows → Batch
sheet → Model Manager.

**Expected observable result.**
- Direction flips to right-to-left across the shell (`.environment(\.layoutDirection, …)`,
  `EditorView.swift:34`), and the top-bar undo/redo arrows swap glyphs rather than mirroring
  (`TopBar.swift:21-29`).
- Digits become Persian-Indic `۰-۹` (`Sources/RetouchStudio/Models/Digits.swift:6-24`); percentages
  use `٪` (`Digits.percent`, `:13-16`).
- Units stay Latin: the pixel readout is `۱۲۳۴ × ۵۶۷۸ px` (`EditorModel.swift:3148-3151`), brush size
  `… px` (`ToolPanel.swift:487`), tile progress and the minute estimate
  `حدود N دقیقه روی این مک.` (`PersianL10n.swift:519-522`). The shared byte formatter deliberately
  keeps English unit names — `KB/MB/GB/TB/PB` — with the Persian table converting only the digits,
  because `ByteCountFormatter` cannot pin its locale (`Localization.swift:764-785`, used at
  `PersianL10n.swift:774-775`). Ledger §9 item 6 phrases this as "`MB` stays `MB`; one bidi-isolated
  run". **Caution:** I did not find an explicit Unicode directional-isolation character in the view
  sources, and Model Manager sizes go through `ByteCountFormatter` directly
  (`ModelManagerView.swift:631-639`), which reads the process locale. Treat isolation as
  **NOT VERIFIED** and judge it by what you see: a run like `۱٫۲ GB` must not reorder into `GB ۱٫۲`
  mid-sentence or strand the unit at the wrong end of the line.
- Legibility sweep: caption-size text is `Theme.Font.caption` = 11 pt at
  `Theme.faint = rgb(0.431, 0.431, 0.431)` (`Views/Theme.swift:37,99`) on the dark panel. Walk every
  faint/caption line in Persian — `modelsOfflineNote`, `watermarkNote`, `settingsModelsNote`, the
  capability reasons, the export size lines — and record any that is unreadable, clipped, truncated
  with `…`, or overlaps in RTL. Persian glyph shaping (broken/disconnected letters) is part of this
  check.

| # | Evidence |
|---|---|
| 12.1 Full RTL flip, no mirrored icons except intended | |
| 12.2 Persian digits everywhere numbers appear | |
| 12.3 Latin units preserved and correctly ordered | |
| 12.4 Percent sign renders as ٪ in Persian | |
| 12.5 Caption/faint text legible in Persian | |
| 12.6 No truncation/overlap in sheets at default size | |

---

## 13. Windows — statement, not a test

**Do not attempt any Windows step in this session.** There is no Windows machine in this acceptance
scope, and per ledger §12 Addendum D an actual Windows install on a real desktop is recorded
**NOT VERIFIED**: every Windows artefact comes from a GitHub-hosted runner.

What is true today, from the record: the .NET host builds, packages, installs, upgrades and
uninstalls through MSI in CI, passes **396 headless host checks** and drives the app through
**fourteen UI-automation passes** (`Docs/CI_GATES.md:329`, run `43758837302`). All four catalogue
models are `macos-arm64` and every Windows `job.submit` is refused `-32020` — **there is no AI on
Windows** (ledger §3 G-WIN).

| # | Evidence |
|---|---|
| 13.1 Acknowledged: Windows is CI-only, untested locally in this session | |

---

## 14. Known limitations to expect — do **not** file these as bugs

Each row is sourced; none is a new claim by this document.

1. **No AI on Windows.** Every catalogue model is `macos-arm64` (`Resources/model-catalog.json`: all four
   entries), so Windows `job.submit` → `-32020`.
   — `Docs/RELEASE_2.0.0_READINESS.md` §3 G-WIN, §12 Addendum D.
   *Clarified 2026-11-23, because "no AI" is easy to misread:* the Windows **worker binaries do ship** —
   `AI/RetouchStudio.AI.Worker.exe`, `RetouchStudio.AI.dll` and `onnxruntime.dll` are required by
   `Tools/build-windows.ps1` and are the reason the MSI is 176 MB against a 4.5 MB DMG — and `migan`'s
   `requiredProvider` is `cpu`, not `macos-python`. What does not exist is an approved model for that
   platform and any capability the host will run, so the packaged transport is deliberately inert. Absent
   capability, not a broken one.
2. **Ad-hoc signed, never notarised; Gatekeeper will prompt on other Macs.** Owner decision D4/D5;
   `Docs/RELEASING.md:81,184`. Right-click → Open on first launch is the supported path.
3. **`--noqtn` does not fix Gatekeeper for the downloaded `.app`** — it only covers extracted runtime
   files. Claiming otherwise is listed FALSE. — ledger §7.
4. **Updater disabled and effectively unimplemented in this build.** No feed URL is compiled in;
   `RSUpdateFeedURLs`/`RSUpdateFeedURL` are absent from `Resources/Info.plist`, so the check can only
   fail with "no update feed configured". Manual DMG install is the supported path. — D6,
   `UpdateController.swift:156-162`, ledger §3 G-UPD, §6.
5. **Colour output is sRGB by policy, with no source-profile preservation.** macOS JPEG/PNG declare
   sRGB **without** an embedded ICC profile (TIFF embeds it); wide-gamut input is converted and
   out-of-gamut colours are **clipped**. This is decision W4-4 Option A, not a defect.
   — `Docs/OUTPUT_COLOR_POLICY.md` §Decision; `MacDocumentRenderer.swift:67,97`.
6. **No runtime download in the light build.** `AIRuntime.package` is `nil`
   (`AIRuntime.swift:40`), so Settings offers no runtime card and the AI tools report unavailable.
   — `Docs/AI_RUNTIME.md` §1–§2, `Docs/TECHNICAL_AUDIT.md` addendum (2026-11-09/10).
7. **Consent sheet shows SPDX names only — no licence-evidence URL rendered.** `licenseEvidenceUrl`
   is decoded and validated but never displayed. — ledger §3 **G-UI**.
8. **Catalogue integrity is fail-closed at this head — this row used to say the opposite, and that was
   the stale claim.** *Superseded (2026-11-22, ledger §3 G-INT):* "a pin absent from a manifest is trusted
   rather than refused on the legacy path", citing `catalog.py:330,358,401,418`. *Measured at `5ce98ec` on
   2026-11-23:* those lines no longer hold that shape (`:358` is `REASON_MISSING_SIZE = "missing-size"`,
   `:418` a `json.dumps`); `pin_problem` (`worker/retouch_ai_worker/catalog.py:470`) is documented as "the
   single admission rule", returns `missing-digest` / `invalid-digest` / `missing-size` instead of skipping,
   and is consulted from `catalog.py:1173,1194,1258,1296,1357`, `capabilities.py:150` and `plan.py:56`. All
   four model-load paths call `catalog.require_verified` (`engine.py:884,938,951,971`), which closes the
   "only the upscaler hashes at load" half as well — pinned by
   `test_a_same_length_substitution_fails_the_job_over_rpc` (`worker/tests/test_server.py`), whose comment
   records the old behaviour on `cd5741b`. Landed as PR #115 (`0cf536b`) after adversarial review. **So a
   model whose pin is missing must read `Not installable: …`, never installable: if you see one offered for
   download, that is a NEW failure against this row, not a known limitation.**
9. **`sam2.1-hiera-tiny` is catalogued but not installable** — missing `sam2` runtime package, shown
   as `Not installable: <reason>`. — ledger §3 G-NOC/§4, Addendum A, DR-5.
10. **Generative FLUX work is excluded on 16 GB Apple silicon** (measured 16.7 GB peak) and its pin is
    under re-recording. — ledger §4, Addendum R.3.
11. **First export after boot may differ by ≤1 LSB** because of the cold `com.apple.metal` cache.
    Pre-existing, P3, not a 2.0.0 gate. — ledger §5 (Issue #64).
12. **Intel Macs get the full editor with no AI.** — `Localization.swift:817-819`
    (`aiRuntimeIntelUnavailable`), `Docs/RELEASING.md:121`.
13. **Bundle-notice validation has known bypasses** (un-attributed pinned distribution, empty helper
    notice, removed fonts, uppercase `ALL RIGHTS RESERVED` all exit 0). Not release-blocking while the
    DMG ships no `Contents/Resources/Worker`. — ledger §12 Addendum B, Q.3.
14. **Windows MSI ships no LICENSE/notice file yet.** — ledger §12 Q.3 final paragraph.
15. **Every ledger item still marked NOT VERIFIED that this session can touch:** G-UI (rendered
    consent evidence), G-UPD's *UI* half, "Gatekeeper instructions in the release notes are truthful"
    (§7), G-QA core behaviour on the release artefact (§3), the canvas status-toast placement (§4b), and
    the licence-refusal wording as a user actually reads it. *Corrected 2026-11-23:* this row previously
    called the last item "blocked by PR #99's ownership of the two localisation files" — PR #99 merged as
    `9e43e14` on 2026-11-23, and the sentence itself exists in both tables (`EditorModel.swift:1765` routes
    `-32010` to `aiLicenseBlocked`, defined at `Localization.swift:1368` and overridden at
    `PersianL10n.swift:1240`). What is missing is not code, it is **an eye on the rendered alert** in
    either language. Anything on this list that you do not exercise stays NOT VERIFIED after the session;
    do not let a completed form imply it was covered.
16. **`ModelStore.install` gates on integrity, not on the licence record** (open work item #157, not yet
    a defect you can trigger). Today FLUX is unreachable because its entry is `unverifiableReason`-refused,
    so the consent sheet never offers it — but the download site itself asks only "does the hash match", not
    "does the record permit this use class". Do not read the closure of row 8 as "licence admission is
    enforced at every door": it is enforced at the capability gate and the plan gate, and the install door
    inherits that only as a side effect. If a record with an unsettled use class ever shows an active
    **Download…** chip, that is a FAIL worth reporting.

---

## 15. Defect triage — what to record for any FAIL

For each FAIL, write one block. Nothing more is required, and no bug tracker, label or assignee
should be invented here.

- **Step id** (e.g. `9.4`) and the section title.
- **Exact build**: version `(build)` from About, plus the DMG filename you mounted.
- **Steps replayed**, numbered, using the labels you actually saw on screen.
- **Expected** — quote this document's line.
- **Actual** — quote the app's text character-for-character, including punctuation and digits.
- **Chrome language at the time**: English or Persian (a defect seen only in one table is a
  localisation defect, not an engine defect — say which).
- **Document involved**: the photo's filename and rough pixel size, whether it has a face, and
  whether it came from the phone/camera/stock set. For recovery/export defects also say **the
  destination folder** and whether the file existed beforehand.
- **State**: helper absent or installed, model installed or not, disk roughly full or not.
- **Reproducibility**: once / every time / only after quit-and-relaunch.
- **Artefacts**: screenshot path, and for any write failure the exact error line plus
  `Console.app` output copied while it happened.

Mark a step **NOT RUN** whenever you skipped it, ran out of time, or the precondition was absent
(for example §9 Branch B with no helper). A NOT RUN cell is honest information; an empty cell is not.

---

## 16. Session close-out

Fill in and keep with the RC archive (ledger §3 G-LOG requires the logs and reports preserved
alongside the candidate):

- Tester: ____________ Date: ____________ Start: ______ End: ______
- Build tested: `__________ ( __ )` · DMG: `____________________________`
- Steps PASS: ____ / FAIL: ____ / NOT RUN: ____
- Failures that block publication in my judgement: ____________________
- Signature: ____________

**This form's completion is not a release approval.** Publication remains reserved to the owner
(ledger D7 / DR-3).
