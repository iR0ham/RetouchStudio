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

/// What a preset is for. The order of the cases is the order the sections
/// appear in the inspector.
enum PresetGroup: String, CaseIterable, Identifiable {
    case everyday, skin, beauty, color, film, makeup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyday: return "Everyday"
        case .skin: return "Skin"
        case .beauty: return "Beauty"
        case .color: return "Color"
        case .film: return "Film"
        case .makeup: return "Makeup"
        }
    }
}

struct Preset: Identifiable, Equatable {
    let id: String
    let title: String
    let group: PresetGroup
    let adjustments: Adjustments

    static func inGroup(_ group: PresetGroup) -> [Preset] { all.filter { $0.group == group } }
    static func with(id: String) -> Preset? { all.first { $0.id == id } }

    /// The library. Every entry is a starting point a photographer would
    /// actually reach for, and each one leaves at least one group alone so
    /// there is something left to adjust afterwards.
    ///
    /// Arguments follow the declaration order of `Adjustments`, which the
    /// memberwise initialiser keeps.
    static let all: [Preset] = [
        // MARK: Everyday — small, defensible corrections

        Preset(id: "natural", title: "Natural", group: .everyday, adjustments: Adjustments(
            smooth: 22, blemish: 30, wrinkle: 18, skinToneEvens: 20,
            darkCircles: 16, texturePreserve: 78,
            teethWhiten: 12, eyeBrighten: 10, eyeSharpen: 14,
            exposure: 3, contrast: 5, vibrance: 8, warmth: 4, clarity: 6)),
        Preset(id: "clean", title: "Clean", group: .everyday, adjustments: Adjustments(
            smooth: 16, blemish: 46, wrinkle: 12, skinToneEvens: 18,
            darkCircles: 24, texturePreserve: 86,
            teethWhiten: 16, eyeBrighten: 8,
            contrast: 6, blacks: 10, vibrance: 6, clarity: 8)),
        Preset(id: "fresh", title: "Fresh", group: .everyday, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 22, darkCircles: 34,
            skinBrighten: 14, texturePreserve: 82,
            teethWhiten: 20, eyeBrighten: 18, eyeSharpen: 16,
            exposure: 6, whites: 10, vibrance: 12, warmth: 5, clarity: 4)),
        Preset(id: "minimal", title: "Barely There", group: .everyday, adjustments: Adjustments(
            blemish: 38, wrinkle: 6, darkCircles: 22, texturePreserve: 100,
            eyeSharpen: 8, contrast: 2, vibrance: 2)),
        Preset(id: "softlight", title: "Soft Light", group: .everyday, adjustments: Adjustments(
            smooth: 26, blemish: 18, skinToneEvens: 14, texturePreserve: 72,
            eyeBrighten: 8, exposure: 7, contrast: -6, whites: 14,
            saturation: -4, vibrance: 6, warmth: 6)),

        // MARK: Skin — what the smoothing itself should feel like

