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

    var id: String { rawValue }

    /// Presets only carry skin, geometry and colour values, so the tools they
    /// leave untouched hide the strip instead of showing a dead control.
    var showsPresets: Bool { self != .crop && self != .look && self != .makeup }

    var title: String {
        switch self {
        case .skin: return "Skin"
        case .heal: return "Healing"
        case .reshape: return "Reshape"
        case .detail: return "Eyes & Teeth"
        case .makeup: return "Makeup"
        case .color: return "Color & Light"
        case .look: return "Looks"
        case .crop: return "Crop"
        }
    }

    var subtitle: String {
        switch self {
        case .skin: return "Texture, tone and blemishes"
        case .heal: return "Stamp out blemishes by hand"
        case .reshape: return "Shape facial features"
        case .detail: return "Whiten teeth and brighten eyes"
        case .makeup: return "Lips, cheeks and brows"
        case .color: return "Exposure, color and light"
        case .look: return "Film grades and grain"
        case .crop: return "Reframe the photo"
        }
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
        }
    }
}
