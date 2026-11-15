using System.Globalization;
using System.Text;

namespace RetouchStudio.Imaging;

/// <summary>
/// Composes a canonical little-endian TIFF/EXIF block from the typed metadata a
/// decoder exposes. It exists for sources this host cannot splice a block out
/// of — a TIFF or HEIC photo has no APP1 segment to copy — because the WinRT
/// writer drops most tags on the way back out. Only tags backed by a decoded
/// property are written; nothing is invented, and a source with no usable
/// property yields no block.
///
/// The orientation and the pixel dimensions are placeholders: the export path
/// rewrites both to describe the frame that is actually written, exactly as it
/// does for a carried block.
/// </summary>
public static class ExifComposer
{
    private const ushort TypeByte = 1;
    private const ushort TypeAscii = 2;
    private const ushort TypeShort = 3;
    private const ushort TypeLong = 4;
    private const ushort TypeRational = 5;

    public const ushort TagImageWidth = 0x0100;
    public const ushort TagImageLength = 0x0101;
    public const ushort TagMake = 0x010F;
    public const ushort TagModel = 0x0110;
    public const ushort TagOrientation = 0x0112;
    public const ushort TagXResolution = 0x011A;
    public const ushort TagYResolution = 0x011B;
    public const ushort TagResolutionUnit = 0x0128;
    public const ushort TagSoftware = 0x0131;
    public const ushort TagDateTime = 0x0132;
    public const ushort TagExifIfd = 0x8769;
    public const ushort TagGpsIfd = 0x8825;
    public const ushort TagExposureTime = 0x829A;
    public const ushort TagFNumber = 0x829D;
    public const ushort TagIsoSpeed = 0x8827;
    public const ushort TagDateTimeOriginal = 0x9003;
    public const ushort TagDateTimeDigitized = 0x9004;
    public const ushort TagFlash = 0x9209;
    public const ushort TagFocalLength = 0x920A;
    public const ushort TagPixelXDimension = 0xA002;
    public const ushort TagPixelYDimension = 0xA003;
    public const ushort TagWhiteBalance = 0xA403;
    public const ushort TagLensModel = 0xA434;
    public const ushort TagGpsVersionId = 0x0000;
    public const ushort TagGpsLatitudeRef = 0x0001;
    public const ushort TagGpsLatitude = 0x0002;
    public const ushort TagGpsLongitudeRef = 0x0003;
    public const ushort TagGpsLongitude = 0x0004;
    public const ushort TagGpsAltitudeRef = 0x0005;
    public const ushort TagGpsAltitude = 0x0006;

