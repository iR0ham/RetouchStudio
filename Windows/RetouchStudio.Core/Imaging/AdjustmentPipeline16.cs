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

        var width = source.Width;
        var height = source.Height;
        var output = new PixelBuffer16(width, height);
        var sourcePixels = source.Pixels;
        var targetPixels = output.Pixels;

        var saturationFactor = 1 + 0.6 * adjustments.Saturation / 100.0;
        var vibranceAmount = adjustments.Vibrance / 100.0;
        var warmthAmount = adjustments.Warmth / 100.0;
        var vignetteExponent = 1.4 * adjustments.Vignette / 100.0;
        var centreX = (width - 1) / 2.0;
        var centreY = (height - 1) / 2.0;
        var shortSide = Math.Min(width, height);

        // Same measured shapes as the 8-bit pass: positive clarity moves
        // luminance detail only, negative clarity blurs every channel, and the
        // vignette follows CIVignette.
        var clarityStrength = adjustments.Clarity / 100.0;
        var clarityRadius = Math.Max(1.5, shortSide * 0.004);
        var softRadius = Math.Max(0.5, shortSide * 0.0015 * -clarityStrength
                                       * Math.Clamp(shortSide / 1400.0, 0.5, 3.0));
        var lumaPlane = clarityStrength > 0 ? new float[width * height] : null;
        var softPlanes = clarityStrength < 0
            ? new float[3][] { new float[width * height], new float[width * height], new float[width * height] }
            : null;

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

                if (lumaPlane is not null)
                {
                    lumaPlane[y * width + x] = (float)(0.2126 * ToLinear(Clamp01(red))
                                                     + 0.7152 * ToLinear(Clamp01(green))
                                                     + 0.0722 * ToLinear(Clamp01(blue)));
                }
                else if (softPlanes is not null)
                {
                    softPlanes[0][y * width + x] = (float)ToLinear(Clamp01(red));
                    softPlanes[1][y * width + x] = (float)ToLinear(Clamp01(green));
                    softPlanes[2][y * width + x] = (float)ToLinear(Clamp01(blue));
                }

                targetPixels[offset] = ToSample(red);
                targetPixels[offset + 1] = ToSample(green);
                targetPixels[offset + 2] = ToSample(blue);
                targetPixels[offset + 3] = sourcePixels[offset + 3];
            }
        }

        if (lumaPlane is not null)
        {
            var blurredLuma = GaussianBlur(lumaPlane, width, height, clarityRadius);
            var amount = 0.75 * clarityStrength;
            Parallel.For(0, height, y =>
            {
                var row = y * width;
                for (var x = 0; x < width; x++)
                {
                    var index = row + x;
                    var offset = index * 4;
                    var detail = (lumaPlane[index] - blurredLuma[index]) * amount;
                    targetPixels[offset] = ToSample(FromLinear(Clamp01(
                        ToLinear(targetPixels[offset] / 65535.0) + detail)));
                    targetPixels[offset + 1] = ToSample(FromLinear(Clamp01(
                        ToLinear(targetPixels[offset + 1] / 65535.0) + detail)));
                    targetPixels[offset + 2] = ToSample(FromLinear(Clamp01(
                        ToLinear(targetPixels[offset + 2] / 65535.0) + detail)));
                }
            });
        }
        else if (softPlanes is not null)
        {
            var blurredRed = GaussianBlur(softPlanes[0], width, height, softRadius);
            var blurredGreen = GaussianBlur(softPlanes[1], width, height, softRadius);
            var blurredBlue = GaussianBlur(softPlanes[2], width, height, softRadius);
            Parallel.For(0, height, y =>
            {
                var row = y * width;
                for (var x = 0; x < width; x++)
                {
                    var index = row + x;
                    var offset = index * 4;
                    targetPixels[offset] = ToSample(FromLinear(Clamp01(blurredRed[index])));
                    targetPixels[offset + 1] = ToSample(FromLinear(Clamp01(blurredGreen[index])));
                    targetPixels[offset + 2] = ToSample(FromLinear(Clamp01(blurredBlue[index])));
                }
            });
        }

        if (vignetteExponent > 0)
        {
            Parallel.For(0, height, y =>
            {
                for (var x = 0; x < width; x++)
                {
                    var offset = (y * width + x) * 4;
                    var dx = x - centreX;
                    var dyPixel = y - centreY;
                    var distance = Math.Sqrt(dx * dx + dyPixel * dyPixel) / shortSide;
                    // Same measured CIVignette shape as the 8-bit pipeline:
                    // linear light, short-side distance, intensity as exponent.
                    var falloff = SmoothStep(0.03, 1.03, distance);
                    var multiplier = Math.Pow(1 - falloff, vignetteExponent);
                    targetPixels[offset] = ToSample(FromLinear(
                        ToLinear(targetPixels[offset] / 65535.0) * multiplier));
                    targetPixels[offset + 1] = ToSample(FromLinear(
                        ToLinear(targetPixels[offset + 1] / 65535.0) * multiplier));
                    targetPixels[offset + 2] = ToSample(FromLinear(
                        ToLinear(targetPixels[offset + 2] / 65535.0) * multiplier));
                }
            });
        }
        return output;
    }

    private static float[] GaussianBlur(float[] plane, int width, int height, double sigma)
    {
        var support = Math.Max(1, (int)Math.Ceiling(3 * sigma));
        var kernel = new double[support * 2 + 1];
        var total = 0.0;
        for (var step = -support; step <= support; step++)
        {
            var weight = Math.Exp(-(step * (double)step) / (2 * sigma * sigma));
            kernel[step + support] = weight;
            total += weight;
        }
        for (var index = 0; index < kernel.Length; index++)
        {
            kernel[index] /= total;
        }

        var horizontal = new float[plane.Length];
        Parallel.For(0, height, y =>
        {
            var row = y * width;
            for (var x = 0; x < width; x++)
            {
                var sum = 0.0;
                for (var step = -support; step <= support; step++)
                {
                    var sample = Math.Clamp(x + step, 0, width - 1);
                    sum += plane[row + sample] * kernel[step + support];
                }
                horizontal[row + x] = (float)sum;
            }
        });

        var blurred = new float[plane.Length];
        Parallel.For(0, height, y =>
        {
            var row = y * width;
            for (var x = 0; x < width; x++)
            {
                var sum = 0.0;
                for (var step = -support; step <= support; step++)
                {
                    var sample = Math.Clamp(y + step, 0, height - 1);
                    sum += horizontal[sample * width + x] * kernel[step + support];
                }
                blurred[row + x] = (float)sum;
            }
        });
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
