import CoreGraphics
import Foundation

/// What one batch file inherits from the open document.
///
/// The shared look, format, quality, privacy answer, watermark and include
/// options come from the base snapshot. Crop, orientation, face choice and
/// analysis pins describe one photo, so they only travel to that photo. The
/// plan is pure; loading, rendering, cancellation and writing stay in the shell.
struct BatchPlanner {
    struct FilePlan {
        var snapshot: ExportSnapshot
        /// True when the document had a crop this file could not use.
        var skippedCrop: Bool
    }

    var base: ExportSnapshot
    var documentURL: URL?
    var documentAspect: CGFloat

    func plan(for fileURL: URL, fileAspect: CGFloat) -> FilePlan {
        let snapshot = BatchExportPolicy.snapshot(base, fileURL: fileURL,
                                                  documentURL: documentURL,
                                                  documentAspect: documentAspect,
                                                  fileAspect: fileAspect)
        return FilePlan(snapshot: snapshot,
                        skippedCrop: base.crop != nil && snapshot.crop == nil)
    }

    /// Upscaling was decided for the document. A file that already reaches the
    /// requested size does not need it, and one past the 4x ceiling is written
    /// at its own size rather than failing the whole batch.
    func fitUpscale(_ snapshot: ExportSnapshot, to pixelSize: CGSize) -> ExportSnapshot {
        guard snapshot.aiUpscale else { return snapshot }
        var snapshot = snapshot
        let longest = max(pixelSize.width, pixelSize.height)
        if longest >= (snapshot.longEdge ?? 0)
            || !ExportUpscale.canHandle(pixelSize) {
            snapshot.aiUpscale = false
        }
        return snapshot
    }

    static func uniqueOutputURL(for url: URL,
                                in folder: URL,
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
