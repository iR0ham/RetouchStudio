import Foundation

/// The image formats an export can write. The host maps a case to its own
/// file-type and encoder objects; the shared rules only need the extension,
/// the depth and whether the container is lossy.
public enum ExportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case jpeg, png, tiff, heic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tif"
        case .heic: return "heic"
        }
    }

    /// The portable type name a host turns into its own identifier. It is data,
    /// not an import: StudioCore still has no file-type framework.
    public var uniformTypeIdentifier: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        case .heic: return "public.heic"
        }
    }

    /// Formats that carry a compression slider.
    public var supportsQuality: Bool { self == .jpeg || self == .heic }

    /// PNG and TIFF define a 16-bit container; JPEG and HEIC stay at 8.
    public var bitsPerChannel: Int { supportsQuality ? 8 : 16 }

    /// Neither JPEG nor HEIC has a dependable alpha channel here, so a
    /// transparent result is flattened onto white before it is encoded.
    public var flattensAlpha: Bool { self == .jpeg || self == .heic }
}

/// A signature burned into exported copies. It is an output preference, not a
/// document edit: the editor keeps showing the clean photo, and project files
/// stay small.
public struct WatermarkSettings: Codable, Equatable, Sendable {
    public enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight, center

        public var id: String { rawValue }
    }

    public var enabled: Bool
    public var text: String
    public var position: Position
    /// 0.05…1; a faint mark still reads without covering the portrait.
    public var opacity: Double
    /// Cap height as a percentage of the exported photo's short side.
    public var sizePercent: Double

    public static let disabled = WatermarkSettings()

    public init(enabled: Bool = false, text: String = "",
                position: Position = .bottomRight, opacity: Double = 0.65,
                sizePercent: Double = 3.0) {
        self.enabled = enabled
        self.text = text
        self.position = position
        self.opacity = opacity
        self.sizePercent = sizePercent
    }

    /// Preferences are decoded from files written by earlier builds, so a
    /// missing key falls back to the same value a fresh install starts with
    /// instead of failing the whole settings load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WatermarkSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? defaults.enabled
        text = try container.decodeIfPresent(String.self, forKey: .text)
            ?? defaults.text
        position = try container.decodeIfPresent(Position.self, forKey: .position)
            ?? defaults.position
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
            ?? defaults.opacity
        sizePercent = try container.decodeIfPresent(Double.self, forKey: .sizePercent)
            ?? defaults.sizePercent
    }

    /// An empty or blank string would draw a shadow with no text, so it counts
    /// as off even when the switch is on.
    public var isActive: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Where the written pixels take their colour profile from. The host owns the
/// actual profile objects; this only states the decision.
public enum RenderColorSpace: String, Codable, Equatable, Sendable {
    /// The profile the source photo was decoded with.
    case source
    /// The upscaler's fixed working profile, because it returns untagged pixels.
    case sRGB
}

/// One image's measurements, as the host decoded them. The pixels stay behind
/// the port; this is what the shared policy is allowed to read.
public struct RenderSourceDescription: Codable, Equatable, Sendable {
    public var pixelSize: StudioSize
    /// Pixel aspect ratio of the whole photo before any crop.
    public var photoAspect: Double
    public var faceCount: Int
    /// The decoded profile's name, for the result record.
    public var colorProfileName: String?

    public init(pixelSize: StudioSize, photoAspect: Double, faceCount: Int,
                colorProfileName: String? = nil) {
        self.pixelSize = pixelSize
        self.photoAspect = photoAspect
        self.faceCount = faceCount
        self.colorProfileName = colorProfileName
    }
}

/// Everything an export takes from the document instead of from the pixels it
/// lands on. The single-photo export and the batch export both build one of
/// these, so the two entry points cannot drift.
public struct RenderRequest: Codable, Equatable {
    public var adjustments: Adjustments
    public var healSpots: [HealSpot]
    public var stickers: [Sticker]
    /// AI patches already stored on disk. They are document edits, not stamps:
    /// they always describe this photo, so a batch clears them for other files.
    public var aiEdits: [AIEdit]
    public var analysis: AnalysisSettings
    /// Crop in normalized photo coordinates with a top-left origin.
    public var crop: StudioRect?
    /// Turn baked into the document's pixels. Batch uses it for this photo's
    /// own file only; other files open in their own orientation.
    public var orientation: DocumentOrientation
    /// Index into the photo's sorted faces, or nil for the automatic choice.
    public var selectedFaceIndex: Int?
    public var format: ExportFormat
    public var quality: Double
    /// Zero or nil keeps the photo's own size.
    public var longEdge: Double?
    /// Keep only non-identifying technical metadata (orientation and
    /// resolution). Every file in a batch shares this one answer.
    public var stripsPrivacyMetadata: Bool
    /// Manual repairs and placed art. Off for batch work unless asked for.
    public var includeStamps: Bool
    /// The analysis callouts. Off for batch work unless asked for.
    public var includeAnalysis: Bool
    /// Run the rendered photo through the local upscaler before writing.
    public var aiUpscale: Bool
    /// Drawn last, over both the photo and its callouts.
    public var watermark: WatermarkSettings

