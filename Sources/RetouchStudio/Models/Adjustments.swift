import Foundation

/// Every retouch setting, in three clearly separated groups so the two Auto
/// actions stay independent and each effect can be individually reset:
///
///   * skin (retouch) — texture and tone of the face
///   * reshape        — geometry of facial features
///   * color/light    — global tonality
///
/// All values are -100...100 with 0 meaning "no change", so a fresh
/// `Adjustments()` is a genuine no-op.
struct Adjustments: Equatable {

    // MARK: - Skin (retouch)
    var smooth: Double = 0            // overall smoothing amount
    var blemish: Double = 0           // acne / spots
    var wrinkle: Double = 0           // fine lines
    var skinToneEvens: Double = 0     // skin tone correction / evening
    var darkCircles: Double = 0       // under-eye correction
    var skinBrighten: Double = 0      // brightness
    var texturePreserve: Double = 0   // 0 = plain blur, 100 = keep maximum texture
    var teethWhiten: Double = 0
    var eyeBrighten: Double = 0
    var eyeSharpen: Double = 0

    // MARK: - Reshape (geometry)
    var eyeSize: Double = 0
    var noseSize: Double = 0
    var noseTip: Double = 0
    var lipSize: Double = 0
    var cheekSize: Double = 0
    var jawWidth: Double = 0
    var chinLength: Double = 0
    var faceWidth: Double = 0
    var faceLength: Double = 0

    // MARK: - Color and light (global)
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var warmth: Double = 0
    var clarity: Double = 0
    var vignette: Double = 0

    static let zero = Adjustments()

    var isIdentity: Bool { self == .zero }

    // MARK: - Group views

    /// The retouch half, with geometry and color/light zeroed.
    var retouchOnly: Adjustments {
        var a = Adjustments()
        a.smooth = smooth
        a.blemish = blemish
        a.wrinkle = wrinkle
        a.skinToneEvens = skinToneEvens
        a.darkCircles = darkCircles
        a.skinBrighten = skinBrighten
        a.texturePreserve = texturePreserve
        a.teethWhiten = teethWhiten
        a.eyeBrighten = eyeBrighten
        a.eyeSharpen = eyeSharpen
        return a
    }

    /// The geometry half, with everything else zeroed.
    var reshapeOnly: Adjustments {
        var a = Adjustments()
        a.eyeSize = eyeSize
        a.noseSize = noseSize
        a.noseTip = noseTip
        a.lipSize = lipSize
        a.cheekSize = cheekSize
        a.jawWidth = jawWidth
        a.chinLength = chinLength
        a.faceWidth = faceWidth
        a.faceLength = faceLength
        return a
    }

    /// The color/light half, with everything else zeroed.
    var colorLightOnly: Adjustments {
        var a = Adjustments()
        a.exposure = exposure
        a.contrast = contrast
        a.saturation = saturation
        a.vibrance = vibrance
        a.warmth = warmth
        a.clarity = clarity
        a.vignette = vignette
        return a
    }

    /// Does any face-dependent tool have an effect?
    var usesFaceTools: Bool { retouchOnly != .zero || reshapeOnly != .zero }

    var hasReshape: Bool { reshapeOnly != .zero }

    // MARK: - Composing groups (keeps the Auto actions independent)

    /// Copy with ONLY the color/light fields taken from `patch`.
    func applyingColorLight(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.exposure = patch.exposure
        result.contrast = patch.contrast
        result.saturation = patch.saturation
        result.vibrance = patch.vibrance
        result.warmth = patch.warmth
        result.clarity = patch.clarity
        result.vignette = patch.vignette
        return result
    }

    /// Copy with ONLY the retouch fields taken from `patch`.
    func applyingRetouch(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.smooth = patch.smooth
        result.blemish = patch.blemish
        result.wrinkle = patch.wrinkle
        result.skinToneEvens = patch.skinToneEvens
        result.darkCircles = patch.darkCircles
        result.skinBrighten = patch.skinBrighten
        result.texturePreserve = patch.texturePreserve
        result.teethWhiten = patch.teethWhiten
        result.eyeBrighten = patch.eyeBrighten
        result.eyeSharpen = patch.eyeSharpen
        return result
    }

    /// Copy with ONLY the geometry fields taken from `patch`.
    func applyingReshape(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.eyeSize = patch.eyeSize
        result.noseSize = patch.noseSize
        result.noseTip = patch.noseTip
        result.lipSize = patch.lipSize
        result.cheekSize = patch.cheekSize
        result.jawWidth = patch.jawWidth
        result.chinLength = patch.chinLength
        result.faceWidth = patch.faceWidth
        result.faceLength = patch.faceLength
        return result
    }
}

/// The three independent tool groups. Used for per-group reset and to keep the
/// two Auto actions honest about what they touch.
enum AdjustmentGroup: String, CaseIterable, Identifiable {
    case skin, reshape, colorLight
    var id: String { rawValue }
}

struct Preset: Identifiable, Equatable {
    let id: String
    let title: String
    let adjustments: Adjustments

    static let all: [Preset] = [
        Preset(id: "natural", title: "Natural", adjustments: Adjustments(
            smooth: 22, blemish: 30, wrinkle: 18, skinToneEvens: 20,
            darkCircles: 16, texturePreserve: 78,
            teethWhiten: 12, eyeBrighten: 10, eyeSharpen: 14,
            exposure: 3, contrast: 5, vibrance: 8, warmth: 4, clarity: 6)),
        Preset(id: "glamour", title: "Glamour", adjustments: Adjustments(
            smooth: 42, blemish: 50, wrinkle: 34, skinToneEvens: 36,
            darkCircles: 30, texturePreserve: 62,
            teethWhiten: 34, eyeBrighten: 22, eyeSharpen: 28,
            eyeSize: 14, lipSize: 12, cheekSize: 8,
            exposure: 6, contrast: 10, vibrance: 14, warmth: 6, clarity: 10, vignette: 10)),
        Preset(id: "studio", title: "Studio", adjustments: Adjustments(
            smooth: 55, blemish: 62, wrinkle: 44, skinToneEvens: 46,
            darkCircles: 38, texturePreserve: 52,
            teethWhiten: 44, eyeBrighten: 30, eyeSharpen: 38,
            eyeSize: 18, lipSize: 10, cheekSize: 14, jawWidth: -16, chinLength: 8,
            faceWidth: -8,
            exposure: 4, contrast: 16, vibrance: 10, warmth: 8, clarity: 16, vignette: 16)),
        Preset(id: "editorial", title: "Editorial", adjustments: Adjustments(
            smooth: 12, blemish: 16, wrinkle: 24, skinToneEvens: 14,
            darkCircles: 20, texturePreserve: 92,
            teethWhiten: 6, eyeBrighten: 8, eyeSharpen: 26,
            cheekSize: -8, jawWidth: -20, chinLength: 10, faceWidth: -12,
            contrast: 20, saturation: -10, vibrance: -4, warmth: -6, clarity: 24, vignette: 16))
    ]
}
