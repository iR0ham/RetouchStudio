namespace RetouchStudio.Core.Imaging;

/// <summary>
/// The source metadata an export may carry. Values are the primitives the
/// platform metadata API hands back (string, numbers, DateTime, arrays), so
/// this type stays free of WinRT and can be asserted in a headless test.
/// Orientation and pixel dimensions are never stored: the pipeline writes
/// upright pixels, so those tags describe a file that no longer exists.
/// </summary>
public sealed record ImageMetadata(
    IReadOnlyDictionary<string, object> Properties,
    double DpiX = 96,
    double DpiY = 96)
{
    public static ImageMetadata Empty { get; } =
        new(new Dictionary<string, object>(), 96, 96);
}
