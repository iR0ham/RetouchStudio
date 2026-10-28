import Foundation
import SwiftUI

/// A cosmetic colour, stored as hue, saturation and value.
///
/// Makeup used to be four hard-coded sRGB triples, so matching a lipstick to a
/// reference photo was impossible and every family looked the same on every
/// skin tone. HSV is the shape the controls need: hue and saturation are the
/// two sliders a colourist reaches for, and value is the density the region is
/// built on — while a colour picker writes all three at once.
///
/// Values are display-referred sRGB. Core Image composites in linear light, so
/// `MakeupEngine` decodes them before blending — the same convention the pixel
/// gates follow, where every threshold was measured on 8-bit pixels.
struct MakeupColor: Hashable, Codable {
    var hue: Double          // 0...360
    var saturation: Double   // 0...1
    var value: Double        // 0...1

    init(hue: Double, saturation: Double, value: Double) {
        self.hue = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        self.saturation = min(1, max(0, saturation))
        self.value = min(1, max(0, value))
    }

    /// The colour a picker handed back.
    init(rgb r: Double, _ g: Double, _ b: Double) {
        let maxChannel = max(r, max(g, b))
        let minChannel = min(r, min(g, b))
        let delta = maxChannel - minChannel
        var h = 0.0
        if delta > 0.0001 {
            if maxChannel == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxChannel == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        self.init(hue: h,
                  saturation: maxChannel > 0.0001 ? delta / maxChannel : 0,
                  value: maxChannel)
    }

    /// Display-referred sRGB components.
    var rgb: (r: Double, g: Double, b: Double) {
        let h = hue / 60
        let c = value * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    var color: Color {
        let c = rgb
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    func with(hue: Double) -> MakeupColor {
        MakeupColor(hue: hue, saturation: saturation, value: value)
    }

    func with(saturation: Double) -> MakeupColor {
        MakeupColor(hue: hue, saturation: saturation, value: value)
    }
}

/// Skin-tone family a shade is mixed for. A berry that reads as a stain on fair
/// skin turns grey on deep skin, so the palette is split the way a makeup counter
/// is: the same idea, mixed for the tone it will sit on.
enum MakeupFamily: String, CaseIterable, Identifiable, Codable {
    case fair, light, medium, tan, deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fair: return "Fair"
        case .light: return "Light"
        case .medium: return "Medium"
        case .tan: return "Tan"
        case .deep: return "Deep"
        }
    }

    /// Which family a measured skin luminance belongs to. Thresholds sit on
    /// 8-bit sRGB luminance, the same space the cosmetic palettes are written
    /// in, and are wide enough that a lit or shaded face lands in the family a
    /// person would name.
    static func of(skinLuminance luma: Double) -> MakeupFamily {
        switch luma {
        case ..<0.30: return .deep
        case ..<0.42: return .tan
        case ..<0.55: return .medium
        case ..<0.67: return .light
        default: return .fair
        }
    }
}

/// One cosmetic region. Each carries its own colour and its own amount, so the
/// tools no longer share a single palette entry.
enum MakeupRegion: String, CaseIterable, Identifiable, Codable {
    case lips, cheeks, shadow, liner, brows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lips: return "Lips"
        case .cheeks: return "Cheeks"
        case .shadow: return "Shadow"
        case .liner: return "Liner"
        case .brows: return "Brows"
        }
    }

    /// Lip and cheek shades are mixed per skin tone; shadow, liner and brow
    /// colours are pigment laid on hair or skin around the eye and work the
    /// same on every tone.
    var hasFamilies: Bool { self == .lips || self == .cheeks }

    /// How much of the colour a tap on a swatch applies, in slider units.
    var defaultAmount: Double {
        switch self {
        case .lips: return 55
        case .cheeks: return 40
        case .shadow: return 35
        case .liner: return 45
        case .brows: return 45
        }
    }

    var colorPath: WritableKeyPath<Adjustments, MakeupColor> {
        switch self {
        case .lips: return \.lipColor
        case .cheeks: return \.blushColor
        case .shadow: return \.shadowColor
        case .liner: return \.linerColor
        case .brows: return \.browColor
        }
    }

    var amountPath: WritableKeyPath<Adjustments, Double> {
        switch self {
        case .lips: return \.lipTint
        case .cheeks: return \.blush
        case .shadow: return \.eyeshadow
        case .liner: return \.eyeliner
        case .brows: return \.browDefine
        }
    }
}

