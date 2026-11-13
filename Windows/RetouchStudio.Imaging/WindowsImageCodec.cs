using RetouchStudio.Core.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace RetouchStudio.Imaging;

/// <summary>
/// Decode and encode through the Windows Imaging Component. Decoding always
/// produces upright, sRGB, straight-alpha BGRA8: the decoder applies the file's
/// EXIF orientation and converts to sRGB, so the document's own orientation is
/// the only rotation the pipeline adds.
///
/// Encoding writes 8-bit files and copies no metadata. The macOS app can keep
/// 16-bit PNG/TIFF and source metadata; this host cannot yet, and says so in
/// <c>Windows/README.md</c> instead of pretending.
/// </summary>
public sealed class WindowsImageCodec : IImageCodec
{
    public async Task<PixelBuffer> DecodeAsync(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
        var decoder = await BitmapDecoder.CreateAsync(stream);

        var data = await decoder.GetPixelDataAsync(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Straight,
            new BitmapTransform(),
            ExifOrientationMode.RespectExifOrientation,
            ColorManagementMode.ColorManageToSRgb);
        var pixels = data.DetachPixelData();

        // OrientedPixelWidth/Height are the size after EXIF orientation, which
        // is the size GetPixelDataAsync returned. PixelWidth/Height are the
        // stored size and would be swapped for a turned photo.
        var width = checked((int)decoder.OrientedPixelWidth);
        var height = checked((int)decoder.OrientedPixelHeight);
        if ((long)width * height * 4 != pixels.Length)
        {
            throw new InvalidOperationException(
                $"the decoder returned {pixels.Length} bytes for an oriented " +
                $"{width}x{height} image");
        }
        return new PixelBuffer(width, height, pixels);
    }

    public async Task EncodeAsync(PixelBuffer image, string path, string format, double quality)
    {
        var container = format.ToLowerInvariant() switch
        {
            "jpeg" or "jpg" => BitmapEncoder.JpegEncoderId,
            "png" => BitmapEncoder.PngEncoderId,
            "tiff" or "tif" => BitmapEncoder.TiffEncoderId,
            "heic" => throw new NotSupportedException(
                "this host cannot write HEIC; the Windows HEIF codec is an optional system component"),
            _ => throw new NotSupportedException($"the format '{format}' is not supported by this host"),
        };

        var full = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(full)
            ?? throw new InvalidOperationException("the destination has no directory");
        var folder = await StorageFolder.GetFolderFromPathAsync(directory);
        var file = await folder.CreateFileAsync(Path.GetFileName(full),
                                                CreationCollisionOption.ReplaceExisting);
        using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.ReadWrite);

        var encoder = await BitmapEncoder.CreateAsync(container, stream);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8,
            format.Equals("jpeg", StringComparison.OrdinalIgnoreCase) ||
            format.Equals("jpg", StringComparison.OrdinalIgnoreCase)
                ? BitmapAlphaMode.Ignore
                : BitmapAlphaMode.Straight,
            (uint)image.Width,
            (uint)image.Height,
            96,
            96,
            image.Pixels);

        if (format.Equals("jpeg", StringComparison.OrdinalIgnoreCase) ||
            format.Equals("jpg", StringComparison.OrdinalIgnoreCase))
        {
            var properties = new BitmapPropertySet
            {
                ["ImageQuality"] = new BitmapTypedValue(
                    (float)Math.Clamp(quality, 0.0, 1.0), Windows.Foundation.PropertyType.Single),
            };
            await encoder.BitmapProperties.SetPropertiesAsync(properties);
        }

        await encoder.FlushAsync();
    }
}