        Preset(id: "airbrush", title: "Airbrush", group: .skin, adjustments: Adjustments(
            smooth: 62, blemish: 70, wrinkle: 52, skinToneEvens: 56,
            darkCircles: 44, skinBrighten: 18, texturePreserve: 38,
            teethWhiten: 30, eyeBrighten: 18,
            exposure: 3, contrast: 8, vibrance: 8, clarity: 6)),
        Preset(id: "texture", title: "Kept Texture", group: .skin, adjustments: Adjustments(
            smooth: 6, blemish: 26, wrinkle: 10, skinToneEvens: 10,
            texturePreserve: 100, eyeSharpen: 20,
            contrast: 10, blacks: 14, clarity: 22)),
        Preset(id: "matte", title: "Matte", group: .skin, adjustments: Adjustments(
            smooth: 44, blemish: 40, skinToneEvens: 34,
            texturePreserve: 58, contrast: 12, blacks: 24, whites: -10,
            saturation: -6, vibrance: -4, clarity: 18)),
        Preset(id: "glow", title: "Dewy Glow", group: .skin, adjustments: Adjustments(
            smooth: 34, blemish: 30, skinToneEvens: 28, darkCircles: 26,
            skinBrighten: 34, texturePreserve: 66,
            teethWhiten: 22, eyeBrighten: 20, eyeSharpen: 12,
            exposure: 5, whites: 18, vibrance: 10, warmth: 6)),
        Preset(id: "eventone", title: "Even Tone", group: .skin, adjustments: Adjustments(
            smooth: 28, blemish: 44, skinToneEvens: 62, darkCircles: 46,
            skinBrighten: 12, texturePreserve: 70,
            contrast: 4, vibrance: 6, warmth: 3, clarity: 4)),
        Preset(id: "bronze", title: "Bronze", group: .skin, adjustments: Adjustments(
            smooth: 30, blemish: 26, skinToneEvens: 22, texturePreserve: 64,
            teethWhiten: 14, exposure: 2, contrast: 8, saturation: 6,
            vibrance: 10, warmth: 24, clarity: 10, vignette: 8)),
        Preset(id: "porcelain", title: "Porcelain", group: .skin, adjustments: Adjustments(
            smooth: 54, blemish: 52, wrinkle: 40, skinToneEvens: 48,
            darkCircles: 38, skinBrighten: 30, texturePreserve: 48,
            teethWhiten: 26, eyeBrighten: 16,
            exposure: 8, contrast: 4, whites: 16, saturation: -6,
            vibrance: 4, warmth: -4)),

        // MARK: Beauty — full portraits, several groups at once

        Preset(id: "glamour", title: "Glamour", group: .beauty, adjustments: Adjustments(
            smooth: 42, blemish: 50, wrinkle: 34, skinToneEvens: 36,
            darkCircles: 30, texturePreserve: 62,
            teethWhiten: 34, eyeBrighten: 22, eyeSharpen: 28,
            eyeSize: 14, lipSize: 12, cheekSize: 8,
            exposure: 6, contrast: 10, vibrance: 14, warmth: 6, clarity: 10, vignette: 10)),
        Preset(id: "studio", title: "Studio", group: .beauty, adjustments: Adjustments(
            smooth: 55, blemish: 62, wrinkle: 44, skinToneEvens: 46,
            darkCircles: 38, texturePreserve: 52,
            teethWhiten: 44, eyeBrighten: 30, eyeSharpen: 38,
            eyeSize: 18, lipSize: 10, cheekSize: 14, jawWidth: -16, chinLength: 8,
            faceWidth: -8,
            exposure: 4, contrast: 16, vibrance: 10, warmth: 8, clarity: 16, vignette: 16)),
        Preset(id: "editorial", title: "Editorial", group: .beauty, adjustments: Adjustments(
            smooth: 12, blemish: 16, wrinkle: 24, skinToneEvens: 14,
            darkCircles: 20, texturePreserve: 92,
            teethWhiten: 6, eyeBrighten: 8, eyeSharpen: 26,
            cheekSize: -8, jawWidth: -20, chinLength: 10, faceWidth: -12,
            contrast: 20, blacks: 18, saturation: -10, vibrance: -4,
            warmth: -6, clarity: 24, vignette: 16)),
        Preset(id: "beauty", title: "Beauty", group: .beauty, adjustments: Adjustments(
            smooth: 38, blemish: 44, wrinkle: 26, skinToneEvens: 32,
            darkCircles: 30, skinBrighten: 16, texturePreserve: 66,
            teethWhiten: 28, eyeBrighten: 24, eyeSharpen: 24,
            eyeSize: 10, lipSize: 8,
            exposure: 4, contrast: 8, whites: 10, vibrance: 10, warmth: 4,
            clarity: 8, lipTint: 16, lipShadeID: MakeupShade.rose.rawValue)),
        Preset(id: "bridal", title: "Bridal", group: .beauty, adjustments: Adjustments(
            smooth: 46, blemish: 48, wrinkle: 32, skinToneEvens: 40,
            darkCircles: 34, skinBrighten: 24, texturePreserve: 58,
            teethWhiten: 38, eyeBrighten: 20, eyeSharpen: 18,
            eyeSize: 8, cheekSize: 6,
            exposure: 7, contrast: 4, whites: 20, saturation: -4,
            vibrance: 8, warmth: 3, clarity: 6, vignette: 6,
            lipTint: 14, lipShadeID: MakeupShade.peach.rawValue,
            blush: 16, blushShadeID: MakeupShade.peach.rawValue)),
        Preset(id: "sculpt", title: "Sculpt", group: .beauty, adjustments: Adjustments(
            smooth: 26, blemish: 30, skinToneEvens: 18, texturePreserve: 76,
            eyeSize: 8, cheekSize: -10, jawWidth: -18, chinLength: 6,
            faceWidth: -12, faceLength: 6,
            contrast: 14, blacks: 16, clarity: 20, vignette: 12)),
        Preset(id: "male", title: "Masculine", group: .beauty, adjustments: Adjustments(
            smooth: 14, blemish: 38, wrinkle: 10, skinToneEvens: 12,
            texturePreserve: 94, eyeBrighten: 8, eyeSharpen: 14,
            jawWidth: -8, chinLength: 6, faceWidth: -6,
            contrast: 14, blacks: 18, saturation: -6, warmth: -4, clarity: 18)),

