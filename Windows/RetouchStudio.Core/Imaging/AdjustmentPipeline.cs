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

    /// <summary>
    /// True when the pass cannot change a pixel. A negative vignette counts
    /// here because, as on macOS, only a positive vignette is applied.
    /// </summary>
    public bool IsIdentity =>
        Exposure == 0 && Contrast == 0 && Blacks == 0 && Whites == 0 &&
        Saturation == 0 && Vibrance == 0 && Warmth == 0 && Clarity == 0 &&
        Vignette <= 0;
}

/// <summary>
/// The global pass. Input is sRGB 8-bit RGBA. Levels, exposure and contrast run
/// per pixel through the shared weights and scale (levels in the luma-weighted
/// shadow/highlight form, exposure on the 0.30 EV scale in linear light), then
/// warmth, saturation and vibrance run per pixel. Clarity and vignette need
/// neighbourhoods or positions, so they run in their own passes afterwards, in
/// the same order the macOS host applies them.
///
/// Parity with the macOS Core Image pipeline is not claimed for the tone and
/// colour stages: this host works in display-referred sRGB and leaves precision
/// at 8 bits. Two stages follow measured Core Image behaviour because their
/// shapes are cheap to reproduce: the vignette (linear-light multiply, falloff
/// in short-side units, intensity as the exponent) and clarity (CIUnsharpMask's
/// Gaussian — radius used as sigma — followed by the keepLuminance kernel, so
/// only luminance detail moves and colour is left where it was). The contract
/// the rest keeps is behavioural — identity means no change, each slider moves
/// in the documented direction, and the output is deterministic.
/// </summary>
public static class AdjustmentPipeline
{
    public static PixelBuffer Apply(PixelBuffer source, GlobalAdjustments adjustments)
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
        var output = new PixelBuffer(width, height);
        var sourcePixels = source.Pixels;
        var targetPixels = output.Pixels;

        var saturationFactor = 1 + 0.6 * adjustments.Saturation / 100.0;
        var vibranceAmount = adjustments.Vibrance / 100.0;
        var warmthAmount = adjustments.Warmth / 100.0;
        // macOS applies CIVignette only above zero; a negative value there is a
        // no-op, and this host follows that instead of inventing a brightening.
        var vignetteExponent = 1.4 * adjustments.Vignette / 100.0;
        var centreX = (width - 1) / 2.0;
        var centreY = (height - 1) / 2.0;
        var shortSide = Math.Min(width, height);

        // Positive clarity sharpens linear luminance and leaves colour alone,
        // which is what CIUnsharpMask plus SkinEngine.keepLuminance do: the
        // written pixel keeps its own chroma and takes the sharpened luminance.
        // Negative clarity blurs all three channels, exactly as the
        // CIGaussianBlur the macOS host reaches for does. Both read the adjusted
        // picture, so they are captured during the main pass and applied after
        // it, before the vignette.
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
                // The buffer is BGRA: blue at +0, green at +1, red at +2. The
                // per-pixel maths runs in double so a chain of small factors
                // cannot round to an unexpected byte.
                double blue = sourcePixels[offset] / 255.0;
                double green = sourcePixels[offset + 1] / 255.0;
                double red = sourcePixels[offset + 2] / 255.0;

                if (levelsActive)
                {
                    // The shared levels kernel: the endpoint move lands on the
                    // shadows and highlights only, weighted by luma, so the
                    // mid-tones keep their balance. Ported from LookEngine: the
                    // kernel works on linear light encoded with a 1/2.2 gamma,
                    // then returns to linear.
                    var encodedBlue = Math.Pow(ToLinear(blue), 0.4545);
                    var encodedGreen = Math.Pow(ToLinear(green), 0.4545);
                    var encodedRed = Math.Pow(ToLinear(red), 0.4545);
                    var levelLuma = 0.2126 * encodedRed + 0.7152 * encodedGreen
                                  + 0.0722 * encodedBlue;
                    var shadowWeight = 1 - SmoothStep(0, 0.48, levelLuma);
                    var highlightWeight = SmoothStep(0.52, 1, levelLuma);
                    var delta = -black * shadowWeight / shadowK
                              + (1 - white) * highlightWeight / highlightK;
                    blue = FromLinear(Math.Pow(Clamp01(encodedBlue + delta), 2.2));
                    green = FromLinear(Math.Pow(Clamp01(encodedGreen + delta), 2.2));
                    red = FromLinear(Math.Pow(Clamp01(encodedRed + delta), 2.2));
                }

