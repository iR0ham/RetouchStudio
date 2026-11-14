using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Imaging;

/// <summary>
/// The same global pass as <see cref="AdjustmentPipeline"/>, on the 16-bit
/// export buffer. The formulas, weights and order are copied deliberately; a
/// test renders both depths from the same 16-bit source and compares them, so
/// the two paths cannot drift apart unnoticed.
/// </summary>
public static class AdjustmentPipeline16
{
    public static PixelBuffer16 Apply(PixelBuffer16 source, GlobalAdjustments adjustments)
    {
        if (adjustments.IsIdentity)
        {
            return source;
        }

        var black = 0.30 * adjustments.Blacks / 100.0;
        var white = 1 - 0.30 * adjustments.Whites / 100.0;
        var levelsActive = Math.Abs(black) > 0.001 || Math.Abs(white - 1) > 0.001;
        var shadowK = Math.Max(0.30, 1 - SmoothStep(0, 0.48, black));
        var highlightK = Math.Max(0.30, SmoothStep(0.52, 1, white));
        var gain = Math.Pow(2, 0.30 * adjustments.Exposure / 100.0);
        var contrast = 1 + 0.45 * adjustments.Contrast / 100.0;
        var toneActive = adjustments.Exposure != 0 || adjustments.Contrast != 0;
        var blurred = adjustments.Clarity == 0
            ? null
            : BoxBlur(source.Pixels, source.Width, source.Height);

        var width = source.Width;
        var height = source.Height;
        var output = new PixelBuffer16(width, height);
        var sourcePixels = source.Pixels;
        var targetPixels = output.Pixels;

        var saturationFactor = 1 + 0.6 * adjustments.Saturation / 100.0;
        var vibranceAmount = adjustments.Vibrance / 100.0;
        var warmthAmount = adjustments.Warmth / 100.0;
        var clarityAmount = adjustments.Clarity / 100.0 * 0.75;
        var vignetteExponent = 1.4 * adjustments.Vignette / 100.0;
        var centreX = (width - 1) / 2.0;
        var centreY = (height - 1) / 2.0;
        var shortSide = Math.Min(width, height);

        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                // RGBA: red at +0, green at +1, blue at +2.
                double red = sourcePixels[offset] / 65535.0;
                double green = sourcePixels[offset + 1] / 65535.0;
                double blue = sourcePixels[offset + 2] / 65535.0;

                if (levelsActive)
                {
                    var encodedRed = Math.Pow(ToLinear(red), 0.4545);
                    var encodedGreen = Math.Pow(ToLinear(green), 0.4545);
                    var encodedBlue = Math.Pow(ToLinear(blue), 0.4545);
                    var levelLuma = 0.2126 * encodedRed + 0.7152 * encodedGreen
                                  + 0.0722 * encodedBlue;
                    var shadowWeight = 1 - SmoothStep(0, 0.48, levelLuma);
                    var highlightWeight = SmoothStep(0.52, 1, levelLuma);
                    var delta = -black * shadowWeight / shadowK
                              + (1 - white) * highlightWeight / highlightK;
                    red = FromLinear(Math.Pow(Clamp01(encodedRed + delta), 2.2));
                    green = FromLinear(Math.Pow(Clamp01(encodedGreen + delta), 2.2));
                    blue = FromLinear(Math.Pow(Clamp01(encodedBlue + delta), 2.2));
                }

                if (toneActive)
                {
                    red = Tone(red, gain, contrast);
                    green = Tone(green, gain, contrast);
                    blue = Tone(blue, gain, contrast);
                }

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
                    var blurLuma = (0.2126 * blurred[offset] +
                                    0.7152 * blurred[offset + 1] +
                                    0.0722 * blurred[offset + 2]) / 65535.0;
                    var delta = (luma - blurLuma) * clarityAmount;
                    red += delta;
                    green += delta;
                    blue += delta;
                }

