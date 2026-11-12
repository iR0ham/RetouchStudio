import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import StudioCore

/// The portable request every export path builds. The name stays because the
/// editor, the corpus harness and the self-check all speak of a snapshot; the
/// value itself is now the shared contract in StudioCore.
typealias ExportSnapshot = RenderRequest

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

extension ExportSource {
    /// What the shared policy may read about the decoded photo. The pixels
    /// themselves stay in this module.
    var renderDescription: RenderSourceDescription {
        RenderSourceDescription(pixelSize: StudioSize(image.extent.size),
                                photoAspect: Double(photoAspect),
                                faceCount: faces.count,
                                colorProfileName: colorSpace?.name as String?)
    }
}

enum ExportService {

    /// The result of the final write, before the UI turns it into a sentence.
    enum WriteResult: Equatable {
        case written
        case failed
        case refusedOriginal
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

    /// The document's crop only describes a file of the same shape.
    static func cropApplies(_ crop: CGRect?, documentAspect: CGFloat, fileAspect: CGFloat) -> Bool {
        BatchRenderPolicy.cropApplies(crop.map(StudioRect.init),
                                      documentAspect: Double(documentAspect),
                                      fileAspect: Double(fileAspect))
    }

    /// The one rendering path. Both entry points call this and then `write`.
    /// `applyAnalysis` is false for the first half of an upscaled export: the
    /// callouts belong on the enlarged photo, not inside the model's input.
    static func render(_ snapshot: ExportSnapshot, source: ExportSource,
                       applyAnalysis: Bool = true,
                       plan: RenderPlan? = nil) -> RenderedExport? {
        let processor = ImageProcessor.shared
        let crop = snapshot.crop?.cgRect
        let plan = plan ?? RenderPolicy.plan(snapshot, source: source.renderDescription)

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

        guard applyAnalysis, plan.appliesAnalysis else {
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
                            plan: RenderPlan? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws -> RenderedExport? {
        let plan = plan ?? RenderPolicy.plan(snapshot, source: source.renderDescription)
        let rendered: RenderedExport?
        if plan.upscales {
            guard let base = render(snapshot, source: source, applyAnalysis: false,
                                    plan: plan) else {
                return nil
            }
            let enlarged = try upscale(base.image, progress: progress)
            if plan.appliesAnalysis {
                rendered = analysisApplied(snapshot, image: enlarged, faces: source.faces,
                                           focus: focusFace(snapshot, faces: source.faces))
            } else {
                rendered = RenderedExport(image: enlarged, carriesSourceMetadata: true)
            }
        } else {
            rendered = render(snapshot, source: source, plan: plan)
        }
        guard let rendered, plan.appliesWatermark,
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
        guard RenderUpscale.canHandle(StudioSize(image.extent.size)) else {
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
                                    maxDimension: snapshot.longEdge.map { CGFloat($0) })
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