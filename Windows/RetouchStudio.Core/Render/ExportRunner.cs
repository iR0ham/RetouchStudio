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

    /// <summary>
    /// The same order on the 16-bit export buffer: crop, orientation, then the
    /// global adjustments.
    /// </summary>
    public static Imaging.PixelBuffer16 RenderDocument16(Imaging.PixelBuffer16 source,
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
        return Imaging.AdjustmentPipeline16.Apply(
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
        return await ExportSourceAsync(document, codec, sourcePath, destination,
                                       format, quality, longEdge, stripPrivacyMetadata);
    }

    /// <summary>
    /// One export from an explicit source, for a document whose edits apply to a
    /// photo other than the opened one. A batch uses this so every file takes
    /// the same path as a single export.
    /// </summary>
    public static async Task<ExportPlan> ExportSourceAsync(DocumentModel document,
                                                           Imaging.IImageCodec codec,
                                                           string sourcePath,
                                                           string destination,
                                                           string format,
                                                           double quality,
                                                           int longEdge,
                                                           bool stripPrivacyMetadata = true)
    {
        if (SameFile(sourcePath, destination))
        {
            throw new InvalidOperationException(
                "the export destination is the opened photo; refusing to overwrite it");
        }

        // The size is read from the header so the plan — including its bit
        // depth — is known before a buffer is allocated. Decoding first would
        // mean either guessing the depth from the format or decoding twice.
        var size = await codec.ReadSizeAsync(sourcePath);
        var plan = RenderRequests.Plan(document, size.Width, size.Height,
                                       format, quality, longEdge,
                                       stripsPrivacyMetadata: stripPrivacyMetadata);
        if (plan.Upscales)
        {
            // The planner can only ask for an upscale when aiUpscale is true,
            // and this host never asks. A true here means the contract changed
            // under the host, so refuse instead of ignoring it.
            throw new NotSupportedException("this host has no AI upscaler");
        }

        // The plan says whether this export is a photograph. The metadata is
        // read even when stripping is on, because the resolution travels with
        // the pixels either way; the codec copies the identity keys only when
        // stripping is off.
        var metadata = plan.CarriesSourceMetadata
            ? await codec.ReadMetadataAsync(sourcePath)
            : Imaging.ImageMetadata.Empty;

        // The plan decides the depth. PNG and TIFF are 16-bit containers in the
        // shared contract, so an export to either keeps 16-bit pixels instead
        // of reducing them to the preview's 8-bit buffer.
        if (plan.BitsPerChannel >= 16)
        {
            var decoded = await codec.Decode16Async(sourcePath);
            var rendered = RenderDocument16(decoded, document);
            var edge = FitLongEdge(document, plan, longEdge);
            if (edge > 0)
            {
                rendered = rendered.ResizeLongEdge(edge);
            }
            if (plan.FlattensAlpha)
            {
                rendered = rendered.FlattenOntoWhite();
            }
            await codec.Encode16Async(rendered, destination, plan.Format,
                                      metadata, stripPrivacyMetadata);
        }
        else
        {
            var decoded = await codec.DecodeAsync(sourcePath);
            var rendered = RenderDocument(decoded, document);
            var edge = FitLongEdge(document, plan, longEdge);
            if (edge > 0)
            {
                rendered = rendered.ResizeLongEdge(edge);
            }
            await codec.EncodeAsync(plan.FlattensAlpha ? rendered.FlattenOntoWhite() : rendered,
                                    destination, plan.Format, quality,
                                    metadata, stripPrivacyMetadata);
        }
        return plan;
    }

    /// <summary>
    /// The long edge to resize to, or zero to keep the frame's own size.
    /// Without a crop or a turn the plan's pixel size is the photo scaled to
    /// the requested long edge, so it can be honoured exactly. A crop or a turn
    /// changes the frame's aspect, so the plan's size describes the whole photo
    /// and only the owner's long edge applies; the frame keeps its aspect.
    /// </summary>
    private static int FitLongEdge(DocumentModel document, ExportPlan plan, int longEdge)
    {
        if (document.Crop is null && document.Orientation.IsIdentity && plan.Width > 0)
        {
            return Math.Max(plan.Width, plan.Height);
        }
        return longEdge > 0 ? longEdge : 0;
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
