using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace RetouchStudio.Imaging;

/// <summary>
/// Carries the source EXIF block, XMP packet and IPTC resource into an encoded
/// file at the container level. The WinRT metadata writer silently drops most
/// EXIF keys, so the block travels as bytes instead: the TIFF structure is
/// patched in place (orientation made upright, the frame's dimensions replaced,
/// the thumbnail unlinked) and spliced into a JPEG APP1 or a PNG eXIf chunk.
/// IPTC travels in a JPEG APP13 Photoshop block; PNG has no container this
/// writer puts it in. Every reader is bounds-checked; a block that fails
/// validation is skipped, never guessed at, so a malformed photo cannot
/// corrupt an export.
/// </summary>
public static class MetadataCarry
{
    /// <summary>One JPEG APP1 payload, minus the six-byte Exif signature.</summary>
    public const int MaxExifBytes = 65527;

    /// <summary>An XMP packet larger than this is dropped rather than written.</summary>
    public const int MaxXmpBytes = 1 << 20;

    /// <summary>
    /// The largest APP13 payload, minus the fourteen-byte Photoshop signature.
    /// </summary>
    public const int MaxIptcBytes = 65519;

    /// <summary>An ICC profile larger than this is dropped rather than written.</summary>
    public const int MaxIccBytes = 1 << 22;

    /// <summary>The largest profile slice one JPEG APP2 segment can carry.</summary>
    public const int MaxIccChunkBytes = 65519;

    private static readonly byte[] IccSignature =
    {
        (byte)'I', (byte)'C', (byte)'C', (byte)'_', (byte)'P', (byte)'R',
        (byte)'O', (byte)'F', (byte)'I', (byte)'L', (byte)'E', 0,
    };

    private const string IccProfileName = "sRGB";

    private const int TagOrientation = 0x0112;
    private const int TagImageWidth = 0x0100;
    private const int TagImageLength = 0x0101;
    private const int TagExifIfd = 0x8769;
    private const int TagPixelXDimension = 0xA002;
    private const int TagPixelYDimension = 0xA003;

    private static readonly byte[] ExifSignature =
        { (byte)'E', (byte)'x', (byte)'i', (byte)'f', 0, 0 };

    private static readonly byte[] XmpSignature =
        Encoding.ASCII.GetBytes("http://ns.adobe.com/xap/1.0/\0");

    private static readonly byte[] IptcSignature = Encoding.ASCII.GetBytes("Photoshop 3.0\0");

    private static readonly byte[] ResourceSignature =
        { (byte)'8', (byte)'B', (byte)'I', (byte)'M' };

    private const int IptcResourceId = 0x0404;

    private static readonly byte[] PngTextKeyword = Encoding.ASCII.GetBytes("XML:com.adobe.xmp");

    private static readonly uint[] CrcTable = BuildCrcTable();

    /// <summary>The TIFF block of a JPEG APP1 Exif segment or a PNG eXIf chunk, or null.</summary>
    public static byte[]? ReadExif(string path)
    {
        var file = File.ReadAllBytes(Path.GetFullPath(path));
        if (IsJpeg(file))
        {
            return ReadJpegSegment(file, ExifSignature, MaxExifBytes);
        }
        if (IsPng(file))
        {
            return ReadPngChunk(file, "eXIf", MaxExifBytes);
        }
        return null;
    }

    /// <summary>The XMP packet of a JPEG APP1 segment or a PNG iTXt chunk, or null.</summary>
    public static byte[]? ReadXmp(string path)
    {
        var file = File.ReadAllBytes(Path.GetFullPath(path));
        if (IsJpeg(file))
        {
            return ReadJpegSegment(file, XmpSignature, MaxXmpBytes);
        }
        if (IsPng(file))
        {
            return ReadPngXmp(file);
        }
        return null;
    }

