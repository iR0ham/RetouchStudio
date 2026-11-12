import CoreGraphics
import Foundation
import StudioCore
import UniformTypeIdentifiers

/// The sidecar document for one photo. The photo itself is never copied or
/// modified; the project records how it should be edited so the work can be
/// resumed later.
struct RetouchProject: Codable {
    /// v2 added AI edits. A v1 project still opens: every later field decodes
    /// as `nil` and means "off". v3 added the frame orientation.
    static let currentVersion = 3
    static let fileExtension = "retouch"

    /// The app declares this type in Info.plist, so the panel filters to real
    /// project files instead of any JSON.
    static var contentType: UTType {
        UTType(exportedAs: "app.retouchstudio.project", conformingTo: .json)
    }

    var version = currentVersion
    var imagePath: String
    /// A bookmark to the photo. It survives moving the file or its folder,
    /// which the recorded path alone does not. `nil` in older projects.
    var imageBookmark: Data? = nil
    var adjustments: Adjustments
    var exportFormat: String
    var exportQuality: Double
    /// Longest exported edge in pixels. `nil` keeps the photo's own size, and
    /// older projects decode as `nil`.
    var exportLongEdge: Int? = nil
    var autoRetouchStrength: Double
    /// Strength for Auto Color & Light. Projects written before it existed
    /// decode as `nil` and the editor falls back to applying the analysis
    /// exactly as measured.
    var autoColorStrength: Double? = nil
    /// Normalized top-left crop applied to the original photo, if any. Projects
    /// written before crop existed decode as `nil`.
    var crop: CGRect? = nil
    /// Turns, mirror and straighten already baked into the pixels. `nil` means
    /// the photo opens upright, as every project before orientation did.
    var orientation: DocumentOrientation? = nil
    /// Manual healing stamps, in the same original-photo coordinates as `crop`.
    /// Empty is written as `nil` so older projects and older readers are
    /// unaffected.
    var healSpots: [HealSpot]? = nil
    /// Placed stickers, again in original-photo coordinates. `nil` keeps older
    /// project files and older readers working unchanged.
    var stickers: [Sticker]? = nil
    /// Saved AI patches, referencing files in the app's own edit store. `nil`
    /// means the project predates them.
    var aiEdits: [AIEdit]? = nil
    /// The face-analysis overlay, including which areas were chosen and where
    /// the leader ends were dragged. `nil` leaves the tool off, as it was
    /// before the tool existed.
    var analysis: AnalysisSettings? = nil
    /// The face the owner was working on, as an index into the accepted faces
    /// (largest first). `nil` keeps the automatic choice.
    var selectedFace: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case version, imagePath, imageBookmark, adjustments, exportFormat,
             exportQuality, exportLongEdge, autoRetouchStrength,
             autoColorStrength, crop, healSpots, stickers, aiEdits, analysis,
             selectedFace, orientation
    }

    /// Every top-level key this schema owns. Anything else in a file is an
    /// unknown field and is carried through a save instead of discarded.
    static let knownJSONKeys: Set<String> = [
        "version", "imagePath", "imageBookmark", "adjustments", "exportFormat",
        "exportQuality", "exportLongEdge", "autoRetouchStrength",
        "autoColorStrength", "crop", "healSpots", "stickers", "aiEdits",
        "analysis", "selectedFace", "orientation"
    ]

    init(imagePath: String, imageBookmark: Data? = nil,
         adjustments: Adjustments, exportFormat: String,
         exportQuality: Double, exportLongEdge: Int? = nil,
         autoRetouchStrength: Double, autoColorStrength: Double? = nil,
         crop: CGRect? = nil, healSpots: [HealSpot]? = nil,
         stickers: [Sticker]? = nil, aiEdits: [AIEdit]? = nil,
         analysis: AnalysisSettings? = nil,
         selectedFace: Int? = nil,
         orientation: DocumentOrientation? = nil) {
        self.imagePath = imagePath
        self.imageBookmark = imageBookmark
        self.adjustments = adjustments
        self.exportFormat = exportFormat
        self.exportQuality = exportQuality
        self.exportLongEdge = exportLongEdge
        self.autoRetouchStrength = autoRetouchStrength
        self.autoColorStrength = autoColorStrength
        self.crop = crop
        self.healSpots = healSpots
        self.stickers = stickers
        self.aiEdits = aiEdits
        self.analysis = analysis
        self.selectedFace = selectedFace
        self.orientation = orientation
    }

    /// Decoded by hand so a project written before the version key existed
    /// still opens: it predates every schema change, so it is version 1.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        imagePath = try c.decode(String.self, forKey: .imagePath)
        imageBookmark = try c.decodeIfPresent(Data.self, forKey: .imageBookmark)
        adjustments = try c.decode(Adjustments.self, forKey: .adjustments)
        exportFormat = try c.decode(String.self, forKey: .exportFormat)
        exportQuality = try c.decode(Double.self, forKey: .exportQuality)
        exportLongEdge = try c.decodeIfPresent(Int.self, forKey: .exportLongEdge)
        autoRetouchStrength = try c.decode(Double.self, forKey: .autoRetouchStrength)
        autoColorStrength = try c.decodeIfPresent(Double.self, forKey: .autoColorStrength)
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        orientation = try c.decodeIfPresent(DocumentOrientation.self, forKey: .orientation)
        healSpots = try c.decodeIfPresent([HealSpotV3].self, forKey: .healSpots)?
            .map(\.spot)
        stickers = try c.decodeIfPresent([StickerV3].self, forKey: .stickers)?
            .map(\.sticker)
        aiEdits = try c.decodeIfPresent([AIEditV3].self, forKey: .aiEdits)?
            .map(\.edit)
        analysis = try c.decodeIfPresent(AnalysisSettingsV3.self, forKey: .analysis)?
            .settings
        selectedFace = try c.decodeIfPresent(Int.self, forKey: .selectedFace)
    }

    /// Writes the same bytes v3 always wrote: the portable values are turned
    /// back into Core Graphics-shaped records here and nowhere else.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(imagePath, forKey: .imagePath)
        try c.encodeIfPresent(imageBookmark, forKey: .imageBookmark)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encode(exportFormat, forKey: .exportFormat)
        try c.encode(exportQuality, forKey: .exportQuality)
        try c.encodeIfPresent(exportLongEdge, forKey: .exportLongEdge)
        try c.encode(autoRetouchStrength, forKey: .autoRetouchStrength)
        try c.encodeIfPresent(autoColorStrength, forKey: .autoColorStrength)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encodeIfPresent(orientation, forKey: .orientation)
        try c.encodeIfPresent(healSpots?.map(HealSpotV3.init), forKey: .healSpots)
        try c.encodeIfPresent(stickers?.map(StickerV3.init), forKey: .stickers)
        try c.encodeIfPresent(aiEdits?.map(AIEditV3.init), forKey: .aiEdits)
        try c.encodeIfPresent(analysis.map(AnalysisSettingsV3.init), forKey: .analysis)
        try c.encodeIfPresent(selectedFace, forKey: .selectedFace)
    }
}

