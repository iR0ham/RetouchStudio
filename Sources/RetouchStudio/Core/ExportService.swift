import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Everything an export takes from the document instead of from the pixels it
/// lands on. The single-photo export and the batch export both build one of
/// these and hand it to `ExportService`, so the two entry points cannot drift.
struct ExportSnapshot: Equatable {
    var adjustments = Adjustments()
    var healSpots: [HealSpot] = []
    var stickers: [Sticker] = []
    var analysis = AnalysisSettings()
    /// Crop in normalized photo coordinates with a top-left origin.
    var crop: CGRect?
    /// Index into the photo's sorted faces, or nil for the automatic choice.
    /// Feature sizes and the callouts follow it, so an export matches what the
    /// editor showed.
    var selectedFaceIndex: Int?
    var format: ExportFormat = .jpeg
    var quality: Double = 0.92
    var longEdge: CGFloat?
    /// Manual repairs and placed art. Off for batch work unless asked for:
    /// stamps describe one face's blemishes, not another photo's.
    var includeStamps = true
    /// The analysis callouts. Off for batch work unless asked for.
    var includeAnalysis = true
}

/// One image's pixels and measurements, as `ImageProcessor.load` reports them.
struct ExportSource {
    var image: CIImage
    var masks: MaskSet?
    var faces: [FaceGeometry]
    /// Pixel aspect ratio of the whole photo before any crop. Sticker sizes are
    /// stored against the photo's short side, so this is the frame they map
    /// from.
    var photoAspect: CGFloat
    var colorSpace: CGColorSpace?
    var metadata: [CFString: Any]
}

struct RenderedExport {
    var image: CIImage
    /// A lines-only export is art on transparency, not a photograph, so the
    /// source EXIF must not travel with it.
    var carriesSourceMetadata: Bool
}

enum ExportService {

    /// How a one-photo export ended. `cancelled` is distinct from `failed`
    /// because nothing was written and the owner asked for it.
    enum Outcome {
        case saved, cancelled, failed
    }

    /// Renders and writes in one cancellable step. Cancellation is checked
    /// before the expensive render and again before the file is committed, so
    /// a cancelled export leaves no photo behind even though Core Image itself
    /// does not stop early.
    static func run(_ snapshot: ExportSnapshot, source: ExportSource, to url: URL) -> Outcome {
        if Task.isCancelled { return .cancelled }
        guard let rendered = render(snapshot, source: source) else { return .failed }
        if Task.isCancelled { return .cancelled }
        let wrote = write(rendered, snapshot: snapshot, to: url,
                          colorSpace: source.colorSpace, metadata: source.metadata)
        return wrote ? .saved : .failed
    }

    /// Aspect ratio of the file as the pipeline will decode it, orientation
    /// applied. Read from metadata so a batch can decide about the crop before
    /// paying for a full decode.
    static func pixelAspect(of url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // EXIF 5–8 turn the picture a quarter turn, swapping width and height.
        return orientation >= 5 ? height / width : width / height
    }

    /// The document's crop only describes a file of the same shape. A square
    /// photo under a 4:3 crop has no matching region: cropping it would cut
    /// away a corner of a different picture, so it exports whole instead.
    static func cropApplies(_ crop: CGRect?, documentAspect: CGFloat, fileAspect: CGFloat) -> Bool {
        guard crop != nil, documentAspect > 0, fileAspect > 0 else { return false }
        return abs(log(fileAspect / documentAspect)) < 0.01
    }

    /// The one rendering path. Both entry points call this and then `write`.
    static func render(_ snapshot: ExportSnapshot, source: ExportSource) -> RenderedExport? {
        let processor = ImageProcessor.shared
        let crop = snapshot.crop

        var masks = source.masks
        // The retained preview set describes a scaled-down frame: stretching it
        // over the export would widen every feather by the same factor. A set
        // built here runs at the photo's own resolution and is released with
        // this call, so back-to-back exports never hold two.
        if masks == nil, !source.faces.isEmpty {
            masks = processor.buildMasks(extent: source.image.extent,
                                         faces: source.faces,
                                         image: source.image,
                                         maskDimension: MaskBuilder.exportMaskDimension)
        }
        if snapshot.adjustments.usesPersonTools, masks?.person == nil,
           let analysis = PersonAnalyzer.analysis(for: source.image) {
            masks = masks.map { set in
                var copy = set
                copy.person = analysis.mask
                copy.pose = analysis.pose
                return copy
            } ?? MaskSet.personOnly(analysis.mask, pose: analysis.pose)
        }

        let spots = snapshot.includeStamps
            ? processor.spotsMask(extent: source.image.extent,
                                  spots: HealGeometry.workingSpots(snapshot.healSpots, crop: crop))
            : nil
        let art = snapshot.includeStamps
            ? ArtGeometry.workingStickers(snapshot.stickers, crop: crop,
                                          aspect: source.photoAspect)
            : []

        let focus = snapshot.selectedFaceIndex
            .flatMap { source.faces.indices.contains($0) ? source.faces[$0] : nil }

        var rendered = processor.process(source.image, adjustments: snapshot.adjustments,
                                         masks: masks, faces: source.faces,
                                         spots: spots, art: art, focus: focus)

        guard snapshot.includeAnalysis, snapshot.analysis.isEnabled, !source.faces.isEmpty
        else { return RenderedExport(image: rendered, carriesSourceMetadata: true) }

        switch snapshot.analysis.exportMode {
        case .onPhoto:
            rendered = AnalysisRenderer.apply(rendered, faces: source.faces,
                                              settings: snapshot.analysis, focus: focus)
        case .poster:
            rendered = AnalysisRenderer.poster(rendered, faces: source.faces,
                                               settings: snapshot.analysis, focus: focus)
        case .overlayOnly:
            // Lines on transparency, for the owner to place over a photo of
            // their own in whatever layout tool they use.
            guard let lines = AnalysisRenderer.render(size: rendered.extent.size,
                                                      faces: source.faces,
                                                      settings: snapshot.analysis,
                                                      focus: focus)
            else { return nil }
            return RenderedExport(image: CIImage(cgImage: lines), carriesSourceMetadata: false)
        }
        return RenderedExport(image: rendered, carriesSourceMetadata: true)
    }

    /// Writes through a temporary file in the destination folder and moves it
    /// into place, so a cancelled or failed export never leaves a half-written
    /// photo behind.
    static func write(_ rendered: RenderedExport,
                      snapshot: ExportSnapshot,
                      to url: URL,
                      colorSpace: CGColorSpace?,
                      metadata: [CFString: Any]) -> Bool {
        let processor = ImageProcessor.shared
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let wrote = processor.write(rendered.image, to: temporary,
                                    format: snapshot.format,
                                    quality: snapshot.quality,
                                    colorSpace: colorSpace,
                                    metadata: rendered.carriesSourceMetadata ? metadata : [:],
                                    maxDimension: snapshot.longEdge)
        guard wrote else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
}