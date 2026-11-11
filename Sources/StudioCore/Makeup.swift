import Foundation

/// Skin-tone family a shade is mixed for. A berry that reads as a stain on fair
/// skin turns grey on deep skin, so the palette is split the way a makeup counter
/// is: the same idea, mixed for the tone it will sit on.
public enum MakeupFamily: String, CaseIterable, Identifiable, Codable {
    case fair, light, medium, tan, deep

    public var id: String { rawValue }

    /// Which family a measured skin luminance belongs to. Thresholds sit on
    /// 8-bit sRGB luminance, the same space the cosmetic palettes are written
    /// in, and are wide enough that a lit or shaded face lands in the family a
    /// person would name.
    public static func of(skinLuminance luma: Double) -> MakeupFamily {
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
public enum MakeupRegion: String, CaseIterable, Identifiable, Codable {
    case lips, cheeks, contour, shadow, liner, brows, hair

    public var id: String { rawValue }

    /// Lip and cheek shades are mixed per skin tone; contour, shadow, liner and
    /// brow colours are pigment laid on skin or hair and work the same on every
    /// tone, as do hair dyes (the amount carries the difference).
    public var hasFamilies: Bool { self == .lips || self == .cheeks }

    /// How much of the colour a tap on a swatch applies, in slider units.
    public var defaultAmount: Double {
        switch self {
        case .lips: return 55
        case .cheeks: return 40
        case .contour: return 35
        case .shadow: return 35
        case .liner: return 45
        case .brows: return 45
        case .hair: return 50
        }
    }

    public var colorPath: WritableKeyPath<Adjustments, MakeupColor> {
        switch self {
        case .lips: return \.lipColor
        case .cheeks: return \.blushColor
        case .contour: return \.contourColor
        case .shadow: return \.shadowColor
        case .liner: return \.linerColor
        case .brows: return \.browColor
        case .hair: return \.hairTint
        }
    }

    public var amountPath: WritableKeyPath<Adjustments, Double> {
        switch self {
        case .lips: return \.lipTint
        case .cheeks: return \.blush
        case .contour: return \.contour
        case .shadow: return \.eyeshadow
        case .liner: return \.eyeliner
        case .brows: return \.browDefine
        case .hair: return \.hairColor
        }
    }
}

/// A named colour in the catalogue. The swatches exist to give the picker a
/// starting point, not to be the only choices — any colour can be dialled in
/// with the picker or the hue and saturation sliders.
public struct MakeupShade: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let region: MakeupRegion
    /// `nil` for pigments that do not change with skin tone.
    public let family: MakeupFamily?
    public let color: MakeupColor

    /// Saved projects and presets store the identifier, so `rawValue` keeps the
    /// old call sites and old files working.
    public var rawValue: String { id }

    public init?(rawValue: String) {
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
    public static func shades(_ region: MakeupRegion, family: MakeupFamily? = nil) -> [MakeupShade] {
        all.filter { $0.region == region && (family == nil || $0.family == family) }
    }

    // MARK: - Lips

    public static let petal = MakeupShade(id: "lip-fair-petal", title: "Petal", region: .lips, family: .fair,
                                   color: MakeupColor(hue: 345, saturation: 0.38, value: 0.86))
    /// The default lip colour, and the one every older project and preset
    /// refers to by identifier.
    public static let rose = MakeupShade(id: "rose", title: "Rose", region: .lips, family: .light,
                                  color: MakeupColor(hue: 350, saturation: 0.60, value: 0.77))
    public static let peach = MakeupShade(id: "peach", title: "Peach", region: .lips, family: .fair,
                                   color: MakeupColor(hue: 28, saturation: 0.38, value: 0.92))
    public static let softRose = MakeupShade(id: "lip-fair-softrose", title: "Soft Rose", region: .lips, family: .fair,
                                      color: MakeupColor(hue: 350, saturation: 0.42, value: 0.85))

    public static let nude = MakeupShade(id: "lip-light-nude", title: "Nude", region: .lips, family: .light,
                                  color: MakeupColor(hue: 18, saturation: 0.30, value: 0.78))
    public static let coral = MakeupShade(id: "coral", title: "Coral", region: .lips, family: .light,
                                   color: MakeupColor(hue: 8, saturation: 0.58, value: 0.86))
    public static let mauve = MakeupShade(id: "lip-light-mauve", title: "Mauve", region: .lips, family: .light,
                                   color: MakeupColor(hue: 335, saturation: 0.38, value: 0.72))
    public static let plum = MakeupShade(id: "lip-light-plum", title: "Plum", region: .lips, family: .light,
                                  color: MakeupColor(hue: 330, saturation: 0.45, value: 0.58))

    public static let berry = MakeupShade(id: "berry", title: "Berry", region: .lips, family: .medium,
                                   color: MakeupColor(hue: 340, saturation: 0.52, value: 0.62))
    public static let terracotta = MakeupShade(id: "lip-medium-terracotta", title: "Terracotta", region: .lips, family: .medium,
                                        color: MakeupColor(hue: 14, saturation: 0.60, value: 0.70))
    public static let brick = MakeupShade(id: "lip-medium-brick", title: "Brick", region: .lips, family: .medium,
                                   color: MakeupColor(hue: 4, saturation: 0.62, value: 0.65))
    public static let wine = MakeupShade(id: "lip-medium-wine", title: "Wine", region: .lips, family: .medium,
                                  color: MakeupColor(hue: 335, saturation: 0.58, value: 0.48))

    public static let copper = MakeupShade(id: "lip-tan-copper", title: "Copper", region: .lips, family: .tan,
                                    color: MakeupColor(hue: 18, saturation: 0.65, value: 0.63))
    public static let rosewood = MakeupShade(id: "lip-tan-rosewood", title: "Rosewood", region: .lips, family: .tan,
                                      color: MakeupColor(hue: 350, saturation: 0.55, value: 0.55))
    public static let ruby = MakeupShade(id: "lip-tan-ruby", title: "Ruby", region: .lips, family: .tan,
                                  color: MakeupColor(hue: 355, saturation: 0.68, value: 0.60))
    public static let merlot = MakeupShade(id: "lip-tan-merlot", title: "Merlot", region: .lips, family: .tan,
                                    color: MakeupColor(hue: 330, saturation: 0.60, value: 0.42))

    public static let chestnut = MakeupShade(id: "lip-deep-chestnut", title: "Chestnut", region: .lips, family: .deep,
                                      color: MakeupColor(hue: 14, saturation: 0.66, value: 0.52))
    public static let mulberry = MakeupShade(id: "lip-deep-mulberry", title: "Mulberry", region: .lips, family: .deep,
                                      color: MakeupColor(hue: 335, saturation: 0.55, value: 0.42))
    public static let rubyred = MakeupShade(id: "lip-deep-ruby", title: "Ruby Red", region: .lips, family: .deep,
                                     color: MakeupColor(hue: 348, saturation: 0.76, value: 0.56))
    public static let aubergine = MakeupShade(id: "lip-deep-aubergine", title: "Aubergine", region: .lips, family: .deep,
                                       color: MakeupColor(hue: 315, saturation: 0.55, value: 0.34))

    // MARK: - Cheeks

    /// The default blush. Sheer peach works on nearly every tone at the low
    /// strength blush is blended at.
    public static let cheekPeach = MakeupShade(id: "cheek-fair-peach", title: "Peach", region: .cheeks, family: .fair,
                                        color: MakeupColor(hue: 25, saturation: 0.35, value: 0.95))
    public static let cheekPetal = MakeupShade(id: "cheek-fair-petal", title: "Petal", region: .cheeks, family: .fair,
                                        color: MakeupColor(hue: 345, saturation: 0.30, value: 0.93))
    public static let cheekRoseFair = MakeupShade(id: "cheek-fair-rose", title: "Rose", region: .cheeks, family: .fair,
                                           color: MakeupColor(hue: 350, saturation: 0.40, value: 0.88))

    public static let cheekPeachLight = MakeupShade(id: "cheek-light-peach", title: "Peach", region: .cheeks, family: .light,
                                             color: MakeupColor(hue: 24, saturation: 0.45, value: 0.90))
    public static let cheekRoseLight = MakeupShade(id: "cheek-light-rose", title: "Rose", region: .cheeks, family: .light,
                                            color: MakeupColor(hue: 350, saturation: 0.45, value: 0.82))
    public static let cheekCoral = MakeupShade(id: "cheek-light-coral", title: "Coral", region: .cheeks, family: .light,
                                        color: MakeupColor(hue: 8, saturation: 0.48, value: 0.88))

    public static let cheekApricotMedium = MakeupShade(id: "cheek-medium-apricot", title: "Apricot", region: .cheeks, family: .medium,
                                                color: MakeupColor(hue: 25, saturation: 0.50, value: 0.85))
    public static let cheekRoseMedium = MakeupShade(id: "cheek-medium-rose", title: "Rose", region: .cheeks, family: .medium,
                                             color: MakeupColor(hue: 348, saturation: 0.42, value: 0.74))
    public static let cheekTerracotta = MakeupShade(id: "cheek-medium-terracotta", title: "Terracotta", region: .cheeks, family: .medium,
                                             color: MakeupColor(hue: 14, saturation: 0.52, value: 0.76))

    public static let cheekApricotTan = MakeupShade(id: "cheek-tan-apricot", title: "Apricot", region: .cheeks, family: .tan,
                                             color: MakeupColor(hue: 22, saturation: 0.58, value: 0.80))
    public static let cheekRosewood = MakeupShade(id: "cheek-tan-rosewood", title: "Rosewood", region: .cheeks, family: .tan,
                                           color: MakeupColor(hue: 350, saturation: 0.48, value: 0.62))
    public static let cheekBrick = MakeupShade(id: "cheek-tan-brick", title: "Brick", region: .cheeks, family: .tan,
                                        color: MakeupColor(hue: 6, saturation: 0.55, value: 0.68))

    public static let cheekCopper = MakeupShade(id: "cheek-deep-copper", title: "Copper", region: .cheeks, family: .deep,
                                         color: MakeupColor(hue: 18, saturation: 0.62, value: 0.66))
    public static let cheekBerry = MakeupShade(id: "cheek-deep-berry", title: "Berry", region: .cheeks, family: .deep,
                                        color: MakeupColor(hue: 340, saturation: 0.52, value: 0.52))
    public static let cheekRuby = MakeupShade(id: "cheek-deep-ruby", title: "Ruby", region: .cheeks, family: .deep,
                                       color: MakeupColor(hue: 348, saturation: 0.62, value: 0.60))

    // MARK: - Eyeshadow

    public static let champagneShadow = MakeupShade(id: "shadow-champagne", title: "Champagne", region: .shadow,
                                             color: MakeupColor(hue: 40, saturation: 0.22, value: 0.92))
    /// The default shadow: a neutral that reads as contour rather than colour.
    public static let taupeShadow = MakeupShade(id: "shadow-taupe", title: "Taupe", region: .shadow,
                                         color: MakeupColor(hue: 28, saturation: 0.20, value: 0.58))
    public static let bronzeShadow = MakeupShade(id: "shadow-bronze", title: "Bronze", region: .shadow,
                                          color: MakeupColor(hue: 30, saturation: 0.48, value: 0.52))
    public static let roseGoldShadow = MakeupShade(id: "shadow-rosegold", title: "Rose Gold", region: .shadow,
                                            color: MakeupColor(hue: 345, saturation: 0.32, value: 0.72))
    public static let plumShadow = MakeupShade(id: "shadow-plum", title: "Plum", region: .shadow,
                                        color: MakeupColor(hue: 315, saturation: 0.32, value: 0.42))
    public static let slateShadow = MakeupShade(id: "shadow-slate", title: "Slate", region: .shadow,
                                         color: MakeupColor(hue: 220, saturation: 0.18, value: 0.45))

    // MARK: - Eyeliner

    public static let inkLiner = MakeupShade(id: "liner-ink", title: "Ink", region: .liner,
                                      color: MakeupColor(hue: 240, saturation: 0.06, value: 0.10))
    public static let espressoLiner = MakeupShade(id: "liner-espresso", title: "Espresso", region: .liner,
                                           color: MakeupColor(hue: 22, saturation: 0.40, value: 0.22))
    public static let navyLiner = MakeupShade(id: "liner-navy", title: "Navy", region: .liner,
                                       color: MakeupColor(hue: 225, saturation: 0.55, value: 0.24))
    public static let plumLiner = MakeupShade(id: "liner-plum", title: "Plum", region: .liner,
                                       color: MakeupColor(hue: 330, saturation: 0.45, value: 0.26))

    // MARK: - Brows

    public static let ashBrow = MakeupShade(id: "brow-ash", title: "Ash", region: .brows,
                                     color: MakeupColor(hue: 30, saturation: 0.12, value: 0.32))
    /// The default brow pigment: dark enough to read as hair, neutral enough
    /// not to fight the photo's own colour.
    public static let taupeBrow = MakeupShade(id: "brow-taupe", title: "Taupe", region: .brows,
                                       color: MakeupColor(hue: 28, saturation: 0.22, value: 0.40))
    public static let warmBrow = MakeupShade(id: "brow-warm", title: "Warm", region: .brows,
                                      color: MakeupColor(hue: 26, saturation: 0.38, value: 0.38))
    public static let espressoBrow = MakeupShade(id: "brow-espresso", title: "Espresso", region: .brows,
                                          color: MakeupColor(hue: 20, saturation: 0.35, value: 0.24))

    // MARK: - Contour

    /// The default sculpting shade: a desaturated taupe that darkens the
    /// hollow under the cheekbone without reading as dirt on the skin.
    public static let contourSoft = MakeupShade(id: "contour-soft", title: "Soft", region: .contour,
                                         color: MakeupColor(hue: 26, saturation: 0.24, value: 0.52))
    public static let contourNeutral = MakeupShade(id: "contour-neutral", title: "Neutral", region: .contour,
                                            color: MakeupColor(hue: 30, saturation: 0.16, value: 0.44))
    public static let contourWarm = MakeupShade(id: "contour-warm", title: "Warm", region: .contour,
                                         color: MakeupColor(hue: 20, saturation: 0.34, value: 0.48))
    public static let contourDeep = MakeupShade(id: "contour-deep", title: "Deep", region: .contour,
                                         color: MakeupColor(hue: 22, saturation: 0.30, value: 0.30))

    // MARK: - Hair

    /// The default hair pigment: a neutral dark brown, which deepens almost
    /// every natural hair colour without shifting it.
    public static let hairEspresso = MakeupShade(id: "hair-espresso", title: "Espresso", region: .hair,
                                          color: MakeupColor(hue: 22, saturation: 0.34, value: 0.24))
    public static let hairSoftBlack = MakeupShade(id: "hair-softblack", title: "Soft Black", region: .hair,
                                           color: MakeupColor(hue: 230, saturation: 0.08, value: 0.12))
    public static let hairChestnut = MakeupShade(id: "hair-chestnut", title: "Chestnut", region: .hair,
                                          color: MakeupColor(hue: 16, saturation: 0.48, value: 0.38))
    public static let hairAuburn = MakeupShade(id: "hair-auburn", title: "Auburn", region: .hair,
                                        color: MakeupColor(hue: 6, saturation: 0.58, value: 0.40))
    public static let hairCaramel = MakeupShade(id: "hair-caramel", title: "Caramel", region: .hair,
                                         color: MakeupColor(hue: 30, saturation: 0.46, value: 0.60))

    /// The whole catalogue, in the order the inspector shows it.
    public static let all: [MakeupShade] = [
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

        contourSoft, contourNeutral, contourWarm, contourDeep,

        champagneShadow, taupeShadow, bronzeShadow,
        roseGoldShadow, plumShadow, slateShadow,

        inkLiner, espressoLiner, navyLiner, plumLiner,

        ashBrow, taupeBrow, warmBrow, espressoBrow,

        hairEspresso, hairSoftBlack, hairChestnut, hairAuburn, hairCaramel,
    ]
}
