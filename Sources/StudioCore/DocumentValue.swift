import Foundation

/// The document value every platform edits: the undo step, the saved project
/// and the export input all describe the same thing.
///
/// Everything here is Foundation-only and uses the portable geometry types, so
/// a host supplies its own drawing, imaging and file access. A host that has
/// CoreGraphics-shaped values (the macOS app's v3 sidecar) converts at its own
/// boundary instead of pulling those shapes into this module.

/// One manual healing stamp: a disc the owner placed on the photo. Coordinates
/// are normalized with a top-left origin and the radius is a fraction of the
/// image's short side, both measured against the *original* photo.
public struct HealSpot: Codable, Equatable {
    public var center: StudioPoint
    public var radius: Double

    public init(center: StudioPoint, radius: Double) {
        self.center = center
        self.radius = radius
    }
}

/// The shapes the art tool can stamp on a portrait. Each one is drawn by the
/// host, so there is no image asset to ship and every sticker stays sharp at
/// export size.
public enum StickerKind: String, CaseIterable, Codable, Identifiable {
    case star, heart, sparkle, flower, butterfly, lightning

    public var id: String { rawValue }
}

/// One placed sticker. Coordinates follow the healing brush exactly: the center
/// is normalized against the original photo with a top-left origin and the size
/// is a fraction of that photo's short side.
public struct Sticker: Codable, Equatable, Identifiable {
    public var id: UUID
    public var kind: StickerKind
    public var center: StudioPoint
    public var size: Double            // fraction of the short side
    public var rotation: Double        // degrees, clockwise
    public var opacity: Double         // 0...1
    public var color: MakeupColor

    public static let defaultColor = MakeupColor(hue: 45, saturation: 0.80, value: 1.0)
    public static let defaultSize: Double = 0.14

    public init(id: UUID = UUID(), kind: StickerKind = .star,
                center: StudioPoint, size: Double, rotation: Double = 0,
                opacity: Double = 1, color: MakeupColor = Sticker.defaultColor) {
        self.id = id
        self.kind = kind
        self.center = center
        self.size = size
        self.rotation = rotation
        self.opacity = opacity
        self.color = color
    }
}

/// One callout of the face-analysis overlay. The names describe where the dot
/// lands, not what the label says: the host never writes text.
public enum AnalysisRegion: String, CaseIterable, Codable, Identifiable {
    case forehead
    case eyeArea
    case underEye
    case brows
    case texture
    case pigmentation
    case jawline
    case lips
    case nose
    case chin

    public var id: String { rawValue }

    /// Which side of the frame its leader line runs to when the owner has not
    /// dragged the end somewhere else.
    public var defaultsToRight: Bool {
        switch self {
        case .forehead, .eyeArea, .pigmentation, .lips: return true
        case .underEye, .brows, .texture, .jawline, .nose, .chin: return false
        }
    }
}

/// How the analysis picture is written.
public enum AnalysisExportMode: String, CaseIterable, Codable, Identifiable {
    case onPhoto
    case poster
    case overlayOnly

    public var id: String { rawValue }
}

/// Ink for the analysis lines. The colour values stay in the host, which knows
/// its own colour type.
public enum AnalysisTint: String, CaseIterable, Codable, Identifiable {
    case chalk
    case lime
    case sky
    case ember
    case ink

    public var id: String { rawValue }

    /// A dark ink needs a pale rim to stay legible on hair and shadow.
    public var isDark: Bool { self == .ink }
}

/// The face-analysis overlay: which areas were chosen and where the leader
/// ends and feature dots were dragged, in normalized photo coordinates.
public struct AnalysisSettings: Codable, Equatable {
    public var isEnabled = false
    public var showsMesh = false
    public var showsFaceOutline = true
    public var regions: Set<AnalysisRegion> = [.forehead, .eyeArea, .texture,
                                               .pigmentation, .jawline]
    /// Leader ends the owner dragged. Regions without an entry use the
    /// automatic layout, so changing the face size later cannot leave a stale
    /// pin behind.
    public var endpoints: [String: StudioPoint] = [:]
    /// Face-side dots the owner dragged. Moving the dot moves where the line
    /// starts without moving where it stops.
    public var anchors: [String: StudioPoint] = [:]
    public var lineOpacity: Double = 1
    /// Line thickness as a percentage of the automatic weight.
    public var lineWeight: Double = 100
    public var tint: AnalysisTint = .chalk
    public var glow = true
    /// Empty border added around the photo in poster export, in percent of the
    /// short side.
    public var marginPercent: Double = 12
    public var exportMode: AnalysisExportMode = .onPhoto

