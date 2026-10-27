import Foundation

/// The inspector only ever shows one tool at a time. Keeping the mode in the
/// model means the rail, menus and keyboard shortcuts can all drive it.
enum ToolMode: String, CaseIterable, Identifiable {
    case skin
    case reshape
    case detail
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skin: return "Skin"
        case .reshape: return "Reshape"
        case .detail: return "Eyes & Teeth"
        case .color: return "Color & Light"
        }
    }

    var subtitle: String {
        switch self {
        case .skin: return "Texture, tone and blemishes"
        case .reshape: return "Shape facial features"
        case .detail: return "Whiten teeth and brighten eyes"
        case .color: return "Exposure, color and light"
        }
    }

    var icon: String {
        switch self {
        case .skin: return "sparkles"
        case .reshape: return "face.smiling"
        case .detail: return "eye"
        case .color: return "camera.filters"
        }
    }
}
