import CoreGraphics
import CoreImage
import CryptoKit
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
    /// The source XMP graph. It has no property keys, so it travels apart from
    /// `metadata` and is written only when privacy stripping is off.
    var xmp: CGImageMetadata? = nil
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

/// Descriptor-relative file operations for paths that cross a trust boundary.
/// Final components are opened with `O_NOFOLLOW` and checked with `fstat`.
/// This deliberately does not claim to close races in ancestor directories or
/// in a separate consumer (the Python helper) that later reopens a pathname.
enum SecureFileIO {
    static func openDirectory(_ url: URL) throws -> Int32 {
        try openDirectory(at: url.path)
    }

    static func openDirectory(in parent: Int32, name: String) throws -> Int32 {
        try validateComponent(name)
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("could not open directory \(name)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            let error = errno
            close(descriptor)
            throw failure("not a directory: \(name)", code: error)
        }
        return descriptor
    }

    static func createDirectory(in parent: Int32, name: String) throws -> Int32 {
        try validateComponent(name)
        guard mkdirat(parent, name, 0o700) == 0 else {
            throw failure("could not create directory \(name)")
        }
        return try openDirectory(in: parent, name: name)
    }

    static func openRegularFile(_ url: URL) throws -> (descriptor: Int32, info: stat) {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        return try openRegularFile(in: parent, name: url.lastPathComponent)
    }

    static func openRegularFile(in parent: Int32, name: String) throws -> (descriptor: Int32, info: stat) {
        try validateComponent(name)
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("could not open regular file \(name)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            let error = errno
            close(descriptor)
            throw failure("not a regular non-symlink file: \(name)", code: error)
        }
        return (descriptor, info)
    }

    static func readFile(at url: URL) throws -> Data {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        return try readFile(in: parent, name: url.lastPathComponent)
    }

    static func readFile(in parent: Int32, name: String) throws -> Data {
        let file = try openRegularFile(in: parent, name: name)
        defer { close(file.descriptor) }
        return try readAll(file.descriptor)
    }

    static func readAll(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("could not read file")
            }
            result.append(contentsOf: chunk.prefix(count))
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("could not write file")
                }
                guard count > 0 else { throw failure("could not finish writing file") }
                sent += count
            }
        }
    }

    static func createRegularFile(in parent: Int32, name: String,
                                  mode: mode_t = 0o644) throws -> Int32 {
        try validateComponent(name)
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw failure("could not create new file \(name)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            let error = errno
            close(descriptor)
            throw failure("created file is not regular: \(name)", code: error)
        }
        return descriptor
    }

    static func write(_ data: Data, toDirectory parent: Int32, name: String) throws {
        let descriptor = try createRegularFile(in: parent, name: name)
        var complete = false
        defer {
            close(descriptor)
            if !complete { unlinkat(parent, name, 0) }
        }
        try writeAll(data, to: descriptor)
        complete = true
    }

    static func copy(from source: URL, toDirectory parent: Int32, name: String,
                     expectedSize: Int? = nil, expectedSHA256: String? = nil) throws {
        let opened = try openRegularFile(source)
        defer { close(opened.descriptor) }
        try copy(opened.descriptor, info: opened.info, toDirectory: parent, name: name,
                 expectedSize: expectedSize, expectedSHA256: expectedSHA256)
    }

    static func copy(_ source: Int32, info: stat, toDirectory parent: Int32, name: String,
                     expectedSize: Int? = nil, expectedSHA256: String? = nil) throws {
        if let expectedSize, Int(info.st_size) != expectedSize {
            throw failure("file size does not match its trusted pin: \(name)")
        }
        let destination = try createRegularFile(in: parent, name: name)
        var complete = false
        defer {
            close(destination)
            if !complete { unlinkat(parent, name, 0) }
        }
        var hasher = SHA256()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("could not read source file \(name)")
            }
            let data = Data(chunk.prefix(count))
            try writeAll(data, to: destination)
            hasher.update(data: data)
        }
        if let expectedSHA256,
           hasher.finalize().map({ String(format: "%02x", $0) }).joined() != expectedSHA256 {
            throw failure("file digest does not match its trusted pin: \(name)")
        }
        guard fchmod(destination, 0o644) == 0 else {
            throw failure("could not set file mode: \(name)")
        }
        complete = true
    }

    static func unlink(in parent: Int32, name: String) {
        do {
            try validateComponent(name)
            unlinkat(parent, name, 0)
        } catch {}
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw failure("could not rewind file") }
        var hasher = SHA256()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("could not hash file")
            }
            hasher.update(data: Data(chunk.prefix(count)))
        }
    }

    private static func openDirectory(at path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("could not open directory \(path)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            let error = errno
            close(descriptor)
            throw failure("not a directory: \(path)", code: error)
        }
        return descriptor
    }

    private static func validateComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw failure("unsafe file component")
        }
    }

    private static func failure(_ detail: String, code: Int32? = nil) -> AIWorkerFailure {
        let error = code ?? errno
        return AIWorkerFailure(code: -32603,
                               message: "\(detail): \(String(cString: strerror(error)))")
    }
}