    /// <summary>
    /// The IPTC resource (Photoshop 8BIM 0x0404) of a JPEG APP13 segment, or
    /// null when the file carries none or the block is malformed. Returns the
    /// resource record itself, so a writer can put it back byte for byte.
    /// </summary>
    public static byte[]? ReadIptc(string path)
    {
        var file = File.ReadAllBytes(Path.GetFullPath(path));
        return IsJpeg(file) ? ReadJpegIptc(file) : null;
    }

    /// <summary>
    /// Copies a source TIFF block with the orientation set upright, the frame
    /// dimensions replaced and the next IFD (the thumbnail) unlinked. Returns
    /// null when the block is not a TIFF structure this writer can trust.
    /// </summary>
    public static byte[]? NormalizeExif(byte[] tiff, int width, int height)
    {
        if (tiff.Length < 8 || width <= 0 || height <= 0 || tiff.Length > MaxExifBytes)
        {
            return null;
        }
        var little = tiff[0] == (byte)'I' && tiff[1] == (byte)'I';
        var big = tiff[0] == (byte)'M' && tiff[1] == (byte)'M';
        if (!little && !big)
        {
            return null;
        }
        if (ReadU16(tiff, 2, little) != 42)
        {
            return null;
        }
        var ifd0 = ReadU32(tiff, 4, little);
        if (ifd0 < 8 || ifd0 > int.MaxValue || (long)ifd0 + 2 > tiff.Length)
        {
            return null;
        }
        var count = ReadU16(tiff, (int)ifd0, little);
        if (count > 4096 || (long)ifd0 + 2 + 12L * count + 4 > tiff.Length)
        {
            return null;
        }

        var copy = (byte[])tiff.Clone();
        uint? exifIfd = null;
        for (var index = 0; index < count; index++)
        {
            var entry = (int)ifd0 + 2 + 12 * index;
            var tag = ReadU16(copy, entry, little);
            switch (tag)
            {
                case TagOrientation:
                    SetShortValue(copy, entry, little, 1);
                    break;
                case TagImageWidth:
                    SetDimension(copy, entry, little, width);
                    break;
                case TagImageLength:
                    SetDimension(copy, entry, little, height);
                    break;
                case TagExifIfd when ReadU16(copy, entry + 2, little) == 4
                                     && ReadU32(copy, entry + 4, little) >= 1:
                    exifIfd = ReadU32(copy, entry + 8, little);
                    break;
            }
        }

        // IFD1 holds the camera's thumbnail, which describes the file as it was
        // before the crop and the turn. Unlinking it drops the stale image
        // without moving any data the in-block offsets point at.
        WriteU32(copy, (int)ifd0 + 2 + 12 * count, 0, little);

        if (exifIfd is { } pointer)
        {
            PatchExifSubIfd(copy, pointer, little, width, height);
        }
        return copy;
    }

    /// <summary>
    /// An XMP packet with <c>tiff:Orientation</c> set upright, or null when the
    /// packet is too large to carry. Properties the packet does not state are
    /// left alone: this is a correction, not a rewrite.
    /// </summary>
    public static byte[]? NormalizeXmp(byte[] xmp)
    {
        if (xmp.Length == 0 || xmp.Length > MaxXmpBytes)
        {
            return null;
        }
        var text = Encoding.UTF8.GetString(xmp);
        var patched = Regex.Replace(
            text,
            "(tiff:Orientation\\s*=\\s*\")([1-8])(\")",
            "${1}1${3}",
            RegexOptions.None,
            TimeSpan.FromSeconds(2));
        return Encoding.UTF8.GetBytes(patched);
    }

