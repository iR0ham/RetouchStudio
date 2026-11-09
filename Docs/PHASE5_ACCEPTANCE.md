# Retouch Studio — Phase 5 Acceptance Report

**Phase:** Packaging, model manager, privacy hardening, release candidate
**Date:** 2026-11-07
**Build:** `Retouch Studio.app` 2.1 (build 3), `local.retouchstudio.app`, assembled by `./build.sh release`
**Environment:** MacBook Air M3, 16 GB RAM, macOS 26.6.2 (arm64)
**Related:** [`AI_RUNTIME.md`](AI_RUNTIME.md), [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md)
**Worker suite:** 57 tests, in the separate worker checkout (outside this repository).

Every item marked **Pass** below was executed on the build named above. Items that could not be executed on this machine are marked **Not verified** and are not claimed as done.

---

## 1. Acceptance matrix

| # | Requirement | Evidence | Result |
|---|---|---|---|
| 1 | The app ships its own AI runtime; no Homebrew, venv or terminal step on the target Mac | `Contents/Resources/Worker` holds Python 3.13.15, the helper package and 71 wheels. Every Mach-O reference to `/opt/homebrew` was rewritten (`relinked 12 Homebrew reference(s)`), and a Mach-O load-command scan finds none remaining | **Pass** |
| 2 | The bundled runtime imports and runs outside the build environment | `env -i` import of `lzma`, `ssl`, `sqlite3`, `decimal`, `numpy`, `PIL`, `torch`, `transformers`, `onnxruntime`, `mlx`, `mflux` succeeds; `_ssl`, `_sqlite3`, `_hashlib`, `_lzma`, `_decimal` and `zlib` report paths inside the bundle; their dylib deps are `@loader_path` | **Pass** |
| 3 | The app launches the bundled helper, not a development one | Process command line is `.../Retouch Studio.app/Contents/Resources/Worker/.../Python -m retouch_ai_worker serve`; `helper-owner.json` records the matching app and worker PIDs | **Pass** |
| 4 | The bundle verifies after build, after launch, after an AI job and after a download | `codesign --verify --deep --strict` → `valid on disk` / `satisfies its Designated Requirement` at all four points; zero `__pycache__` directories in the bundle | **Pass** |
| 5 | Every embedded Mach-O is signed | All Mach-O files under `Contents/Resources/Worker` respond to `codesign -dv`; unsigned count 0 | **Pass** |
| 6 | Gatekeeper accepts the app | `spctl -a -vv` → `rejected`; the signature is ad-hoc because no Developer ID certificate exists. Documented as a limitation in [`AI_RUNTIME.md`](AI_RUNTIME.md) §2 | **Not verified (blocked by certificate)** |
| 7 | Install → download → edit → export without terminal steps | Model download, consent sheet, download progress and completion were driven through the UI; editing itself uses the same paths verified in earlier phases. A clean second Mac was not available | **Partially verified** |
| 8 | The app runs from a different location | Copied the signed bundle to `/tmp/RS-relocated.app`: signature still valid, helper started from the copy, `health` → `ok`, real Swin2SR job → `succeeded` (256×256, `mps`, 0.46 s) | **Pass** |
| 9 | Model manager: list, license, size, verify, consent, download, remove, re-download | See §2 — live UI session | **Pass** |
| 10 | Downloads require explicit consent and verify checksums | Consent sheet text, manifest hash matching, SHA256 verification, staged/atomic install; see §2 and [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md) §2.3 | **Pass** |
| 11 | No outbound request except user-initiated downloads | See [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md) §3: zero sockets while idle and during a real job; exactly two HTTPS connections during an approved download | **Pass** |
| 12 | Crash/OOM recovery; launch self-test | See §3 — helper restart, stale-owner takeover and launch health check | **Pass** |
| 13 | Uninstall leaves nothing behind | The app is self-contained: no launch agents, no daemons, no login items; all state is under `~/Library/Application Support/RetouchStudio`. Removal steps are documented in [`AI_RUNTIME.md`](AI_RUNTIME.md) §5. The destructive step was **not** executed on the owner's real data because it would delete the installed models | **Documented, not executed** |
| 14 | Engine and worker suites pass on the final tree | `ENGINE TESTS: PASS`, `MODEL TESTS: PASS`, worker `Ran 57 tests ... OK`, `build.sh` processing self-test passes | **Pass** |
| 15 | Documentation covers licenses, consent, offline behavior and uninstall | [`AI_RUNTIME.md`](AI_RUNTIME.md), [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md), this report | **Pass** |

---

## 2. Model manager — measured session

Performed through **Settings (⌘,) → Manage Models…** on the release app.

