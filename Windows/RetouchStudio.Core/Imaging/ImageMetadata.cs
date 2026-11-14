namespace RetouchStudio.Core.Imaging;

/// <summary>
/// The source metadata an export may carry. Values are the primitives the
/// platform metadata API hands back (string, numbers, DateTime, arrays), so
/// this type stays free of WinRT and can be asserted in a headless test.
///
/// The raw blocks are carried because the Windows metadata writer cannot
/// express most EXIF keys: <see cref="ExifTiff"/> is the source TIFF block and
/// <see cref="Xmp"/> the source XMP packet, both copied by the host's container
/// writer after the platform has dropped them. Neither is written verbatim: the
/// orientation is made upright, the pixel dimensions are replaced with the
/// exported frame's and the camera thumbnail is unlinked, so the carried tags
/// describe the file that is actually written.
/// </summary>
public sealed record ImageMetadata(
    IReadOnlyDictionary<string, object> Properties,
    double DpiX = 96,
    double DpiY = 96,
    byte[]? ExifTiff = null,
    byte[]? Xmp = null)
{
    public static ImageMetadata Empty { get; } =
        new(new Dictionary<string, object>(), 96, 96);
}
