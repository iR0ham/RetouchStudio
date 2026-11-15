# Windows format audit (W4-6)

What the Windows host accepts, decodes, writes and carries, format by format.
Every statement below is backed by a check in
`Windows/RetouchStudio.Tests/Program.cs` run headless on `windows-2025`; a
claim with no check behind it is marked NOT VERIFIED here instead of assumed.

The evidence run and its check count are recorded in `Docs/CI_GATES.md`.

## Import and decode

| Container | Read | Depth reported | Notes |
|---|---|---|---|
| JPEG | yes | 8 | WIC decoder; EXIF orientation applied |
| PNG | yes | 8 or 16 from IHDR | 16-bit keeps every sample through the pipeline |
| TIFF | yes | 8 or 16 from `BitsPerSample` | classic TIFF only; BigTIFF reports 8 rather than guessing |
| HEIC | conditional | — | decode needs the optional system HEIF codec; NOT VERIFIED on the runner |
| RAW | no | — | no RAW path exists in any host |

Decoding always produces upright, straight-alpha pixels in sRGB. Two modes of
orientation are distinguished: a container-flagged `Orientation` tag turns the
pixels inside the decoder ("an orientation-6 JPEG decodes upright"), and the
document's own orientation is then applied by the export order, so the two
never multiply.

The depth probe reads the container header, not a metadata property: PNG's IHDR
bit depth and TIFF's `BitsPerSample` ("the PNG header reports the 16-bit
fixture's depth", "a TIFF reports the export's 16 bits"). A BigTIFF or malformed
header reports 8, because a missed 16-bit preview loses a refinement while a
wrong 16-bit claim corrupts nothing visible but everything numeric.

## Colour

- Every decoded photo is colour-managed to sRGB. A Display P3 source is
  converted and stays within 3 levels of the measured sRGB points at 8 bits and
  4 at 16 ("a Display P3 photo is colour-managed to sRGB on decode", "the
  16-bit export path is colour-managed the same way").
- Wide-gamut values outside sRGB are clipped by that conversion. This is the
  same trade-off macOS documents, and it is the known W4-4 gap: the source
  profile is not carried to the output.
- Exports embed a generated ICC v2 sRGB profile instead of relying on
  convention: JPEG as an APP2 `ICC_PROFILE` block, PNG as an `iCCP` chunk
  ("an exported JPEG declares an RGB display profile", "an exported PNG
  declares the same profile bytes"). The profile is not privacy metadata, so it
  is written even when stripping is on ("stripping the source identity keeps the
  colour profile").
- The decoder recognises that profile on read-back and skips a redundant
  conversion, which keeps a no-op export pixel-identical ("a zero-adjustment
  export is pixel-identical", "a 16-bit no-op export reads back at 8 bits
  unchanged"). Any other profile, or none, still converts.
- TIFF is written untagged. A TIFF export keeps every 16-bit sample but
  declares no profile, so a strict reader falls back to convention. This is a
  documented gap, not a claim of completeness.

## Metadata

Two mechanisms travel, and they are not interchangeable:

1. **Pixel format metadata, via the WinRT encoder.** Only keys a headless probe
   proved a JPEG and a TIFF keep are requested. That allowlist is
   `System.Photo.CameraModel` and `System.Photo.IsoSpeed`; the resolution
   travels as a first-class encoder property regardless of stripping.
2. **Container blocks, on Windows only.** With stripping off, the source EXIF
   block and XMP packet are spliced into JPEG and PNG at the container level,
   because the WinRT writer silently drops most EXIF keys and throws on
   `DateTaken`. The source's own EXIF and XMP therefore survive an export that
   the WinRT metadata graph alone could not carry. A JPEG also carries the
   source's IPTC resource (Photoshop APP13, 8BIM 0x0404) byte for byte; the
   other resources in that Photoshop block are not carried, since digests and
   resolution describe the old pixels. PNG and TIFF have no IPTC path here.

The carried EXIF is rewritten to describe the pixels actually written:

- orientation is set to 1 (the pixels are already upright),
- `PixelXDimension`/`PixelYDimension` name the exported frame,
- IFD1 is unlinked so no stale thumbnail travels,
- the result holds through crop, quarter turn and long-edge resize ("a cropped
  export names the cropped frame in EXIF", "a turned export is upright", "a
  resized export is upright").

With stripping on, no EXIF block, XMP packet or IPTC resource is written
("stripping leaves no carried EXIF", "stripping leaves no XMP", "stripping
leaves no IPTC"), and no GPS key appears in the allowlist path. An EXIF or IPTC
block that cannot be parsed is skipped and the export still succeeds ("an
invalid EXIF block is skipped without failing the export", "a malformed IPTC
block is skipped").

Unsupported by design, and therefore absent rather than half-carried: GPS,
`DateTaken`, exposure time, f-number, flash and white balance in the WinRT
metadata graph. Of these, the whole EXIF block (including them) does travel in
JPEG and PNG when the source is a JPEG or PNG that had them, because the
container splice bypasses the WinRT writer. TIFF has no such splice and keeps
only the allowlist.

## Bit depth and containers

| Format | Export depth | Alpha | Metadata path |
|---|---|---|---|
| JPEG | 8, quality from the plan | flattened onto white | WinRT allowlist + EXIF/XMP/IPTC splice |
| PNG | 16 | kept straight | WinRT allowlist + EXIF/XMP splice |
| TIFF | 16 | RGBA written; transparency not verified | WinRT allowlist only |
| HEIC | refused | — | `EncodeAsync` throws `NotSupportedException` |

The plan decides the depth, not the extension: an export asks for 16 bits for
PNG and TIFF ("the plan asks for 16 bits for a PNG") and the host follows it
rather than reducing the preview buffer ("a PNG export stores 16 bits per
sample", "a TIFF export keeps every 16-bit sample"). An 8-bit PNG writer exists
in the codec for the 8-bit path, but the shared plan never requests it, so it is
not a shipping configuration.

## Batch

A batch takes exactly the single-export path (`ExportSourceAsync`): same plan,
same metadata policy, same colour handling. A batch renders identically to the
single export ("a batch renders exactly like the single export"), leaves the
sources untouched ("a batch leaves the sources untouched"), refuses to overwrite
a file it did not create, reports an unreadable source and exports the rest, and
honours cancellation between files ("cancelling a batch stops after the file in
flight", "a cancelled batch starts no later file").

## Not part of this audit

- Windows crash recovery is covered by its own checks in the same suite and by
  `Docs/MASTER_PLAN_REMAINING_WORK.md` (WP-5, R-5, X-5).
- The preview surface is not a container path; it decodes through the same codec
  and is covered by the preview and depth checks.