| Step | Observed |
|---|---|
| Open the sheet | Four models listed with task, license and size; installed models carry an “Installed” chip |
| Verify | Result: “Checksums match.” (MI-GAN’s on-disk SHA256 `6f1f3530…c40b` matched the catalog and the retained backup) |
| Re-download with consent | Alert: “1 file, 28.1 MB. License: MIT. This is the only step that uses the internet.” — the sheet only proceeds on approval |
| Progress | Live percentage `0 → 97 → 100 %`, driven by the downloader’s JSON progress stream |
| Completion | “MI-GAN (512, Places2) is installed.” |
| Remove | Confirmation alert; the row changes to “Not installed” and the file leaves the models folder |
| Plain Download again | Model reinstalled; same checksum verified |

Consent is bound to the manifest the owner saw: the RPC `models.plan` hash and the CLI `models download --consent-hash` value were identical for MI-GAN (`9d70e718…`). If the catalog changes in between, the downloader refuses instead of installing something else.

The sheet was also checked for pluralisation: a one-file model now reads “1 file, 28.1 MB…”, not “1 files”.

---

## 3. Crash recovery — measured session

| Scenario | Observed |
|---|---|
| Normal launch | Log line: `AI self-test: helper ready, 4 installed model(s), health ok`; `health` is a size check, not a full hash, so it finishes behind the first paint |
| Helper killed while the app runs | Pressing Verify started a new helper in place (PID 48083 → 48138) and the call succeeded on the retry; checksums matched |
| App killed with SIGKILL | Helper stayed alive with a dead-owner record, by design, so a restarted app can adopt or replace it |
| App relaunched | The stale helper was shut down and replaced (new PID 47354); `helper-owner.json` rewritten with the new pair |
| App terminated with SIGTERM | The helper also stayed alive (the signal does not run the app's quit path) and held the socket; the next launch replaces it, which is the same recovery path as SIGKILL |
| Quit from the app | `AIWorker.terminate()` shuts the helper down and removes the owner record (code path; not separately re-run in this session) |

At launch the app also deletes helper working copies under its temp root older than one day, and removes the socket of a dead helper before starting a new one.

---

## 4. Bundle measurements

| Measurement | Value |
|---|---|
| App bundle | 1,374,352 KB (~1.31 GiB) |
| Bundled runtime (`Contents/Resources/Worker`) | 1,356,984 KB (~1.29 GiB) |
| App binary | 5.9 MB |
| Fonts (Vazirmatn, OFL) | 496 KB |
| Bundled wheels | 71 pinned packages |
| Homebrew dylib references | 12 rewritten; 0 remain |
| Broken symlinks | 0 |
| Signature | ad-hoc; `codesign --verify --deep --strict` passes |
| Gatekeeper | rejected (no Developer ID / notarization) |

A real 4× upscale of a 64×64 test image through the packaged runtime: output 256×256, device `mps`, compute 0.46–2.37 s across runs, whole job 5–7 s including model load and socket round-trips. These are single-machine observations, not benchmarks.

---

## 5. Known limitations and follow-ups

1. **Notarization is impossible in this project as it stands.** The app is ad-hoc signed. Public distribution needs an Apple Developer ID certificate and `notarytool` submission; neither exists here. The app runs on this Mac and on Macs where the owner approves the first launch.
2. **No second physical Mac was used.** Relocation was verified locally by copying the bundle to `/tmp`; a true clean-machine install (fresh account, no Homebrew, Gatekeeper path) remains a release follow-up.
3. **Bundle size.** The runtime is ~1.3 GiB before models. This is the cost of shipping a Python helper; Phase 6 (native migration) is the long-term answer and is explicitly gated on quality parity.
4. **Worker source lives outside this repository.** The helper is bundled when `RETOUCH_WORKER_ROOT` and `RETOUCH_WORKER_VENV` point at a separate checkout. Builds do not require it: without the helper the app still compiles and runs, and the AI tools report it as missing. Moving the worker in-repo is recommended but was not part of this task.
5. **Disk use.** Downloaded models are 28 MB–4.6 GB depending on selection; they are user data under Application Support and are removed by the documented uninstall.

---

## 6. Reproduce

```bash
./build.sh release
codesign --verify --deep --strict "Retouch Studio.app"
./Tests/run.sh
cd "$RETOUCH_WORKER_ROOT" && ../.venv/bin/python -m unittest discover -s tests

# Runtime checks
RETOUCH_AI_MODELS="/path/to/models" \
  "Retouch Studio.app/Contents/MacOS/RetouchStudio" &
# then: lsof audit, health RPC, upscale job — see PRIVACY_AUDIT.md §5
```

Expected: build self-test passes; signature verifies; both Swift suites and all 57 worker tests pass; idle and job windows show no sockets; only an approved download opens HTTPS connections.
