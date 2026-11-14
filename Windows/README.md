# Retouch Studio for Windows

A native Windows host for the same project files the macOS app writes. It is a
light editor, not a port of the macOS feature set: the shared StudioCore rules
(project bytes, versions, unknown fields, undo history, export plan) run behind
the C ABI in `studioscore_core.dll`, and this host owns pixels through the
in-box Windows Imaging Component.

| Project | Role |
| --- | --- |
| `RetouchStudio.Core` | `net10.0`. The C ABI wrapper, the v4 document model, the undo session, the BGRA8 preview buffer and the 16-bit export buffer, crop/orientation/adjustment passes at both depths and the export runner. No WinRT, no WPF. |
| `RetouchStudio.Imaging` | WIC decode and encode through `Windows.Graphics.Imaging`. |
| `RetouchStudio.App` | The WPF window (`net10.0-windows10.0.19041.0`). |
| `RetouchStudio.Tests` | Headless checks against the real DLL and the real WIC codec. |
| `native/studioscore_core.def` | The complete export surface of the DLL. |

## Build

```powershell
pwsh -File Tools/build-windows.ps1
```

Requires a Swift toolchain for Windows (`swiftc.exe` with its `clang.exe` and
`lld`) and the .NET 10 SDK, both on PATH; the CI job installs both. The script

1. builds `Sources/StudioCore` as a static library,
2. links `Sources/StudioCoreABI` into `build/windows/native/studioscore_core.dll`
   with `studioscore_core.def` as the export list, and checks every export when
   `dumpbin` is available,
3. copies the Swift runtime DLLs the app needs next to the exe, so the published
   folder does not require the toolchain,
4. publishes the app self-contained to `build/windows/app` (x64; Intel and AMD
   run the same binary),
5. runs the headless host tests, and
6. starts the published exe and waits for it to open a window.

`Tools/package-windows.ps1 -AppDir build/windows/app -Version 1.0.0` turns that
folder into one zip plus a SHA-256 file.

## What it does

- Opens a JPEG/PNG/TIFF/BMP photo and decodes it upright to sRGB BGRA8, with the
  file's EXIF orientation applied by the decoder.
- Opens and saves the same `.retouch` project bytes as the macOS app, through
  `ProjectCodec`: v3 files are read and rewritten as v3, v4 files keep their
  version, their keyed geometry and every unknown key the file carried.
- Nine global sliders in the same -100…100 range as macOS: exposure, contrast,
  blacks, whites, saturation, vibrance, warmth, clarity, vignette. Undo, redo and
  the dirty flag are the shared `DocumentHistory`, not a host copy.
- Orientation: mirror, clockwise quarter turns and a straighten angle.
- Centred crop presets (square, 4:5, 3:2, 16:9) written as the same normalized
  crop record in photo coordinates that macOS reads.
- Export to JPEG, PNG or TIFF at a chosen long edge, following the `RenderPlan`
  that StudioCore returns: format, pixel size, 8/16-bit depth, alpha flattening
  and colour space are the shared decision, not the host's. A PNG or TIFF plan
  says 16 bits, so that export decodes the source at 16 bits, runs the same
  crop/orientation/adjustment order on the 16-bit buffer and writes 16-bit
  samples; JPEG stays 8-bit.
- Metadata policy: an export keeps only the resolution by default. With
  "Keep camera metadata" on, JPEG, TIFF and 16-bit PNG carry the two keys the
  headless probe proved the Windows writer keeps — camera model and ISO. The
  rest of the EXIF block (make, capture date, exposure, aperture, flash, white
  balance, GPS, comment) is silently dropped by that writer, so it is not
  promised. The pixels are upright, so the orientation tag and the source pixel
  dimensions are never copied.
- Exports never overwrite the opened photo.

## What it does not do

- No AI tools, skin/makeup/scene engines, healing, stickers, presets, batch,
  analysis callouts, watermark or poster export.
- No freeform crop; the presets are the whole crop UI.
- No 16-bit preview or editing path. The preview and the JPEG export work in
  the 8-bit buffer, so a 16-bit source is reduced for display. Only a PNG or
  TIFF export keeps 16-bit samples, and only through the exported document;
  the sliders and the on-screen image are 8-bit.
- No XMP and no IPTC: the Windows metadata API exposes neither, and its EXIF
  writer keeps only the two measured keys, so a kept export carries the camera
  model and ISO only. The 16-bit PNG writer does carry those two keys; an
  8-bit PNG export dropped them in earlier runs, and this host no longer writes
  one.
- No HEIC write (the HEIF codec is an optional system component) and no HEIC
  read path beyond whatever WIC happens to install. The `windows-2025` runner
  has no HEIF decoder, so the probe on the corpus HEIC export fails with
  `0x88982F8B`.
