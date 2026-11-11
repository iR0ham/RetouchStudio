# Retouch Studio 1.0.0

> **Document history.** This file has two parts. The first reproduces the
> release-notes text that was present at tag `v1.0.0` (commit `d4e7d58`). The
> second records what happened to this file and to the release assets after the
> tag. The stabilization branch is based on `2d0affc` (the current `main`).

## Release notes at the v1.0.0 tag (commit `d4e7d58`)

First public release. A native, local-first portrait retouching studio for Apple silicon and Intel Macs, with a complete English/Persian interface.

### Highlights

- Twelve tools in one inspector: Skin, Healing, Reshape, Eyes & Teeth, Makeup, Color & Light, Looks, Crop, Body, Background, Stickers and Analysis.
- Non-destructive editing with up to 100 undo steps, saveable `.retouch` projects, user presets and a recovery copy.
- Automatic analysis and Auto Retouch that only move what the measurements justify.
- Local AI tools — remove object, heal area, reimagine and 4× upscale — running on-device through an optional bundled helper.
- Export to JPEG, PNG, TIFF or HEIC with long-edge cap, quality, watermark and optional face overlay. GPS and camera identity are removed from exported copies.
- Full English and Persian localisation, including Persian digits, plus hover help on every tool, section and slider.

### Requirements

- macOS 14 Sonoma or later.
- Apple silicon or Intel; the release is a universal app.
- AI tools require Apple silicon. The editor, analysis, presets and export work on Intel.

### Install

1. Download `RetouchStudio-1.0.0-universal.zip` and its `.sha256` file.
2. Verify the archive: `shasum -a 256 -c RetouchStudio-1.0.0-universal.zip.sha256`.
3. Unzip with Finder or `ditto`, then move `Retouch Studio.app` to `/Applications`.
4. First launch: right-click the app and choose **Open**, or allow it under **System Settings → Privacy & Security → Open Anyway**.

This build is ad-hoc signed and not notarized, so Gatekeeper asks once. No account, subscription or network connection is needed to use the editor.

SHA256 of `RetouchStudio-1.0.0-universal.zip`:

```
8a51d028fa6cfb9c75a880d35bd44f116421f87aee7c5b75b5205873ce4b41f2
```

### Local AI

If this archive includes the helper runtime, the AI tools work on Apple silicon after the models are downloaded. The helper is an Apple-silicon runtime; on Intel the AI tools report that it is unavailable. The download sheet lists every file, its size and its SHA256 before anything is fetched; approving it is the only action in the app that uses the internet. Model weights are not part of this archive and are stored under `~/Library/Application Support/RetouchStudio/AI/models`. Without the helper, the rest of the editor works normally and the AI tools report that the helper is not installed.

### Privacy

No telemetry, no analytics, no cloud inference and no automatic uploads. The measured network inventory is in `Docs/PRIVACY_AUDIT.md` in the repository.

### Known limitations

- Ad-hoc signature; not notarized.
- AI tools need Apple silicon; Intel Macs get the full editor without AI.
- The helper runtime adds roughly 1.3–1.6 GB to the app before any model download.
- Windows and Linux are not supported.
- Very large upscales and generative edits are limited by available memory and take seconds to minutes on an M3.
- No clean-machine install on a second physical Mac has been verified yet.

### License

MIT. See `LICENSE` in the repository. The bundled Vazir typeface is under the SIL Open Font License.

## After the tag: what changed on the stabilization branch

- **The tagged text is the historical record.** Tag `v1.0.0` points at `d4e7d58`, whose release notes are reproduced above: a universal archive, a bundled helper and the `8a51d028…` checksum. `d4e7d58`'s own history is `d82ab45 feat: ship the 1.0.0 public release as a universal build`.
- **The file was rewritten after the tag.** In `c32eb0b` (`feat: download the local AI runtime on demand`), developed on the stabilization branch based on `2d0affc`, `Docs/RELEASE_NOTES_1.0.0.md` was rewritten. The universal-archive section became per-architecture light disk images with a new checksum list and on-demand runtime-download text. That rewritten body describes a later build; it is not the tagged 1.0.0 text. A later note in this file, added by `be79453` (`fix: align runtime support paths and documentation`), called the rewritten body "the historical release record"; that note was inaccurate and has been replaced by this history.
- **The installer is disabled in the current build.** The runtime-download path added in `c32eb0b` remains in the code, but no official protocol-v2 package has been approved: `AIRuntime.package` is nil, Settings offers no runtime download, and no runtime transfer occurs. The `RetouchStudio-1.0.0-ai-runtime-arm64.zip` asset is a legacy archive; it is not treated as a compatible protocol-v2 package, and its compatibility has not been verified.
- **The model consent sheet claim needs a correction.** The tagged text says the download sheet "lists every file, its size and its SHA256". Even at `d4e7d58` the sheet built its message from the file count, total size and licence (`ModelManagerView.swift` called `modelsDownloadBody(files:size:license:)`), not a per-file list or SHA256. The current build still shows count, total size and licence; the runtime sheet, when enabled, shows the archive name, size and a 16-character SHA256 prefix.
- **No binary claim is made here.** This document makes no claim that a published 1.0.0 binary was built from a particular commit, contained the bundled helper, or fetched a runtime. The light-image checksums printed by the later build are not reproduced because this document cannot verify which of them, if any, were published as release assets. `README.md` and `Docs/RELEASING.md` describe the current build and packaging flow.
