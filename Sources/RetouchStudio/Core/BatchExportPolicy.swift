import CoreGraphics
import Foundation

/// Which parts of the open document's export snapshot belong to one batch file.
///
/// The look, format, quality, privacy answer, watermark, upscale policy and the
/// include options are shared by the whole batch. The crop, selected face and
/// analysis pins describe one photo's frame, so they travel only when the file
/// being written is that photo. Every other file gets its own automatic focus
/// and callout layout.
enum BatchExportPolicy {
    static func snapshot(_ base: ExportSnapshot,
                         fileURL: URL,
                         documentURL: URL?,
                         documentAspect: CGFloat,
                         fileAspect: CGFloat) -> ExportSnapshot {
        // The document's own file always keeps the crop it was edited with.
        // After a quarter turn the crop is expressed in the turned frame while
        // `fileAspect` still describes the unturned file, so the aspect gate
        // below cannot judge that crop. Single-file export already uses these
        // exact crop and orientation values together.
        guard fileURL.resolvingSymlinksInPath() != documentURL else { return base }

        var snapshot = base
        // A quarter turn or mirror re-expresses the crop in a different frame.
        // Another photo opens in its own frame, so that crop must not travel.
        let sharesDocumentFrame = base.orientation.quarterTurns == 0
            && !base.orientation.flipped
        let applies = sharesDocumentFrame
            && ExportService.cropApplies(base.crop,
                                         documentAspect: documentAspect,
                                         fileAspect: fileAspect)
        snapshot.crop = applies ? base.crop : nil

        // A patch describes exactly the pixels it was generated from, and the
        // turn belongs to this photo's frame.
        snapshot.aiEdits = []
        snapshot.orientation = .identity
        // Face selection and the dragged leader ends are photo coordinates.
        snapshot.selectedFaceIndex = nil
        snapshot.analysis.resetEndpoints()
        snapshot.analysis.resetAnchors()
        return snapshot
    }
}