    /// <summary>
    /// Replaces the JPEG's Exif and XMP APP1 segments, its IPTC APP13 block and
    /// its ICC profile APP2 segments with the supplied blocks. The file is left
    /// untouched when it is not a complete JPEG or a segment is malformed; the
    /// rewrite goes through a temporary file so an interrupted write cannot
    /// leave a half-file behind.
    /// </summary>
    public static void WriteJpeg(string path, byte[]? exif, byte[]? xmp, byte[]? icc = null,
                                 byte[]? iptc = null)
    {
        var full = Path.GetFullPath(path);
        var file = File.ReadAllBytes(full);
        if (!IsJpeg(file))
        {
            return;
        }
        var writeExif = exif is { Length: > 0 }
                        && exif.Length + ExifSignature.Length + 2 <= ushort.MaxValue;
        var writeXmp = xmp is { Length: > 0 }
                       && xmp.Length + XmpSignature.Length + 2 <= ushort.MaxValue;
        var writeIptc = iptc is { Length: > 0 }
                        && iptc.Length + IptcSignature.Length + 2 <= ushort.MaxValue;
        var writeIcc = icc is { Length: > 0 } && icc.Length <= MaxIccBytes;
        if (!writeExif && !writeXmp && !writeIptc && !writeIcc)
        {
            return;
        }

        using var output = new MemoryStream(
            file.Length + (exif?.Length ?? 0) + (xmp?.Length ?? 0) + (iptc?.Length ?? 0) + 64);
        output.WriteByte(0xFF);
        output.WriteByte(0xD8);
        var inserted = false;
        var index = 2;
        var reachesScan = false;
        while (index + 4 <= file.Length)
        {
            if (file[index] != 0xFF)
            {
                return;
            }
            var marker = file[index + 1];
            if (marker == 0xDA)
            {
                reachesScan = true;
                break;
            }
            var length = (file[index + 2] << 8) | file[index + 3];
            if (length < 2 || index + 2 + length > file.Length)
            {
                return;
            }
            var isExif = writeExif && marker == 0xE1
                         && StartsWith(file, index + 4, length - 2, ExifSignature);
            var isXmp = writeXmp && marker == 0xE1
                        && StartsWith(file, index + 4, length - 2, XmpSignature);
            var isIptc = writeIptc && marker == 0xED
                         && StartsWith(file, index + 4, length - 2, IptcSignature);
            var isIcc = writeIcc && marker == 0xE2
                        && StartsWith(file, index + 4, length - 2, IccSignature);
            if (!isExif && !isXmp && !isIptc && !isIcc)
            {
                output.Write(file, index, 2 + length);
            }
            if (marker == 0xE0 && !inserted)
            {
                WriteCarriedSegments(output, writeExif ? exif : null,
                                     writeXmp ? xmp : null, writeIptc ? iptc : null,
                                     writeIcc ? icc : null);
                inserted = true;
            }
            index += 2 + length;
        }
        if (!reachesScan)
        {
            return;
        }
        if (!inserted)
        {
            WriteCarriedSegments(output, writeExif ? exif : null,
                                 writeXmp ? xmp : null, writeIptc ? iptc : null,
                                 writeIcc ? icc : null);
        }
        output.Write(file, index, file.Length - index);
        Replace(full, output.ToArray());
    }

    /// <summary>
    /// Replaces the PNG's eXIf, XMP iTXt and iCCP chunks with the supplied
    /// blocks. The chunks go immediately before the first IDAT so a decoder
    /// sees the metadata and the colour space as soon as the image begins.
    /// </summary>
    public static void WritePng(string path, byte[]? exif, byte[]? xmp, byte[]? icc = null)
    {
        var full = Path.GetFullPath(path);
        var file = File.ReadAllBytes(full);
        if (!IsPng(file))
        {
            return;
        }
        var writeExif = exif is { Length: > 0 } && exif.Length <= MaxExifBytes;
        var writeXmp = xmp is { Length: > 0 } && xmp.Length <= MaxXmpBytes;
        var writeIcc = icc is { Length: > 0 } && icc.Length <= MaxIccBytes;
        if (!writeExif && !writeXmp && !writeIcc)
        {
            return;
        }

        using var output = new MemoryStream(
            file.Length + (exif?.Length ?? 0) + (xmp?.Length ?? 0) + 96);
        output.Write(file, 0, 8);
        var index = 8;
        var inserted = false;
        while (index + 12 <= file.Length)
        {
            var raw = ReadU32Big(file, index);
            if (raw > int.MaxValue)
            {
                return;
            }
            var length = (int)raw;
            if ((long)index + 12 + length > file.Length)
            {
                return;
            }
            var name = Encoding.ASCII.GetString(file, index + 4, 4);
            if (!inserted && name == "IDAT")
            {
                WriteCarriedChunks(output, writeExif ? exif : null,
                                   writeXmp ? xmp : null, writeIcc ? icc : null);
                inserted = true;
            }
            var drop = (writeExif && name == "eXIf")
                       || (writeXmp && name == "iTXt" && IsXmpText(file, index, length))
                       || (writeIcc && name == "iCCP");
            if (!drop)
            {
                output.Write(file, index, 12 + length);
            }
            index += 12 + length;
            if (name == "IEND")
            {
                break;
            }
        }
        if (!inserted)
        {
            return;
        }
        Replace(full, output.ToArray());
    }

