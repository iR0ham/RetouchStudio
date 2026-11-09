# Retouch Studio 1.0.0

First public release. A native, local-first portrait retouching studio for Apple silicon and Intel Macs, with a complete English/Persian interface.

## Highlights

- Twelve tools in one inspector: Skin, Healing, Reshape, Eyes & Teeth, Makeup, Color & Light, Looks, Crop, Body, Background, Stickers and Analysis.
- Non-destructive editing with up to 100 undo steps, saveable `.retouch` projects, user presets and a recovery copy.
- Automatic analysis and Auto Retouch that only move what the measurements justify.
- Local AI tools — remove object, heal area, reimagine and 4× upscale — running on-device through an optional bundled helper.
- Export to JPEG, PNG, TIFF or HEIC with long-edge cap, quality, watermark and optional face overlay. GPS and camera identity are removed from exported copies.
- Full English and Persian localisation, including Persian digits, plus hover help on every tool, section and slider.

## Requirements

- macOS 14 Sonoma or later.
- Apple silicon or Intel; the release is a universal app.
- AI tools require Apple silicon. The editor, analysis, presets and export work on Intel.

## Install

1. Download `RetouchStudio-1.0.0-universal.dmg` and its `.sha256` file.
2. Verify the image: `shasum -a 256 -c RetouchStudio-1.0.0-universal.dmg.sha256`.
3. Open the disk image and drag `Retouch Studio.app` to the Applications folder.
4. First launch: right-click the app and choose **Open**, or allow it under **System Settings → Privacy & Security → Open Anyway**.

Prefer a plain archive? `RetouchStudio-1.0.0-universal.zip` is published beside the DMG; verify it the same way and unzip with Finder or `ditto`. Both packages hold the same universal app, so one download serves Apple silicon and Intel.

This build is ad-hoc signed and not notarized, so Gatekeeper asks once. No account, subscription or network connection is needed to use the editor.

Checksums:

```
23de31d51aca1d18a689d22eb7d8ad1b815af6a43f66d9c73ba8caab6f921147  RetouchStudio-1.0.0-universal.dmg
8a51d028fa6cfb9c75a880d35bd44f116421f87aee7c5b75b5205873ce4b41f2  RetouchStudio-1.0.0-universal.zip
```

## Local AI

If this archive includes the helper runtime, the AI tools work on Apple silicon after the models are downloaded. The helper is an Apple-silicon runtime; on Intel the AI tools report that it is unavailable. The download sheet lists every file, its size and its SHA256 before anything is fetched; approving it is the only action in the app that uses the internet. Model weights are not part of this archive and are stored under `~/Library/Application Support/RetouchStudio/AI/models`. Without the helper, the rest of the editor works normally and the AI tools report that the helper is not installed.

## Privacy

No telemetry, no analytics, no cloud inference and no automatic uploads. The measured network inventory is in `Docs/PRIVACY_AUDIT.md` in the repository.

## Known limitations

- Ad-hoc signature; not notarized.
- AI tools need Apple silicon; Intel Macs get the full editor without AI.
- The helper runtime adds roughly 1.3–1.6 GB to the app before any model download.
- Windows and Linux are not supported.
- Very large upscales and generative edits are limited by available memory and take seconds to minutes on an M3.
- No clean-machine install on a second physical Mac has been verified yet.

## License

MIT. See `LICENSE` in the repository. The bundled Vazir typeface is under the SIL Open Font License.
