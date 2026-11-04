import Foundation

/// The inspector only ever shows one tool at a time. Keeping the mode in the
/// model means the rail, menus and keyboard shortcuts can all drive it.
enum ToolMode: String, CaseIterable, Identifiable {
    case skin
    case heal
    case reshape
    case detail
    case makeup
    case color
    case look
    case crop
    case body
    case background
    case art
    case analysis

    var id: String { rawValue }

    /// Presets only carry skin, geometry and colour values, so the tools they
    /// leave untouched hide the strip instead of showing a dead control.
    var showsPresets: Bool {
        self != .crop && self != .look && self != .makeup
            && self != .body && self != .background && self != .art
            && self != .analysis
    }

    var title: String {
        L10n.current.toolTitle(self)
    }

    var subtitle: String {
        L10n.current.toolSubtitle(self)
    }

    /// The bare number that picks this tool, in the order of the bar. The art
    /// tool is deliberately left without one: it is the eleventh case and the
    /// row only has ten number keys.
    var shortcutKey: String? {
        guard let index = Self.allCases.firstIndex(of: self), index < 10 else { return nil }
        return index == 9 ? "0" : String(index + 1)
    }

    var icon: String {
        switch self {
        case .skin: return "sparkles"
        case .heal: return "bandage"
        case .reshape: return "face.smiling"
        case .detail: return "eye"
        case .makeup: return "paintpalette"
        case .color: return "camera.filters"
        case .look: return "film"
        case .crop: return "crop"
        case .body: return "figure.stand"
        case .background: return "person.and.background.dotted"
        case .art: return "star.circle"
        case .analysis: return "viewfinder"
        }
    }
}
