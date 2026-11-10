import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO

/// Everything an export takes from the document instead of from the pixels it
/// lands on. The single-photo export and the batch export both build one of
/// these and hand it to `ExportService`, so the two entry points cannot drift.
struct ExportSnapshot: Equatable {
    var adjustments = Adjustments()
    var healSpots: [HealSpot] = []
    var stickers: [Sticker] = []
    /// AI patches already stored on disk. They are document edits, not stamps:
    /// they always describe this photo, so a batch clears them for other files.
    var aiEdits: [AIEdit] = []
    var analysis = AnalysisSettings()
    /// Crop in normalized photo coordinates with a top-left origin.
    var crop: CGRect?
    /// Turn baked into the document's pixels. Batch uses it for this photo's
    /// own file only; other files open in their own orientation.
    var orientation = DocumentOrientation.identity
    /// Index into the photo's sorted faces, or nil for the automatic choice.
    /// Feature sizes and the callouts follow it, so an export matches what the
    /// editor showed.
    var selectedFaceIndex: Int?
    var format: ExportFormat = .jpeg
    var quality: Double = 0.92
    var longEdge: CGFloat?
    /// Drop GPS and camera identity from the copied EXIF. The setting is on by
    /// default, and every file in a batch shares this one answer.
    var stripsPrivacyMetadata = true
    /// Manual repairs and placed art. Off for batch work unless asked for:
    /// stamps describe one face's blemishes, not another photo's.
    var includeStamps = true
    /// The analysis callouts. Off for batch work unless asked for.
    var includeAnalysis = true
    /// Run the rendered photo through the local 4x upscaler before writing.
    /// Only meaningful when the requested size is larger than the photo; the
    /// UI hides the switch otherwise.
    var aiUpscale = false
    /// Drawn last, over both the photo and its callouts, so a signature sits on
    /// top of everything the file carries.
    var watermark = WatermarkSettings.disabled
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

/// What the local upscaler can promise, decided before a job is queued.
///
/// Swin2SR is a fixed 4x model and the helper refuses to build an output above
/// 40 megapixels (`UPSCALE_MAX_OUTPUT`), which bounds a full 4x pass to a
/// 2.5 MP source on this machine. Mirroring both numbers here means the sheet
/// can say no in the same terms the helper would use.
enum ExportUpscale {
    static let factor: CGFloat = 4
    static let maxOutputPixels = 40_000_000

    /// The intermediate copy and the written file both use sRGB. The helper
    /// works on untagged 8-bit pixels, so handing it wide-gamut values and
    /// then tagging the result the same way would shift every colour.
    static let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func canHandle(_ size: CGSize) -> Bool {
        guard size.width >= 1, size.height >= 1 else { return false }
        let width = Int((size.width * factor).rounded())
        let height = Int((size.height * factor).rounded())
        return width * height <= maxOutputPixels
    }

    /// The long edge actually written: 4x the photo, but never past the edge
    /// the owner picked.
    static func outputLongEdge(sourceLong: CGFloat, requested: CGFloat?) -> CGFloat {
        let quadrupled = sourceLong * factor
        guard let requested, requested > 0 else { return quadrupled }
        return min(quadrupled, requested)
    }

    /// Measured on this Mac (M3, 16 GB, MPS) with the default 256 px tiles:
    /// 28 tiles, 150 s for a 900x1600 photo, whose 4x output is 23 MP. That is
    /// about 6.5 s per megapixel of output. This only feeds the sheet's
    /// estimate; the helper's own tile report is the measured truth while a
    /// job runs.
    static let secondsPerOutputMegapixel = 6.5

    static func estimatedSeconds(for size: CGSize) -> Int {
        let megapixels = (size.width * factor) * (size.height * factor) / 1_000_000
        return Int((megapixels * secondsPerOutputMegapixel).rounded())
    }
}

enum ExportService {

    /// How a one-photo export ended. `cancelled` is distinct from `failed`
    /// because nothing was written and the owner asked for it. `refusedSource`
    /// means the chosen destination is the opened photo itself, or an alias of
    /// it, so nothing was rendered or written.
    enum Outcome {
        case saved, cancelled, failed, refusedSource
    }

    /// The result of the final write, before the UI turns it into a sentence.
    enum WriteResult: Equatable {
        case written
        case failed
        case refusedOriginal
    }