    private static byte[]? ReadJpegSegment(byte[] file, byte[] signature, int maximum,
                                           byte markerWanted = 0xE1)
    {
        var index = 2;
        while (index + 4 <= file.Length)
        {
            if (file[index] != 0xFF)
            {
                return null;
            }
            var marker = file[index + 1];
            if (marker == 0xDA || marker == 0xD9)
            {
                return null;
            }
            var length = (file[index + 2] << 8) | file[index + 3];
            if (length < 2 || index + 2 + length > file.Length)
            {
                return null;
            }
            if (marker == markerWanted
                && StartsWith(file, index + 4, length - 2, signature))
            {
                var start = index + 4 + signature.Length;
                var count = length - 2 - signature.Length;
                return count > 0 && count <= maximum
                    ? file.AsSpan(start, count).ToArray()
                    : null;
            }
            index += 2 + length;
        }
        return null;
    }

    /// <summary>
    /// Walks the 8BIM resources of a Photoshop APP13 payload and returns the IPTC
    /// resource record exactly as it was written. The other resources in the
    /// block (thumbnails, digests, resolution) are not IPTC and can be stale
    /// against the exported pixels, so they are not carried.
    /// </summary>
    private static byte[]? ReadJpegIptc(byte[] file)
    {
        var payload = ReadJpegSegment(file, IptcSignature, MaxIptcBytes, 0xED);
        if (payload is null)
        {
            return null;
        }
        var index = 0;
        while (index + 12 <= payload.Length)
        {
            if (!StartsWith(payload, index, 4, ResourceSignature))
            {
                return null;
            }
            var id = (payload[index + 4] << 8) | payload[index + 5];
            var nameStart = index + 6;
            var nameLength = payload[nameStart];
            var dataStart = nameStart + 1 + nameLength;
            if ((nameLength + 1) % 2 != 0)
            {
                dataStart++;
            }
            if (dataStart + 4 > payload.Length)
            {
                return null;
            }
            var size = ReadU32Big(payload, dataStart);
            if (size > int.MaxValue)
            {
                return null;
            }
            var end = dataStart + 4 + (int)size;
            if (end > payload.Length)
            {
                return null;
            }
            var next = end + ((int)size % 2);
            if (next > payload.Length)
            {
                next = end;
            }
            if (id == IptcResourceId && size > 0)
            {
                return payload.AsSpan(index, next - index).ToArray();
            }
            index = next;
        }
        return null;
    }

    private static byte[]? ReadPngChunk(byte[] file, string type, int maximum)
    {
        var index = 8;
        while (index + 12 <= file.Length)
        {
            var raw = ReadU32Big(file, index);
            if (raw > int.MaxValue)
            {
                return null;
            }
            var length = (int)raw;
            if ((long)index + 12 + length > file.Length)
            {
                return null;
            }
            var name = Encoding.ASCII.GetString(file, index + 4, 4);
            if (name == type)
            {
                return length > 0 && length <= maximum
                    ? file.AsSpan(index + 8, length).ToArray()
                    : null;
            }
            if (name == "IEND")
            {
                return null;
            }
            index += 12 + length;
        }
        return null;
    }