                if (toneActive)
                {
                    blue = Tone(blue, gain, contrast);
                    green = Tone(green, gain, contrast);
                    red = Tone(red, gain, contrast);
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
                    softPlanes[0][y * width + x] = (float)ToLinear(Clamp01(blue));
                    softPlanes[1][y * width + x] = (float)ToLinear(Clamp01(green));
                    softPlanes[2][y * width + x] = (float)ToLinear(Clamp01(red));
                }

                targetPixels[offset] = ToByte(blue);
                targetPixels[offset + 1] = ToByte(green);
                targetPixels[offset + 2] = ToByte(red);
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
                    targetPixels[offset] = ToByte(FromLinear(Clamp01(
                        ToLinear(targetPixels[offset] / 255.0) + detail)));
                    targetPixels[offset + 1] = ToByte(FromLinear(Clamp01(
                        ToLinear(targetPixels[offset + 1] / 255.0) + detail)));
                    targetPixels[offset + 2] = ToByte(FromLinear(Clamp01(
                        ToLinear(targetPixels[offset + 2] / 255.0) + detail)));
                }
            });
        }
        else if (softPlanes is not null)
        {
            var blurredBlue = GaussianBlur(softPlanes[0], width, height, softRadius);
            var blurredGreen = GaussianBlur(softPlanes[1], width, height, softRadius);
            var blurredRed = GaussianBlur(softPlanes[2], width, height, softRadius);
            Parallel.For(0, height, y =>
            {
                var row = y * width;
                for (var x = 0; x < width; x++)
                {
                    var index = row + x;
                    var offset = index * 4;
                    targetPixels[offset] = ToByte(FromLinear(Clamp01(blurredBlue[index])));
                    targetPixels[offset + 1] = ToByte(FromLinear(Clamp01(blurredGreen[index])));
                    targetPixels[offset + 2] = ToByte(FromLinear(Clamp01(blurredRed[index])));
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
                    // CIVignette multiplies in linear light and raises the
                    // falloff to the intensity, so a stronger slider darkens
                    // more than linearly. Both were measured from the filter's
                    // own output; the distance is in short-side units, which
                    // made the falloff identical at 512, 720 and 1024 pixels.
                    var falloff = SmoothStep(0.03, 1.03, distance);
                    var multiplier = Math.Pow(1 - falloff, vignetteExponent);
                    targetPixels[offset] = ToByte(FromLinear(
                        ToLinear(targetPixels[offset] / 255.0) * multiplier));
                    targetPixels[offset + 1] = ToByte(FromLinear(
                        ToLinear(targetPixels[offset + 1] / 255.0) * multiplier));
                    targetPixels[offset + 2] = ToByte(FromLinear(
                        ToLinear(targetPixels[offset + 2] / 255.0) * multiplier));
                }
            });
        }
        return output;
    }

    /// <summary>
    /// Exposure on the shared 0.30 EV scale in linear light, then a contrast
    /// pivot at mid grey, both in display-referred sRGB like the rest of the
    /// pass.
    /// </summary>
    private static double Tone(double value, double gain, double contrast)
    {
        value = FromLinear(ToLinear(value) * gain);
        return Clamp01(0.5 + (value - 0.5) * contrast);
    }

    /// <summary>
    /// A separable Gaussian whose sigma is the radius Core Image's unsharp mask
    /// takes, truncated at three sigma and clamped at the edges the way the
    /// host's clampedToExtent blur is. Three box passes would be faster, but the
    /// measured kernel is a Gaussian, and a box approximation would show as a
    /// ring on the detail chart.
    /// </summary>
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

    private static byte ToByte(double value) => (byte)Math.Clamp(Math.Round(value * 255), 0, 255);
}
