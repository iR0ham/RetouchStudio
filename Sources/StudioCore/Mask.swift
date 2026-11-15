import Foundation

/// One brush stroke of a stored mask, in `source_normalized` space: fractions
/// of the upright, uncropped source photo with a top-left origin — the same
/// space as `crop`, `healSpots` and an AI edit's `box`.
///
/// `width` is a fraction of the photo's width, so a stroke keeps its size when
/// the mask is rendered at preview or export resolution.
public struct MaskStroke: Codable, Equatable, Sendable {
    public var points: [StudioPoint]
    public var width: Double
    /// True when the stroke removes paint instead of adding it.
    public var erase: Bool

    public init(points: [StudioPoint], width: Double, erase: Bool = false) {
        self.points = points
        self.width = width
        self.erase = erase
    }
}

/// A derived raster a mask may point at, such as an edge-following refinement.
/// It is never authoritative: the strokes and box above describe what the owner
/// drew, and deleting the file only costs a recomputation.
public struct MaskRasterReference: Codable, Equatable, Sendable {
    /// File name inside the mask store folder named by the mask's id.
    public var file: String
    /// Lower-case SHA-256 of the file's bytes, so a replaced raster is noticed
    /// instead of applied as if it belonged to this mask.
    public var sha256: String
    public var width: Int
    public var height: Int

    public init(file: String, sha256: String, width: Int, height: Int) {
        self.file = file
        self.sha256 = sha256
        self.width = width
        self.height = height
    }
}

/// Tool settings a mask was drawn with. Absent values mean the tool default,
/// which keeps a mask that never touched them small.
public struct MaskParameters: Codable, Equatable, Sendable {
    /// Edge softening as a fraction of the photo's smaller edge.
    public var feather: Double?
    public var opacity: Double?

    public init(feather: Double? = nil, opacity: Double? = nil) {
        self.feather = feather
        self.opacity = opacity
    }
}

/// The pixel size of the source photo a mask was drawn against. Recorded so a
/// document opened on a different image can refuse the mask instead of placing
/// it at coordinates that now mean something else.
public struct MaskSourceFrame: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One persistent mask. `id` is minted once and never derived from an array
/// index or a face's rank, so it survives reordering, reloads and hosts.
///
/// The geometry is user data; `refined` is a cache reference. `faceId` names a
/// `FaceIdentityRecord`, not a face container: a mask never owns a person.
public struct MaskRecord: Codable, Equatable, Identifiable, Sendable {
    /// The only kind this build produces. A reader keeps an unknown kind's
    /// record untouched and refuses to apply it.
    public static let selectionKind = "selection"
    /// The only space this build writes. The name is stored so a future kind
    /// can say it uses another one without guessing.
    public static let sourceNormalized = "source_normalized"

    public var id: UUID
    public var kind: String
    /// Increments each time the owner changes this mask, so a derived cache can
    /// tell a stale raster from a current one.
    public var revision: Int
    public var updatedAt: Date?
    public var space: String
    public var frame: MaskSourceFrame
    public var strokes: [MaskStroke]
    public var box: StudioRect?
    public var inverted: Bool
    public var parameters: MaskParameters?
    public var refined: MaskRasterReference?
    public var faceId: UUID?

    public init(id: UUID = UUID(), kind: String = MaskRecord.selectionKind,
                revision: Int = 1, updatedAt: Date? = nil,
                space: String = MaskRecord.sourceNormalized,
                frame: MaskSourceFrame, strokes: [MaskStroke] = [],
                box: StudioRect? = nil, inverted: Bool = false,
                parameters: MaskParameters? = nil,
                refined: MaskRasterReference? = nil, faceId: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.updatedAt = updatedAt
        self.space = space
        self.frame = frame
        self.strokes = strokes
        self.box = box
        self.inverted = inverted
        self.parameters = parameters
        self.refined = refined
        self.faceId = faceId
    }

    public var hasContent: Bool {
        refined != nil || box != nil || !strokes.isEmpty
    }

    /// True when this mask was drawn against the photo that is open now.
    public func applies(toWidth width: Int, height: Int) -> Bool {
        frame.width == width && frame.height == height
    }
}

/// A person the owner has worked with, persisted so a mask can stay attached to
/// them across a reopen. The box is evidence for re-finding the same face, not
/// a detection cache; detection runs again on every open.
public struct FaceIdentityRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var box: StudioRect
    public var source: String

    public init(id: UUID = UUID(), box: StudioRect, source: String = "vision") {
        self.id = id
        self.box = box
        self.source = source
    }
}
