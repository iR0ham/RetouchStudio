import CoreGraphics
import Foundation

/// One callout of the face-analysis overlay. The names describe where the dot
/// lands, not what the label says: the app never writes text, the owner adds it
/// after the picture is exported.
enum AnalysisRegion: String, CaseIterable, Codable, Identifiable {
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

    var id: String { rawValue }

    /// Which side of the frame its leader line runs to when the owner has not
    /// dragged the end somewhere else. Split so two callouts on the same side
    /// do not land on top of each other.
    var defaultsToRight: Bool {
        switch self {
        case .forehead, .eyeArea, .pigmentation, .lips: return true
        case .underEye, .brows, .texture, .jawline, .nose, .chin: return false
        }
    }
}

/// How the analysis picture is written. `onPhoto` keeps the photo's own frame,
/// `poster` adds a blurred bleed so the leader lines can end in empty space for
/// text, and `overlayOnly` writes just the lines on transparency.
enum AnalysisExportMode: String, CaseIterable, Codable, Identifiable {
    case onPhoto
    case poster
    case overlayOnly

    var id: String { rawValue }
}

/// Ink for the analysis lines. Chalk is the neutral default; the others let a
/// line sit against a pale or a dark photo without extra work.
enum AnalysisTint: String, CaseIterable, Codable, Identifiable {
    case chalk
    case lime
    case sky
    case ember
    case ink

    var id: String { rawValue }

    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .chalk: return (1, 1, 1)
        case .lime: return (0.78, 0.97, 0.24)
        case .sky: return (0.36, 0.80, 1)
        case .ember: return (1, 0.62, 0.32)
        case .ink: return (0.06, 0.07, 0.09)
        }
    }

    /// A dark ink needs a pale rim to stay legible on hair and shadow.
    var isDark: Bool { self == .ink }
}

struct AnalysisSettings: Codable, Equatable {
    var isEnabled = false
    var showsMesh = false
    var showsFaceOutline = true
    var regions: Set<AnalysisRegion> = [.forehead, .eyeArea, .texture, .pigmentation, .jawline]
    /// Leader ends the owner dragged, in photo coordinates. Regions without an
    /// entry use the automatic layout, so changing the face size later cannot
    /// leave a stale pin behind.
    var endpoints: [String: CGPoint] = [:]
    /// Face-side dots the owner dragged, in the same coordinates. The dot is the
    /// end of the line that sits on the feature; moving it moves where the line
    /// starts without moving where it stops.
    var anchors: [String: CGPoint] = [:]
    var lineOpacity: Double = 1
    /// Line thickness as a percentage of the automatic weight.
    var lineWeight: Double = 100
    var tint: AnalysisTint = .chalk
    var glow = true
    /// Empty border added around the photo in poster export, in percent of the
    /// short side.
    var marginPercent: Double = 12
    var exportMode: AnalysisExportMode = .onPhoto

    var primaryCallouts: [AnalysisRegion] {
        AnalysisRegion.allCases.filter { regions.contains($0) }
    }

    func endpoint(for region: AnalysisRegion) -> CGPoint? {
        endpoints[region.rawValue]
    }

    mutating func setEndpoint(_ point: CGPoint, for region: AnalysisRegion) {
        endpoints[region.rawValue] = point
    }

    func anchor(for region: AnalysisRegion) -> CGPoint? {
        anchors[region.rawValue]
    }

    mutating func setAnchor(_ point: CGPoint, for region: AnalysisRegion) {
        anchors[region.rawValue] = point
    }

    mutating func resetEndpoints() {
        endpoints.removeAll()
    }

    mutating func resetAnchors() {
        anchors.removeAll()
    }
}

extension AnalysisSettings {
    /// Project files written before the analysis tool existed decode with every
    /// new key missing, so each one falls back instead of failing the open.
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
}
