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
        var snapshot = base
        let applies = ExportService.cropApplies(base.crop,
                                                documentAspect: documentAspect,
                                                fileAspect: fileAspect)
        snapshot.crop = applies ? base.crop : nil
        guard fileURL.resolvingSymlinksInPath() != documentURL else { return snapshot }

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
