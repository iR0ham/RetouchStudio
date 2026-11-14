namespace RetouchStudio.Core.Imaging;

/// <summary>
/// A histogram of the preview, one array per channel plus luma, each bin
/// normalized to the tallest bin across all four. The same shape macOS
/// <c>HistogramBins</c> produces, so both hosts describe the picture the same way.
/// </summary>
public sealed record HistogramBins(double[] Red, double[] Green, double[] Blue, double[] Luma)
{
    public static HistogramBins Empty { get; } =
        new(Array.Empty<double>(), Array.Empty<double>(),
            Array.Empty<double>(), Array.Empty<double>());

    public int Count => Red.Length;

    public bool IsEmpty => Red.Length == 0;
}

/// <summary>
/// Reads the live histogram from the rendered preview. macOS draws the preview
/// into an 80 px copy and bins that; this bins every pixel of the preview
/// buffer the host already holds, which is the same picture without a second
/// resample, and still cheap enough to run on each preview update. Alpha is
/// ignored: the histogram describes the colours, not their coverage.
/// </summary>
public static class HistogramSampler
{
    public static HistogramBins Sample(PixelBuffer image, int count = 64)
    {
        if (image.Width <= 0 || image.Height <= 0 || count <= 0)
        {
            return HistogramBins.Empty;
        }

        var red = new double[count];
        var green = new double[count];
        var blue = new double[count];
        var luma = new double[count];
        var pixels = image.Pixels;
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            var r = pixels[offset + 2];
            var g = pixels[offset + 1];
            var b = pixels[offset];
            red[Bin(r, count)] += 1;
            green[Bin(g, count)] += 1;
            blue[Bin(b, count)] += 1;
            var l = (int)Math.Round(0.2126 * r + 0.7152 * g + 0.0722 * b);
            luma[Bin(l, count)] += 1;
        }

        var peak = Math.Max(Math.Max(Max(red), Max(green)), Math.Max(Max(blue), Max(luma)));
        if (peak <= 0)
        {
            return HistogramBins.Empty;
        }
        return new HistogramBins(Normalize(red, peak), Normalize(green, peak),
                                 Normalize(blue, peak), Normalize(luma, peak));
    }

    private static int Bin(int value, int count) =>
        Math.Min(count - 1, value * count / 256);

    private static double Max(double[] values)
    {
        var peak = 0.0;
        foreach (var value in values)
        {
            peak = Math.Max(peak, value);
        }
        return peak;
    }

    private static double[] Normalize(double[] values, double peak)
    {
        var scaled = new double[values.Length];
        for (var index = 0; index < values.Length; index++)
        {
            scaled[index] = values[index] / peak;
        }
        return scaled;
    }
}
