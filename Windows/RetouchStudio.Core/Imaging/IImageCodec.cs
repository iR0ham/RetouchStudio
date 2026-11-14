namespace RetouchStudio.Core.Imaging;

/// <summary>
/// Turns a document into pixels. The Windows host implements this with the
/// platform decoder; the tests use the same implementation so what is tested is
/// what ships.
/// </summary>
public interface IImageCodec
{
    Task<PixelBuffer> DecodeAsync(string path);

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
}
