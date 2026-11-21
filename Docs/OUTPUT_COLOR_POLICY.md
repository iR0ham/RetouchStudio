# Output colour policy (1.0)

Status: **DECIDED** by the Product Owner on 2026-11-15 (decision W4-4, Option A).
This document states the policy, what each host does to honour it, how it was
verified, and what remains outside it.

## Decision

RetouchStudio 1.0 writes **sRGB** as the output colour space for every export.
The decoded source profile is the working space, not the written profile.

- JPEG and PNG declare sRGB **without embedding an ICC profile** on macOS:
  ImageIO writes a PNG `sRGB` chunk (no `iCCP`) and only an EXIF
  `ColorSpace = 1` tag in JPEG (no APP2 `ICC_PROFILE` block); readers take
  sRGB from those markers. macOS TIFF does embed the canonical sRGB v2
  profile (tag 34675). Windows writes a generated ICC v2.1 profile as a JPEG
  APP2 `ICC_PROFILE` block and a PNG `iCCP` chunk.
- A wide-gamut source (Display P3, Adobe RGB) is converted to sRGB. **Colours
  outside the sRGB gamut are clipped** by that conversion. This is the
  documented trade-off of the policy, not a defect to be discovered later.
- The decision keeps 1.0 output comparable between the two hosts and with the
  golden corpus. Passing a source profile through, or exporting P3
  universally, is a future wide-gamut feature with its own fixtures.

## What the code does

The decision lives in one place per host, so the two entry points (single
export and batch) cannot drift.

| Host | Where | Behaviour |
|---|---|---|
| Shared | [`RenderPolicy.plan`](../Sources/StudioCore/RenderPolicy.swift#L130) | Every plan names `colorSpace: .sRGB`, whether or not the source is wide-gamut. |
| macOS | [`MacDocumentRenderer.write`](../Sources/RetouchStudio/Core/MacDocumentRenderer.swift#L67) | Maps the plan to a concrete `CGColorSpace`. A P3 or grayscale source is drawn into sRGB; an sRGB source keeps its own sRGB-profile space, which leaves its exported bytes exactly as before ([`sRGBOutput`](../Sources/RetouchStudio/Core/MacDocumentRenderer.swift#L97)). |
| Windows | `Windows/RetouchStudio.Core` decoder and encoder | WIC decodes every photo colour-managed to sRGB (the decoder skips a redundant conversion when the source carries the same generated profile), and the encoder writes that profile for JPEG and PNG. |

The macOS identity case exists because the decoded sRGB fixture's colour space
and the canonical sRGB object both carry the same ICC bytes but are not the
same object: drawing into the canonical object moved 5 of 262,144 samples by
one 16-bit step. Keeping the source's own sRGB space holds existing sRGB
exports byte-identical without weakening the policy — the file declares sRGB
either way, by an embedded ICC in TIFF and by the PNG/JPEG markers elsewhere.

## Evidence

- `Docs/IMAGE_ENGINE_CHARACTERIZATION.md` previously recorded that a Display P3
  PNG export kept its P3 profile. That is no longer true on macOS: the F11 case
  now asserts a 16-bit PNG whose pixels decode in sRGB and whose `sRGB` chunk
  declares `sRGB IEC61966-2.1` (`Tests/CorpusTests.swift`, "P3 source PNG
  export is sRGB"); it carries no `iCCP` chunk.
- The mechanism above was measured on 2026-11-21 (macOS 27.2, ImageIO, `main`
  @ `1a5a6f3`) from 8×8 sRGB exports: JPEG had one APP1/EXIF segment and no
  APP2; PNG had an `sRGB` chunk and no `iCCP`; TIFF had ICC tag 34675 holding
  a 3,144-byte sRGB v2.16 profile.
- The only tracked corpus artifact renewed by this decision is
  `Tests/Corpus/Exports/F11_export_256.png`, explicitly authorised by the
  Product Owner. Every other tracked corpus file keeps its previous hash,
  including `F01_export_256.png` and `F01_export_256.tif`, which the identity
  case above leaves untouched. Reference PNGs are not regenerated.
- The ABI plan fixture `Tests/ABI/Fixtures/render-plan.json` now pins
  `"colorSpace": "sRGB"`; the wire shape is unchanged, only the planned value.
- Windows colour behaviour and its measurements are recorded in
  `Docs/WINDOWS_FORMAT_AUDIT.md` ("Colour").

## Extensibility

`RenderColorSpace` still has a `.source` case
([`RenderContract.swift`](../Sources/StudioCore/RenderContract.swift#L112)).
1.0 never plans it, but the macOS writer still honours an explicit profile, so
a future wide-gamut export changes the plan (and adds its own fixtures and
references) rather than the writer. The C ABI exposes the same enum value.

## Not covered

- **TIFF on Windows is untagged.** The policy is sRGB, but the WIC TIFF encoder
  writes no profile; a strict reader falls back to convention. macOS TIFF
  exports embed sRGB. Closing this needs a TIFF writer, not a policy change.
- **Preview, print and PDF paths** are not covered by this policy and are
  **NOT VERIFIED** for wide-gamut sources.
- **HEIC output** follows the same sRGB plan where the encoder exists; the
  Windows HEIC path is refused (no decoder/encoder on the CI image).
- **RAW** sources are absent on both hosts.