// MARK: - Frozen v3 wire records

/// Core Graphics' own Codable shape is unkeyed: a point is `[x, y]`, a size is
/// `[width, height]` and a rect is `[[x, y], [width, height]]`. v3 files have
/// always written those arrays, so these records keep that shape exactly while
/// the editing code speaks the portable types. They are used only by
/// `RetouchProject`'s coding and mean nothing outside it.

struct HealSpotV3: Codable, Equatable {
    var center: CGPoint
    var radius: CGFloat

    init(_ spot: HealSpot) {
        center = spot.center.cgPoint
        radius = CGFloat(spot.radius)
    }

    var spot: HealSpot {
        HealSpot(center: StudioPoint(center), radius: Double(radius))
    }
}

struct StickerV3: Codable, Equatable {
    var id: UUID
    var kind: StickerKind
    var center: CGPoint
    var size: Double
    var rotation: Double
    var opacity: Double
    var color: MakeupColor

    init(_ sticker: Sticker) {
        id = sticker.id
        kind = sticker.kind
        center = sticker.center.cgPoint
        size = sticker.size
        rotation = sticker.rotation
        opacity = sticker.opacity
        color = sticker.color
    }

    var sticker: Sticker {
        Sticker(id: id, kind: kind, center: StudioPoint(center), size: size,
                rotation: rotation, opacity: opacity, color: color)
    }
}

struct AIEditV3: Codable, Equatable {
    var id: UUID
    var preset: String
    var prompt: String
    var seed: Int
    var patchFile: String
    var alphaFile: String
    var box: CGRect
    var imagePixels: CGSize
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
        box = edit.box.cgRect
        imagePixels = edit.imagePixels.cgSize
        patchOrientation = edit.patchOrientation
        createdAt = edit.createdAt
        seconds = edit.seconds
        outsidePixelsIdentical = edit.outsidePixelsIdentical
    }

    var edit: AIEdit {
        AIEdit(id: id, preset: preset, prompt: prompt, seed: seed,
               patchFile: patchFile, alphaFile: alphaFile,
               box: StudioRect(box), imagePixels: StudioSize(imagePixels),
               patchOrientation: patchOrientation, createdAt: createdAt,
               seconds: seconds, outsidePixelsIdentical: outsidePixelsIdentical)
    }
}

/// v3 wrote analysis pins as Core Graphics points and the chosen regions as a
/// `Set`, and tolerated every key being absent. It still does.
struct AnalysisSettingsV3: Codable, Equatable {
    var isEnabled: Bool
    var showsMesh: Bool
    var showsFaceOutline: Bool
    var regions: Set<AnalysisRegion>
    var endpoints: [String: CGPoint]
    var anchors: [String: CGPoint]
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
        regions = settings.regions
        endpoints = settings.endpoints.mapValues(\.cgPoint)
        anchors = settings.anchors.mapValues(\.cgPoint)
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

    /// The same tolerant decode the v3 model had: a project written before the
    /// analysis tool existed opens with the tool off, not with an error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        showsMesh = try c.decodeIfPresent(Bool.self, forKey: .showsMesh) ?? false
        showsFaceOutline = try c.decodeIfPresent(Bool.self, forKey: .showsFaceOutline) ?? true
        regions = try c.decodeIfPresent(Set<AnalysisRegion>.self, forKey: .regions)
            ?? [.forehead, .eyeArea, .texture, .pigmentation, .jawline]
        endpoints = try c.decodeIfPresent([String: CGPoint].self, forKey: .endpoints) ?? [:]
        anchors = try c.decodeIfPresent([String: CGPoint].self, forKey: .anchors) ?? [:]
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
        value.regions = regions
        value.endpoints = endpoints.mapValues(StudioPoint.init)
        value.anchors = anchors.mapValues(StudioPoint.init)
        value.lineOpacity = lineOpacity
        value.lineWeight = lineWeight
        value.tint = tint
        value.glow = glow
        value.marginPercent = marginPercent
        value.exportMode = exportMode
        return value
    }
}
