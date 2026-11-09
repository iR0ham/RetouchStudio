import CoreGraphics
import Foundation
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
        healSpots = try c.decodeIfPresent([HealSpot].self, forKey: .healSpots)
        stickers = try c.decodeIfPresent([Sticker].self, forKey: .stickers)
        aiEdits = try c.decodeIfPresent([AIEdit].self, forKey: .aiEdits)
        analysis = try c.decodeIfPresent(AnalysisSettings.self, forKey: .analysis)
        selectedFace = try c.decodeIfPresent(Int.self, forKey: .selectedFace)
    }
}
