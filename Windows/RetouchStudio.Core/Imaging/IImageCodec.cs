namespace RetouchStudio.Core.Imaging;

/// <summary>The upright pixel size of a file, read without decoding pixels.</summary>
public readonly record struct ImageSize(int Width, int Height);

/// <summary>
/// Turns a document into pixels. The Windows host implements this with the
/// platform decoder; the tests use the same implementation so what is tested is
/// what ships.
/// </summary>
public interface IImageCodec
{
    /// <summary>
    /// The upright pixel size, so the export plan can be built (and its bit
    /// depth known) before a buffer of either depth is allocated.
    /// </summary>
    Task<ImageSize> ReadSizeAsync(string path);

    Task<PixelBuffer> DecodeAsync(string path);

    /// <summary>
    /// Decodes at the file's own depth into a 16-bit buffer. The export path
    /// uses it when the plan asks for 16 bits and the container can hold them.
    /// </summary>
    Task<PixelBuffer16> Decode16Async(string path);

    /// <summary>
    /// The carryable source metadata for <paramref name="path"/>, read without
    /// decoding pixels. Empty when the file has none.
    /// </summary>
    Task<ImageMetadata> ReadMetadataAsync(string path);

    /// <summary>
    /// Writes <paramref name="image"/>. With
    /// <paramref name="stripPrivacyMetadata"/> on, the file keeps only the
    /// resolution the pixels were written with; with it off, the carryable
    /// keys in <paramref name="metadata"/> are copied to the destination.
    /// </summary>
    Task EncodeAsync(PixelBuffer image, string path, string format, double quality,
                     ImageMetadata? metadata = null, bool stripPrivacyMetadata = true);

    /// <summary>
    /// Writes 16-bit pixels to a container that stores them (PNG or TIFF).
    /// </summary>
    Task Encode16Async(PixelBuffer16 image, string path, string format,
                       ImageMetadata? metadata = null, bool stripPrivacyMetadata = true);
}