enum ExportService {

    /// The result of the final write, before the UI turns it into a sentence.
    enum WriteResult: Equatable {
        case written
        case failed
        case refusedOriginal
        /// The bytes were ready but the caller cancelled before the commit.
        case cancelled
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

    struct UpscaleArtifact {
        let image: CIImage
        let artifact: URL
        let provenance: URL
        let jobID: String?
        let inputSHA256: String?
        let model: ModelCatalogEntry?
        /// The device the worker says it actually used. Nil is deliberately
        /// not inferred from pixels or catalog metadata; the diagnostic fails
        /// closed when the result cannot establish it.
        let provider: String?

        init(image: CIImage, artifact: URL, provenance: URL,
             jobID: String? = nil, inputSHA256: String? = nil,
             model: ModelCatalogEntry? = nil, provider: String? = nil) {
            self.image = image
            self.artifact = artifact
            self.provenance = provenance
            self.jobID = jobID
            self.inputSHA256 = inputSHA256
            self.model = model
            self.provider = provider
        }
    }

    /// The only model identity an upscale may claim: the exact Swin2SR entry in
    /// the catalog sealed into this app. A self-consistent manifest supplied by
    /// a caller is not a trust root.
    static func trustedUpscaleEntry() throws -> ModelCatalogEntry {
        let catalog = try ModelCatalog.bundled()
        guard let entry = catalog.entry(id: "swin2sr-x4"),
              entry.version == "1.0.0",
              entry.format == "pytorch",
              entry.capabilities.contains(AICapabilityReport.upscale4x),
              entry.sha256 == "e0da6778bbcffbb26d61fda450648998e22f66d5867924706fee6d929aa50cdf",
              entry.unverifiableReason == nil else {
            throw AIWorkerFailure(code: -32021,
                                  message: "the bundled catalog does not pin the approved 4× upscaler")
        }
        let required = Set(["config.json", "preprocessor_config.json", "pytorch_model.bin"])
        var files: [String: ModelCatalogFile] = [:]
        for file in entry.files {
            guard required.contains(file.path), file.isVerifiable,
                  files[file.path] == nil else {
                throw AIWorkerFailure(code: -32021,
                                      message: "the bundled upscaler catalog has invalid file pins")
            }
            files[file.path] = file
        }
        guard Set(files.keys) == required else {
            throw AIWorkerFailure(code: -32021,
                                  message: "the bundled upscaler catalog does not pin the exact checkpoint")
        }
        return entry
    }

