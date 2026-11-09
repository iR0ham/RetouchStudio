# Retouch Studio 1.0.0

First public release. A native, local-first portrait retouching studio for Apple silicon and Intel Macs, with a complete English/Persian interface.

## Highlights

- Twelve tools in one inspector: Skin, Healing, Reshape, Eyes & Teeth, Makeup, Color & Light, Looks, Crop, Body, Background, Stickers and Analysis.
- Non-destructive editing with up to 100 undo steps, saveable `.retouch` projects, user presets and a recovery copy.
- Automatic analysis and Auto Retouch that only move what the measurements justify.
- Local AI tools — remove object, heal area, reimagine and 4× upscale — running on-device through an optional helper that the app downloads (about 390 MB, SHA256-verified) only after approval.
- Export to JPEG, PNG, TIFF or HEIC with long-edge cap, quality, watermark and optional face overlay. GPS and camera identity are removed from exported copies.
- Full English and Persian localisation, including Persian digits, plus hover help on every tool, section and slider.

## Requirements

- macOS 14 Sonoma or later.
- Apple silicon or Intel; each Mac downloads its own light disk image (about 4 MB).
- AI tools require Apple silicon. On first use the model manager offers the local helper runtime after showing the file, its size and its SHA256; models follow, each with its own approval. The editor, analysis, presets and export work on Intel.

## Install

1. Download the image for this Mac: `RetouchStudio-1.0.0-arm64.dmg` for Apple silicon, `RetouchStudio-1.0.0-x86_64.dmg` for Intel.
2. Verify it: `shasum -a 256 -c RetouchStudio-1.0.0-arm64.dmg.sha256` (or the `x86_64` checksum file).
3. Open the disk image and drag `Retouch Studio.app` to the Applications folder.
4. First launch: right-click the app and choose **Open**, or allow it under **System Settings → Privacy & Security → Open Anyway**.

Both images carry the same light app. For AI on Apple silicon, open **Settings → Manage Models…** and approve the runtime download (about 390 MB; the file name, size and SHA256 are shown first), then download the models you need. Prefer a plain archive? `RetouchStudio-1.0.0-universal.zip` holds both architectures without the runtime; verify it the same way and unzip with Finder or `ditto`.

This build is ad-hoc signed and not notarized, so Gatekeeper asks once. No account or subscription is needed, and the editor itself never uses the network.

Checksums:

```
1f86aa173cc6913c3bcc3c5deb93cf755e21e5d15ac02b35810d0df24f649002  RetouchStudio-1.0.0-arm64.dmg
6c8601a298311bfc81eb34f1a13ce847fb85ca8336956618ee22e082d754c3bd  RetouchStudio-1.0.0-x86_64.dmg
708643a8b3b24a3f1a95e6fb825a100000c86c7a666222ce9649ea2eef485565  RetouchStudio-1.0.0-universal.zip
cb1485beecad1bb947f5e3e2e056b0a2783816522c6e6ba90ed25cf069dddcfd  RetouchStudio-1.0.0-ai-runtime-arm64.zip
```

## Local AI

The helper is not part of the app download. On Apple silicon, **Settings → Manage Models…** first offers the runtime: the sheet shows the archive name, its size (about 390 MB) and its SHA256, downloads it from this repository's release page, verifies the hash and installs it under `~/Library/Application Support/RetouchStudio/AI/runtime`. Only then does the model list appear; each model download shows every file, its size, its licence and its SHA256 before anything is fetched. Those two approved downloads are the only actions in the app that use the internet. On Intel the AI tools report that the runtime is unavailable; the rest of the editor works normally.

## Privacy

No telemetry, no analytics, no cloud inference and no automatic uploads. Network use is limited to the two approved downloads above, both verified by SHA256. The network inventory is in `Docs/PRIVACY_AUDIT.md` in the repository.

## Known limitations

- Ad-hoc signature; not notarized.
- AI tools need Apple silicon and the optional runtime download; Intel Macs get the full editor without AI.
- The runtime is about 390 MB to download and about 1.3 GB installed, before any model download.
- Windows and Linux are not supported.
- Very large upscales and generative edits are limited by available memory and take seconds to minutes on an M3.
- No clean-machine install on a second physical Mac has been verified yet.

## License

MIT. See `LICENSE` in the repository. The bundled Vazir typeface is under the SIL Open Font License.
