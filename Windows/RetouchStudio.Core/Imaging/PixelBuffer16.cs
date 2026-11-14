using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Imaging;

/// <summary>
/// A tightly packed 16-bit RGBA image, top-left origin. This is the export-side
/// buffer: a PNG or TIFF export whose plan asks for 16 bits keeps the decoded
/// depth instead of the 8-bit reduction the preview works in. Channel order is
/// RGBA to match the WIC `Rgba16` format, so both directions are a copy.
/// </summary>
public sealed class PixelBuffer16
{
    public PixelBuffer16(int width, int height, ushort[] rgba)
    {
        if (width <= 0 || height <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "a buffer needs a positive size");
        }
        if (rgba.Length != width * height * 4)
        {
            throw new ArgumentException("the buffer is not width * height * 4 samples",
                                        nameof(rgba));
        }
        Width = width;
        Height = height;
        Pixels = rgba;
    }

    public PixelBuffer16(int width, int height)
        : this(width, height, new ushort[width * height * 4])
    {
    }

    public int Width { get; }
    public int Height { get; }
    public ushort[] Pixels { get; }

    public PixelBuffer16 Crop(CropValue crop)
    {
        var x = (int)Math.Round(crop.X * Width);
        var y = (int)Math.Round(crop.Y * Height);
        var width = (int)Math.Round(crop.Width * Width);
        var height = (int)Math.Round(crop.Height * Height);
        if (width <= 0 || height <= 0 || x >= Width || y >= Height)
        {
            throw new ArgumentException("the crop does not overlap the photo", nameof(crop));
        }
        x = Math.Clamp(x, 0, Width - 1);
        y = Math.Clamp(y, 0, Height - 1);
        width = Math.Clamp(width, 1, Width - x);
        height = Math.Clamp(height, 1, Height - y);

        var output = new PixelBuffer16(width, height);
        for (var row = 0; row < height; row++)
        {
            Buffer.BlockCopy(Pixels, ((y + row) * Width + x) * 8,
                             output.Pixels, row * width * 8, width * 8);
        }
        return output;
    }

    public PixelBuffer16 ApplyOrientation(OrientationValue orientation)
    {
        var current = this;
        if (orientation.Flipped)
        {
            current = current.FlipHorizontally();
        }
        for (var turn = 0; turn < ((orientation.QuarterTurns % 4) + 4) % 4; turn++)
        {
            current = current.RotateQuarterClockwise();
        }
        if (orientation.Angle != 0)
        {
            current = current.RotateDegrees(orientation.Angle);
        }
        return current;
    }

    public PixelBuffer16 FlipHorizontally()
    {
        var output = new PixelBuffer16(Width, Height);
        for (var y = 0; y < Height; y++)
        {
            var sourceRow = y * Width;
            var targetRow = y * Width;
            for (var x = 0; x < Width; x++)
            {
                Buffer.BlockCopy(Pixels, (sourceRow + x) * 8, output.Pixels,
                                 (targetRow + (Width - 1 - x)) * 8, 8);
            }
        }
        return output;
    }

    public PixelBuffer16 RotateQuarterClockwise()
    {
        var output = new PixelBuffer16(Height, Width);
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                var destinationX = Height - 1 - y;
                var destinationY = x;
                Buffer.BlockCopy(Pixels, (y * Width + x) * 8, output.Pixels,
                                 (destinationY * output.Width + destinationX) * 8, 8);
            }
        }
        return output;
    }

    /// <summary>Bilinear rotation with clamped edges; positive is clockwise.</summary>
    public PixelBuffer16 RotateDegrees(double degrees)
    {
        if (degrees == 0)
        {
            return this;
        }
        var radians = degrees * Math.PI / 180.0;
        var cos = Math.Cos(radians);
        var sin = Math.Sin(radians);
        var centreX = (Width - 1) / 2.0;
        var centreY = (Height - 1) / 2.0;
        var output = new PixelBuffer16(Width, Height);

        for (var y = 0; y < Height; y++)
        {
            var dy = y - centreY;
            for (var x = 0; x < Width; x++)
            {
                var dx = x - centreX;
                var sourceX = centreX + dx * cos + dy * sin;
                var sourceY = centreY - dx * sin + dy * cos;
                Sample(sourceX, sourceY, output.Pixels, (y * Width + x) * 8);
            }
        }
        return output;
    }

    public PixelBuffer16 ResizeLongEdge(int longEdge)
    {
        var longSide = Math.Max(Width, Height);
        if (longEdge <= 0 || longEdge == longSide)
        {
            return this;
        }
        var scale = longEdge / (double)longSide;
        var width = Math.Max(1, (int)Math.Round(Width * scale));
        var height = Math.Max(1, (int)Math.Round(Height * scale));
        var output = new PixelBuffer16(width, height);
        for (var y = 0; y < height; y++)
        {
            var sourceY = (y + 0.5) / scale - 0.5;
            for (var x = 0; x < width; x++)
            {
                var sourceX = (x + 0.5) / scale - 0.5;
                Sample(sourceX, sourceY, output.Pixels, (y * width + x) * 8);
            }
        }
        return output;
    }

    /// <summary>
    /// Reduces to the host's BGRA8 display buffer, rounding each sample to the
    /// nearest 8-bit level. The preview pipeline works in 16 bits and comes
    /// through here only for the final bitmap.
    /// </summary>
    public PixelBuffer ToBgra8()
    {
        var bytes = new byte[Width * Height * 4];
        for (var offset = 0; offset < Pixels.Length; offset += 4)
        {
            bytes[offset] = ToByte(Pixels[offset + 2]);
            bytes[offset + 1] = ToByte(Pixels[offset + 1]);
            bytes[offset + 2] = ToByte(Pixels[offset]);
            bytes[offset + 3] = ToByte(Pixels[offset + 3]);
        }
        return new PixelBuffer(Width, Height, bytes);
    }

    private static byte ToByte(ushort value) => (byte)((value * 255 + 32767) / 65535);

    public PixelBuffer16 FlattenOntoWhite()
    {
        var output = new PixelBuffer16(Width, Height);
        for (var offset = 0; offset < Pixels.Length; offset += 4)
        {
            var alpha = Pixels[offset + 3] / 65535.0;
            for (var channel = 0; channel < 3; channel++)
            {
                output.Pixels[offset + channel] = (ushort)Math.Clamp(
                    Math.Round(Pixels[offset + channel] * alpha + 65535 * (1 - alpha)),
                    0, 65535);
            }
            output.Pixels[offset + 3] = 65535;
        }
        return output;
    }

    private void Sample(double x, double y, ushort[] destination, int offset)
    {
        var clampedX = Math.Clamp(x, 0, Width - 1);
        var clampedY = Math.Clamp(y, 0, Height - 1);
        var x0 = (int)clampedX;
        var y0 = (int)clampedY;
        var x1 = Math.Min(x0 + 1, Width - 1);
        var y1 = Math.Min(y0 + 1, Height - 1);
        var fx = clampedX - x0;
        var fy = clampedY - y0;

        for (var channel = 0; channel < 4; channel++)
        {
            var p00 = Pixels[(y0 * Width + x0) * 4 + channel];
            var p10 = Pixels[(y0 * Width + x1) * 4 + channel];
            var p01 = Pixels[(y1 * Width + x0) * 4 + channel];
            var p11 = Pixels[(y1 * Width + x1) * 4 + channel];
            var top = p00 + (p10 - p00) * fx;
            var bottom = p01 + (p11 - p01) * fx;
            destination[offset + channel] = (ushort)Math.Clamp(
                Math.Round(top + (bottom - top) * fy), 0, 65535);
        }
    }
}
