namespace RetouchStudio.Core.Project;

/// <summary>The corner of a crop rectangle a drag moves.</summary>
public enum CropCorner
{
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

/// <summary>A rectangle in display units, top-left origin.</summary>
public readonly record struct DisplayRect(double X, double Y, double Width, double Height);

/// <summary>
/// The arithmetic behind the crop overlay: where the photo sits inside the
/// preview box, and what a drag does to a normalized crop. Both are pure
/// functions, so the drag rules are testable without a window.
/// </summary>
public static class CropGeometry
{
    /// <summary>The smallest crop side, in normalized photo units.</summary>
    public const double MinimumSide = 0.05;

    /// <summary>
    /// The rectangle a uniformly scaled photo occupies inside a box, centred
    /// on both axes — the same placement WPF's <c>Uniform</c> stretch uses.
    /// </summary>
    public static DisplayRect Fit(int photoWidth, int photoHeight,
                                  double boxWidth, double boxHeight)
    {
        if (photoWidth <= 0 || photoHeight <= 0 || boxWidth <= 0 || boxHeight <= 0)
        {
            return new DisplayRect(0, 0, 0, 0);
        }
        var scale = Math.Min(boxWidth / photoWidth, boxHeight / photoHeight);
        var width = photoWidth * scale;
        var height = photoHeight * scale;
        return new DisplayRect((boxWidth - width) / 2, (boxHeight - height) / 2,
                               width, height);
    }

    /// <summary>
    /// Moves one corner by a normalized delta. The moving edges stay inside the
    /// photo and never cross the opposite edges beyond the minimum side; the
    /// others do not move.
    /// </summary>
    public static CropValue Resize(CropValue start, CropCorner corner, double dx, double dy)
    {
        var left = start.X;
        var top = start.Y;
        var right = start.X + start.Width;
        var bottom = start.Y + start.Height;

        if (corner is CropCorner.TopLeft or CropCorner.BottomLeft)
        {
            left = Math.Clamp(left + dx, 0, right - MinimumSide);
        }
        else
        {
            right = Math.Clamp(right + dx, left + MinimumSide, 1);
        }
        if (corner is CropCorner.TopLeft or CropCorner.TopRight)
        {
            top = Math.Clamp(top + dy, 0, bottom - MinimumSide);
        }
        else
        {
            bottom = Math.Clamp(bottom + dy, top + MinimumSide, 1);
        }
        return new CropValue(left, top, right - left, bottom - top);
    }

    /// <summary>
    /// Slides the whole rectangle by a normalized delta, keeping its size and
    /// staying inside the photo.
    /// </summary>
    public static CropValue Move(CropValue start, double dx, double dy)
    {
        var x = Math.Clamp(start.X + dx, 0, 1 - start.Width);
        var y = Math.Clamp(start.Y + dy, 0, 1 - start.Height);
        return start with { X = x, Y = y };
    }

    /// <summary>
    /// The centred crop that makes the finished frame a preset aspect. The crop
    /// is applied to the upright frame (the orientation is baked in first), so
    /// the frame's aspect is the photo's, swapped on an odd quarter turn.
    /// Returns <c>null</c> for the "original" preset, which has no crop.
    /// </summary>
    public static CropValue? Preset(string preset, int sourceWidth, int sourceHeight,
                                    int quarterTurns)
    {
        if (preset == "original" || sourceWidth <= 0 || sourceHeight <= 0)
        {
            return null;
        }
        var aspect = preset switch
        {
            "4:5" => 4.0 / 5.0,
            "3:2" => 3.0 / 2.0,
            "16:9" => 16.0 / 9.0,
            _ => 1.0,
        };
        var turned = ((quarterTurns % 4) + 4) % 4 % 2 != 0;
        var photoAspect = sourceWidth / (double)sourceHeight;
        var frameAspect = turned ? 1 / photoAspect : photoAspect;
        double width = 1;
        double height = 1;
        if (aspect > frameAspect)
        {
            height = frameAspect / aspect;
        }
        else
        {
            width = aspect / frameAspect;
        }
        return new CropValue((1 - width) / 2, (1 - height) / 2, width, height);
    }

    /// <summary>
    /// Brings an arbitrary rectangle inside the photo with both sides at least
    /// <see cref="MinimumSide"/> long, for a value that did not come from a
    /// drag.
    /// </summary>
    public static CropValue Clamp(CropValue value)
    {
        var width = Math.Clamp(value.Width, MinimumSide, 1);
        var height = Math.Clamp(value.Height, MinimumSide, 1);
        var x = Math.Clamp(value.X, 0, 1 - width);
        var y = Math.Clamp(value.Y, 0, 1 - height);
        return new CropValue(x, y, width, height);
    }
}