    /// <summary>
    /// The block, or null when the properties carry nothing this composer can
    /// name. Values the decoder reports are the only inputs; a missing property
    /// leaves its tag out rather than writing a guess.
    /// </summary>
    public static byte[]? Build(IReadOnlyDictionary<string, object> properties,
                                double dpiX, double dpiY)
    {
        var ifd0 = new List<Entry>();
        var exif = new List<Entry>();
        var gps = new List<Entry>();
        var contributed = false;

        contributed |= AddAscii(ifd0, TagMake, Text(properties, "System.Photo.CameraManufacturer"));
        contributed |= AddAscii(ifd0, TagModel, Text(properties, "System.Photo.CameraModel"));
        ifd0.Add(Short(TagOrientation, 1));
        ifd0.Add(Short(TagImageWidth, 1));
        ifd0.Add(Short(TagImageLength, 1));
        ifd0.Add(Rational(TagXResolution, dpiX));
        ifd0.Add(Rational(TagYResolution, dpiY));
        ifd0.Add(Short(TagResolutionUnit, 2));
        ifd0.Add(Ascii(TagSoftware, "Retouch Studio"));

        if (Date(properties, "System.Photo.DateTaken") is { } taken)
        {
            var text = taken.ToString("yyyy:MM:dd HH:mm:ss", CultureInfo.InvariantCulture);
            ifd0.Add(Ascii(TagDateTime, text));
            exif.Add(Ascii(TagDateTimeOriginal, text));
            exif.Add(Ascii(TagDateTimeDigitized, text));
            contributed = true;
        }
        if (Number(properties, "System.Photo.ExposureTime") is { } exposure && exposure > 0)
        {
            exif.Add(Rational(TagExposureTime, exposure));
            contributed = true;
        }
        if (Number(properties, "System.Photo.FNumber") is { } aperture && aperture > 0)
        {
            exif.Add(Rational(TagFNumber, aperture));
            contributed = true;
        }
        if (Integer(properties, "System.Photo.IsoSpeed") is { } iso
            && iso is > 0 and <= ushort.MaxValue)
        {
            exif.Add(Short(TagIsoSpeed, (ushort)iso));
            contributed = true;
        }
        if (Integer(properties, "System.Photo.Flash") is { } flash
            && flash is >= 0 and <= ushort.MaxValue)
        {
            exif.Add(Short(TagFlash, (ushort)flash));
            contributed = true;
        }
        if (Number(properties, "System.Photo.FocalLength") is { } focal && focal > 0)
        {
            exif.Add(Rational(TagFocalLength, focal));
            contributed = true;
        }
        if (Integer(properties, "System.Photo.WhiteBalance") is { } balance
            && balance is >= 0 and <= ushort.MaxValue)
        {
            exif.Add(Short(TagWhiteBalance, (ushort)balance));
            contributed = true;
        }
        contributed |= AddAscii(exif, TagLensModel, Text(properties, "System.Photo.LensModel"));
        // Placeholders; the export path replaces both with the written frame.
        exif.Add(Long(TagPixelXDimension, 1));
        exif.Add(Long(TagPixelYDimension, 1));

        if (Coordinate(properties, "System.GPS.Latitude") is { } latitude)
        {
            AddAscii(gps, TagGpsLatitudeRef, Text(properties, "System.GPS.LatitudeRef") ?? "N");
            gps.Add(CoordinateEntry(TagGpsLatitude, latitude));
            contributed = true;
        }
        if (Coordinate(properties, "System.GPS.Longitude") is { } longitude)
        {
            AddAscii(gps, TagGpsLongitudeRef, Text(properties, "System.GPS.LongitudeRef") ?? "E");
            gps.Add(CoordinateEntry(TagGpsLongitude, longitude));
            contributed = true;
        }
        if (Number(properties, "System.GPS.Altitude") is { } altitude)
        {
            var below = Integer(properties, "System.GPS.AltitudeRef") is 1;
            gps.Add(new Entry(TagGpsAltitudeRef, TypeByte, 1,
                              new[] { (byte)(below ? 1 : 0) }));
            gps.Add(Rational(TagGpsAltitude, Math.Abs(altitude)));
            contributed = true;
        }
        if (gps.Count > 0)
        {
            // The GPS IFD starts with its version; readers use its presence to
            // decide that the IFD follows the EXIF 2.3 layout at all.
            gps.Add(new Entry(TagGpsVersionId, TypeByte, 4, new byte[] { 2, 3, 0, 0 }));
        }

        return contributed ? Serialize(ifd0, exif, gps) : null;
    }

    private readonly record struct Entry(ushort Tag, ushort Type, uint Count, byte[] Value);