    private static byte[]? ReadPngXmp(byte[] file)
    {
        var index = 8;
        while (index + 12 <= file.Length)
        {
            var raw = ReadU32Big(file, index);
            if (raw > int.MaxValue)
            {
                return null;
            }
            var length = (int)raw;
            if ((long)index + 12 + length > file.Length)
            {
                return null;
            }
            var name = Encoding.ASCII.GetString(file, index + 4, 4);
            if (name == "iTXt" && IsXmpText(file, index, length))
            {
                var data = file.AsSpan(index + 8, length);
                var zero = data.IndexOf((byte)0);
                if (zero < 0 || zero + 5 > data.Length)
                {
                    return null;
                }
                var rest = data[(zero + 3)..];
                var language = rest.IndexOf((byte)0);
                if (language < 0)
                {
                    return null;
                }
                rest = rest[(language + 1)..];
                var translated = rest.IndexOf((byte)0);
                if (translated < 0)
                {
                    return null;
                }
                var text = rest[(translated + 1)..];
                return text.Length > 0 && text.Length <= MaxXmpBytes
                    ? text.ToArray()
                    : null;
            }
            if (name == "IEND")
            {
                return null;
            }
            index += 12 + length;
        }
        return null;
    }

    private static bool IsXmpText(byte[] file, int index, int length)
    {
        var data = file.AsSpan(index + 8, length);
        if (data.Length <= PngTextKeyword.Length
            || data[PngTextKeyword.Length] != 0)
        {
            return false;
        }
        return data[..PngTextKeyword.Length].SequenceEqual(PngTextKeyword);
    }

    private static void WriteCarriedSegments(MemoryStream output, byte[]? exif,
                                             byte[]? xmp, byte[]? iptc, byte[]? icc)
    {
        if (exif is not null)
        {
            WriteApp1(output, ExifSignature, exif);
        }
        if (xmp is not null)
        {
            WriteApp1(output, XmpSignature, xmp);
        }
        if (iptc is not null)
        {
            WriteApp13(output, iptc);
        }
        if (icc is not null)
        {
            WriteApp2Profile(output, icc);
        }
    }

    private static void WriteApp13(MemoryStream output, byte[] payload)
    {
        var length = IptcSignature.Length + payload.Length + 2;
        output.WriteByte(0xFF);
        output.WriteByte(0xED);
        output.WriteByte((byte)(length >> 8));
        output.WriteByte((byte)length);
        output.Write(IptcSignature, 0, IptcSignature.Length);
        output.Write(payload, 0, payload.Length);
    }

    /// <summary>
    /// A profile larger than one segment is split in order; each segment names
    /// its position and the total, which is how readers reassemble it.
    /// </summary>
    private static void WriteApp2Profile(MemoryStream output, byte[] profile)
    {
        var count = (profile.Length + MaxIccChunkBytes - 1) / MaxIccChunkBytes;
        for (var part = 0; part < count; part++)
        {
            var start = part * MaxIccChunkBytes;
            var length = Math.Min(MaxIccChunkBytes, profile.Length - start);
            var segment = IccSignature.Length + 2 + length + 2;
            output.WriteByte(0xFF);
            output.WriteByte(0xE2);
            output.WriteByte((byte)(segment >> 8));
            output.WriteByte((byte)segment);
            output.Write(IccSignature, 0, IccSignature.Length);
            output.WriteByte((byte)(part + 1));
            output.WriteByte((byte)count);
            output.Write(profile, start, length);
        }
    }

    private static void WriteApp1(MemoryStream output, byte[] signature, byte[] payload)
    {
        var length = signature.Length + payload.Length + 2;
        output.WriteByte(0xFF);
        output.WriteByte(0xE1);
        output.WriteByte((byte)(length >> 8));
        output.WriteByte((byte)length);
        output.Write(signature, 0, signature.Length);
        output.Write(payload, 0, payload.Length);
    }

