using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Render;

/// <summary>
/// One export, end to end: render the document, ask StudioCore for the pass
/// contract, follow it and write the file. The order is fixed here so the
/// preview and the export cannot disagree about what a document looks like.
/// </summary>
public static class ExportRunner
{
    /// <summary>
    /// Crop in normalized photo coordinates, then the document orientation,
    /// then the global adjustments. This is the shared model's order: the crop
    /// is stored against the photo, not against the rotated frame.
    /// </summary>
    public static Imaging.PixelBuffer RenderDocument(Imaging.PixelBuffer source,
                                                     DocumentModel document)
    {
        var image = source;
        if (document.Crop is { } crop)
        {
            image = image.Crop(crop);
        }
        var orientation = document.Orientation;
        if (!orientation.IsIdentity)
        {
            image = image.ApplyOrientation(orientation);
        }
        return Imaging.AdjustmentPipeline.Apply(
            image, Imaging.GlobalAdjustments.FromDocument(document));
    }

    public static async Task<ExportPlan> ExportAsync(ProjectSession session,
                                                     Imaging.IImageCodec codec,
                                                     string destination,
                                                     string format,
                                                     double quality,
                                                     int longEdge,
                                                     bool stripPrivacyMetadata = true)
    {
        var document = session.Document;
        var sourcePath = document.ImagePath;
        if (string.IsNullOrEmpty(sourcePath))
        {
            throw new InvalidOperationException("the document has no photo");
        }
        if (SameFile(sourcePath, destination))
        {
            throw new InvalidOperationException(
                "the export destination is the opened photo; refusing to overwrite it");
        }

        var decoded = await codec.DecodeAsync(sourcePath);
        var plan = RenderRequests.Plan(document, decoded.Width, decoded.Height,
                                       format, quality, longEdge,
                                       stripsPrivacyMetadata: stripPrivacyMetadata);
        if (plan.Upscales)
        {
            // The planner can only ask for an upscale when aiUpscale is true,
            // and this host never asks. A true here means the contract changed
            // under the host, so refuse instead of ignoring it.
            throw new NotSupportedException("this host has no AI upscaler");
        }

        var rendered = RenderDocument(decoded, document);

        if (document.Crop is null && document.Orientation.IsIdentity && plan.Width > 0)
        {
            // No geometry transform: the plan's size is the photo scaled to the
            // requested long edge, so it can be honoured exactly.
            rendered = rendered.ResizeLongEdge(Math.Max(plan.Width, plan.Height));
        }
        else if (longEdge > 0)
        {
            // A crop or a turn changes the frame's aspect, so the plan's pixel
            // size describes the whole photo, not this frame. The owner's
            // request is the long edge, and this host keeps the frame's aspect.
            rendered = rendered.ResizeLongEdge(longEdge);
        }

        // The plan says whether this export is a photograph. The metadata is
        // read even when stripping is on, because the resolution travels with
        // the pixels either way; the codec copies the identity keys only when
        // stripping is off.
        var metadata = plan.CarriesSourceMetadata
            ? await codec.ReadMetadataAsync(sourcePath)
            : Imaging.ImageMetadata.Empty;
        await codec.EncodeAsync(plan.FlattensAlpha ? rendered.FlattenOntoWhite() : rendered,
                                destination, plan.Format, quality,
                                metadata, stripPrivacyMetadata);
        return plan;
    }

    private static bool SameFile(string first, string second)
    {
        try
        {
            return string.Equals(
                Path.GetFullPath(first), Path.GetFullPath(second),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }
}
