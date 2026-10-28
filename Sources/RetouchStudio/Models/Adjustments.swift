import Foundation

/// Every retouch setting, in clearly separated groups so the two Auto actions
/// stay independent and each effect can be individually reset:
///
///   * skin (retouch) — texture and tone of the face
///   * reshape        — geometry of facial features
///   * makeup         — colour cosmetics on lips, cheeks and brows
///   * color/light    — global tonality
///   * look           — film grade and grain
///
/// All amounts are -100...100 or 0...100 with 0 meaning "no change", so a fresh
/// `Adjustments()` is a genuine no-op.
struct Adjustments: Equatable, Codable {

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
    /// Input level mapped to black. Positive digs the shadows out — the cure
    /// for a faded frame — and negative lets them glow.
    var blacks: Double = 0
    /// Input level mapped to white. Positive lifts the highlights.
    var whites: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var warmth: Double = 0
    var clarity: Double = 0
    var vignette: Double = 0

    // MARK: - Look (film grade and grain)
    //
    // `lookID` is the raw value of a `FilmLook`; an empty string means no look
    // is applied, so a fresh `Adjustments()` is still a genuine no-op.
    var lookID: String = ""
    var lookStrength: Double = 0    // 0...100, how far the grade is blended in
    var grain: Double = 0           // 0...100

    /// The look as an enum; an unknown identifier reads as no look.
    var look: FilmLook {
        get { FilmLook.named(lookID) }
        set { lookID = newValue.rawValue }
    }

    // MARK: Levels

    /// The input values the Blacks/Whites sliders map to black and white, in
    /// display-referred light. ±100 moves an endpoint by 0.30 — far enough to
    /// pull a genuinely faded frame back to the ends of the range, and safe to
    /// ask for because `LookEngine.applyLevels` spends that move on the shadows
    /// and highlights only, never on the mid-tones in between.
    ///
    /// A black level above zero digs the shadows out; below zero it lets them
    /// glow, which is how a matte fade is made. A white level below one lifts the
    /// highlights, above one compresses them.
    var blackLevel: Double { 0.30 * blacks / 100 }
    var whiteLevel: Double { 1 - 0.30 * whites / 100 }

    // MARK: - Makeup (colour cosmetics)
    //
    // The shade identifiers default per region: an empty or unknown value reads
    // as the shade that region starts with, so a project saved before makeup
    // existed still shows a sensible swatch.
    var lipTint: Double = 0
    var lipShadeID: String = ""
    var blush: Double = 0
    var blushShadeID: String = ""
    var browDefine: Double = 0

    var lipShade: MakeupShade {
        get { MakeupShade(rawValue: lipShadeID) ?? .rose }
        set { lipShadeID = newValue.rawValue }
    }

