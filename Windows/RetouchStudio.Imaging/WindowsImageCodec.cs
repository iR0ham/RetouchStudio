using RetouchStudio.Core.Imaging;
using Windows.Foundation;
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
/// Encoding writes 8-bit files. It carries the camera, capture, GPS and comment
/// keys below when privacy stripping is off and the container supports EXIF
/// (JPEG and TIFF); with stripping on, only the resolution the pixels were
/// written with travels. XMP is not exposed by the Windows metadata API and is
/// never written.
/// </summary>
public sealed class WindowsImageCodec : IImageCodec
{
    // The allowlist, not a denylist: identity and location keys are copied only
    // when the caller asked for them, and anything unknown is dropped.
    private static readonly string[] CarriedProperties =
    {
        "System.Photo.CameraManufacturer", "System.Photo.CameraModel",
        "System.Photo.DateTaken", "System.Photo.ExposureTime",
        "System.Photo.FNumber", "System.Photo.FocalLength",
        "System.Photo.FocalLengthInFilm", "System.Photo.IsoSpeed",
        "System.Photo.ExposureBias", "System.Photo.Flash",
        "System.Photo.MeteringMode", "System.Photo.LightSource",
        "System.Photo.WhiteBalance", "System.Photo.DigitalZoom",
        "System.GPS.Latitude", "System.GPS.Longitude", "System.GPS.Altitude",
        "System.GPS.LatitudeRef", "System.GPS.LongitudeRef",
        "System.GPS.AltitudeRef", "System.Comment",
    };

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

    public async Task<ImageMetadata> ReadMetadataAsync(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
        var decoder = await BitmapDecoder.CreateAsync(stream);

        var found = await decoder.BitmapProperties.GetPropertiesAsync(CarriedProperties);

        var values = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var key in CarriedProperties)
        {
            if (found.TryGetValue(key, out var typed) && typed.Value is not null)
            {
                values[key] = typed.Value;
            }
        }
        // The decoder reports the resolution as a first-class property; the
        // metadata graph does not always expose it under a property key.
        return new ImageMetadata(values, decoder.DpiX, decoder.DpiY);
    }

    public async Task EncodeAsync(PixelBuffer image, string path, string format, double quality,
                                  ImageMetadata? metadata = null, bool stripPrivacyMetadata = true)
    {
        var lower = format.ToLowerInvariant();
        var container = lower switch
        {
            "jpeg" or "jpg" => BitmapEncoder.JpegEncoderId,
            "png" => BitmapEncoder.PngEncoderId,
            "tiff" or "tif" => BitmapEncoder.TiffEncoderId,
            "heic" => throw new NotSupportedException(
                "this host cannot write HEIC; the Windows HEIF codec is an optional system component"),
            _ => throw new NotSupportedException($"the format '{format}' is not supported by this host"),
        };
        var carriesExif = lower is "jpeg" or "jpg" or "tiff" or "tif";

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
            lower is "jpeg" or "jpg" ? BitmapAlphaMode.Ignore : BitmapAlphaMode.Straight,
            (uint)image.Width,
            (uint)image.Height,
            DpiOr96(metadata?.DpiX),
            DpiOr96(metadata?.DpiY),
            image.Pixels);

        var properties = new BitmapPropertySet();
        if (lower is "jpeg" or "jpg")
        {
            properties["ImageQuality"] = new BitmapTypedValue(
                (float)Math.Clamp(quality, 0.0, 1.0), PropertyType.Single);
        }
        if (!stripPrivacyMetadata && carriesExif && metadata is not null)
        {
            foreach (var (key, value) in metadata.Properties)
            {
                if (ToTypedValue(value) is { } typed)
                {
                    properties[key] = typed;
                }
            }
        }
        if (properties.Count > 0)
        {
            // One call, not one per key: a second call replaces the values of
            // the same metadata schema, which would silently drop the keys set
            // by the first. The allowlist is exactly the set the headless test
            // proves a JPEG and a TIFF keep.
            await encoder.BitmapProperties.SetPropertiesAsync(properties);
        }

        await encoder.FlushAsync();
    }

    private static double DpiOr96(double? value) =>
        value is { } dpi && dpi >= 1 && dpi <= 100000 ? dpi : 96;

    /// <summary>
    /// The WinRT encoder takes a typed value, and the source only hands back the
    /// boxed CLR value, so the property type is inferred from the type the
    /// decoder produced.
    /// </summary>
    private static BitmapTypedValue? ToTypedValue(object value) => value switch
    {
        string text => new BitmapTypedValue(text, PropertyType.String),
        double number => new BitmapTypedValue(number, PropertyType.Double),
        float number => new BitmapTypedValue(number, PropertyType.Single),
        ushort number => new BitmapTypedValue(number, PropertyType.UInt16),
        uint number => new BitmapTypedValue(number, PropertyType.UInt32),
        byte number => new BitmapTypedValue(number, PropertyType.UInt8),
        bool flag => new BitmapTypedValue(flag, PropertyType.Boolean),
        DateTime date => new BitmapTypedValue(date, PropertyType.DateTime),
        double[] numbers => new BitmapTypedValue(numbers, PropertyType.DoubleArray),
        string[] texts => new BitmapTypedValue(texts, PropertyType.StringArray),
        _ => null,
    };
}