    private static void WriteCarriedChunks(MemoryStream output, byte[]? exif,
                                           byte[]? xmp, byte[]? icc)
    {
        if (exif is not null)
        {
            WritePngChunk(output, "eXIf", exif);
        }
        if (icc is not null)
        {
            var name = Encoding.ASCII.GetBytes(IccProfileName);
            var compressed = ZlibCompress(icc);
            var data = new byte[name.Length + 2 + compressed.Length];
            name.CopyTo(data, 0);
            // The name terminator, then compression method 0 (deflate).
            data[name.Length] = 0;
            compressed.CopyTo(data, name.Length + 2);
            WritePngChunk(output, "iCCP", data);
        }
        if (xmp is not null)
        {
            var data = new byte[PngTextKeyword.Length + 5 + xmp.Length];
            PngTextKeyword.CopyTo(data, 0);
            // Keyword terminator, compression flag, compression method, then
            // the empty language tag and translated keyword terminators.
            data.AsSpan(PngTextKeyword.Length, 5).Clear();
            xmp.CopyTo(data, PngTextKeyword.Length + 5);
            WritePngChunk(output, "iTXt", data);
        }
    }

    /// <summary>
    /// The ICC profile the container declares, or false when it declares none
    /// or the profile cannot be read whole. The decoder uses this to recognise
    /// files this host wrote: their pixels are already sRGB, so converting them
    /// again would only add rounding.
    /// </summary>
    public static bool TryReadIcc(string path, out byte[] profile)
    {
        profile = Array.Empty<byte>();
        try
        {
            // The profile sits before the image data, so only the head of the
            // file is read; a 26-megapixel export is not loaded twice.
            using var stream = File.OpenRead(Path.GetFullPath(path));
            var head = new byte[MaxIccBytes + (1 << 16)];
            var read = 0;
            int got;
            while (read < head.Length
                   && (got = stream.Read(head, read, head.Length - read)) > 0)
            {
                read += got;
            }
            var file = read == head.Length ? head : head.AsSpan(0, read).ToArray();
            var declared = IsJpeg(file) ? ReadJpegIcc(file)
                         : IsPng(file) ? ReadPngIcc(file)
                         : null;
            if (declared is null)
            {
                return false;
            }
            profile = declared;
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static byte[]? ReadJpegIcc(byte[] file)
    {
        var parts = new SortedDictionary<int, byte[]>();
        var expected = -1;
        var index = 2;
        while (index + 4 <= file.Length)
        {
            if (file[index] != 0xFF)
            {
                return null;
            }
            var marker = file[index + 1];
            if (marker is 0xDA or 0xD9)
            {
                break;
            }
            var length = (file[index + 2] << 8) | file[index + 3];
            if (length < 2 || index + 2 + length > file.Length)
            {
                return null;
            }
            if (marker == 0xE2
                && StartsWith(file, index + 4, length - 2, IccSignature))
            {
                var payload = index + 4 + IccSignature.Length;
                var available = length - 2 - IccSignature.Length;
                if (available < 2)
                {
                    return null;
                }
                int sequence = file[payload];
                int count = file[payload + 1];
                if (sequence == 0 || count == 0 || count > 255)
                {
                    return null;
                }
                if (expected < 0)
                {
                    expected = count;
                }
                else if (expected != count)
                {
                    return null;
                }
                parts[sequence] = file.AsSpan(payload + 2, available - 2).ToArray();
            }
            index += 2 + length;
        }
        if (expected <= 0 || parts.Count != expected)
        {
            return null;
        }
        var total = 0;
        foreach (var part in parts.Values)
        {
            total += part.Length;
        }
        if (total <= 0 || total > MaxIccBytes)
        {
            return null;
        }
        var profile = new byte[total];
        var at = 0;
        for (var i = 1; i <= expected; i++)
        {
            if (!parts.TryGetValue(i, out var part))
            {
                return null;
            }
            part.CopyTo(profile, at);
            at += part.Length;
        }
        return profile;
    }

    private static byte[]? ReadPngIcc(byte[] file)
    {
        var chunk = ReadPngChunk(file, "iCCP", MaxIccBytes);
        if (chunk is null)
        {
            return null;
        }
        var zero = chunk.AsSpan().IndexOf((byte)0);
        if (zero <= 0 || zero + 2 > chunk.Length || chunk[zero + 1] != 0)
        {
            return null;
        }
        var compressed = chunk.AsSpan(zero + 2).ToArray();
        return compressed.Length == 0 ? null : ZlibDecompress(compressed, MaxIccBytes);
    }

    private static byte[]? ZlibDecompress(byte[] input, int maximum)
    {
        try
        {
            using var source = new MemoryStream(input, writable: false);
            using var zlib = new ZLibStream(source, CompressionMode.Decompress);
            using var output = new MemoryStream();
            var buffer = new byte[8192];
            int read;
            while ((read = zlib.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (output.Length + read > maximum)
                {
                    return null;
                }
                output.Write(buffer, 0, read);
            }
            return output.ToArray();
        }
        catch (InvalidDataException)
        {
            return null;
        }
    }

    private static byte[] ZlibCompress(byte[] input)
    {
        using var output = new MemoryStream();
        using (var zlib = new ZLibStream(output, CompressionLevel.SmallestSize, leaveOpen: true))
        {
            zlib.Write(input, 0, input.Length);
        }
        return output.ToArray();
    }

    private static void WritePngChunk(MemoryStream output, string type, byte[] data)
    {
        var name = Encoding.ASCII.GetBytes(type);
        var crc = Crc32(name, data);
        output.WriteByte((byte)(data.Length >> 24));
        output.WriteByte((byte)(data.Length >> 16));
        output.WriteByte((byte)(data.Length >> 8));
        output.WriteByte((byte)data.Length);
        output.Write(name, 0, 4);
        output.Write(data, 0, data.Length);
        output.WriteByte((byte)(crc >> 24));
        output.WriteByte((byte)(crc >> 16));
        output.WriteByte((byte)(crc >> 8));
        output.WriteByte((byte)crc);
    }

    private static void Replace(string path, byte[] bytes)
    {
        var temporary = path + ".metadata-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            try
            {
                File.Delete(temporary);
            }
            catch (IOException)
            {
            }
            throw;
        }
    }

    private static bool IsJpeg(byte[] file) =>
        file.Length >= 4 && file[0] == 0xFF && file[1] == 0xD8;

    private static bool IsPng(byte[] file) =>
        file.Length >= 8
        && file[0] == 0x89 && file[1] == 0x50 && file[2] == 0x4E && file[3] == 0x47
        && file[4] == 0x0D && file[5] == 0x0A && file[6] == 0x1A && file[7] == 0x0A;

    private static bool StartsWith(byte[] file, int offset, int count, byte[] signature) =>
        count >= signature.Length
        && file.AsSpan(offset, signature.Length).SequenceEqual(signature);

    private static void SetShortValue(byte[] tiff, int entry, bool little, ushort value)
    {
        if (ReadU16(tiff, entry + 2, little) != 3)
        {
            return;
        }
        var count = ReadU32(tiff, entry + 4, little);
        if (count == 0)
        {
            return;
        }
        if (count == 1 || count == 2)
        {
            WriteU16(tiff, entry + 8, value, little);
            return;
        }
        var offset = ReadU32(tiff, entry + 8, little);
        if (offset <= int.MaxValue && (long)offset + 2 <= tiff.Length)
        {
            WriteU16(tiff, (int)offset, value, little);
        }
    }

    private static void SetDimension(byte[] tiff, int entry, bool little, int value)
    {
        var type = ReadU16(tiff, entry + 2, little);
        var count = ReadU32(tiff, entry + 4, little);
        if (count == 0)
        {
            return;
        }
        if (type == 3)
        {
            var at = count <= 2
                ? entry + 8
                : Offset(tiff, ReadU32(tiff, entry + 8, little));
            if (at is { } offset && (long)offset + 2 <= tiff.Length)
            {
                WriteU16(tiff, offset, (ushort)Math.Min(value, ushort.MaxValue), little);
            }
        }
        else if (type == 4)
        {
            var at = count == 1
                ? entry + 8
                : Offset(tiff, ReadU32(tiff, entry + 8, little));
            if (at is { } offset && (long)offset + 4 <= tiff.Length)
            {
                WriteU32(tiff, offset, (uint)value, little);
            }
        }
    }

    private static void PatchExifSubIfd(byte[] tiff, uint pointer, bool little,
                                        int width, int height)
    {
        var offset = Offset(tiff, pointer);
        if (offset is not { } at || (long)at + 2 > tiff.Length)
        {
            return;
        }
        var count = ReadU16(tiff, at, little);
        if (count > 4096 || (long)at + 2 + 12L * count > tiff.Length)
        {
            return;
        }
        for (var index = 0; index < count; index++)
        {
            var entry = at + 2 + 12 * index;
            var tag = ReadU16(tiff, entry, little);
            if (tag == TagPixelXDimension)
            {
                SetDimension(tiff, entry, little, width);
            }
            else if (tag == TagPixelYDimension)
            {
                SetDimension(tiff, entry, little, height);
            }
        }
    }

    private static int? Offset(byte[] tiff, uint value) =>
        value <= int.MaxValue && value < tiff.Length ? (int)value : null;

    private static ushort ReadU16(byte[] bytes, int offset, bool little)
    {
        if (offset < 0 || offset + 2 > bytes.Length)
        {
            return 0;
        }
        return little
            ? (ushort)(bytes[offset] | (bytes[offset + 1] << 8))
            : (ushort)((bytes[offset] << 8) | bytes[offset + 1]);
    }

    private static uint ReadU32(byte[] bytes, int offset, bool little)
    {
        if (offset < 0 || offset + 4 > bytes.Length)
        {
            return 0;
        }
        return little
            ? (uint)bytes[offset] | ((uint)bytes[offset + 1] << 8)
              | ((uint)bytes[offset + 2] << 16) | ((uint)bytes[offset + 3] << 24)
            : ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16)
              | ((uint)bytes[offset + 2] << 8) | bytes[offset + 3];
    }

    private static uint ReadU32Big(byte[] bytes, int offset) =>
        ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16)
        | ((uint)bytes[offset + 2] << 8) | bytes[offset + 3];