    var blushShade: MakeupShade {
        get { MakeupShade(rawValue: blushShadeID) ?? .peach }
        set { blushShadeID = newValue.rawValue }
    }

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
        a.blacks = blacks
        a.whites = whites
        a.saturation = saturation
        a.vibrance = vibrance
        a.warmth = warmth
        a.clarity = clarity
        a.vignette = vignette
        return a
    }

    /// Does any face-dependent tool have an effect?
    var usesFaceTools: Bool { retouchOnly != .zero || reshapeOnly != .zero || makeupOnly != .zero }

    var hasReshape: Bool { reshapeOnly != .zero }

    /// The look half: grade and grain, with everything else zeroed.
    var lookOnly: Adjustments {
        var a = Adjustments()
        a.lookID = lookID
        a.lookStrength = lookStrength
        a.grain = grain
        return a
    }

    var hasLook: Bool { lookOnly != .zero }

    /// The makeup half: lips, cheeks, brows.
    var makeupOnly: Adjustments {
        var a = Adjustments()
        a.lipTint = lipTint
        a.lipShadeID = lipShadeID
        a.blush = blush
        a.blushShadeID = blushShadeID
        a.browDefine = browDefine
        return a
    }

    var hasMakeup: Bool { makeupOnly != .zero }

    // MARK: - Composing groups (keeps the Auto actions independent)

    /// Copy with ONLY the makeup fields taken from `patch`.
    func applyingMakeup(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.lipTint = patch.lipTint
        result.lipShadeID = patch.lipShadeID
        result.blush = patch.blush
        result.blushShadeID = patch.blushShadeID
        result.browDefine = patch.browDefine
        return result
    }

    /// Copy with ONLY the look fields taken from `patch`.
    func applyingLook(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.lookID = patch.lookID
        result.lookStrength = patch.lookStrength
        result.grain = patch.grain
        return result
    }

    /// Copy with ONLY the color/light fields taken from `patch`.
    func applyingColorLight(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.exposure = patch.exposure
        result.contrast = patch.contrast
        result.blacks = patch.blacks
        result.whites = patch.whites
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

    /// Scales the strength of an auto-generated retouch patch. Only the actual
    /// effects are scaled; `texturePreserve` is a preference about how the
    /// smoothing looks, so it is carried over unchanged.
    func scaledRetouch(by percent: Double) -> Adjustments {
        let factor = min(1, max(0, percent / 100))
        var result = self
        result.smooth = smooth * factor
        result.blemish = blemish * factor
        result.wrinkle = wrinkle * factor
        result.skinToneEvens = skinToneEvens * factor
        result.darkCircles = darkCircles * factor
        result.skinBrighten = skinBrighten * factor
        result.teethWhiten = teethWhiten * factor
        result.eyeBrighten = eyeBrighten * factor
        result.eyeSharpen = eyeSharpen * factor
        return result
    }

    /// Scales an auto-generated color/light patch. Every field in this group is
    /// an effect, so all of them move together with the strength.
    func scaledColorLight(by percent: Double) -> Adjustments {
        let factor = min(1, max(0, percent / 100))
        var result = self
        result.exposure = exposure * factor
        result.contrast = contrast * factor
        result.blacks = blacks * factor
        result.whites = whites * factor
        result.saturation = saturation * factor
        result.vibrance = vibrance * factor
        result.warmth = warmth * factor
        result.clarity = clarity * factor
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
    case skin, reshape, makeup, colorLight, look
    var id: String { rawValue }
}

// MARK: - Coding
//
// A project saved by an older build simply lacks the keys added since. Every
// field defaults to "no change", so a missing key reads as that default instead
// of failing the whole file. Living in an extension keeps the memberwise
// initialiser that the presets below are written with.
extension Adjustments {

    enum CodingKeys: String, CodingKey {
        case smooth, blemish, wrinkle, skinToneEvens, darkCircles, skinBrighten
        case texturePreserve, teethWhiten, eyeBrighten, eyeSharpen
        case eyeSize, noseSize, noseTip, lipSize, cheekSize, jawWidth, chinLength
        case faceWidth, faceLength
        case exposure, contrast, saturation, vibrance, warmth, clarity, vignette
        case blacks, whites
        case lookID, lookStrength, grain
        case lipTint, lipShadeID, blush, blushShadeID, browDefine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func amount(_ key: CodingKeys) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0
        }
        func text(_ key: CodingKeys) -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? ""
        }
        smooth = amount(.smooth)
        blemish = amount(.blemish)
        wrinkle = amount(.wrinkle)
        skinToneEvens = amount(.skinToneEvens)
        darkCircles = amount(.darkCircles)
        skinBrighten = amount(.skinBrighten)
        texturePreserve = amount(.texturePreserve)
        teethWhiten = amount(.teethWhiten)
        eyeBrighten = amount(.eyeBrighten)
        eyeSharpen = amount(.eyeSharpen)
        eyeSize = amount(.eyeSize)
        noseSize = amount(.noseSize)
        noseTip = amount(.noseTip)
        lipSize = amount(.lipSize)
        cheekSize = amount(.cheekSize)
        jawWidth = amount(.jawWidth)
        chinLength = amount(.chinLength)
        faceWidth = amount(.faceWidth)
        faceLength = amount(.faceLength)
        exposure = amount(.exposure)
        contrast = amount(.contrast)
        blacks = amount(.blacks)
        whites = amount(.whites)
        saturation = amount(.saturation)
        vibrance = amount(.vibrance)
        warmth = amount(.warmth)
        clarity = amount(.clarity)
        vignette = amount(.vignette)
        lookID = text(.lookID)
        lookStrength = amount(.lookStrength)
        grain = amount(.grain)
        lipTint = amount(.lipTint)
        lipShadeID = text(.lipShadeID)
        blush = amount(.blush)
        blushShadeID = text(.blushShadeID)
        browDefine = amount(.browDefine)
    }
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
