# Retouch Studio

**English** · [فارسی](README.fa.md)

A native macOS portrait-retouching studio with a bilingual English/Persian interface. Everything — analysis, retouching, masking, upscaling and export — runs on the machine. There is no cloud service, no account and no automatic upload.

Built with SwiftUI, Core Image and Vision, and shipped as a self-contained `.app` that does not need Xcode, Homebrew or a separate Python install.

## Highlights

- **Twelve tools in one inspector**: Skin, Healing, Reshape, Eyes & Teeth, Makeup, Color & Light, Looks, Crop, Body, Background, Stickers and Analysis.
- **Non-destructive edits**: every adjustment is a value in a project, so a saved `.retouch` file can be reopened and changed later. Up to 100 steps of undo and redo.
- **Automatic analysis** with a face overlay: skin, eyes, teeth and background are measured, and Auto Retouch only moves what the measurement justifies.
- **Optional local AI helper**: remove an object from a marked region, continue texture over a small area, reimagine the frame from a prompt, or upscale 4×. The models are downloaded on request; nothing is uploaded.
- **Project files and recovery**: `.retouch` projects, editable presets, and a debounced recovery copy while unsaved work exists.
- **Export control**: JPEG, PNG, TIFF or HEIC, long-edge cap, quality slider, watermark, optional face overlay, and GPS/camera identity stripped from the saved copy.
- **Bilingual UI**: complete English and Persian localisation (including Persian digits), switchable in Settings.
- **Hover help everywhere**: every tool, section, icon and slider explains itself in a tooltip.

## Screenshots

![Editor overview](Docs/screenshots/editor.png)

*Smart Analyze and AI Edit on the left, the before/after canvas, and the tool inspector on the right.*

![Painting an AI mask](Docs/screenshots/ai-mask.png)

*Marking a small area for the local inpainting model; brush size, expand and feather are adjustable.*

![Hover help](Docs/screenshots/hover-help.png)

*Every control explains itself on hover — here the AI brush size.*

![AI Models](Docs/screenshots/model-manager.png)

*The model manager lists size, licence and verification state; a download starts only after approval.*

The screenshots use an AI-generated fictional portrait. No personal photo is included in this repository.

## Requirements

- macOS 14 Sonoma or later on Apple silicon or Intel. Releases are published as separate Apple-silicon (arm64) and Intel (x86_64) disk images, plus a universal zip archive.
- AI tools require Apple silicon: the arm64 download carries the helper, while the Intel download leaves it out. On Intel the editor, analysis and export work fully; the AI tools report the helper as unavailable.
- To run a release build: nothing else. The app is self-contained.
- To build from source: Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not required; `build.sh` compiles directly with `swiftc`.

Windows and Linux are not supported: the interface is built on SwiftUI/AppKit and the engine on Core Image and Vision, none of which exist off macOS.

## Run a release build

1. Download the disk image for this Mac — `RetouchStudio-1.0.0-arm64.dmg` for Apple silicon, `RetouchStudio-1.0.0-x86_64.dmg` for Intel — open it and drag `Retouch Studio.app` to Applications. The arm64 image includes the AI helper; the Intel image is the editor only. A universal zip archive is published beside them for anyone who prefers one.
2. First launch: right-click the app and choose **Open**, or allow it under **System Settings → Privacy & Security → Open Anyway**. Release builds are ad-hoc signed and not notarized, so Gatekeeper asks once. See [`Docs/RELEASING.md`](Docs/RELEASING.md) for why and what comes next.

## Build from source

```bash
git clone <repository-url> RetouchStudio
cd RetouchStudio

./build.sh release                       # universal build, self-test, ad-hoc signature
open "Retouch Studio.app"
```

The default build is universal. A single-architecture build is available when the other slice is not needed:

```bash
RETOUCH_ARCH=arm64 ./build.sh release    # Apple silicon only
RETOUCH_ARCH=x86_64 ./build.sh release   # Intel only
```

A universal build runs the self-test natively and then again through the Intel slice (via Rosetta on an Apple-silicon build machine), so a release cannot ship an untested architecture.

The build copies the app into `Retouch Studio.app` in the repository root and stamps the version from `Resources/Info.plist`. A release build can override it without editing a source file:

```bash
RETOUCH_VERSION=1.0.0 RETOUCH_BUILD=1 ./build.sh release
```

Debug build (no optimisation):

```bash
./build.sh debug
```

Package the built app as a drag-to-Applications disk image (the name follows the built architecture):