    private static byte[] Serialize(List<Entry> ifd0, List<Entry> exif, List<Entry> gps)
    {
        if (exif.Count > 0)
        {
            ifd0.Add(new Entry(TagExifIfd, TypeLong, 1, new byte[4]));
        }
        if (gps.Count > 0)
        {
            ifd0.Add(new Entry(TagGpsIfd, TypeLong, 1, new byte[4]));
        }
        ifd0.Sort((left, right) => left.Tag.CompareTo(right.Tag));
        exif.Sort((left, right) => left.Tag.CompareTo(right.Tag));
        gps.Sort((left, right) => left.Tag.CompareTo(right.Tag));

        const int header = 8;
        var ifd0Offset = header;
        var ifd0Size = Size(ifd0);
        var exifOffset = ifd0Offset + ifd0Size;
        var exifSize = exif.Count > 0 ? Size(exif) : 0;
        var gpsOffset = exifOffset + exifSize;
        var gpsSize = gps.Count > 0 ? Size(gps) : 0;

        if (exif.Count > 0)
        {
            Point(ifd0, TagExifIfd, (uint)exifOffset);
        }
        if (gps.Count > 0)
        {
            Point(ifd0, TagGpsIfd, (uint)gpsOffset);
        }

        var bytes = new byte[gpsOffset + gpsSize];
        bytes[0] = (byte)'I';
        bytes[1] = (byte)'I';
        WriteU16(bytes, 2, 42);
        WriteU32(bytes, 4, (uint)ifd0Offset);
        WriteIfd(bytes, ifd0Offset, ifd0);
        if (exif.Count > 0)
        {
            WriteIfd(bytes, exifOffset, exif);
        }
        if (gps.Count > 0)
        {
            WriteIfd(bytes, gpsOffset, gps);
        }
        return bytes;
    }

    private static int Size(List<Entry> entries)
    {
        var size = 2 + 12 * entries.Count + 4;
        foreach (var entry in entries)
        {
            if (entry.Value.Length > 4)
            {
                size += Align2(entry.Value.Length);
            }
        }
        return size;
    }

    private static void WriteIfd(byte[] bytes, int offset, List<Entry> entries)
    {
        WriteU16(bytes, offset, (ushort)entries.Count);
        var data = offset + 2 + 12 * entries.Count + 4;
        for (var index = 0; index < entries.Count; index++)
        {
            var entry = entries[index];
            var at = offset + 2 + 12 * index;
            WriteU16(bytes, at, entry.Tag);
            WriteU16(bytes, at + 2, entry.Type);
            WriteU32(bytes, at + 4, entry.Count);
            if (entry.Value.Length <= 4)
            {
                entry.Value.CopyTo(bytes, at + 8);
                continue;
            }
            WriteU32(bytes, at + 8, (uint)data);
            entry.Value.CopyTo(bytes, data);
            data += Align2(entry.Value.Length);
        }
        // No next IFD: this block carries no thumbnail.
        WriteU32(bytes, offset + 2 + 12 * entries.Count, 0);
    }

    private static void Point(List<Entry> entries, ushort tag, uint offset)
    {
        for (var index = 0; index < entries.Count; index++)
        {
            if (entries[index].Tag == tag)
            {
                var value = new byte[4];
                WriteU32(value, 0, offset);
                entries[index] = entries[index] with { Value = value };
                return;
            }
        }
    }

    private static int Align2(int length) => length + (length % 2);