                if (vignetteExponent > 0)
                {
                    var dx = x - centreX;
                    var dyPixel = y - centreY;
                    var distance = Math.Sqrt(dx * dx + dyPixel * dyPixel) / shortSide;
                    // Same measured CIVignette shape as the 8-bit pipeline:
                    // linear light, short-side distance, intensity as exponent.
                    var falloff = SmoothStep(0.03, 1.03, distance);
                    var multiplier = Math.Pow(1 - falloff, vignetteExponent);
                    red = FromLinear(ToLinear(Clamp01(red)) * multiplier);
                    green = FromLinear(ToLinear(Clamp01(green)) * multiplier);
                    blue = FromLinear(ToLinear(Clamp01(blue)) * multiplier);
                }

                targetPixels[offset] = ToSample(red);
                targetPixels[offset + 1] = ToSample(green);
                targetPixels[offset + 2] = ToSample(blue);
                targetPixels[offset + 3] = sourcePixels[offset + 3];
            }
        }
        return output;
    }

    private static ushort[] BoxBlur(ushort[] source, int width, int height)
    {
        var radius = Math.Max(1, (int)Math.Round(Math.Min(width, height) * 0.004));
        var current = source;
        for (var pass = 0; pass < 3; pass++)
        {
            current = BlurPass(current, width, height, radius);
        }
        return current;
    }

    private static ushort[] BlurPass(ushort[] source, int width, int height, int radius)
    {
        var horizontal = new ushort[source.Length];
        for (var y = 0; y < height; y++)
        {
            var row = y * width;
            for (var x = 0; x < width; x++)
            {
                var low = Math.Max(0, x - radius);
                var high = Math.Min(width - 1, x + radius);
                var count = high - low + 1;
                long red = 0;
                long green = 0;
                long blue = 0;
                for (var sample = low; sample <= high; sample++)
                {
                    var offset = (row + sample) * 4;
                    red += source[offset];
                    green += source[offset + 1];
                    blue += source[offset + 2];
                }
                var target = (row + x) * 4;
                horizontal[target] = (ushort)(red / count);
                horizontal[target + 1] = (ushort)(green / count);
                horizontal[target + 2] = (ushort)(blue / count);
                horizontal[target + 3] = 65535;
            }
        }

        var blurred = new ushort[source.Length];
        for (var y = 0; y < height; y++)
        {
            var low = Math.Max(0, y - radius);
            var high = Math.Min(height - 1, y + radius);
            var count = high - low + 1;
            for (var x = 0; x < width; x++)
            {
                long red = 0;
                long green = 0;
                long blue = 0;
                for (var sample = low; sample <= high; sample++)
                {
                    var offset = (sample * width + x) * 4;
                    red += horizontal[offset];
                    green += horizontal[offset + 1];
                    blue += horizontal[offset + 2];
                }
                var target = (y * width + x) * 4;
                blurred[target] = (ushort)(red / count);
                blurred[target + 1] = (ushort)(green / count);
                blurred[target + 2] = (ushort)(blue / count);
                blurred[target + 3] = 65535;
            }
        }
        return blurred;
    }

    private static double Tone(double value, double gain, double contrast)
    {
        value = FromLinear(ToLinear(value) * gain);
        return Clamp01(0.5 + (value - 0.5) * contrast);
    }

    private static double ToLinear(double value) =>
        value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);

    private static double FromLinear(double value) =>
        value <= 0.0031308 ? value * 12.92 : 1.055 * Math.Pow(value, 1 / 2.4) - 0.055;

    private static double SmoothStep(double edge0, double edge1, double value)
    {
        var t = Clamp01((value - edge0) / (edge1 - edge0));
        return t * t * (3 - 2 * t);
    }

    private static double Clamp01(double value) => Math.Clamp(value, 0, 1);

    private static ushort ToSample(double value) =>
        (ushort)Math.Clamp(Math.Round(value * 65535), 0, 65535);
}