    public init() {}

    public var primaryCallouts: [AnalysisRegion] {
        AnalysisRegion.allCases.filter { regions.contains($0) }
    }

    public func endpoint(for region: AnalysisRegion) -> StudioPoint? {
        endpoints[region.rawValue]
    }

    public mutating func setEndpoint(_ point: StudioPoint, for region: AnalysisRegion) {
        endpoints[region.rawValue] = point
    }

    public func anchor(for region: AnalysisRegion) -> StudioPoint? {
        anchors[region.rawValue]
    }

    public mutating func setAnchor(_ point: StudioPoint, for region: AnalysisRegion) {
        anchors[region.rawValue] = point
    }

    public mutating func resetEndpoints() {
        endpoints.removeAll()
    }

    public mutating func resetAnchors() {
        anchors.removeAll()
    }
}

extension AnalysisSettings {
    /// Project files written before the analysis tool existed decode with every
    /// new key missing, so each one falls back instead of failing the open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        showsMesh = try c.decodeIfPresent(Bool.self, forKey: .showsMesh) ?? false
        showsFaceOutline = try c.decodeIfPresent(Bool.self, forKey: .showsFaceOutline) ?? true
        regions = try c.decodeIfPresent(Set<AnalysisRegion>.self, forKey: .regions)
            ?? [.forehead, .eyeArea, .texture, .pigmentation, .jawline]
        endpoints = try c.decodeIfPresent([String: StudioPoint].self, forKey: .endpoints) ?? [:]
        anchors = try c.decodeIfPresent([String: StudioPoint].self, forKey: .anchors) ?? [:]
        lineOpacity = try c.decodeIfPresent(Double.self, forKey: .lineOpacity) ?? 1
        lineWeight = try c.decodeIfPresent(Double.self, forKey: .lineWeight) ?? 100
        tint = try c.decodeIfPresent(AnalysisTint.self, forKey: .tint) ?? .chalk
        glow = try c.decodeIfPresent(Bool.self, forKey: .glow) ?? true
        marginPercent = try c.decodeIfPresent(Double.self, forKey: .marginPercent) ?? 12
        exportMode = try c.decodeIfPresent(AnalysisExportMode.self, forKey: .exportMode) ?? .onPhoto
    }
}

/// The frame a photo is shown in: quarter turns, an optional mirror and a
/// straighten angle. It is baked into the pixels at load time, exactly like the
/// camera's EXIF orientation.
///
/// This is the value only. Applying a turn, mapping coordinates through it and
/// rasterizing it belong to the host, which owns the image types.
public struct DocumentOrientation: Codable, Equatable {
    /// Clockwise quarter turns, normalized to 0…3.
    public var quarterTurns: Int = 0
    /// Mirror across the vertical centre line, applied after the rotation.
    public var flipped: Bool = false
    /// Extra clockwise rotation in degrees, used by the straighten slider.
    public var angle: Double = 0

    public static let identity = DocumentOrientation()
    public static let maxStraighten: Double = 45

    public init() {}

    public init(quarterTurns: Int = 0, flipped: Bool = false, angle: Double = 0) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.flipped = flipped
        self.angle = angle
    }

    public var isIdentity: Bool {
        quarterTurns == 0 && !flipped && abs(angle) < 0.0001
    }

    /// Total clockwise rotation of the frame, mirror aside.
    public var rotationDegrees: Double { Double(quarterTurns) * 90 + angle }

    /// Size of the frame after the quarter turns. Straighten keeps the size and
    /// trims the corners instead.
    public func outputSize(base: StudioSize) -> StudioSize {
        quarterTurns % 2 == 0 ? base : StudioSize(width: base.height, height: base.width)
    }

    /// `second` applied on top of `first`, in the frame `first` produces.
    public static func compose(_ second: DocumentOrientation,
                               over first: DocumentOrientation) -> DocumentOrientation {
        if first.flipped {
            return DocumentOrientation(quarterTurns: first.quarterTurns - second.quarterTurns,
                                       flipped: !second.flipped,
                                       angle: first.angle - second.angle)
        }
        return DocumentOrientation(quarterTurns: first.quarterTurns + second.quarterTurns,
                                   flipped: second.flipped,
                                   angle: first.angle + second.angle)
    }

    /// The opposite turn, in the same mirrored family.
    public var inverted: DocumentOrientation {
        // A mirror combined with a rotation is itself a reflection, so it is
        // its own inverse.
        flipped ? self : DocumentOrientation(quarterTurns: -quarterTurns, angle: -angle)
    }

    public func rotatedClockwise() -> DocumentOrientation {
        DocumentOrientation.compose(DocumentOrientation(quarterTurns: 1), over: self)
    }

    public func rotatedCounterClockwise() -> DocumentOrientation {
        DocumentOrientation.compose(DocumentOrientation(quarterTurns: -1), over: self)
    }

    public func flippedHorizontally() -> DocumentOrientation {
        DocumentOrientation.compose(DocumentOrientation(flipped: true), over: self)
    }

    /// Sets the straighten angle while keeping the quarter turns and mirror.
    /// A mirrored frame reads its angle through the mirror, so the stored
    /// delta changes sign there.
    public func straightened(to target: Double) -> DocumentOrientation {
        let delta = flipped ? (angle - target) : (target - angle)
        return DocumentOrientation.compose(DocumentOrientation(angle: delta), over: self)
    }
}