    /// Hashes the RGB8 pixels the helper will decode from the submitted PNG.
    /// The PNG container bytes are not the input identity: the worker records
    /// `array.tobytes()` after `PIL.Image.convert("RGB")`.
    static func rgb8SHA256(of url: URL) throws -> String {
        let data = try SecureFileIO.readFile(at: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIWorkerFailure(code: -32603, message: "the submitted RGB input cannot be decoded")
        }
        let width = image.width, height = image.height
        let bits = image.bitsPerComponent
        guard width > 0, height > 0,
              (bits == 8 || bits == 16),
              image.bitsPerPixel == bits * 4,
              image.alphaInfo == .last,
              let provider = image.dataProvider,
              let providerData = provider.data,
              let raw = providerData as Data?,
              raw.count >= image.bytesPerRow * height else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the submitted PNG is not a supported straight RGBA image")
        }
        let bigEndian16: Bool
        if bits == 16 {
            if image.bitmapInfo.contains(.byteOrder16Big) {
                bigEndian16 = true
            } else if image.bitmapInfo.contains(.byteOrder16Little) {
                bigEndian16 = false
            } else {
                throw AIWorkerFailure(code: -32603,
                                      message: "the submitted RGBA16 PNG has no known byte order")
            }
        } else {
            bigEndian16 = false
        }

