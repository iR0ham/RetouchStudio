import CoreGraphics
import Foundation

/// A film-style colour grade expressed as tone curve plus split toning, so a
/// whole look is one colour-cube pass instead of a stack of filters.
struct LookGrade: Equatable {
    /// Strength of the S-curve around mid-grey. Negative flattens.
    var contrast: Double = 0
    /// Matte black lift: 0 is a true black, 0.25 is a faded print.
    var lift: Double = 0
    /// Compression of the top of the curve, which is what makes highlights
    /// read as film rather than as clipped digital.
    var rolloff: Double = 0
    /// Colour multiplier, below 1 desaturates.
    var saturation: Double = 1
    /// Per-channel multipliers pushed into the shadows and the highlights.
    var shadowTint: SIMD3<Double> = SIMD3(repeating: 1)
    var highlightTint: SIMD3<Double> = SIMD3(repeating: 1)

    init(contrast: Double = 0, lift: Double = 0, rolloff: Double = 0,
         saturation: Double = 1,
         shadowTint: SIMD3<Double> = SIMD3(repeating: 1),
         highlightTint: SIMD3<Double> = SIMD3(repeating: 1)) {
        self.contrast = contrast
        self.lift = lift
        self.rolloff = rolloff
        self.saturation = saturation
        self.shadowTint = shadowTint
        self.highlightTint = highlightTint
    }

    /// The graded value of one channel, in 0...1 display space.
    func curve(_ x: Double) -> Double {
        var v = 0.5 + (x - 0.5) * (1 + contrast)
        let over = max(0, v - 0.72)
        v -= rolloff * over * over * 3
        // A matte lift raises black toward grey and leaves white alone, which
        // is what a faded print does; scaling the whole range would instead
        // darken the highlights every bit as much.
        v = lift + v * (1 - lift)
        return min(1, max(0, v))
    }

    func apply(to rgb: SIMD3<Double>) -> SIMD3<Double> {
        let curved = SIMD3(curve(rgb.x), curve(rgb.y), curve(rgb.z))
        let luma = curved.x * 0.2126 + curved.y * 0.7152 + curved.z * 0.0722
        let desaturated = SIMD3(repeating: luma)
        let coloured = desaturated + (curved - desaturated) * saturation
        // Split toning is weighted by how far the pixel sits from mid-grey, so
        // a tint never lands on both ends of the range at once.
        let w = min(1, max(0, luma))
        let tint = shadowTint * (1 - w) + highlightTint * w
        return SIMD3(
            min(1, max(0, coloured.x * tint.x)),
            min(1, max(0, coloured.y * tint.y)),
            min(1, max(0, coloured.z * tint.z)))
    }
}

/// The built-in looks. Names describe the character rather than a product.
enum FilmLook: String, CaseIterable, Identifiable, Codable {
    case none
    case warmGold
    case portraitFilm
    case nightStock
    case crossProcess
    case fadedMatte

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .warmGold: return "Warm Gold"
        case .portraitFilm: return "Portrait"
        case .nightStock: return "Night Stock"
        case .crossProcess: return "Cross Process"
        case .fadedMatte: return "Faded Matte"
        }
    }

    var grade: LookGrade {
        switch self {
        case .none:
            return LookGrade()
        case .warmGold:
            return LookGrade(contrast: 0.12, rolloff: 0.35, saturation: 0.94,
                             shadowTint: SIMD3(1.02, 0.99, 0.90),
                             highlightTint: SIMD3(1.06, 1.01, 0.90))
        case .portraitFilm:
            return LookGrade(contrast: 0.06, lift: 0.05, rolloff: 0.55, saturation: 0.88,
                             shadowTint: SIMD3(0.97, 0.99, 1.04),
                             highlightTint: SIMD3(1.05, 1.00, 0.95))
        case .nightStock:
            return LookGrade(contrast: 0.22, rolloff: 0.20, saturation: 0.82,
                             shadowTint: SIMD3(0.88, 0.96, 1.16),
                             highlightTint: SIMD3(1.08, 1.00, 0.88))
        case .crossProcess:
            return LookGrade(contrast: 0.26, lift: 0.03, saturation: 1.18,
                             shadowTint: SIMD3(0.90, 1.00, 0.96),
                             highlightTint: SIMD3(1.06, 1.02, 0.86))
        case .fadedMatte:
            return LookGrade(contrast: -0.10, lift: 0.16, rolloff: 0.45, saturation: 0.76,
                             shadowTint: SIMD3(0.96, 0.99, 1.06),
                             highlightTint: SIMD3(1.03, 1.00, 0.95))
        }
    }

    /// Default strength when a look is picked from the rail, as a percentage.
    var defaultStrength: Double {
        self == .none ? 0 : 100
    }

    static func named(_ raw: String) -> FilmLook {
        FilmLook(rawValue: raw) ?? .none
    }
}
