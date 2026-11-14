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
/// The global pass. Input is sRGB 8-bit RGBA. Levels, exposure and contrast run
/// per pixel through the shared weights and scale (levels in the luma-weighted
/// shadow/highlight form, exposure on the 0.30 EV scale in linear light), then
/// warmth, saturation, vibrance, clarity and vignette run per pixel.
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

        var black = 0.30 * adjustments.Blacks / 100.0;
        var white = 1 - 0.30 * adjustments.Whites / 100.0;
        var levelsActive = Math.Abs(black) > 0.001 || Math.Abs(white - 1) > 0.001;
        var shadowK = Math.Max(0.30, 1 - SmoothStep(0, 0.48, black));
        var highlightK = Math.Max(0.30, SmoothStep(0.52, 1, white));
        var gain = Math.Pow(2, 0.30 * adjustments.Exposure / 100.0);
        var contrast = 1 + 0.45 * adjustments.Contrast / 100.0;
        var toneActive = adjustments.Exposure != 0 || adjustments.Contrast != 0;
        var blurred = adjustments.Clarity == 0 ? null : BoxBlur(source.Pixels, source.Width, source.Height);

        var width = source.Width;
        var height = source.Height;
        var output = new PixelBuffer(width, height);
        var sourcePixels = source.Pixels;
        var targetPixels = output.Pixels;

        var saturationFactor = 1 + 0.6 * adjustments.Saturation / 100.0;
        var vibranceAmount = adjustments.Vibrance / 100.0;
        var warmthAmount = adjustments.Warmth / 100.0;
        var clarityAmount = adjustments.Clarity / 100.0 * 0.75;
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
    /// Exposure on the shared 0.30 EV scale in linear light, then a contrast
    /// pivot at mid grey, both in display-referred sRGB like the rest of the
    /// pass.
    /// </summary>
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

    /// <summary>
    /// Three box passes approximate a Gaussian of the radius the shared unsharp
    /// mask uses (0.4% of the short side), and the radius scales with the photo
    /// so the effect reads the same at any resolution.
    /// </summary>
    private static byte[] BoxBlur(byte[] source, int width, int height)
    {
        var radius = Math.Max(1, (int)Math.Round(Math.Min(width, height) * 0.004));
        var current = source;
        for (var pass = 0; pass < 3; pass++)
        {
            current = BlurPass(current, width, height, radius);
        }
        return current;
    }

    private static byte[] BlurPass(byte[] source, int width, int height, int radius)
    {
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

    private static double Clamp01(double value) => Math.Clamp(value, 0, 1);

    private static byte ToByte(double value) => (byte)Math.Clamp(Math.Round(value * 255), 0, 255);
}