        // MARK: Colour — the whole frame, no skin work

        Preset(id: "warmsun", title: "Warm Sun", group: .color, adjustments: Adjustments(
            exposure: 4, contrast: 6, whites: 10, vibrance: 12,
            warmth: 24, clarity: 4)),
        Preset(id: "cool", title: "Cool Tone", group: .color, adjustments: Adjustments(
            exposure: 2, contrast: 8, blacks: 10, saturation: -4,
            warmth: -22, clarity: 6)),
        Preset(id: "vibrant", title: "Vibrant", group: .color, adjustments: Adjustments(
            exposure: 2, contrast: 12, blacks: 12, whites: 12,
            saturation: 8, vibrance: 24, clarity: 8)),
        Preset(id: "muted", title: "Muted", group: .color, adjustments: Adjustments(
            contrast: 4, blacks: 12, saturation: -18, vibrance: -8,
            warmth: -3, clarity: 6)),
        Preset(id: "pastel", title: "Pastel", group: .color, adjustments: Adjustments(
            exposure: 9, contrast: -8, whites: 16, saturation: -12,
            vibrance: 4, warmth: 4)),
        Preset(id: "punchy", title: "Punchy", group: .color, adjustments: Adjustments(
            contrast: 26, blacks: 24, whites: 20, saturation: 4,
            vibrance: 12, clarity: 16)),
        Preset(id: "fade", title: "Matte Fade", group: .color, adjustments: Adjustments(
            exposure: 5, contrast: -12, blacks: -34, whites: -14,
            saturation: -8, vibrance: -4, warmth: 6)),
        Preset(id: "noir", title: "Noir", group: .color, adjustments: Adjustments(
            exposure: -4, contrast: 30, blacks: 26, saturation: -100,
            clarity: 22, vignette: 26)),
        Preset(id: "monosoft", title: "Soft Mono", group: .color, adjustments: Adjustments(
            exposure: 5, contrast: 8, blacks: -16, whites: 10,
            saturation: -100, clarity: 6, grain: 26)),

        // MARK: Film — grade and grain, lightly supported by skin work

