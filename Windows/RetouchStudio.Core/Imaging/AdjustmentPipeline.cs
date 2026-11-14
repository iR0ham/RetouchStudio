using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Imaging;

/// <summary>
/// The global colour and light values this host honours, in the same -100…100
/// ranges as the macOS sliders. Zero is a genuine no-op, so a document with no
/// edits renders unchanged.
/// </summary>
public readonly record struct GlobalAdjustments(
    double Exposure, double Contrast, double Blacks, double Whites,
    double Saturation, double Vibrance, double Warmth, double Clarity,
    double Vignette)
{
    public static readonly GlobalAdjustments Identity = default;

    public static GlobalAdjustments FromDocument(DocumentModel document) => new(
        document.Adjustment("exposure"),
        document.Adjustment("contrast"),
        document.Adjustment("blacks"),
        document.Adjustment("whites"),
        document.Adjustment("saturation"),
        document.Adjustment("vibrance"),
        document.Adjustment("warmth"),
        document.Adjustment("clarity"),
        document.Adjustment("vignette"));

    public bool IsIdentity =>
        Exposure == 0 && Contrast == 0 && Blacks == 0 && Whites == 0 &&
        Saturation == 0 && Vibrance == 0 && Warmth == 0 && Clarity == 0 &&
        Vignette == 0;
}

