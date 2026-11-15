using RetouchStudio.Core.IO;
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
    /// The document orientation, then the crop, then the global adjustments.
    /// This is the shared model's order: the orientation is baked in first, so
    /// the crop describes the upright frame the owner sees (macOS
    /// <c>ImageProcessor.load</c> does the same and states it).
    /// </summary>
    public static Imaging.PixelBuffer RenderDocument(Imaging.PixelBuffer source,
                                                     DocumentModel document)
    {
        var image = source;
        var orientation = document.Orientation;
        if (!orientation.IsIdentity)
        {
            image = image.ApplyOrientation(orientation);
        }
        if (document.Crop is { } crop)
        {
            image = image.Crop(crop);
        }
        return Imaging.AdjustmentPipeline.Apply(
            image, Imaging.GlobalAdjustments.FromDocument(document));
    }

    /// <summary>
    /// The same order on the 16-bit export buffer: orientation, then crop, then
    /// the global adjustments.
    /// </summary>
    public static Imaging.PixelBuffer16 RenderDocument16(Imaging.PixelBuffer16 source,
                                                         DocumentModel document)
    {
        var image = source;
        var orientation = document.Orientation;
        if (!orientation.IsIdentity)
        {
            image = image.ApplyOrientation(orientation);
        }
        if (document.Crop is { } crop)
        {
            image = image.Crop(crop);
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
                                                     bool stripPrivacyMetadata = true,
                                                     CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var document = session.Document;
        var sourcePath = document.ImagePath;
        if (string.IsNullOrEmpty(sourcePath))
        {
            throw new InvalidOperationException("the document has no photo");
        }
        return await ExportSourceAsync(document, codec, sourcePath, destination,
                                       format, quality, longEdge, stripPrivacyMetadata,
                                       cancellationToken);
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
                                                           bool stripPrivacyMetadata = true,
                                                           CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
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
        cancellationToken.ThrowIfCancellationRequested();

        var fullDestination = Path.GetFullPath(destination);
        // A hidden sibling with a unique name: two exports into the same folder
        // cannot collide. A temp left behind by a crash is swept first, so the
        // folder does not grow one stale file per interrupted export.
        var temporary = TemporaryFiles.SiblingTempPath(fullDestination);
        TemporaryFiles.SweepStaleSiblings(fullDestination);
        try
        {
            // The plan decides the depth. PNG and TIFF are 16-bit containers in
            // the shared contract, so an export to either keeps 16-bit pixels
            // instead of reducing them to the preview's 8-bit buffer.
            if (plan.BitsPerChannel >= 16)
            {
                var decoded = await codec.Decode16Async(sourcePath);
                cancellationToken.ThrowIfCancellationRequested();
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
                cancellationToken.ThrowIfCancellationRequested();
                await codec.Encode16Async(rendered, temporary, plan.Format,
                                          metadata, stripPrivacyMetadata);
                TemporaryFiles.Hide(temporary);
            }
            else
            {
                var decoded = await codec.DecodeAsync(sourcePath);
                cancellationToken.ThrowIfCancellationRequested();
                var rendered = RenderDocument(decoded, document);
                var edge = FitLongEdge(document, plan, longEdge);
                if (edge > 0)
                {
                    rendered = rendered.ResizeLongEdge(edge);
                }
                var output = plan.FlattensAlpha ? rendered.FlattenOntoWhite() : rendered;
                cancellationToken.ThrowIfCancellationRequested();
                await codec.EncodeAsync(output, temporary, plan.Format, quality,
                                        metadata, stripPrivacyMetadata);
                TemporaryFiles.Hide(temporary);
            }

            // A cancel that arrives after the encode must not publish the file:
            // the check sits between the finished encode and the rename.
            cancellationToken.ThrowIfCancellationRequested();
            TemporaryFiles.Unhide(temporary);
            // Publish the temp by rename, so a codec failure, a full disk or a
            // crash cannot leave a partial destination. Replace renames over an
            // existing file without unlinking it first, so a failed publish
            // leaves the old bytes intact; a plain move covers the absent case.
            if (File.Exists(fullDestination))
            {
                File.Replace(temporary, fullDestination, null);
            }
            else
            {
                File.Move(temporary, fullDestination);
            }
        }
        catch
        {
            try
            {
                File.Delete(temporary);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
            throw;
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
