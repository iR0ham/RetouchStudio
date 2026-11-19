import Foundation

/// What the local upscaler can promise, decided before a job is queued.
///
/// The model is a fixed 4x pass with a 40 MP output ceiling. Mirroring both
/// numbers here means the export sheet and the renderer say no in the same
/// terms the helper would use.
public enum RenderUpscale {
    public static let factor: Double = 4
    public static let maxOutputPixels = 40_000_000

    public static func canHandle(_ size: StudioSize) -> Bool {
        guard size.width >= 1, size.height >= 1 else { return false }
        let width = Int((size.width * factor).rounded())
        let height = Int((size.height * factor).rounded())
        return width * height <= maxOutputPixels
    }

    /// The long edge actually written: 4x the photo, but never past the edge
    /// the owner picked.
    public static func outputLongEdge(sourceLong: Double, requested: Double?) -> Double {
        let quadrupled = sourceLong * factor
        guard let requested, requested > 0 else { return quadrupled }
        return min(quadrupled, requested)
    }

    /// Planning estimate for an upscale pass: a fixed per-job cost plus a
    /// rate per output mega-pixel.
    ///
    /// Measured on a 16 GB M3 (macOS 27.2) with the default 256 px tiles on
    /// 2026-11-19, on the banded path at `77951c3`: four cold first jobs
    /// wrote 4.000, 9.986, 20.070 and 39.942 output mega-pixels in 46.94,
    /// 100.22, 176.48 and 354.84 s (11.74, 10.04, 8.79 and 8.88 s per
    /// output-MP), and a warm repeat at 20.070 MP took 189.68 s.
    /// `Docs/W5_UPSCALER_ACCEPTANCE.md` §12.5 records the runs.
    ///
    /// A least-squares fit over the cold jobs gives 11.9 s + 8.53 s/MP. The
    /// base is rounded up to 12 s, and the warm repeat raises the rate the
    /// base must carry to 8.85 s/MP, so the rate is rounded up to 9.0. The
    /// estimate therefore never under-predicts a measured job, and the 40 MP
    /// ceiling projects 372 s against the host's 1500 s wait.
    ///
    /// It is a developer-machine measurement, not a shipped build, and only
    /// feeds the sheet's estimate; the helper's own tile report is the
    /// measured truth while a job runs.
    public static let baseSeconds = 12.0

    /// See `baseSeconds`: 9.0 s per output mega-pixel, above the measured
    /// 8.53–8.88 s/MP so the projection stays conservative.
    public static let secondsPerOutputMegapixel = 9.0

    public static func estimatedSeconds(for size: StudioSize) -> Int {
        let megapixels = (size.width * factor) * (size.height * factor) / 1_000_000
        return Int((baseSeconds + megapixels * secondsPerOutputMegapixel).rounded())
    }
}

/// The decisions a single-photo export makes before any pixel is touched.
///
/// Naming, format, output size and the pass plan live here so the export
/// sheet, the single export and the batch cannot read a different answer from
/// the same document.
public enum RenderPolicy {

    /// The upscaler only runs when the owner asked for a larger long edge than
    /// the photo already has, and the helper accepts that output size.
    public static func upscaleAvailable(source: StudioSize, longEdge: Double) -> Bool {
        guard longEdge > 0, source.width > 0, source.height > 0 else { return false }
        let longest = max(source.width, source.height)
        return longest < longEdge && RenderUpscale.canHandle(source)
    }

    public static func upscaleEstimate(source: StudioSize) -> Int {
        RenderUpscale.estimatedSeconds(for: source)
    }

    /// An overlay-only export is lines on transparency, so it is always PNG.
    /// A batch that leaves the callouts out is not an overlay export at all:
    /// forcing PNG there would write a transparent-format file for a job that
    /// only asked for the photo.
    public static func effectiveFormat(chosen: ExportFormat,
                                       analysis: AnalysisSettings,
                                       includeAnalysis: Bool,
                                       faceCount: Int) -> ExportFormat {
        includeAnalysis && analysis.isEnabled
            && analysis.exportMode == .overlayOnly && faceCount > 0
            ? .png : chosen
    }

    /// Pixel size the export will actually write. Downscaling never enlarges a
    /// photo; a larger long edge is only reached through the upscaler.
    public static func outputPixelSize(source: StudioSize, longEdge: Double,
                                       upscales: Bool) -> StudioSize {
        guard longEdge > 0, source.width > 0, source.height > 0 else { return source }
        let longest = max(source.width, source.height)
        if longest >= longEdge {
            let scale = longEdge / longest
            return StudioSize(width: (source.width * scale).rounded(),
                              height: (source.height * scale).rounded())
        }
        guard upscales else { return source }
        let edge = RenderUpscale.outputLongEdge(sourceLong: longest, requested: longEdge)
        let scale = edge / longest
        return StudioSize(width: (source.width * scale).rounded(),
                          height: (source.height * scale).rounded())
    }

    public static func suggestedFileName(imageName: String, format: ExportFormat,
                                         analysis: AnalysisSettings,
                                         faceCount: Int) -> String {
        let base = (imageName as NSString).deletingPathExtension
        let name = base.isEmpty ? "retouched" : "\(base)-retouched"
        // A file name that says "analysis" promises callouts the export cannot
        // draw when the host found no face.
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

    /// The complete pass contract for one request on one decoded photo.
    public static func plan(_ request: RenderRequest,
                            source: RenderSourceDescription) -> RenderPlan {
        let linesOnly = request.includeAnalysis && request.analysis.isEnabled
            && request.analysis.exportMode == .overlayOnly && source.faceCount > 0
        let format = linesOnly ? .png : request.format
        let upscales = request.aiUpscale
        let size = outputPixelSize(source: source.pixelSize,
                                   longEdge: request.longEdge ?? 0,
                                   upscales: upscales)
        return RenderPlan(format: format,
                          pixelSize: size,
                          upscales: upscales,
                          appliesAnalysis: request.includeAnalysis
                              && request.analysis.isEnabled && source.faceCount > 0,
                          appliesWatermark: request.watermark.isActive && !linesOnly,
                          flattensAlpha: format.flattensAlpha,
                          bitsPerChannel: format.bitsPerChannel,
                          // 1.0 writes every export in sRGB whether or not
                          // the source is wide-gamut; the decoded source
                          // profile stays the working space, not the output.
                          colorSpace: .sRGB,
                          carriesSourceMetadata: !linesOnly)
    }

    /// A batch shares one upscale answer. A file that already reaches the
    /// requested size does not need the pass, and one past the ceiling is
    /// written at its own size rather than failing the whole batch.
    public static func fittingUpscale(_ request: RenderRequest,
                                      to pixelSize: StudioSize) -> RenderRequest {
        guard request.aiUpscale else { return request }
        var request = request
        let longest = max(pixelSize.width, pixelSize.height)
        if longest >= (request.longEdge ?? 0)
            || !RenderUpscale.canHandle(pixelSize) {
            request.aiUpscale = false
        }
        return request
    }
}