- No recovery store, updater, installer or signing. Packaging is a zip.
- No macOS pixel parity claim. Exposure, blacks, whites, contrast and saturation
  now use the shared scales: against the macOS reference PNGs the host measures
  MAE 0.01 for exposure +40 and 0.007 for blacks +60, while clarity +55 still
  differs (MAE 5.8; CI's unsharp mask is approximated) and vignette +55 differs
  (MAE 5.2). Every measurement is printed by the headless suite; no tolerance is
  approved.

## Pixel semantics

- Preview buffer: tightly packed BGRA8, top-left origin, straight alpha, sRGB.
- Export buffer: tightly packed RGBA16 for PNG and TIFF, the same origin, alpha
  and colour space. Both pipelines use the same formulas and order; a headless
  check renders one image through both and requires them to agree within one
  8-bit level, which is the only difference rounding may introduce.
- Document order: crop in normalized photo coordinates, then orientation
  (mirror, quarter turns, straighten), then the nine global adjustments. The
  crop is stored against the photo, exactly as the shared model says.
- Straighten rotates clockwise for a positive angle, keeps the canvas size and
  samples with clamped edges. The macOS renderer's sign and framing are not
  claimed to match.
- Preview renders the decoded photo resized to a 1600-pixel long edge; export
  re-renders from the full-size decode.
- A crop or a turn changes the frame's aspect, so the plan's pixel size
  describes the whole photo and cannot be applied to the frame. In that case the
  export keeps the frame's aspect and honours the requested long edge instead.

## Why WPF and not WinUI 3

`Docs/WINDOWS_IMPLEMENTATION_PATH.md` recommended a WinUI 3 shell. WPF is
in-box with the .NET SDK, so the published folder needs no Windows App SDK
bootstrapper, no MSIX and no NuGet package, and the same XAML subset costs
nothing in maintenance for a light editor. The decision and its scope are
recorded in that document under "W2 stack deviation"; WinUI 3 remains the
choice to revisit if the Windows host grows past a light editor.

## Verification

The `Windows App` CI job (`.github/workflows/ci.yml`) runs this build, the host
tests and the window smoke check on `windows-2025`. It first ran green on
`28f8462` (PR #14) on 2026-11-13; the step log ends with:

```
-> building studioscore_core.dll
-> checking the DLL export table
   all 13 exports present
-> collecting the Swift runtime
   copied 142 runtime DLLs
-> publishing the WPF host (win-x64, self-contained)
-> running the Windows host tests
WINDOWS HOST TESTS: PASS (55 checks)
-> smoke-running the published app
   the published app loaded its window: 'Retouch Studio' (native handle 262482)
WINDOWS APP BUILD: PASS
```

The tests run against the real `studioscore_core.dll` and the real WIC codec:
v4 project round trips with an unknown key preserved, the shared history rules,
crop/orientation geometry on real pixels, adjustment response, export-plan
decisions, encode-decode and source protection. The smoke check starts the
published, self-contained folder and waits for the loaded window to write its
own marker, because a hosted CI session does not reliably expose a main-window
handle. The first runs of this job exposed a wrong assertion about the shared
undo rule and a missing culture lookup that would have crashed the window on
first layout; both were fixed on the branch before this run.

Since `d0673d8` the job also opens the fixture projects that the macOS app and
the shared conformance suite use, and reports `PASS (69 checks)` on CI run
43534410772. Those 14 checks are the interchange gate: the v3 and v4 fixtures
open here, save back to structurally identical JSON, keep the unknown top-level
key and the required feature, and a v3 file still saves as v3. The comparison is
over parsed JSON, not bytes: key order and whitespace are not part of the
portable contract. The unknown key is asserted
on the save *after* a reopen, because the C ABI hands the host the typed record
and keeps unknown top-level keys in the write context; checking the record
itself would have asserted the wrong thing, which is what the first run caught.

The 16-bit export path landed with `20d3a8c` and reports `PASS (108 checks)` on
CI run [43557855311](https://github.com/iR0ham/RetouchStudio/actions/runs/43557855311).
Those checks read the depth from each written file's own header (PNG IHDR and
TIFF `BitsPerSample` both say 16), require an 8-bit source to promote exactly,
require a no-op 16-bit export to keep every sample and still read back at 8 bits
byte-for-byte, require the 16-bit P3 fixture to export sample-exact, round-trip a
synthetic buffer that is off the 8-bit grid through PNG and TIFF, and find
766 310 of 786 432 colour samples off the 8-bit grid in an adjusted export. The
same run measured the two pipelines against each other on one input: one level
of drift on tone and colour, two on clarity, because the 8-bit blur truncates
on every pass while the 16-bit blur does not.

What this does not prove: pixel parity with the macOS renderer, HEIC, XMP or
IPTC metadata, packaging, an installer, a 16-bit preview or editing path, or
anything on a real desktop session. The run is also recorded in
[`Docs/CI_GATES.md`](../Docs/CI_GATES.md#verified-runs).