```bash
./Tools/make-dmg.sh                      # RetouchStudio-<version>-arm64.dmg + checksum

RETOUCH_ARCH=x86_64 RETOUCH_SKIP_WORKER=1 ./build.sh release
./Tools/make-dmg.sh                      # RetouchStudio-<version>-x86_64.dmg + checksum
```

## The local AI helper is optional

The AI tools (remove object, heal area, reimagine, 4× upscale) are executed by a local Python worker. Its source lives in a separate checkout, and the bundler copies a relocatable interpreter plus the required wheels into `Retouch Studio.app/Contents/Resources/Worker` (about 1.3–1.6 GB). Model weights are never bundled; they are downloaded at runtime, after an explicit confirmation, into Application Support.

Without the worker the app still builds and runs; AI tools simply report that the helper is not installed. The bundled runtime is Apple-silicon-only, so an Intel Mac uses the editor without AI even when the helper is present in the bundle; a source checkout with a matching environment can still supply it.

```bash
./build.sh release                                   # bundle the helper if it can be found
RETOUCH_WORKER_ROOT=/path/to/worker \
  RETOUCH_WORKER_VENV=/path/to/venv ./build.sh release   # point at a checkout explicitly
RETOUCH_SKIP_WORKER=1 ./build.sh release             # app only, helper skipped
```

At runtime a source checkout is found by walking up from the executable to a folder containing `worker/retouch_ai_worker`; `RETOUCH_AI_WORKER_ROOT` and `RETOUCH_AI_PYTHON` override that. Details, dependency versions and model licences are in [`Docs/AI_RUNTIME.md`](Docs/AI_RUNTIME.md).

## Tests

```bash
./Tests/run.sh
```

`Tests/run.sh` compiles the whole source tree with `swiftc` and runs two suites against real rendered pixels:

- `EngineTests.swift` — the image pipeline, analysis, geometry, makeup, looks, export and mask behaviour.
- `ModelTests.swift` — project round-trips, presets, settings, localisation completeness and recovery.

The worker has its own Python suite (`unittest`); see `Docs/AI_RUNTIME.md`.

## Privacy

- The app links no networking API. Image analysis, editing, upscaling and export are entirely local.
- The only network use in the whole product is the model downloader, and it runs only after the owner approves the exact manifest (file list, size, SHA256).
- GPS and camera identity are removed from exported copies.
- No telemetry, no analytics, no crash reporting service.

The measured inventory — frameworks, sockets, download consent and the runtime sampling method — is in [`Docs/PRIVACY_AUDIT.md`](Docs/PRIVACY_AUDIT.md).

## Project layout

```
Sources/RetouchStudio/
  App.swift            app entry point and menus
  Core/                rendering engines, analysis, export, AI helper client
  Models/              projects, settings, localisation, presets, model manager
  Views/               editor, inspector, tool panels, overlays, settings
Resources/             Info.plist, app icon, Vazir fonts (OFL)
Tests/                 engine and model suites plus run.sh harness
Tools/                 bundle-worker.sh (optional Python runtime), make-dmg.sh
Docs/                  AI runtime, privacy audit, technical audit, release notes
build.sh               compile + assemble + sign + self-test
```

## Documentation

| Document | Contents |
|---|---|
| [`Docs/AI_RUNTIME.md`](Docs/AI_RUNTIME.md) | Helper architecture, dependencies, model catalogue and licences |
| [`Docs/PRIVACY_AUDIT.md`](Docs/PRIVACY_AUDIT.md) | Network inventory and consent model |
| [`Docs/PHASE5_ACCEPTANCE.md`](Docs/PHASE5_ACCEPTANCE.md) | What was verified for the packaged AI runtime |
| [`Docs/TECHNICAL_AUDIT.md`](Docs/TECHNICAL_AUDIT.md) | Engine and UI audit findings |
| [`Docs/STABILIZATION_PLAN.md`](Docs/STABILIZATION_PLAN.md) | Stabilization scope and acceptance criteria |
| [`Docs/RELEASING.md`](Docs/RELEASING.md) | Versioning, signing, packaging and publishing checklist |
| [`Docs/RELEASE_NOTES_1.0.0.md`](Docs/RELEASE_NOTES_1.0.0.md) | Draft release notes for the first public build |

## License

MIT — see [`LICENSE`](LICENSE). The bundled Vazir typeface is distributed under the SIL Open Font License (see `Resources/Fonts/OFL.txt`). Model weights are downloaded by the user and carry their own licences, listed in `Docs/AI_RUNTIME.md`.
