import Foundation

/// Which parts of one request belong to one batch file.
///
/// The look, format, quality, privacy answer, watermark, upscale policy and the
/// include options are shared by the whole batch. The crop, selected face and
/// analysis pins describe one photo's frame, so they travel only when the file
/// being written is that photo. Every other file gets its own automatic focus
/// and callout layout.
public enum BatchRenderPolicy {

    /// The document's crop only describes a file of the same shape. A square
    /// photo under a 4:3 crop has no matching region: cropping it would cut
    /// away a corner of a different picture, so it exports whole instead.
    public static func cropApplies(_ crop: StudioRect?,
                                   documentAspect: Double,
                                   fileAspect: Double) -> Bool {
        guard crop != nil, documentAspect > 0, fileAspect > 0 else { return false }
        return abs(log(fileAspect / documentAspect)) < 0.01
    }

    public static func request(_ base: RenderRequest,
                               fileURL: URL,
                               documentURL: URL?,
                               documentAspect: Double,
                               fileAspect: Double) -> RenderRequest {
        // The document's own file always keeps the crop it was edited with.
        // After a quarter turn the crop is expressed in the turned frame while
        // `fileAspect` still describes the unturned file, so the aspect gate
        // below cannot judge that crop. Single-file export already uses these
        // exact crop and orientation values together.
        guard fileURL.resolvingSymlinksInPath() != documentURL else { return base }

        var request = base
        // A quarter turn or mirror re-expresses the crop in a different frame.
        // Another photo opens in its own frame, so that crop must not travel.
        let sharesDocumentFrame = base.orientation.quarterTurns == 0
            && !base.orientation.flipped
        let applies = sharesDocumentFrame
            && cropApplies(base.crop, documentAspect: documentAspect,
                           fileAspect: fileAspect)
        request.crop = applies ? base.crop : nil

        // A patch describes exactly the pixels it was generated from, and the
        // turn belongs to this photo's frame.
        request.aiEdits = []
        request.orientation = .identity
        // Face selection and the dragged leader ends are photo coordinates.
        request.selectedFaceIndex = nil
        request.analysis.resetEndpoints()
        request.analysis.resetAnchors()
        return request
    }

    /// A destination name that does not replace an earlier file in the same
    /// batch.
    public static func uniqueOutputURL(for url: URL, in folder: URL,
                                       format: ExportFormat,
                                       exists: (URL) -> Bool = {
                                           FileManager.default.fileExists(atPath: $0.path)
                                       }) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        var out = folder.appendingPathComponent("\(base)-retouched.\(format.fileExtension)")
        var counter = 2
        while exists(out) {
            out = folder.appendingPathComponent("\(base)-retouched-\(counter).\(format.fileExtension)")
            counter += 1
        }
        return out
    }
}
