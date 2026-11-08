# Retouch Studio — Local AI Runtime

**Applies to:** `Retouch Studio.app` 2.1 (build 3), bundle identifier `local.retouchstudio.app`
**Target:** macOS 14.0 or later, Apple silicon (arm64); built and measured on a MacBook Air M3 with 16 GB
**Related:** [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md), [`PHASE5_ACCEPTANCE.md`](PHASE5_ACCEPTANCE.md)

The app and its AI helper are one self-contained bundle. Everything that runs — the retouching engine, the Python helper, PyTorch, Transformers, ONNX Runtime and MLX — is inside the app. Model weights are the only thing downloaded, and only after the owner approves the exact manifest.

---

## 1. What ships, and what does not

| Component | Location | Size |
|---|---|---|
| App, engine and UI | `Contents/MacOS/RetouchStudio` | 5.9 MB |
| Python 3.13.15 + wheels + helper | `Contents/Resources/Worker/` | ~1.29 GiB |
| Typeface (Vazirmatn, SIL OFL) | `Contents/Resources/Fonts/` | ~496 KB |
| **Whole app bundle** | | **~1.31 GiB** |
| Model weights | Not shipped; downloaded by consent | 28 MB – 4.6 GB |

Download sizes from the catalog: FLUX.2 klein 4B q4 — 4.6 GB; SAM 2.1 tiny — ~298 MB on disk; Swin2SR x4 — 48.5 MB; MI-GAN — 28.1 MB. The app works with any subset; a missing model produces a clear “open Manage Models” message instead of a failed job.

The worker is the framework interpreter copied from Homebrew Python 3.13.15, with the Homebrew dylibs it needs (`libssl`, `libcrypto`, `liblzma`, `libmpdec`, `libsqlite3`) relocated into `Worker/lib` and every Mach-O reference rewritten to `@loader_path`. No Homebrew installation is required on the target Mac, and no Mach-O load command in the bundle refers to `/opt/homebrew`. A handful of unused framework scripts (`pip3`, `pydoc3`, `idle3`) and pkg-config files still carry Homebrew shebangs or build paths; the helper never runs them — it is started through the bundled `Python.framework` interpreter.

---

## 2. Install

