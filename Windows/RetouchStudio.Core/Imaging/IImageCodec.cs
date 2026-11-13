using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Imaging;

/// <summary>
/// Turns a document into pixels. The Windows host implements this with the
/// platform decoder; the tests use the same implementation so what is tested is
/// what ships.
/// </summary>
public interface IImageCodec
{
    Task<PixelBuffer> DecodeAsync(string path);

    Task EncodeAsync(PixelBuffer image, string path, string format, double quality);
}