/// A named colour in the catalogue. The swatches exist to give the picker a
/// starting point, not to be the only choices — any colour can be dialled in
/// with the picker or the hue and saturation sliders.
struct MakeupShade: Identifiable, Hashable {
    let id: String
    let title: String
    let region: MakeupRegion
    /// `nil` for pigments that do not change with skin tone.
    let family: MakeupFamily?
    let color: MakeupColor

    /// Saved projects and presets store the identifier, so `rawValue` keeps the
    /// old call sites and old files working.
    var rawValue: String { id }

    init?(rawValue: String) {
        guard let match = Self.all.first(where: { $0.id == rawValue }) else { return nil }
        self = match
    }

    private init(id: String, title: String, region: MakeupRegion,
                 family: MakeupFamily? = nil, color: MakeupColor) {
        self.id = id
        self.title = title
        self.region = region
        self.family = family
        self.color = color
    }

    /// Shades for one region, optionally narrowed to a skin-tone family.
    static func shades(_ region: MakeupRegion, family: MakeupFamily? = nil) -> [MakeupShade] {
        all.filter { $0.region == region && (family == nil || $0.family == family) }
    }

    // MARK: - Lips

    static let petal = MakeupShade(id: "lip-fair-petal", title: "Petal", region: .lips, family: .fair,
                                   color: MakeupColor(hue: 345, saturation: 0.38, value: 0.86))
    /// The default lip colour, and the one every older project and preset
    /// refers to by identifier.
    static let rose = MakeupShade(id: "rose", title: "Rose", region: .lips, family: .light,
                                  color: MakeupColor(hue: 350, saturation: 0.60, value: 0.77))
    static let peach = MakeupShade(id: "peach", title: "Peach", region: .lips, family: .fair,
                                   color: MakeupColor(hue: 28, saturation: 0.38, value: 0.92))
    static let softRose = MakeupShade(id: "lip-fair-softrose", title: "Soft Rose", region: .lips, family: .fair,
                                      color: MakeupColor(hue: 350, saturation: 0.42, value: 0.85))

    static let nude = MakeupShade(id: "lip-light-nude", title: "Nude", region: .lips, family: .light,
                                  color: MakeupColor(hue: 18, saturation: 0.30, value: 0.78))
    static let coral = MakeupShade(id: "coral", title: "Coral", region: .lips, family: .light,
                                   color: MakeupColor(hue: 8, saturation: 0.58, value: 0.86))
    static let mauve = MakeupShade(id: "lip-light-mauve", title: "Mauve", region: .lips, family: .light,
                                   color: MakeupColor(hue: 335, saturation: 0.38, value: 0.72))
    static let plum = MakeupShade(id: "lip-light-plum", title: "Plum", region: .lips, family: .light,
                                  color: MakeupColor(hue: 330, saturation: 0.45, value: 0.58))

    static let berry = MakeupShade(id: "berry", title: "Berry", region: .lips, family: .medium,
                                   color: MakeupColor(hue: 340, saturation: 0.52, value: 0.62))
    static let terracotta = MakeupShade(id: "lip-medium-terracotta", title: "Terracotta", region: .lips, family: .medium,
                                        color: MakeupColor(hue: 14, saturation: 0.60, value: 0.70))
    static let brick = MakeupShade(id: "lip-medium-brick", title: "Brick", region: .lips, family: .medium,
                                   color: MakeupColor(hue: 4, saturation: 0.62, value: 0.65))
    static let wine = MakeupShade(id: "lip-medium-wine", title: "Wine", region: .lips, family: .medium,
                                  color: MakeupColor(hue: 335, saturation: 0.58, value: 0.48))

    static let copper = MakeupShade(id: "lip-tan-copper", title: "Copper", region: .lips, family: .tan,
                                    color: MakeupColor(hue: 18, saturation: 0.65, value: 0.63))
    static let rosewood = MakeupShade(id: "lip-tan-rosewood", title: "Rosewood", region: .lips, family: .tan,
                                      color: MakeupColor(hue: 350, saturation: 0.55, value: 0.55))
    static let ruby = MakeupShade(id: "lip-tan-ruby", title: "Ruby", region: .lips, family: .tan,
                                  color: MakeupColor(hue: 355, saturation: 0.68, value: 0.60))
    static let merlot = MakeupShade(id: "lip-tan-merlot", title: "Merlot", region: .lips, family: .tan,
                                    color: MakeupColor(hue: 330, saturation: 0.60, value: 0.42))