        // Pillow drops alpha and keeps the high byte of each 16-bit channel.
        // Drawing through an opaque CGContext would instead composite alpha
        // and rescale 16-bit values, binding the sidecar to different pixels.
        // Read ImageIO's straight RGBA samples directly. Unsupported layouts
        // are refused above rather than hashed with guessed semantics.
        let bytesPerPixel = bits / 8 * 4
        var row = [UInt8](repeating: 0, count: width * 3)
        var hasher = SHA256()
        raw.withUnsafeBytes { buffer in
            let bytes = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let rowStart = y * image.bytesPerRow
                for x in 0..<width {
                    let pixelStart = rowStart + x * bytesPerPixel
                    for channel in 0..<3 {
                        let offset = pixelStart + channel * (bits / 8)
                        if bits == 8 {
                            row[x * 3 + channel] = bytes[offset]
                        } else {
                            let value = bigEndian16
                                ? (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
                                : UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                            row[x * 3 + channel] = UInt8(value >> 8)
                        }
                    }
                }
                hasher.update(data: row)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the helper's output bytes and binds every identity-bearing
    /// sidecar field to facts the host measured or sealed into the app.
    static func verifyUpscaleProvenance(path: String, sidecarPath: String,
                                        jobID: String, inputSHA256: String,
                                        model: ModelCatalogEntry) throws -> URL {
        guard model.id == "swin2sr-x4", model.version == "1.0.0",
              model.format == "pytorch",
              model.capabilities.contains(AICapabilityReport.upscale4x),
              model.sha256 == "e0da6778bbcffbb26d61fda450648998e22f66d5867924706fee6d929aa50cdf",
              model.isVerifiable else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the upscale provenance has no trusted model context")
        }
        guard !jobID.isEmpty, inputSHA256.count == 64,
              inputSHA256.allSatisfy(\.isHexDigit) else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the upscale provenance has no trusted submission context")
        }
        let requiredFiles = Set(["config.json", "preprocessor_config.json", "pytorch_model.bin"])
        guard model.files.count == requiredFiles.count,
              Set(model.files.map(\.path)) == requiredFiles else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the upscale provenance has incomplete model pins")
        }
        let artifact = URL(fileURLWithPath: path)
        let sidecar = URL(fileURLWithPath: sidecarPath)
        guard sidecar.lastPathComponent == artifact.lastPathComponent + AIProvenance.sidecarSuffix,
              sidecar.deletingLastPathComponent().path == artifact.deletingLastPathComponent().path else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the provenance is not the sidecar of this artifact")
        }
        let parent = try SecureFileIO.openDirectory(artifact.deletingLastPathComponent())
        defer { close(parent) }
        let artifactFile = try SecureFileIO.openRegularFile(in: parent, name: artifact.lastPathComponent)
        defer { close(artifactFile.descriptor) }
        let sidecarFile = try SecureFileIO.openRegularFile(in: parent, name: sidecar.lastPathComponent)
        defer { close(sidecarFile.descriptor) }
        let data = try SecureFileIO.readAll(sidecarFile.descriptor)
        let actualDigest = try SecureFileIO.sha256(of: artifactFile.descriptor)
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (record["output"] as? [String: Any])?["sha256"] as? String == actualDigest,
              record["schema"] as? String == AIProvenance.schema,
              record["capabilityId"] as? String == AICapabilityReport.upscale4x,
              record["jobId"] as? String == jobID,
              record["state"] as? String == "succeeded",
              (record["input"] as? [String: Any])?["sha256"] as? String == inputSHA256,
              (record["parameters"] as? [String: Any])?["scale"] as? Int == 4,
              let recordedModel = record["model"] as? [String: Any],
              recordedModel["id"] as? String == model.id,
              recordedModel["version"] as? String == model.version,
              recordedModel["format"] as? String == model.format,
              let recordedFiles = recordedModel["files"] as? [[String: Any]],
              recordedFiles.count == model.files.count else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the upscale provenance is not bound to this submission")
        }
        let expected = Dictionary(uniqueKeysWithValues: model.files.map {
            ($0.path, $0.sha256 ?? "")
        })
        var seen = Set<String>()
        for file in recordedFiles {
            guard Set(file.keys) == Set(["path", "sha256"]),
                  let path = file["path"] as? String,
                  let digest = file["sha256"] as? String,
                  let trusted = expected[path], digest == trusted,
                  seen.insert(path).inserted else {
                throw AIWorkerFailure(code: -32603,
                                      message: "the upscale provenance does not name the trusted model files")
            }
        }
        guard seen == Set(expected.keys) else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the upscale provenance omits a trusted model file")
        }
        return artifact
    }

    /// Runs one upscale job through the local helper and reads the result back
    /// into memory. The working copy is deleted; the helper trims its own job
    /// folders. Cancelling the surrounding task cancels the job as well. The
    /// result is read only after its provenance sidecar has been matched
    /// against the artifact's bytes, and the job is named by its capability id
    /// so the helper applies its own verdict before it loads a model.
    private static func upscale(_ image: CIImage,
                                progress: ((Int, Int) -> Void)?) throws -> CIImage {
        try upscaleArtifact(image, progress: progress).image
    }

    /// The same production path, with the adopted file pair retained for the
    /// explicit packaged-runtime diagnostic. Export itself uses only `image`.
    static func upscaleArtifact(_ image: CIImage,
                                progress: ((Int, Int) -> Void)?) throws -> UpscaleArtifact {
        guard RenderUpscale.canHandle(StudioSize(image.extent.size)) else {
            throw AIWorkerFailure(code: -32602, message: L10n.current.exportUpscaleTooLarge)
        }
        let model = try trustedUpscaleEntry()
        try AIWorker.ensureRunning()
        let copy = try AIWorker.writeUpscaleSource(image)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let inputSHA256 = try rgb8SHA256(of: copy)

        var used = false
        ModelActivity.shared.begin(.swin)
        defer { ModelActivity.shared.finish(.swin, used: used) }
        let id = try WorkerClient.shared.submit(
            "upscale", ["image": ["path": copy.path]],
            capability: AICapabilityReport.upscale4x)
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
              let provenancePath = payload["provenance"] as? String else {
            throw AIWorkerFailure(code: -32603, message: L10n.current.exportUpscaleFailed)
        }
        // §3.6: the file is adoptable only together with the sidecar that names
        // these bytes. The helper publishes the sidecar first, so a refusal here
        // means the pair arrived inconsistent rather than merely early, and
        // decoding anyway would show the user an edit whose origin cannot be
        // accounted for. The message is the one the user already sees for a
        // failed pass; the refusal's technical reason is not carried further
        // by this type — it is recoverable from the worker log, and the
        // provenance contract, not the wording, is what refused the artifact.
        let artifact: URL
        do {
            artifact = try verifyUpscaleProvenance(
                path: path, sidecarPath: provenancePath, jobID: id,
                inputSHA256: inputSHA256, model: model)
        } catch {
            throw AIWorkerFailure(code: -32603,
                                  message: L10n.current.exportUpscaleFailed)
        }
        guard let source = CGImageSourceCreateWithURL(artifact as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIWorkerFailure(code: -32603, message: L10n.current.exportUpscaleFailed)
        }
        return UpscaleArtifact(image: CIImage(cgImage: decoded), artifact: artifact,
                               provenance: URL(fileURLWithPath: provenancePath),
                               jobID: id, inputSHA256: inputSHA256, model: model,
                               provider: PackagedUpscaleSelfTest.inferenceProvider(from: payload))
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
                      xmp: CGImageMetadata? = nil,
                      protecting protectedURL: URL? = nil) -> Bool {
        writeResult(rendered, snapshot: snapshot, to: url,
                    colorSpace: colorSpace, metadata: metadata, xmp: xmp,
                    protecting: protectedURL) == .written
    }

    static func writeResult(_ rendered: RenderedExport,
                            snapshot: ExportSnapshot,
                            to url: URL,
                            colorSpace: CGColorSpace?,
                            metadata: [CFString: Any],
                            xmp: CGImageMetadata? = nil,
                            protecting protectedURL: URL?,
                            isCancelled: () -> Bool = { Task.isCancelled }) -> WriteResult {
        if let protectedURL, referencesSameFile(url, protectedURL) {
            return .refusedOriginal
        }
        sweepStaleSiblingTemps(for: url)
        let processor = ImageProcessor.shared
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let wrote = processor.write(rendered.image, to: temporary,
                                    format: snapshot.format,
                                    quality: snapshot.quality,
                                    colorSpace: colorSpace,
                                    metadata: rendered.carriesSourceMetadata ? metadata : [:],
                                    xmp: rendered.carriesSourceMetadata ? xmp : nil,
                                    stripPrivacyMetadata: snapshot.stripsPrivacyMetadata,
                                    maxDimension: snapshot.longEdge.map { CGFloat($0) })
        guard wrote else {
            try? FileManager.default.removeItem(at: temporary)
            return .failed
        }
        // The bytes exist, but a cancel that arrived while they were written
        // must win over committing them: the user asked for nothing to land.
        if isCancelled() {
            try? FileManager.default.removeItem(at: temporary)
            return .cancelled
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

    /// Removes temp siblings a crashed or force-quit export left behind: files
    /// named exactly ".<destination>.<stamp>.tmp" in the destination folder,
    /// regular files, untouched for more than `olderThan`. The stamp is the
    /// dashed UUID `writeResult` creates, or a compact 32-hex spelling of one;
    /// dots in the destination name are matched literally, the folder is not
    /// searched recursively, and nothing else is considered. Returns how many
    /// entries were removed.
    @discardableResult
    static func sweepStaleSiblingTemps(for url: URL,
                                       now: Date = Date(),
                                       olderThan: TimeInterval = 24 * 60 * 60) -> Int {
        let folder = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return 0
        }
        var removed = 0
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { continue }
            let stamp = name.dropFirst(prefix.count).dropLast(".tmp".count)
            guard isTempStamp(stamp) else { continue }
            let candidate = folder.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > olderThan else { continue }
            guard (try? FileManager.default.removeItem(at: candidate)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    /// A UUID as `UUID().uuidString` writes it (8-4-4-4-12, hex, either case),
    /// or the same value as 32 hex digits.
    private static func isTempStamp(_ stamp: Substring) -> Bool {
        let text = String(stamp)
        if text.count == 32 {
            return text.allSatisfy { $0.isHexDigit }
        }
        guard text.count == 36 else { return false }
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return text.allSatisfy { $0 == "-" || $0.isHexDigit }
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