/// <summary>
/// The global pass. Input is sRGB 8-bit RGBA; levels, exposure and contrast run
/// through a 256-entry table, then warmth, saturation, vibrance, clarity and
/// vignette run per pixel.
///
/// Parity with the macOS Core Image pipeline is not claimed: this host works in
/// display-referred sRGB and leaves precision at 8 bits. The contract it does
/// keep is behavioural — identity means no change, each slider moves in the
/// documented direction, and the output is deterministic.
/// </summary>
public static class AdjustmentPipeline
{
    public static PixelBuffer Apply(PixelBuffer source, GlobalAdjustments adjustments)
    {
        if (adjustments.IsIdentity)
        {
            return source;
        }

        var table = BuildToneTable(adjustments);
        var blurred = adjustments.Clarity == 0 ? null : BoxBlur(source.Pixels, source.Width, source.Height);

        var width = source.Width;
        var height = source.Height;
        var output = new PixelBuffer(width, height);
        var sourcePixels = source.Pixels;
        var targetPixels = output.Pixels;

        var saturationFactor = 1 + adjustments.Saturation / 100.0;
        var vibranceAmount = adjustments.Vibrance / 100.0;
        var warmthAmount = adjustments.Warmth / 100.0;
        var clarityAmount = adjustments.Clarity / 100.0 * 1.5;
        var vignetteAmount = adjustments.Vignette / 100.0;
        var centreX = (width - 1) / 2.0;
        var centreY = (height - 1) / 2.0;
        var maxRadius = Math.Sqrt(centreX * centreX + centreY * centreY);

        for (var y = 0; y < height; y++)
        {
            var dy = (y - centreY) / maxRadius;
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                // The buffer is BGRA: blue at +0, green at +1, red at +2. The
                // tone table is float; the per-pixel maths runs in double so a
                // chain of small factors cannot round to an unexpected byte.
                double blue = table[sourcePixels[offset]];
                double green = table[sourcePixels[offset + 1]];
                double red = table[sourcePixels[offset + 2]];

                if (warmthAmount != 0)
                {
                    red = Clamp01(red * (1 + 0.18 * warmthAmount));
                    blue = Clamp01(blue * (1 - 0.18 * warmthAmount));
                }

                var luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue;

                if (saturationFactor != 1)
                {
                    red = luma + (red - luma) * saturationFactor;
                    green = luma + (green - luma) * saturationFactor;
                    blue = luma + (blue - luma) * saturationFactor;
                }

                if (vibranceAmount != 0)
                {
                    var maximum = Math.Max(red, Math.Max(green, blue));
                    var minimum = Math.Min(red, Math.Min(green, blue));
                    var current = maximum <= 0 ? 0 : (maximum - minimum) / maximum;
                    var factor = 1 + vibranceAmount * (1 - current);
                    red = luma + (red - luma) * factor;
                    green = luma + (green - luma) * factor;
                    blue = luma + (blue - luma) * factor;
                }

                if (blurred is not null)
                {
                    var blurLuma = (0.2126 * blurred[offset + 2] +
                                    0.7152 * blurred[offset + 1] +
                                    0.0722 * blurred[offset]) / 255.0;
                    var delta = (luma - blurLuma) * clarityAmount;
                    red += delta;
                    green += delta;
                    blue += delta;
                }

                if (vignetteAmount != 0)
                {
                    var dx = (x - centreX) / maxRadius;
                    var radius = Math.Sqrt(dx * dx + dy * dy);
                    var falloff = SmoothStep(0.35, 1.0, radius);
                    var multiplier = 1 - vignetteAmount * falloff;
                    red *= multiplier;
                    green *= multiplier;
                    blue *= multiplier;
                }

                targetPixels[offset] = ToByte(blue);
                targetPixels[offset + 1] = ToByte(green);
                targetPixels[offset + 2] = ToByte(red);
                targetPixels[offset + 3] = sourcePixels[offset + 3];
            }
        }
        return output;
    }

    /// <summary>
    /// Levels, then exposure, then a contrast pivot at mid grey. The black and
    /// white endpoints move by at most 0.30, the same bound the shared model
    /// documents for the Blacks/Whites sliders.
    /// </summary>
    private static float[] BuildToneTable(GlobalAdjustments adjustments)
    {
        var black = 0.30 * adjustments.Blacks / 100.0;
        var white = 1 - 0.30 * adjustments.Whites / 100.0;
        var range = white - black;
        if (Math.Abs(range) < 1e-3)
        {
            range = range < 0 ? -1e-3 : 1e-3;
        }
        var gain = Math.Pow(2, 0.30 * adjustments.Exposure / 100.0);
        var contrast = (100 + adjustments.Contrast) / 100.0;

        var table = new float[256];
        for (var index = 0; index < 256; index++)
        {
            var value = index / 255.0;
            value = Clamp01((value - black) / range);
            // The shared scale is 0.30 EV at the slider's end, applied in linear
            // light as the macOS exposure filter does; the table is otherwise
            // display-referred sRGB.
            value = FromLinear(ToLinear(value) * gain);
            value = 0.5 + (value - 0.5) * contrast;
            table[index] = (float)Clamp01(value);
        }
        return table;
    }

    private static double ToLinear(double value) =>
        value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);

    private static double FromLinear(double value) =>
        value <= 0.0031308 ? value * 12.92 : 1.055 * Math.Pow(value, 1 / 2.4) - 0.055;

    /// <summary>
    /// A separable box blur used only by clarity. The radius scales with the
    /// photo so the effect reads the same at any resolution.
    /// </summary>
    private static byte[] BoxBlur(byte[] source, int width, int height)
    {
        var radius = Math.Max(2, Math.Min(width, height) / 300);
        var horizontal = new byte[source.Length];
        for (var y = 0; y < height; y++)
        {
            var row = y * width;
            for (var x = 0; x < width; x++)
            {
                var low = Math.Max(0, x - radius);
                var high = Math.Min(width - 1, x + radius);
                var count = high - low + 1;
                var red = 0;
                var green = 0;
                var blue = 0;
                for (var sample = low; sample <= high; sample++)
                {
                    var offset = (row + sample) * 4;
                    red += source[offset];
                    green += source[offset + 1];
                    blue += source[offset + 2];
                }
                var target = (row + x) * 4;
                horizontal[target] = (byte)(red / count);
                horizontal[target + 1] = (byte)(green / count);
                horizontal[target + 2] = (byte)(blue / count);
                horizontal[target + 3] = 255;
            }
        }

        var blurred = new byte[source.Length];
        for (var y = 0; y < height; y++)
        {
            var low = Math.Max(0, y - radius);
            var high = Math.Min(height - 1, y + radius);
            var count = high - low + 1;
            for (var x = 0; x < width; x++)
            {
                var red = 0;
                var green = 0;
                var blue = 0;
                for (var sample = low; sample <= high; sample++)
                {
                    var offset = (sample * width + x) * 4;
                    red += horizontal[offset];
                    green += horizontal[offset + 1];
                    blue += horizontal[offset + 2];
                }
                var target = (y * width + x) * 4;
                blurred[target] = (byte)(red / count);
                blurred[target + 1] = (byte)(green / count);
                blurred[target + 2] = (byte)(blue / count);
                blurred[target + 3] = 255;
            }
        }
        return blurred;
    }

    private static double SmoothStep(double edge0, double edge1, double value)
    {
        var t = Clamp01((value - edge0) / (edge1 - edge0));
        return t * t * (3 - 2 * t);
    }

    private static double Clamp01(double value) => Math.Clamp(value, 0, 1);

    private static byte ToByte(double value) => (byte)Math.Clamp(Math.Round(value * 255), 0, 255);
}