    /// Renders and writes in one cancellable step. Cancellation is checked
    /// before the expensive render and again before the file is committed, so
    /// a cancelled export leaves no photo behind even though Core Image itself
    /// does not stop early.
    static func run(_ snapshot: ExportSnapshot, source: ExportSource, to url: URL,
                    protecting protectedURL: URL? = nil,
                    progress: ((Int, Int) -> Void)? = nil) -> Outcome {
        if Task.isCancelled { return .cancelled }
        let rendered: RenderedExport?
        do {
            rendered = try renderFinal(snapshot, source: source, progress: progress)
        } catch {
            // A cancelled upscale is the owner's doing, not a failure.
            return Task.isCancelled || (error as? AIWorkerFailure)?.code == -32014
                ? .cancelled : .failed
        }
        guard let rendered else { return .failed }
        if Task.isCancelled { return .cancelled }
        // The upscaler hands back sRGB pixels, so an upscaled file is written
        // with the profile those pixels were produced in.
        let colorSpace = snapshot.aiUpscale ? ExportUpscale.workingColorSpace : source.colorSpace
        let wrote = writeResult(rendered, snapshot: snapshot, to: url,
                                colorSpace: colorSpace, metadata: source.metadata,
                                protecting: protectedURL)
        switch wrote {
        case .written: return .saved
        case .failed: return .failed
        case .refusedOriginal: return .refusedSource
        }
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
    /// `applyAnalysis` is false for the first half of an upscaled export: the
    /// callouts belong on the enlarged photo, not inside the model's input.
    static func render(_ snapshot: ExportSnapshot, source: ExportSource,
                       applyAnalysis: Bool = true) -> RenderedExport? {
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

        let focus = focusFace(snapshot, faces: source.faces)

        var rendered = processor.process(source.image, adjustments: snapshot.adjustments,
                                         masks: masks, faces: source.faces,
                                         spots: spots, art: art,
                                         ai: AICompositor.layers(snapshot.aiEdits, crop: crop),
                                         focus: focus)

        guard applyAnalysis, snapshot.includeAnalysis, snapshot.analysis.isEnabled,
              !source.faces.isEmpty else {
            return RenderedExport(image: rendered, carriesSourceMetadata: true)
        }
        return analysisApplied(snapshot, image: rendered, faces: source.faces, focus: focus)
    }

    /// What actually gets written. With AI upscaling on, the photo is rendered
    /// at its own size, enlarged by the helper, and only then given its
    /// callouts: anything drawn before the job would be reinterpreted by the
    /// model instead of staying crisp.
    static func renderFinal(_ snapshot: ExportSnapshot,
                            source: ExportSource,
                            progress: ((Int, Int) -> Void)? = nil) throws -> RenderedExport? {
        let rendered: RenderedExport?
        if snapshot.aiUpscale {
            guard let base = render(snapshot, source: source, applyAnalysis: false) else {
                return nil
            }
            let enlarged = try upscale(base.image, progress: progress)
            if snapshot.includeAnalysis, snapshot.analysis.isEnabled, !source.faces.isEmpty {
                rendered = analysisApplied(snapshot, image: enlarged, faces: source.faces,
                                           focus: focusFace(snapshot, faces: source.faces))
            } else {
                rendered = RenderedExport(image: enlarged, carriesSourceMetadata: true)
            }
        } else {
            rendered = render(snapshot, source: source)
        }
        guard let rendered, snapshot.watermark.isActive,
              rendered.carriesSourceMetadata else { return rendered }
        // A lines-only export is art on transparency; a signature would land in
        // the layout tool, not on a photo, so it is left off.
        return RenderedExport(image: WatermarkRenderer.apply(snapshot.watermark,
                                                             to: rendered.image),
                              carriesSourceMetadata: true)
    }

    private static func focusFace(_ snapshot: ExportSnapshot,
                                  faces: [FaceGeometry]) -> FaceGeometry? {
        snapshot.selectedFaceIndex
            .flatMap { faces.indices.contains($0) ? faces[$0] : nil }
    }

    /// The callouts at whatever size the image already has. Face geometry is
    /// normalized, so the same call lands on the original and on a 4x upscale.
    private static func analysisApplied(_ snapshot: ExportSnapshot, image: CIImage,
                                        faces: [FaceGeometry],
                                        focus: FaceGeometry?) -> RenderedExport? {
        switch snapshot.analysis.exportMode {
        case .onPhoto:
            return RenderedExport(image: AnalysisRenderer.apply(image, faces: faces,
                                                                settings: snapshot.analysis,
                                                                focus: focus),
                                  carriesSourceMetadata: true)
        case .poster:
            return RenderedExport(image: AnalysisRenderer.poster(image, faces: faces,
                                                                 settings: snapshot.analysis,
                                                                 focus: focus),
                                  carriesSourceMetadata: true)
        case .overlayOnly:
            // Lines on transparency, for the owner to place over a photo of
            // their own in whatever layout tool they use.
            guard let lines = AnalysisRenderer.render(size: image.extent.size,
                                                      faces: faces,
                                                      settings: snapshot.analysis,
                                                      focus: focus)
            else { return nil }
            return RenderedExport(image: CIImage(cgImage: lines), carriesSourceMetadata: false)
        }
    }

    /// Runs one upscale job through the local helper and reads the result back
    /// into memory. The working copy is deleted; the helper trims its own job
    /// folders. Cancelling the surrounding task cancels the job as well.
    private static func upscale(_ image: CIImage,
                                progress: ((Int, Int) -> Void)?) throws -> CIImage {
        guard ExportUpscale.canHandle(image.extent.size) else {
            throw AIWorkerFailure(code: -32602, message: L10n.current.exportUpscaleTooLarge)
        }
        try AIWorker.ensureRunning()
        let copy = try AIWorker.writeUpscaleSource(image)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        var used = false
        ModelActivity.shared.begin(.swin)
        defer { ModelActivity.shared.finish(.swin, used: used) }
        let id = try WorkerClient.shared.submit("upscale", ["image": ["path": copy.path]])
        let reply: [String: Any]
        do {
            reply = try WorkerClient.shared.wait(
                job: id, timeout: 1500,
                cancelled: { Task.isCancelled },
                fields: { update in
                    // The helper reports tiles finished, not a percentage; the
                    // status line shows the same count so a long pass is
                    // visibly moving.
                    guard let done = update["tile"] as? Int,
                          let total = update["tiles"] as? Int else { return }
                    progress?(done, total)
                })
            used = true
        } catch {
            WorkerClient.shared.cancel(job: id)
            throw error
        }
        guard let payload = reply["result"] as? [String: Any],
              let path = payload["output"] as? String,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIWorkerFailure(code: -32603, message: L10n.current.exportUpscaleFailed)
        }
        return CIImage(cgImage: decoded)
    }