    static let chestnut = MakeupShade(id: "lip-deep-chestnut", title: "Chestnut", region: .lips, family: .deep,
                                      color: MakeupColor(hue: 14, saturation: 0.66, value: 0.52))
    static let mulberry = MakeupShade(id: "lip-deep-mulberry", title: "Mulberry", region: .lips, family: .deep,
                                      color: MakeupColor(hue: 335, saturation: 0.55, value: 0.42))
    static let rubyred = MakeupShade(id: "lip-deep-ruby", title: "Ruby Red", region: .lips, family: .deep,
                                     color: MakeupColor(hue: 348, saturation: 0.76, value: 0.56))
    static let aubergine = MakeupShade(id: "lip-deep-aubergine", title: "Aubergine", region: .lips, family: .deep,
                                       color: MakeupColor(hue: 315, saturation: 0.55, value: 0.34))

    // MARK: - Cheeks

    /// The default blush. Sheer peach works on nearly every tone at the low
    /// strength blush is blended at.
    static let cheekPeach = MakeupShade(id: "cheek-fair-peach", title: "Peach", region: .cheeks, family: .fair,
                                        color: MakeupColor(hue: 25, saturation: 0.35, value: 0.95))
    static let cheekPetal = MakeupShade(id: "cheek-fair-petal", title: "Petal", region: .cheeks, family: .fair,
                                        color: MakeupColor(hue: 345, saturation: 0.30, value: 0.93))
    static let cheekRoseFair = MakeupShade(id: "cheek-fair-rose", title: "Rose", region: .cheeks, family: .fair,
                                           color: MakeupColor(hue: 350, saturation: 0.40, value: 0.88))

    static let cheekPeachLight = MakeupShade(id: "cheek-light-peach", title: "Peach", region: .cheeks, family: .light,
                                             color: MakeupColor(hue: 24, saturation: 0.45, value: 0.90))
    static let cheekRoseLight = MakeupShade(id: "cheek-light-rose", title: "Rose", region: .cheeks, family: .light,
                                            color: MakeupColor(hue: 350, saturation: 0.45, value: 0.82))
    static let cheekCoral = MakeupShade(id: "cheek-light-coral", title: "Coral", region: .cheeks, family: .light,
                                        color: MakeupColor(hue: 8, saturation: 0.48, value: 0.88))

    static let cheekApricotMedium = MakeupShade(id: "cheek-medium-apricot", title: "Apricot", region: .cheeks, family: .medium,
                                                color: MakeupColor(hue: 25, saturation: 0.50, value: 0.85))
    static let cheekRoseMedium = MakeupShade(id: "cheek-medium-rose", title: "Rose", region: .cheeks, family: .medium,
                                             color: MakeupColor(hue: 348, saturation: 0.42, value: 0.74))
    static let cheekTerracotta = MakeupShade(id: "cheek-medium-terracotta", title: "Terracotta", region: .cheeks, family: .medium,
                                             color: MakeupColor(hue: 14, saturation: 0.52, value: 0.76))

    static let cheekApricotTan = MakeupShade(id: "cheek-tan-apricot", title: "Apricot", region: .cheeks, family: .tan,
                                             color: MakeupColor(hue: 22, saturation: 0.58, value: 0.80))
    static let cheekRosewood = MakeupShade(id: "cheek-tan-rosewood", title: "Rosewood", region: .cheeks, family: .tan,
                                           color: MakeupColor(hue: 350, saturation: 0.48, value: 0.62))
    static let cheekBrick = MakeupShade(id: "cheek-tan-brick", title: "Brick", region: .cheeks, family: .tan,
                                        color: MakeupColor(hue: 6, saturation: 0.55, value: 0.68))

