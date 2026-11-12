import CoreGraphics
import Foundation
import StudioCore

/// Any JSON value, kept so an unknown project key can be written back
/// unchanged. Objects and arrays recurse; numbers decode as `Int` when they are
/// integral and `Double` otherwise.
enum ProjectJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ProjectJSONValue])
    case object([String: ProjectJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ProjectJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ProjectJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var integerValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}

/// What the open document's file looked like, so a save can keep it that way.
/// A v3 file stays v3; a v4 file stays v4 and keeps its unknown keys.
struct ProjectWriteContext: Equatable {
    var version: Int
    var unknownFields: [String: ProjectJSONValue]
    var requiredFeatures: [String]

    static let v3 = ProjectWriteContext(version: RetouchProject.currentVersion,
                                        unknownFields: [:], requiredFeatures: [])

    var isV4: Bool { version >= ProjectV4.currentVersion }

    /// True when the file carries data a plain v3 rewrite would drop. A context
    /// that carries nothing is not stored in a recovery snapshot at all, which
    /// keeps a v3 snapshot byte-identical to what earlier builds wrote.
    var carriesFileMetadata: Bool {
        isV4 || !unknownFields.isEmpty || !requiredFeatures.isEmpty
    }
}

/// Recovery snapshots keep the open document's write context next to the v3
/// payload, so a crash-recovered v4 document saves as v4 again. Decoding is
/// tolerant: a context written by an earlier build, or a partial one, falls back
/// to the v3 defaults instead of failing the whole snapshot.
extension ProjectWriteContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, unknownFields, requiredFeatures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? RetouchProject.currentVersion
        unknownFields = try container.decodeIfPresent([String: ProjectJSONValue].self,
                                                      forKey: .unknownFields) ?? [:]
        requiredFeatures = try container.decodeIfPresent([String].self,
                                                         forKey: .requiredFeatures) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(unknownFields, forKey: .unknownFields)
        try container.encode(requiredFeatures, forKey: .requiredFeatures)
    }
}

/// A project read from disk: the v3 model every call site already uses, plus
/// the file-level facts a save has to preserve.
struct ProjectFile {
    var project: RetouchProject
    var context: ProjectWriteContext
}

/// The v4 project document. It differs from v3 only where portability and
/// preservation require it: geometry is written as named `{x, y, width,
/// height}` / `{width, height}` records instead of CoreGraphics' unkeyed
/// arrays, and unknown top-level keys are carried through a save.
struct ProjectV4: Codable, Equatable {
    static let currentVersion = 4

    /// The capabilities this build can honor when a file requires them.
    static let supportedFeatures: Set<String> = ["portable_geometry"]

    static let knownKeys: Set<String> = [
        "version", "imagePath", "imageBookmark", "adjustments", "exportFormat",
        "exportQuality", "exportLongEdge", "autoRetouchStrength",
        "autoColorStrength", "crop", "orientation", "healSpots", "stickers",
        "aiEdits", "analysis", "selectedFace", "requiredFeatures"
    ]

    var version = ProjectV4.currentVersion
    var imagePath: String
    var imageBookmark: Data?
    var adjustments: Adjustments
    var exportFormat: String
    var exportQuality: Double
    var exportLongEdge: Int?
    var autoRetouchStrength: Double
    var autoColorStrength: Double?
    var crop: StudioRect?
    var orientation: DocumentOrientation?
    var healSpots: [HealSpotV4]?
    var stickers: [StickerV4]?
    var aiEdits: [AIEditV4]?
    var analysis: AnalysisSettingsV4?
    var selectedFace: Int?
    var requiredFeatures: [String]?

    init(project: RetouchProject, requiredFeatures: [String] = []) {
        imagePath = project.imagePath
        imageBookmark = project.imageBookmark
        adjustments = project.adjustments
        exportFormat = project.exportFormat
        exportQuality = project.exportQuality
        exportLongEdge = project.exportLongEdge
        autoRetouchStrength = project.autoRetouchStrength
        autoColorStrength = project.autoColorStrength
        crop = project.crop.map(StudioRect.init)
        orientation = project.orientation
        healSpots = project.healSpots?.map(HealSpotV4.init)
        stickers = project.stickers?.map(StickerV4.init)
        aiEdits = project.aiEdits?.map(AIEditV4.init)
        analysis = project.analysis.map(AnalysisSettingsV4.init)
        selectedFace = project.selectedFace
        self.requiredFeatures = requiredFeatures.isEmpty ? nil : requiredFeatures
    }

    /// The v3 model this file describes. The returned project is always
    /// version 3: v4 is a file format, not a second in-memory document model.
    var project: RetouchProject {
        RetouchProject(imagePath: imagePath,
                       imageBookmark: imageBookmark,
                       adjustments: adjustments,
                       exportFormat: exportFormat,
                       exportQuality: exportQuality,
                       exportLongEdge: exportLongEdge,
                       autoRetouchStrength: autoRetouchStrength,
                       autoColorStrength: autoColorStrength,
                       crop: crop?.cgRect,
                       healSpots: healSpots?.map(\.healSpot),
                       stickers: stickers?.map(\.sticker),
                       aiEdits: aiEdits?.map(\.edit),
                       analysis: analysis?.settings,
                       selectedFace: selectedFace,
                       orientation: orientation)
    }
}

struct HealSpotV4: Codable, Equatable {
    var center: StudioPoint
    var radius: Double

    init(_ spot: HealSpot) {
        center = StudioPoint(spot.center)
        radius = Double(spot.radius)
    }