        Preset(id: "golden", title: "Golden Hour", group: .film, adjustments: Adjustments(
            smooth: 18, blemish: 20, skinBrighten: 10, texturePreserve: 80,
            exposure: 4, contrast: 6, whites: 12, vibrance: 10, warmth: 16,
            lookID: FilmLook.warmGold.rawValue, lookStrength: 55, grain: 10)),
        Preset(id: "portra", title: "Portrait Film", group: .film, adjustments: Adjustments(
            smooth: 22, blemish: 24, skinToneEvens: 16, texturePreserve: 84,
            exposure: 3, contrast: 4, whites: 8, saturation: -4, warmth: 6,
            lookID: FilmLook.portraitFilm.rawValue, lookStrength: 62, grain: 18)),
        Preset(id: "cinema", title: "Cinematic", group: .film, adjustments: Adjustments(
            smooth: 16, blemish: 18, texturePreserve: 86, eyeSharpen: 12,
            contrast: 14, blacks: 16, warmth: -8, clarity: 8, vignette: 18,
            lookID: FilmLook.nightStock.rawValue, lookStrength: 45, grain: 14)),
        Preset(id: "faded", title: "Faded Print", group: .film, adjustments: Adjustments(
            smooth: 14, texturePreserve: 88, exposure: 4, contrast: -6,
            blacks: -28, saturation: -6, warmth: 4,
            lookID: FilmLook.fadedMatte.rawValue, lookStrength: 65, grain: 22)),
        Preset(id: "cross", title: "Cross Process", group: .film, adjustments: Adjustments(
            smooth: 10, texturePreserve: 90, contrast: 18, blacks: 14,
            saturation: 6, clarity: 10,
            lookID: FilmLook.crossProcess.rawValue, lookStrength: 45, grain: 12)),
        Preset(id: "kodachrome", title: "Vintage Slide", group: .film, adjustments: Adjustments(
            smooth: 12, texturePreserve: 86, exposure: 2, contrast: 16,
            blacks: 18, saturation: 10, vibrance: 8, warmth: 10, clarity: 10,
            lookID: FilmLook.warmGold.rawValue, lookStrength: 38, grain: 20)),

        // MARK: Makeup — cosmetics, with the skin work kept minimal

        Preset(id: "rose", title: "Rose", group: .makeup, adjustments: Adjustments(
            smooth: 20, blemish: 22, skinToneEvens: 16, skinBrighten: 12,
            texturePreserve: 78, eyeBrighten: 10, eyeSharpen: 12,
            contrast: 4, vibrance: 6, warmth: 8,
            lipTint: 48, lipShadeID: MakeupShade.rose.rawValue,
            blush: 30, blushShadeID: MakeupShade.rose.rawValue)),
        Preset(id: "coral", title: "Coral", group: .makeup, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 18, skinBrighten: 14,
            texturePreserve: 74, teethWhiten: 22, eyeBrighten: 12,
            exposure: 3, vibrance: 12, warmth: 10,
            lipTint: 54, lipShadeID: MakeupShade.coral.rawValue,
            blush: 34, blushShadeID: MakeupShade.coral.rawValue)),
        Preset(id: "berry", title: "Berry", group: .makeup, adjustments: Adjustments(
            smooth: 24, blemish: 28, skinToneEvens: 20, texturePreserve: 74,
            teethWhiten: 26, eyeBrighten: 12, eyeSharpen: 10,
            contrast: 8, blacks: 10, saturation: 4,
            lipTint: 38, lipShadeID: MakeupShade.berry.rawValue,
            blush: 14, blushShadeID: MakeupShade.berry.rawValue)),
        Preset(id: "redcarpet", title: "Red Carpet", group: .makeup, adjustments: Adjustments(
            smooth: 40, blemish: 46, wrinkle: 28, skinToneEvens: 38,
            darkCircles: 28, texturePreserve: 60,
            teethWhiten: 42, eyeBrighten: 22, eyeSharpen: 24, eyeSize: 10,
            contrast: 12, blacks: 14, saturation: 6, vibrance: 8, warmth: 4,
            clarity: 8, vignette: 12,
            lipTint: 48, lipShadeID: MakeupShade.berry.rawValue,
            blush: 12, blushShadeID: MakeupShade.rose.rawValue, browDefine: 18)),
        Preset(id: "nude", title: "No-Makeup", group: .makeup, adjustments: Adjustments(
            smooth: 12, blemish: 34, wrinkle: 8, skinToneEvens: 12,
            darkCircles: 26, texturePreserve: 94,
            teethWhiten: 16, eyeBrighten: 14, eyeSharpen: 18,
            exposure: 4, vibrance: 8, warmth: 4,
            lipTint: 26, lipShadeID: MakeupShade.peach.rawValue,
            blush: 18, blushShadeID: MakeupShade.peach.rawValue, browDefine: 28)),
        Preset(id: "brows", title: "Defined", group: .makeup, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 14, texturePreserve: 84,
            eyeBrighten: 14, eyeSharpen: 22, contrast: 8, clarity: 10,
            lipTint: 8, lipShadeID: MakeupShade.peach.rawValue, browDefine: 42)),
    ]
}