    private static void WriteU16(byte[] bytes, int offset, ushort value, bool little)
    {
        if (little)
        {
            bytes[offset] = (byte)value;
            bytes[offset + 1] = (byte)(value >> 8);
        }
        else
        {
            bytes[offset] = (byte)(value >> 8);
            bytes[offset + 1] = (byte)value;
        }
    }

    private static void WriteU32(byte[] bytes, int offset, uint value, bool little)
    {
        if (little)
        {
            bytes[offset] = (byte)value;
            bytes[offset + 1] = (byte)(value >> 8);
            bytes[offset + 2] = (byte)(value >> 16);
            bytes[offset + 3] = (byte)(value >> 24);
        }
        else
        {
            bytes[offset] = (byte)(value >> 24);
            bytes[offset + 1] = (byte)(value >> 16);
            bytes[offset + 2] = (byte)(value >> 8);
            bytes[offset + 3] = (byte)value;
        }
    }

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint index = 0; index < 256; index++)
        {
            var value = index;
            for (var bit = 0; bit < 8; bit++)
            {
                value = (value & 1) != 0 ? 0xEDB88320u ^ (value >> 1) : value >> 1;
            }
            table[index] = value;
        }
        return table;
    }

    private static uint Crc32(byte[] type, byte[] data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var value in type)
        {
            crc = CrcTable[(crc ^ value) & 0xFF] ^ (crc >> 8);
        }
        foreach (var value in data)
        {
            crc = CrcTable[(crc ^ value) & 0xFF] ^ (crc >> 8);
        }
        return crc ^ 0xFFFFFFFFu;
    }
}