    public init(adjustments: Adjustments = Adjustments(),
                healSpots: [HealSpot] = [],
                stickers: [Sticker] = [],
                aiEdits: [AIEdit] = [],
                analysis: AnalysisSettings = AnalysisSettings(),
                crop: StudioRect? = nil,
                orientation: DocumentOrientation = .identity,
                selectedFaceIndex: Int? = nil,
                format: ExportFormat = .jpeg,
                quality: Double = 0.92,
                longEdge: Double? = nil,
                stripsPrivacyMetadata: Bool = true,
                includeStamps: Bool = true,
                includeAnalysis: Bool = true,
                aiUpscale: Bool = false,
                watermark: WatermarkSettings = .disabled) {
        self.adjustments = adjustments
        self.healSpots = healSpots
        self.stickers = stickers
        self.aiEdits = aiEdits
        self.analysis = analysis
        self.crop = crop
        self.orientation = orientation
        self.selectedFaceIndex = selectedFaceIndex
        self.format = format
        self.quality = quality
        self.longEdge = longEdge
        self.stripsPrivacyMetadata = stripsPrivacyMetadata
        self.includeStamps = includeStamps
        self.includeAnalysis = includeAnalysis
        self.aiUpscale = aiUpscale
        self.watermark = watermark
    }
}

/// The document-level pass decisions for one request.
///
/// It is derived before any pixel work and names every choice a host renderer
/// must honour: whether to run the upscaler, whether callouts and a signature
/// belong on the result, and how the file is encoded. Two hosts can therefore
/// make the same decisions with different pixel types.
public struct RenderPlan: Codable, Equatable, Sendable {
    public var format: ExportFormat
    public var pixelSize: StudioSize
    public var upscales: Bool
    public var appliesAnalysis: Bool
    public var appliesWatermark: Bool
    public var flattensAlpha: Bool
    public var bitsPerChannel: Int
    public var colorSpace: RenderColorSpace
    /// False for a lines-only export, which is art on transparency and must not
    /// carry the source photo's EXIF.
    public var carriesSourceMetadata: Bool

    public init(format: ExportFormat, pixelSize: StudioSize, upscales: Bool,
                appliesAnalysis: Bool, appliesWatermark: Bool,
                flattensAlpha: Bool, bitsPerChannel: Int,
                colorSpace: RenderColorSpace, carriesSourceMetadata: Bool) {
        self.format = format
        self.pixelSize = pixelSize
        self.upscales = upscales
        self.appliesAnalysis = appliesAnalysis
        self.appliesWatermark = appliesWatermark
        self.flattensAlpha = flattensAlpha
        self.bitsPerChannel = bitsPerChannel
        self.colorSpace = colorSpace
        self.carriesSourceMetadata = carriesSourceMetadata
    }
}

/// Which half of an export is running. A host may report more than one; the
/// upscaler reports tiles, everything else reports its stage only.
public enum RenderStage: String, Equatable, Sendable {
    case preparing
    case rendering
    case upscaling
    case writing
}

/// A portable progress value. `total` is zero when the host cannot count the
/// work; the fraction is then nil instead of a fake percentage.
public struct RenderProgress: Equatable, Sendable {
    public var stage: RenderStage
    public var completed: Int
    public var total: Int

    public init(stage: RenderStage, completed: Int = 0, total: Int = 0) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }

    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// The failures a renderer reports, without leaking a host error domain into
/// the shared rules.
public enum RenderError: Error, Equatable, Sendable {
    /// The owner stopped the job. Nothing was written.
    case cancelled
    /// The destination is the opened photo, or an alias of it.
    case sourceIsDestination
    /// The requested output is past what the upscaler accepts.
    case imageTooLarge
    case upscaleFailed
    case renderFailed
    case writeFailed
}

/// What a completed write produced, for the caller and the record.
public struct RenderResult: Equatable, Sendable {
    public var destination: URL
    public var pixelSize: StudioSize
    public var format: ExportFormat
    public var colorSpace: RenderColorSpace
    /// The profile actually attached to the file, when the host knows it.
    public var colorProfileName: String?
    public var carriedSourceMetadata: Bool

    public init(destination: URL, pixelSize: StudioSize, format: ExportFormat,
                colorSpace: RenderColorSpace, colorProfileName: String?,
                carriedSourceMetadata: Bool) {
        self.destination = destination
        self.pixelSize = pixelSize
        self.format = format
        self.colorSpace = colorSpace
        self.colorProfileName = colorProfileName
        self.carriedSourceMetadata = carriedSourceMetadata
    }
}

/// The renderer port a host implements.
///
/// `Source` and `Output` are whatever pixel containers the host owns, so Core
/// Image objects, CGImage and Vision results never enter StudioCore. The
/// shared policy still decides the request and the plan; the host only turns
/// them into pixels and bytes.
///
/// Rendering and writing are separate because a batch chooses a unique
/// destination after the photo is rendered. `renderAndWrite` keeps the
/// single-photo order explicit.
public protocol DocumentRenderPipeline {
    associatedtype Source
    associatedtype Output

    func render(_ request: RenderRequest, source: Source,
                progress: ((RenderProgress) -> Void)?) throws -> Output

    func write(_ output: Output, request: RenderRequest, source: Source,
               to destination: URL, protecting protectedURL: URL?) throws -> RenderResult
}

public extension DocumentRenderPipeline {
    func renderAndWrite(_ request: RenderRequest, source: Source,
                        to destination: URL, protecting protectedURL: URL? = nil,
                        progress: ((RenderProgress) -> Void)? = nil) throws -> RenderResult {
        let output = try render(request, source: source, progress: progress)
        return try write(output, request: request, source: source,
                         to: destination, protecting: protectedURL)
    }
}
