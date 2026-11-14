using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Imaging;

/// <summary>
/// A tightly packed 8-bit BGRA image, top-left origin. The preview and every
/// 8-bit export work in this buffer: the decoder produces it, the pipeline
/// edits it, the encoder writes it and the WPF preview displays it without a
/// copy. A PNG or TIFF export whose plan asks for 16 bits uses
/// <see cref="PixelBuffer16"/> instead, so a deeper source is not reduced.
/// </summary>
public sealed class PixelBuffer
{
    public PixelBuffer(int width, int height, byte[] rgba)
    {
        if (width <= 0 || height <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "a buffer needs a positive size");
        }
        if (rgba.Length != width * height * 4)
        {
            throw new ArgumentException("the buffer is not width * height * 4 bytes", nameof(rgba));
        }
        Width = width;
        Height = height;
        Pixels = rgba;
    }

    public PixelBuffer(int width, int height) : this(width, height, new byte[width * height * 4])
    {
    }

    public int Width { get; }
    public int Height { get; }
    public byte[] Pixels { get; }

    /// <summary>
    /// Cuts a crop in normalized photo coordinates. A crop that would be empty
    /// or off the image is refused instead of silently replaced, so a bad
    /// document cannot produce a surprising export.
    /// </summary>
    public PixelBuffer Crop(CropValue crop)
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

        var output = new PixelBuffer(width, height);
        for (var row = 0; row < height; row++)
        {
            Buffer.BlockCopy(Pixels, ((y + row) * Width + x) * 4,
                             output.Pixels, row * width * 4, width * 4);
        }
        return output;
    }

    /// <summary>
    /// Applies the document orientation: mirror, quarter turns, then the
    /// straighten angle. The angle rotates the image clockwise about its centre
    /// and keeps the canvas size, sampling with clamped edges. Aligning the
    /// result with the macOS renderer is not claimed; the host's convention is
    /// documented in <c>Windows/README.md</c>.
    /// </summary>
    public PixelBuffer ApplyOrientation(OrientationValue orientation)
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

    public PixelBuffer FlipHorizontally()
    {
        var output = new PixelBuffer(Width, Height);
        for (var y = 0; y < Height; y++)
        {
            var sourceRow = y * Width;
            var targetRow = y * Width;
            for (var x = 0; x < Width; x++)
            {
                Buffer.BlockCopy(Pixels, (sourceRow + x) * 4, output.Pixels,
                                 (targetRow + (Width - 1 - x)) * 4, 4);
            }
        }
        return output;
    }

    public PixelBuffer RotateQuarterClockwise()
    {
        var output = new PixelBuffer(Height, Width);
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                var destinationX = Height - 1 - y;
                var destinationY = x;
                Buffer.BlockCopy(Pixels, (y * Width + x) * 4, output.Pixels,
                                 (destinationY * output.Width + destinationX) * 4, 4);
            }
        }
        return output;
    }

    /// <summary>Bilinear rotation with clamped edges; positive is clockwise.</summary>
    public PixelBuffer RotateDegrees(double degrees)
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
        var output = new PixelBuffer(Width, Height);

        for (var y = 0; y < Height; y++)
        {
            var dy = y - centreY;
            for (var x = 0; x < Width; x++)
            {
                var dx = x - centreX;
                var sourceX = centreX + dx * cos + dy * sin;
                var sourceY = centreY - dx * sin + dy * cos;
                Sample(sourceX, sourceY, output.Pixels, (y * Width + x) * 4);
            }
        }
        return output;
    }

    /// <summary>
    /// Bilinear resample so the long edge is <paramref name="longEdge"/> pixels.
    /// Upscaling is allowed; the AI upscaler is a separate feature this host
    /// does not have.
    /// </summary>
    public PixelBuffer ResizeLongEdge(int longEdge)
    {
        var longSide = Math.Max(Width, Height);
        if (longEdge <= 0 || longEdge == longSide)
        {
            return this;
        }
        var scale = longEdge / (double)longSide;
        var width = Math.Max(1, (int)Math.Round(Width * scale));
        var height = Math.Max(1, (int)Math.Round(Height * scale));
        var output = new PixelBuffer(width, height);
        for (var y = 0; y < height; y++)
        {
            var sourceY = (y + 0.5) / scale - 0.5;
            for (var x = 0; x < width; x++)
            {
                var sourceX = (x + 0.5) / scale - 0.5;
                Sample(sourceX, sourceY, output.Pixels, (y * width + x) * 4);
            }
        }
        return output;
    }

    /// <summary>
    /// Composites onto white. JPEG and HEIC have no dependable alpha channel, so
    /// the export flattens onto white before encoding, exactly as the shared
    /// render contract says a host must.
    /// </summary>
    public PixelBuffer FlattenOntoWhite()
    {
        var output = new PixelBuffer(Width, Height);
        for (var offset = 0; offset < Pixels.Length; offset += 4)
        {
            var alpha = Pixels[offset + 3] / 255.0;
            for (var channel = 0; channel < 3; channel++)
            {
                output.Pixels[offset + channel] = (byte)Math.Clamp(
                    Math.Round(Pixels[offset + channel] * alpha + 255 * (1 - alpha)), 0, 255);
            }
            output.Pixels[offset + 3] = 255;
        }
        return output;
    }

    private void Sample(double x, double y, byte[] destination, int offset)
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
            destination[offset + channel] = (byte)Math.Clamp(Math.Round(top + (bottom - top) * fy), 0, 255);
        }
    }
}