    private static bool AddAscii(List<Entry> entries, ushort tag, string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }
        entries.Add(Ascii(tag, text));
        return true;
    }

    private static Entry Ascii(ushort tag, string text)
    {
        var value = new byte[Encoding.ASCII.GetByteCount(text) + 1];
        Encoding.ASCII.GetBytes(text, 0, text.Length, value, 0);
        return new Entry(tag, TypeAscii, (uint)value.Length, value);
    }

    private static Entry Short(ushort tag, ushort value)
    {
        var bytes = new byte[2];
        WriteU16(bytes, 0, value);
        return new Entry(tag, TypeShort, 1, bytes);
    }

    private static Entry Long(ushort tag, uint value)
    {
        var bytes = new byte[4];
        WriteU32(bytes, 0, value);
        return new Entry(tag, TypeLong, 1, bytes);
    }

    private static Entry Rational(ushort tag, double value)
    {
        var bytes = new byte[8];
        var (numerator, denominator) = Fraction(value);
        WriteU32(bytes, 0, numerator);
        WriteU32(bytes, 4, denominator);
        return new Entry(tag, TypeRational, 1, bytes);
    }

    private static Entry CoordinateEntry(ushort tag, (double Degrees, double Minutes, double Seconds) value)
    {
        var bytes = new byte[24];
        var parts = new[] { value.Degrees, value.Minutes, value.Seconds };
        for (var index = 0; index < 3; index++)
        {
            var (numerator, denominator) = Fraction(parts[index]);
            WriteU32(bytes, index * 8, numerator);
            WriteU32(bytes, index * 8 + 4, denominator);
        }
        return new Entry(tag, TypeRational, 3, bytes);
    }

    /// <summary>
    /// A fraction EXIF can hold: a unit fraction below one, otherwise a
    /// ten-thousandth grid reduced to lowest terms. Readers display the value,
    /// so 2.8 must survive as 14/5 rather than 2/1.
    /// </summary>
    private static (uint Numerator, uint Denominator) Fraction(double value)
    {
        if (!(value > 0) || double.IsInfinity(value) || double.IsNaN(value))
        {
            return (0, 1);
        }
        if (value < 1)
        {
            var inverse = Math.Round(1.0 / value);
            if (inverse is >= 1 and <= uint.MaxValue)
            {
                return (1, (uint)inverse);
            }
        }
        var grid = Math.Round(value * 10000);
        if (grid > uint.MaxValue)
        {
            return (uint.MaxValue, 1);
        }
        var numerator = (uint)grid;
        var denominator = 10000u;
        var divisor = Gcd(numerator, denominator);
        return divisor > 1 ? (numerator / divisor, denominator / divisor) : (numerator, denominator);
    }

    private static uint Gcd(uint left, uint right)
    {
        while (right != 0)
        {
            (left, right) = (right, left % right);
        }
        return left;
    }

    private static string? Text(IReadOnlyDictionary<string, object> properties, string key) =>
        properties.TryGetValue(key, out var value) && value is string text && text.Length > 0
            ? text
            : null;

    private static DateTime? Date(IReadOnlyDictionary<string, object> properties, string key) =>
        properties.TryGetValue(key, out var value)
            ? value switch
            {
                DateTime date => date,
                DateTimeOffset offset => offset.DateTime,
                _ => (DateTime?)null,
            }
            : null;

    private static double? Number(IReadOnlyDictionary<string, object> properties, string key) =>
        properties.TryGetValue(key, out var value)
            ? value switch
            {
                double number => number,
                float number => number,
                int number => number,
                uint number => number,
                long number => number,
                ulong number => number,
                short number => number,
                ushort number => number,
                byte number => number,
                decimal number => (double)number,
                _ => (double?)null,
            }
            : null;

    private static int? Integer(IReadOnlyDictionary<string, object> properties, string key) =>
        Number(properties, key) is { } number
        && number >= int.MinValue && number <= int.MaxValue
            ? (int)Math.Round(number)
            : null;

    /// <summary>
    /// The decoder reports a GPS coordinate as degrees, minutes and seconds, or
    /// as one decimal value for some containers; both are accepted, and the
    /// decimal form is split on the usual base-60 grid.
    /// </summary>
    private static (double Degrees, double Minutes, double Seconds)? Coordinate(
        IReadOnlyDictionary<string, object> properties, string key)
    {
        if (!properties.TryGetValue(key, out var value))
        {
            return null;
        }
        if (value is double[] { Length: >= 3 } parts)
        {
            return (parts[0], parts[1], parts[2]);
        }
        if (Number(properties, key) is not { } decimal_)
        {
            return null;
        }
        var absolute = Math.Abs(decimal_);
        var degrees = Math.Floor(absolute);
        var minutes = Math.Floor((absolute - degrees) * 60);
        var seconds = (absolute - degrees - minutes / 60) * 3600;
        return (degrees, minutes, seconds);
    }

    private static void WriteU16(byte[] bytes, int offset, ushort value)
    {
        bytes[offset] = (byte)value;
        bytes[offset + 1] = (byte)(value >> 8);
    }

    private static void WriteU32(byte[] bytes, int offset, uint value)
    {
        bytes[offset] = (byte)value;
        bytes[offset + 1] = (byte)(value >> 8);
        bytes[offset + 2] = (byte)(value >> 16);
        bytes[offset + 3] = (byte)(value >> 24);
    }
}
