namespace RetouchStudio.Core.View;

/// <summary>
/// The before/after split: a fraction of the displayed photo, measured from its
/// left edge, that shows the untouched photo, with the edit on the rest. The
/// same rule as the macOS canvas — the default is 0.45, dragging adds the
/// pointer delta divided by the displayed width, and the split cannot leave the
/// photo.
/// </summary>
public static class CompareSplit
{
    public const double DefaultFraction = 0.45;

    public static double Clamp(double fraction) => Math.Clamp(fraction, 0, 1);

    public static double Move(double fraction, double deltaX, double displayedWidth) =>
        displayedWidth <= 0 ? Clamp(fraction) : Clamp(fraction + deltaX / displayedWidth);
}