1. Copy `Retouch Studio.app` to `/Applications` (or anywhere writable).
2. Launch it. On a Mac other than the build machine, macOS may quarantine the ad-hoc signature; if the first launch is refused, right-click the app → **Open**, or clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Retouch Studio.app"
   ```

3. Open **Settings (⌘,) → Manage Models…**, pick the models you need, and approve the download sheet. The sheet lists file count, total size, license and states that this is the only step that uses the internet.
4. When the download finishes, the app is fully usable offline.

There are no launch agents, no background daemons and no login items. The helper starts with the app, lives inside the app bundle, and stops when the app quits normally. After a crash it is left running (or replaced) by the next launch, as described in [`PHASE5_ACCEPTANCE.md`](PHASE5_ACCEPTANCE.md) §3.

### Signature status

The app is signed **ad-hoc** (`codesign --verify --deep --strict` passes; `spctl -a` rejects it, because Gatekeeper only accepts Developer ID signatures). It is not notarized: notarization requires an Apple Developer ID certificate that this project does not have. Consequences:

- The app runs normally on the Mac that built it and on Macs where the owner approves the first launch.
- It cannot be distributed publicly as a “download and double-click” build until it is signed with a Developer ID and notarized.
- The bundle seal is real and is verified after launch, after an edit job and after a download — the helper never writes into the sealed bundle (`PYTHONDONTWRITEBYTECODE=1`).

---

## 3. Offline behaviour

After the models are installed:

- opening a photo, all twelve retouch tools, Auto Retouch, masking, AI edits, 4× upscaling and export are local;
- the helper communicates with the app over a Unix socket in `~/Library/Application Support/RetouchStudio/AI/worker.sock`;
- no network API exists in the app, and the helper's only networking is the downloader (`Downloads` is a separate command that requires consent).

This was measured, not assumed: see [`PRIVACY_AUDIT.md`](PRIVACY_AUDIT.md) §3 — zero TCP/UDP endpoints while idle and during a real upscale job, and exactly two HTTPS connections during an approved download.

If a model file is damaged, `Manage Models… → Verify` reports the mismatched file and the model can be downloaded again. Launch never re-downloads anything on its own.

---

## 4. Where data lives

| Path | Contents |
|---|---|
| `~/Library/Application Support/RetouchStudio/AI/models/` | Installed model weights |
| `~/Library/Application Support/RetouchStudio/AI/jobs/` | Helper working copies and job outputs (cleaned up over time) |
| `~/Library/Application Support/RetouchStudio/AI/download-consent.json` | The approved manifest and its timestamp |
| `~/Library/Application Support/RetouchStudio/AI/helper-owner.json` | Which app instance owns the running helper |
| `~/Library/Application Support/RetouchStudio/AI/worker.log` | Helper stdout/stderr |
| `~/Library/Application Support/RetouchStudio/AI/worker.sock` | Local JSON-RPC socket |

Projects and originals are never modified in place; exports are written where the owner chooses. Private test photos are never read by the helper unless the owner sends that photo to it as part of an edit.

---

## 5. Uninstall

1. Quit the app (the helper stops with it).
2. Delete the app bundle.
3. Delete the data folder:

   ```bash
   rm -rf "$HOME/Library/Application Support/RetouchStudio"
   ```

   This removes downloaded models, job working copies, the consent record, the owner record and logs. Nothing else is installed — no preference panes, no launch agents, no system extensions.

To keep the models but remove everything else, delete everything in that folder except `AI/models`.

---

## 6. Dependencies and licenses

### 6.1 Interpreter and system libraries

| Component | Version | License |
|---|---|---|
| Python | 3.13.15 (Homebrew framework) | PSF-2.0 |
| OpenSSL (`libssl.3`, `libcrypto.3`) | 3.5.x | Apache-2.0 |
| liblzma (`liblzma.5`) | 5.8.x (xz) | 0BSD (the xz CLI is GPL-2.0-or-later and is not shipped) |
| libmpdec (`libmpdec.4`) | 4.0.1 | BSD-2-Clause |
| SQLite (`libsqlite3`) | 3.54.x | Public domain |
| Vazirmatn typeface | bundled | SIL Open Font License 1.1 (`Resources/Fonts/OFL.txt`) |

The corresponding license texts ship inside each wheel's `.dist-info` directory where the package includes one.

### 6.2 Python wheels

71 pinned packages are bundled. The principal ones:

| Package | Version | License |
|---|---|---|
| torch, torchvision | 2.15.0 / 0.29.2 | Apache-2.0 (plus BSD components) |
| transformers | 5.22.1 | Apache-2.0 |
| onnxruntime | 1.31.1 | MIT |
| numpy | 2.5.4 | BSD-3-Clause (bundle of permissive licenses) |
| pillow | 13.0.0 | MIT-CMU |
| mlx, mlx-metal | 0.32.4 | MIT |
| mflux | 0.24.0 | MIT |
| opencv-python | 5.0.0.93 | Apache-2.0 |
| huggingface-hub | 1.33.0 | Apache-2.0 |
| tokenizers | 0.23.3 | Apache-2.0 |
| safetensors | 0.8.0 | Apache-2.0 |
| SAM-2 (`facebookresearch/sam2` @ `2b90b9f`) | git checkout | Apache-2.0 |
| simple-lama-inpainting | 0.1.0 | Apache-2.0 |
| matplotlib, fsspec, protobuf | 3.11.2 / 2026.9.0 / 7.36.2 | PSF-style / BSD-3-Clause / BSD-3-Clause |

The complete pinned list is `RetouchStudio-Phase0/worker/requirements.lock`.

### 6.3 Models

| Model | Role | License | Commercial use |
|---|---|---|---|
| FLUX.2 klein 4B (q4) | Generative edits | Apache-2.0 | Yes |
| SAM 2.1 tiny | Segmentation | Apache-2.0 | Yes |
| Swin2SR x4 | Upscaling | Apache-2.0 | Yes |
| MI-GAN (512, Places2) | Small-hole inpainting | MIT (weights) | Yes |

Weights are downloaded, never redistributed inside the app. Each download is verified against the SHA256 in the catalog when the manifest provides one.

---

## 7. Building from source

Prerequisites: macOS with Xcode Command Line Tools, Homebrew Python 3.13, and the Phase 0 checkout at `~/RetouchStudio-Phase0` (worker source, venv and, for tests, the model weights).

```bash
./build.sh release            # compiles, bundles the runtime, runs the engine self-test, signs ad-hoc
RETOUCH_REBUNDLE=1 ./build.sh release   # force a fresh copy of the Python runtime
./Tests/run.sh                # engine + model tests
cd ~/RetouchStudio-Phase0/worker && ../.venv/bin/python -m unittest discover -s tests   # 57 worker tests
```

Overrides used by the bundler:

- `RETOUCH_WORKER_ROOT` — worker source directory (default `~/RetouchStudio-Phase0/worker`)
- `RETOUCH_WORKER_VENV` — Python environment with the wheels (default `~/RetouchStudio-Phase0/.venv`)
- `RETOUCH_REBUNDLE=1` — ignore the runtime stamp and copy the interpreter again

`Tools/bundle-worker.sh` keeps a stamp of the Python version, the worker source hash and the wheel list in `Worker/.stamp`; an unchanged runtime is reused across builds. It refuses to finish if any Mach-O still refers to `/opt/homebrew`, if a symlink in the runtime is broken, or if a required signature step fails.

> **Build dependency to note:** the worker source currently lives only in `~/RetouchStudio-Phase0/worker`, not in this repository. Building the app from a fresh clone requires that folder (or `RETOUCH_WORKER_ROOT` pointing at a copy). Moving `worker/` and `requirements.lock` into this repository would make the build self-contained; it is listed as a follow-up, not done here.