    var healSpot: HealSpot {
        HealSpot(center: center.cgPoint, radius: CGFloat(radius))
    }
}

struct StickerV4: Codable, Equatable {
    var id: UUID
    var kind: StickerKind
    var center: StudioPoint
    var size: Double
    var rotation: Double
    var opacity: Double
    var color: MakeupColor

    init(_ sticker: Sticker) {
        id = sticker.id
        kind = sticker.kind
        center = StudioPoint(sticker.center)
        size = sticker.size
        rotation = sticker.rotation
        opacity = sticker.opacity
        color = sticker.color
    }

    var sticker: Sticker {
        var value = Sticker(center: center.cgPoint, size: size)
        value.id = id
        value.kind = kind
        value.rotation = rotation
        value.opacity = opacity
        value.color = color
        return value
    }
}

struct AIEditV4: Codable, Equatable {
    var id: UUID
    var preset: String
    var prompt: String
    var seed: Int
    var patchFile: String
    var alphaFile: String
    var box: StudioRect
    var imagePixels: StudioSize
    var patchOrientation: DocumentOrientation?
    var createdAt: Date
    var seconds: Double
    var outsidePixelsIdentical: Bool

    init(_ edit: AIEdit) {
        id = edit.id
        preset = edit.preset
        prompt = edit.prompt
        seed = edit.seed
        patchFile = edit.patchFile
        alphaFile = edit.alphaFile
        box = StudioRect(edit.box)
        imagePixels = StudioSize(edit.imagePixels)
        patchOrientation = edit.patchOrientation
        createdAt = edit.createdAt
        seconds = edit.seconds
        outsidePixelsIdentical = edit.outsidePixelsIdentical
    }

    var edit: AIEdit {
        var value = AIEdit(preset: preset, prompt: prompt, seed: seed,
                           patchFile: patchFile, alphaFile: alphaFile,
                           box: box.cgRect, imagePixels: imagePixels.cgSize)
        value.id = id
        value.patchOrientation = patchOrientation
        value.createdAt = createdAt
        value.seconds = seconds
        value.outsidePixelsIdentical = outsidePixelsIdentical
        return value
    }
}

struct AnalysisSettingsV4: Codable, Equatable {
    var isEnabled: Bool
    var showsMesh: Bool
    var showsFaceOutline: Bool
    /// Sorted by raw value so the same set writes the same bytes on every
    /// architecture; v3's `Set` encoding has no order guarantee.
    var regions: [AnalysisRegion]
    var endpoints: [String: StudioPoint]
    var anchors: [String: StudioPoint]
    var lineOpacity: Double
    var lineWeight: Double
    var tint: AnalysisTint
    var glow: Bool
    var marginPercent: Double
    var exportMode: AnalysisExportMode

    init(_ settings: AnalysisSettings) {
        isEnabled = settings.isEnabled
        showsMesh = settings.showsMesh
        showsFaceOutline = settings.showsFaceOutline
        regions = settings.regions.sorted { $0.rawValue < $1.rawValue }
        endpoints = settings.endpoints.mapValues(StudioPoint.init)
        anchors = settings.anchors.mapValues(StudioPoint.init)
        lineOpacity = settings.lineOpacity
        lineWeight = settings.lineWeight
        tint = settings.tint
        glow = settings.glow
        marginPercent = settings.marginPercent
        exportMode = settings.exportMode
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, showsMesh, showsFaceOutline, regions, endpoints, anchors,
             lineOpacity, lineWeight, tint, glow, marginPercent, exportMode
    }

    /// Missing keys fall back exactly like `AnalysisSettings`, so a hand-written
    /// or partial v4 document opens with the same defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        showsMesh = try c.decodeIfPresent(Bool.self, forKey: .showsMesh) ?? false
        showsFaceOutline = try c.decodeIfPresent(Bool.self, forKey: .showsFaceOutline) ?? true
        regions = (try c.decodeIfPresent([AnalysisRegion].self, forKey: .regions)
            ?? Array(AnalysisSettings().regions)).sorted { $0.rawValue < $1.rawValue }
        endpoints = try c.decodeIfPresent([String: StudioPoint].self, forKey: .endpoints) ?? [:]
        anchors = try c.decodeIfPresent([String: StudioPoint].self, forKey: .anchors) ?? [:]
        lineOpacity = try c.decodeIfPresent(Double.self, forKey: .lineOpacity) ?? 1
        lineWeight = try c.decodeIfPresent(Double.self, forKey: .lineWeight) ?? 100
        tint = try c.decodeIfPresent(AnalysisTint.self, forKey: .tint) ?? .chalk
        glow = try c.decodeIfPresent(Bool.self, forKey: .glow) ?? true
        marginPercent = try c.decodeIfPresent(Double.self, forKey: .marginPercent) ?? 12
        exportMode = try c.decodeIfPresent(AnalysisExportMode.self, forKey: .exportMode) ?? .onPhoto
    }

    var settings: AnalysisSettings {
        var value = AnalysisSettings()
        value.isEnabled = isEnabled
        value.showsMesh = showsMesh
        value.showsFaceOutline = showsFaceOutline
        value.regions = Set(regions)
        value.endpoints = endpoints.mapValues { $0.cgPoint }
        value.anchors = anchors.mapValues { $0.cgPoint }
        value.lineOpacity = lineOpacity
        value.lineWeight = lineWeight
        value.tint = tint
        value.glow = glow
        value.marginPercent = marginPercent
        value.exportMode = exportMode
        return value
    }
}