    /// Writes through a temporary file in the destination folder and moves it
    /// into place, so a cancelled or failed export never leaves a half-written
    /// photo behind. `protecting` is the opened photo: writing anywhere that
    /// resolves to that file is refused, even through a symbolic or hard link.
    static func write(_ rendered: RenderedExport,
                      snapshot: ExportSnapshot,
                      to url: URL,
                      colorSpace: CGColorSpace?,
                      metadata: [CFString: Any],
                      protecting protectedURL: URL? = nil) -> Bool {
        writeResult(rendered, snapshot: snapshot, to: url,
                    colorSpace: colorSpace, metadata: metadata,
                    protecting: protectedURL) == .written
    }

    static func writeResult(_ rendered: RenderedExport,
                            snapshot: ExportSnapshot,
                            to url: URL,
                            colorSpace: CGColorSpace?,
                            metadata: [CFString: Any],
                            protecting protectedURL: URL?) -> WriteResult {
        if let protectedURL, referencesSameFile(url, protectedURL) {
            return .refusedOriginal
        }
        let processor = ImageProcessor.shared
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let wrote = processor.write(rendered.image, to: temporary,
                                    format: snapshot.format,
                                    quality: snapshot.quality,
                                    colorSpace: colorSpace,
                                    metadata: rendered.carriesSourceMetadata ? metadata : [:],
                                    stripPrivacyMetadata: snapshot.stripsPrivacyMetadata,
                                    maxDimension: snapshot.longEdge)
        guard wrote else {
            try? FileManager.default.removeItem(at: temporary)
            return .failed
        }
        // Check again at the commit point: the destination could have been
        // replaced or linked to the source while the render was being written.
        if let protectedURL, referencesSameFile(url, protectedURL) {
            try? FileManager.default.removeItem(at: temporary)
            return .refusedOriginal
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return .written
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .failed
        }
    }

    /// True when writing to `destination` would replace `source`, including a
    /// symbolic link, a hard link, or a differently-cased spelling on a
    /// case-insensitive volume. `stat` follows links, so the device/inode pair
    /// is the reliable identity check; resolved paths cover a destination that
    /// does not exist yet but names the source.
    static func referencesSameFile(_ destination: URL, _ source: URL) -> Bool {
        let destinationURL = destination.resolvingSymlinksInPath().standardizedFileURL
        let sourceURL = source.resolvingSymlinksInPath().standardizedFileURL
        if destinationURL.path == sourceURL.path { return true }
        if let destinationID = fileIdentity(destinationURL),
           let sourceID = fileIdentity(sourceURL),
           destinationID == sourceID {
            return true
        }
        // A missing destination has no inode. APFS is case-insensitive by
        // default, so compare the remaining spellings conservatively rather
        // than risk replacing the source through a case-only alias.
        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL.path.compare(sourceURL.path,
                                               options: [.caseInsensitive]) == .orderedSame
        }
        return false
    }

    private static func fileIdentity(_ url: URL) -> String? {
        var info = stat()
        let result = url.path.withCString { stat($0, &info) }
        guard result == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}