extension DocumentOrientation {
    /// Old projects predate orientation entirely; every key is optional so
    /// they open unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = ((try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0) % 4 + 4) % 4
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
    }
}

/// One generative edit: the pixels the worker produced, the alpha that says
/// where they may be used, and where that rectangle sits on the original photo.
///
/// The photo itself is never rewritten. An edit is a layer the host
/// re-composites, so undo is a list change.
public struct AIEdit: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Which Quick Edit preset produced it, for the UI and the report.
    public var preset: String
    public var prompt: String
    public var seed: Int
    /// `patch.png`: the worker's edited pixels for `box`, at the job's size.
    public var patchFile: String
    /// `alpha.png`: 0…255, zero everywhere outside the authorized region.
    public var alphaFile: String
    /// Authorized rectangle in normalized original-photo coordinates, top-left
    /// origin, like `HealSpot` and `Sticker`.
    public var box: StudioRect
    /// The job image's pixel size.
    public var imagePixels: StudioSize
    /// Turn applied to the two files since they were written. The rasters stay
    /// untouched on disk so undo can point the same bytes back the other way.
    public var patchOrientation: DocumentOrientation?
    public var createdAt: Date

    /// How long the worker took, kept for the record and the status line.
    public var seconds: Double
    /// The worker's own report that nothing outside the region moved.
    public var outsidePixelsIdentical: Bool

    public init(id: UUID = UUID(), preset: String, prompt: String, seed: Int,
                patchFile: String, alphaFile: String, box: StudioRect,
                imagePixels: StudioSize,
                patchOrientation: DocumentOrientation? = nil,
                createdAt: Date = Date(), seconds: Double = 0,
                outsidePixelsIdentical: Bool = true) {
        self.id = id
        self.preset = preset
        self.prompt = prompt
        self.seed = seed
        self.patchFile = patchFile
        self.alphaFile = alphaFile
        self.box = box
        self.imagePixels = imagePixels
        self.patchOrientation = patchOrientation
        self.createdAt = createdAt
        self.seconds = seconds
        self.outsidePixelsIdentical = outsidePixelsIdentical
    }
}

/// The document values one undo step covers. A plain value: a host still owns
/// editing, history timers, dirty tracking, saving, autosave and recovery; this
/// type only carries the fields those features agree on.
public struct DocumentState: Codable, Equatable {
    public var adjustments: Adjustments
    public var healSpots: [HealSpot]
    public var stickers: [Sticker]
    public var aiEdits: [AIEdit]
    public var analysis: AnalysisSettings
    public var crop: StudioRect?
    public var orientation: DocumentOrientation
    public var selectedFaceIndex: Int?

    public init(adjustments: Adjustments = Adjustments(),
                healSpots: [HealSpot] = [],
                stickers: [Sticker] = [],
                aiEdits: [AIEdit] = [],
                analysis: AnalysisSettings = AnalysisSettings(),
                crop: StudioRect? = nil,
                orientation: DocumentOrientation = .identity,
                selectedFaceIndex: Int? = nil) {
        self.adjustments = adjustments
        self.healSpots = healSpots
        self.stickers = stickers
        self.aiEdits = aiEdits
        self.analysis = analysis
        self.crop = crop
        self.orientation = orientation
        self.selectedFaceIndex = selectedFaceIndex
    }
}

/// A document state is a history step on every platform, so the conformance
/// lives with the value instead of being added retroactively by a host.
extension DocumentState: HistoryState {}
