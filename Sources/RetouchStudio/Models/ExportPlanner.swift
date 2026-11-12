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
    var crop: StudioRect?
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
        RenderPolicy.upscaleAvailable(source: StudioSize(workingPixelSize),
                                      longEdge: Double(longEdge))
    }

    var usesUpscale: Bool { aiUpscale && upscaleAvailable }

    var upscaleEstimate: Int {
        RenderPolicy.upscaleEstimate(source: StudioSize(workingPixelSize))
    }

    var effectiveFormat: ExportFormat { effectiveFormat(includeAnalysis: true) }

    /// An overlay-only export is lines on transparency, so it is always PNG.
    func effectiveFormat(includeAnalysis: Bool) -> ExportFormat {
        RenderPolicy.effectiveFormat(chosen: format, analysis: analysis,
                                     includeAnalysis: includeAnalysis,
                                     faceCount: faceCount)
    }

    /// Pixel size the export will actually write. Downscaling never enlarges a
    /// photo; a larger long edge is only reached through the upscaler.
    var pixelSize: CGSize {
        RenderPolicy.outputPixelSize(source: StudioSize(workingPixelSize),
                                     longEdge: Double(longEdge),
                                     upscales: usesUpscale).cgSize
    }

    func suggestedFileName() -> String {
        RenderPolicy.suggestedFileName(imageName: imageName, format: format,
                                       analysis: analysis, faceCount: faceCount)
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
                       format: effectiveFormat(includeAnalysis: includeAnalysis),
                       quality: quality,
                       longEdge: longEdge > 0 ? Double(longEdge) : nil,
                       stripsPrivacyMetadata: stripsMetadata,
                       includeStamps: includeStamps,
                       includeAnalysis: includeAnalysis,
                       aiUpscale: usesUpscale,
                       watermark: watermark)
    }
}