    static let cheekCopper = MakeupShade(id: "cheek-deep-copper", title: "Copper", region: .cheeks, family: .deep,
                                         color: MakeupColor(hue: 18, saturation: 0.62, value: 0.66))
    static let cheekBerry = MakeupShade(id: "cheek-deep-berry", title: "Berry", region: .cheeks, family: .deep,
                                        color: MakeupColor(hue: 340, saturation: 0.52, value: 0.52))
    static let cheekRuby = MakeupShade(id: "cheek-deep-ruby", title: "Ruby", region: .cheeks, family: .deep,
                                       color: MakeupColor(hue: 348, saturation: 0.62, value: 0.60))

    // MARK: - Eyeshadow

    static let champagneShadow = MakeupShade(id: "shadow-champagne", title: "Champagne", region: .shadow,
                                             color: MakeupColor(hue: 40, saturation: 0.22, value: 0.92))
    /// The default shadow: a neutral that reads as contour rather than colour.
    static let taupeShadow = MakeupShade(id: "shadow-taupe", title: "Taupe", region: .shadow,
                                         color: MakeupColor(hue: 28, saturation: 0.20, value: 0.58))
    static let bronzeShadow = MakeupShade(id: "shadow-bronze", title: "Bronze", region: .shadow,
                                          color: MakeupColor(hue: 30, saturation: 0.48, value: 0.52))
    static let roseGoldShadow = MakeupShade(id: "shadow-rosegold", title: "Rose Gold", region: .shadow,
                                            color: MakeupColor(hue: 345, saturation: 0.32, value: 0.72))
    static let plumShadow = MakeupShade(id: "shadow-plum", title: "Plum", region: .shadow,
                                        color: MakeupColor(hue: 315, saturation: 0.32, value: 0.42))
    static let slateShadow = MakeupShade(id: "shadow-slate", title: "Slate", region: .shadow,
                                         color: MakeupColor(hue: 220, saturation: 0.18, value: 0.45))

    // MARK: - Eyeliner

    static let inkLiner = MakeupShade(id: "liner-ink", title: "Ink", region: .liner,
                                      color: MakeupColor(hue: 240, saturation: 0.06, value: 0.10))
    static let espressoLiner = MakeupShade(id: "liner-espresso", title: "Espresso", region: .liner,
                                           color: MakeupColor(hue: 22, saturation: 0.40, value: 0.22))
    static let navyLiner = MakeupShade(id: "liner-navy", title: "Navy", region: .liner,
                                       color: MakeupColor(hue: 225, saturation: 0.55, value: 0.24))
    static let plumLiner = MakeupShade(id: "liner-plum", title: "Plum", region: .liner,
                                       color: MakeupColor(hue: 330, saturation: 0.45, value: 0.26))

    // MARK: - Brows

    static let ashBrow = MakeupShade(id: "brow-ash", title: "Ash", region: .brows,
                                     color: MakeupColor(hue: 30, saturation: 0.12, value: 0.32))
    /// The default brow pigment: dark enough to read as hair, neutral enough
    /// not to fight the photo's own colour.
    static let taupeBrow = MakeupShade(id: "brow-taupe", title: "Taupe", region: .brows,
                                       color: MakeupColor(hue: 28, saturation: 0.22, value: 0.40))
    static let warmBrow = MakeupShade(id: "brow-warm", title: "Warm", region: .brows,
                                      color: MakeupColor(hue: 26, saturation: 0.38, value: 0.38))
    static let espressoBrow = MakeupShade(id: "brow-espresso", title: "Espresso", region: .brows,
                                          color: MakeupColor(hue: 20, saturation: 0.35, value: 0.24))

    /// The whole catalogue, in the order the inspector shows it.
    static let all: [MakeupShade] = [
        petal, peach, softRose, rose,
        nude, coral, mauve, plum,
        berry, terracotta, brick, wine,
        copper, rosewood, ruby, merlot,
        chestnut, mulberry, rubyred, aubergine,

        cheekPetal, cheekPeach, cheekRoseFair,
        cheekPeachLight, cheekRoseLight, cheekCoral,
        cheekApricotMedium, cheekRoseMedium, cheekTerracotta,
        cheekApricotTan, cheekRosewood, cheekBrick,
        cheekCopper, cheekBerry, cheekRuby,

        champagneShadow, taupeShadow, bronzeShadow,
        roseGoldShadow, plumShadow, slateShadow,

        inkLiner, espressoLiner, navyLiner, plumLiner,

        ashBrow, taupeBrow, warmBrow, espressoBrow,
    ]
}
