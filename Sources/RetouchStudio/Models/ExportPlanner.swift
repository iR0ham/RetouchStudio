import CoreGraphics
import Foundation
import StudioCore

/// The decisions a single-photo export makes before any pixel is touched.
///
/// Naming, format, output size, upscale eligibility and the snapshot handed to
/// the renderer live here so the sheet, the export and the batch cannot read a
/// different answer from the same document.
struct ExportPlanner {
    var adjustments: Adjustments
    var healSpots: [HealSpot]
    var stickers: [Sticker]
    var aiEdits: [AIEdit]
    var analysis: AnalysisSettings
    var crop: CGRect?
    var orientation: DocumentOrientation
    var selectedFaceIndex: Int?
    var imageName: String
    var faceCount: Int
    var workingPixelSize: CGSize
    var format: ExportFormat
    var quality: Double
    /// Zero keeps the photo's own size.
    var longEdge: Int
    var aiUpscale: Bool
    var stripsMetadata: Bool
    var watermark: WatermarkSettings

    /// The upscaler only runs when the owner asked for a larger long edge than
    /// the photo already has, and the helper accepts that output size.
    var upscaleAvailable: Bool {
        let size = workingPixelSize
        guard longEdge > 0, size.width > 0, size.height > 0 else { return false }
        let longest = max(size.width, size.height)
        return longest < CGFloat(longEdge) && ExportUpscale.canHandle(size)
    }

    var usesUpscale: Bool { aiUpscale && upscaleAvailable }

    var upscaleEstimate: Int { ExportUpscale.estimatedSeconds(for: workingPixelSize) }

    /// An overlay-only export is lines on transparency, so it is always PNG.
    var effectiveFormat: ExportFormat {
        analysis.isEnabled && analysis.exportMode == .overlayOnly && faceCount > 0
            ? .png : format
    }

    /// Pixel size the export will actually write. Downscaling never enlarges a
    /// photo; a larger long edge is only reached through the upscaler.
    var pixelSize: CGSize {
        let size = workingPixelSize
        guard longEdge > 0, size.width > 0, size.height > 0 else { return size }
        let longest = max(size.width, size.height)
        if longest >= CGFloat(longEdge) {
            let scale = CGFloat(longEdge) / longest
            return CGSize(width: (size.width * scale).rounded(),
                          height: (size.height * scale).rounded())
        }
        guard usesUpscale else { return size }
        let edge = ExportUpscale.outputLongEdge(sourceLong: longest,
                                                requested: CGFloat(longEdge))
        let scale = edge / longest
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }

    func suggestedFileName() -> String {
        let base = (imageName as NSString).deletingPathExtension
        let name = base.isEmpty ? "retouched" : "\(base)-retouched"
        // A file name that says "analysis" promises callouts the export cannot
        // draw when Vision found no face.
        guard analysis.isEnabled, faceCount > 0 else {
            return "\(name).\(format.fileExtension)"
        }
        switch analysis.exportMode {
        case .onPhoto:
            return "\(name)-analysis.\(format.fileExtension)"
        case .poster:
            return "\(name)-analysis-poster.\(format.fileExtension)"
        case .overlayOnly:
            return "\(name)-analysis-lines.png"
        }
    }

    func snapshot(includeStamps: Bool = true,
                  includeAnalysis: Bool = true) -> ExportSnapshot {
        ExportSnapshot(adjustments: adjustments,
                       healSpots: healSpots,
                       stickers: stickers,
                       aiEdits: aiEdits,
                       analysis: analysis,
                       crop: crop,
                       orientation: orientation,
                       selectedFaceIndex: selectedFaceIndex,
                       format: effectiveFormat,
                       quality: quality,
                       longEdge: longEdge > 0 ? CGFloat(longEdge) : nil,
                       stripsPrivacyMetadata: stripsMetadata,
                       includeStamps: includeStamps,
                       includeAnalysis: includeAnalysis,
                       aiUpscale: usesUpscale,
                       watermark: watermark)
    }
}
