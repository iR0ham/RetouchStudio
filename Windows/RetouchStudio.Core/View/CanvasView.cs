namespace RetouchStudio.Core.View;

/// <summary>
/// Zoom and pan for the photo canvas, at the same limits and with the same
/// arithmetic as the macOS canvas: 1× means fitted to the window, 4× is the
/// ceiling, a zoom about the pointer keeps the point under the pointer still,
/// and a pan never drags the photo off its canvas. The caller supplies the
/// fitted photo size and the canvas size in the same units, so this class has
/// no dependency on a UI toolkit and can be checked headlessly.
/// </summary>
public sealed class CanvasView
{
    public const double MinZoom = 1.0;
    public const double MaxZoom = 4.0;
    public const double ZoomStep = 1.5;

    // macOS treats anything at or below 1.0001 as fitted, so a rounding error
    // cannot leave a pan that the clamps have already flattened.
    private const double FittedTolerance = 0.0001;

    public double Zoom { get; private set; } = MinZoom;
    public double PanX { get; private set; }
    public double PanY { get; private set; }

    public bool IsZoomed => Zoom > MinZoom + FittedTolerance;

    public string ZoomText => IsZoomed
        ? $"{Math.Round(Zoom * 100, MidpointRounding.AwayFromZero):0}%"
        : "Fit";

    public void Reset()
    {
        Zoom = MinZoom;
        PanX = 0;
        PanY = 0;
    }

    /// <summary>
    /// Zooms about a point given in canvas coordinates — the same rule macOS
    /// applies to a pinch or a ⌘-scroll: the image point under the pointer
    /// stays under it, then the pan is clamped so the photo still covers the
    /// canvas when it is larger, and cannot leave it when it is not.
    /// </summary>
    public void SetZoom(double value, double anchorX, double anchorY,
                        double fittedWidth, double fittedHeight,
                        double canvasWidth, double canvasHeight)
    {
        var clamped = Math.Clamp(value, MinZoom, MaxZoom);
        var ratio = clamped / Zoom;
        if (fittedWidth > 0 && fittedHeight > 0 && canvasWidth > 0 && canvasHeight > 0)
        {
            var ax = anchorX - canvasWidth / 2;
            var ay = anchorY - canvasHeight / 2;
            PanX = ax - (ax - PanX) * ratio;
            PanY = ay - (ay - PanY) * ratio;
        }
        Zoom = clamped;
        if (IsZoomed)
        {
            ClampPan(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        }
        else
        {
            PanX = 0;
            PanY = 0;
        }
    }

    /// <summary>Zooms about the canvas centre, for a button or a shortcut.</summary>
    public void SetZoomCentered(double value, double fittedWidth, double fittedHeight,
                                double canvasWidth, double canvasHeight) =>
        SetZoom(value, canvasWidth / 2, canvasHeight / 2, fittedWidth, fittedHeight,
                canvasWidth, canvasHeight);

    public void ZoomIn(double fittedWidth, double fittedHeight,
                       double canvasWidth, double canvasHeight) =>
        SetZoomCentered(Zoom * ZoomStep, fittedWidth, fittedHeight, canvasWidth, canvasHeight);

    public void ZoomOut(double fittedWidth, double fittedHeight,
                        double canvasWidth, double canvasHeight) =>
        SetZoomCentered(Zoom / ZoomStep, fittedWidth, fittedHeight, canvasWidth, canvasHeight);

    /// <summary>A double-click toggles between fitted and the 4× ceiling.</summary>
    public void Toggle(double fittedWidth, double fittedHeight,
                       double canvasWidth, double canvasHeight)
    {
        if (IsZoomed)
        {
            Reset();
        }
        else
        {
            SetZoomCentered(MaxZoom, fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        }
    }

    /// <summary>Slides the photo by a screen-space delta and re-clamps it.</summary>
    public void PanBy(double dx, double dy, double fittedWidth, double fittedHeight,
                      double canvasWidth, double canvasHeight)
    {
        PanX += dx;
        PanY += dy;
        ClampPan(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
    }

    public void ClampPan(double fittedWidth, double fittedHeight,
                         double canvasWidth, double canvasHeight)
    {
        var displayedWidth = fittedWidth * Zoom;
        var displayedHeight = fittedHeight * Zoom;
        if (displayedWidth <= 0 || canvasWidth <= 0)
        {
            PanX = 0;
            PanY = 0;
            return;
        }
        var maxX = Math.Max(0, (displayedWidth - canvasWidth) / 2);
        var maxY = Math.Max(0, (displayedHeight - canvasHeight) / 2);
        PanX = Math.Min(maxX, Math.Max(-maxX, PanX));
        PanY = Math.Min(maxY, Math.Max(-maxY, PanY));
    }
}
