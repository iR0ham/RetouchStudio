import CoreGraphics
import Foundation
import StudioCore

/// What one batch file inherits from the open document.
///
/// The shared look, format, quality, privacy answer, watermark and include
/// options come from the base request. Crop, orientation, face choice and
/// analysis pins describe one photo, so they only travel to that photo. The
/// plan is pure; loading, rendering, cancellation and writing stay in the shell.
struct BatchPlanner {
    struct FilePlan {
        var snapshot: RenderRequest
        /// True when the document had a crop this file could not use.
        var skippedCrop: Bool
    }

    var base: RenderRequest
    var documentURL: URL?
    var documentAspect: CGFloat

    func plan(for fileURL: URL, fileAspect: CGFloat) -> FilePlan {
        let snapshot = BatchRenderPolicy.request(base, fileURL: fileURL,
                                                 documentURL: documentURL,
                                                 documentAspect: Double(documentAspect),
                                                 fileAspect: Double(fileAspect))
        return FilePlan(snapshot: snapshot,
                        skippedCrop: base.crop != nil && snapshot.crop == nil)
    }

    /// Upscaling was decided for the document. A file that already reaches the
    /// requested size does not need it, and one past the 4x ceiling is written
    /// at its own size rather than failing the whole batch.
    func fitUpscale(_ snapshot: RenderRequest, to pixelSize: CGSize) -> RenderRequest {
        RenderPolicy.fittingUpscale(snapshot, to: StudioSize(pixelSize))
    }

    static func uniqueOutputURL(for url: URL,
                                in folder: URL,
                                format: ExportFormat,
                                exists: (URL) -> Bool = {
                                    FileManager.default.fileExists(atPath: $0.path)
                                }) -> URL {
        BatchRenderPolicy.uniqueOutputURL(for: url, in: folder,
                                          format: format, exists: exists)
    }
}
