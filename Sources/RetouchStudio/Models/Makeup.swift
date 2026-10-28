import Foundation
import SwiftUI

/// Cosmetic colours offered by the Makeup tool.
///
/// Shades are stored as display-referred sRGB components, which is how a swatch
/// is drawn and how the tint layer is built. Core Image works in linear light,
/// so the engine decodes them before blending — the same convention the pixel
/// gates in `MaskBuilder` use, where every threshold was measured on 8-bit
/// pixels.
enum MakeupShade: String, CaseIterable, Identifiable, Codable {
    case rose
    case coral
    case peach
    case berry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rose: return "Rose"
        case .coral: return "Coral"
        case .peach: return "Peach"
        case .berry: return "Berry"
        }
    }

    /// Linear-light channel multipliers.
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .rose: return (0.72, 0.20, 0.28)
        case .coral: return (0.86, 0.36, 0.24)
        case .peach: return (0.90, 0.52, 0.38)
        case .berry: return (0.52, 0.14, 0.28)
        }
    }

    var swatch: Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
