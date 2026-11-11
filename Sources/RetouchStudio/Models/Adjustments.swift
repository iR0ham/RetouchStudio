import Foundation
import StudioCore

extension Adjustments {
    /// The look as an enum; an unknown identifier reads as no look.
    var look: FilmLook {
        get { FilmLook.named(lookID) }
        set { lookID = newValue.rawValue }
    }
}

extension HSLBand {
    var title: String {
        L10n.current.hueBandTitle(self)
    }
}

/// What a preset is for. The order of the cases is the order the sections
/// appear in the inspector.
enum PresetGroup: String, CaseIterable, Identifiable {
    case everyday, skin, beauty, color, film, makeup

    var id: String { rawValue }

    var title: String {
        L10n.current.presetGroupTitle(self)
    }
}

/// The identity of a built-in look. The raw values are what a project file
/// stores, so they never change; the name for each one lives in the string
/// table.
enum PresetID: String, CaseIterable {
    case natural, clean, fresh, minimal, softlight
    case airbrush, texture, matte, glow, eventone, bronze, porcelain
    case glamour, studio, editorial, beauty, bridal, sculpt, male
    case warmsun, cool, vibrant, muted, pastel, punchy, fade, noir, monosoft
    case golden, portra, cinema, faded, cross, kodachrome
    case rose, coral, berry, redcarpet, nude, brows
}

struct Preset: Identifiable, Equatable {
    let id: PresetID
    let group: PresetGroup
    let adjustments: Adjustments

    var title: String { L10n.current.presetTitle(id) }

    static func inGroup(_ group: PresetGroup) -> [Preset] { all.filter { $0.group == group } }
    static func with(id: String) -> Preset? {
        guard let id = PresetID(rawValue: id) else { return nil }
        return all.first { $0.id == id }
    }

    /// The library. Every entry is a starting point a photographer would
    /// actually reach for, and each one leaves at least one group alone so
    /// there is something left to adjust afterwards.
    ///
    /// Arguments follow the declaration order of `Adjustments`, which the
    /// memberwise initialiser keeps.
    static let all: [Preset] = [
        // MARK: Everyday — small, defensible corrections

        Preset(id: .natural, group: .everyday, adjustments: Adjustments(
            smooth: 22, blemish: 30, wrinkle: 18, skinToneEvens: 20,
            darkCircles: 16, texturePreserve: 78,
            teethWhiten: 12, eyeBrighten: 10, eyeSharpen: 14,
            exposure: 3, contrast: 5, vibrance: 8, warmth: 4, clarity: 6)),
        Preset(id: .clean, group: .everyday, adjustments: Adjustments(
            smooth: 16, blemish: 46, wrinkle: 12, skinToneEvens: 18,
            darkCircles: 24, texturePreserve: 86,
            teethWhiten: 16, eyeBrighten: 8,
            contrast: 6, blacks: 10, vibrance: 6, clarity: 8)),
        Preset(id: .fresh, group: .everyday, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 22, darkCircles: 34,
            skinBrighten: 14, texturePreserve: 82,
            teethWhiten: 20, eyeBrighten: 18, eyeSharpen: 16,
            exposure: 6, whites: 10, vibrance: 12, warmth: 5, clarity: 4)),
        Preset(id: .minimal, group: .everyday, adjustments: Adjustments(
            blemish: 38, wrinkle: 6, darkCircles: 22, texturePreserve: 100,
            eyeSharpen: 8, contrast: 2, vibrance: 2)),
        Preset(id: .softlight, group: .everyday, adjustments: Adjustments(
            smooth: 26, blemish: 18, skinToneEvens: 14, texturePreserve: 72,
            eyeBrighten: 8, exposure: 7, contrast: -6, whites: 14,
            saturation: -4, vibrance: 6, warmth: 6)),

        // MARK: Skin — what the smoothing itself should feel like

        Preset(id: .airbrush, group: .skin, adjustments: Adjustments(
            smooth: 62, blemish: 70, wrinkle: 52, skinToneEvens: 56,
            darkCircles: 44, skinBrighten: 18, texturePreserve: 38,
            teethWhiten: 30, eyeBrighten: 18,
            exposure: 3, contrast: 8, vibrance: 8, clarity: 6)),
        Preset(id: .texture, group: .skin, adjustments: Adjustments(
            smooth: 6, blemish: 26, wrinkle: 10, skinToneEvens: 10,
            texturePreserve: 100, eyeSharpen: 20,
            contrast: 10, blacks: 14, clarity: 22)),
        Preset(id: .matte, group: .skin, adjustments: Adjustments(
            smooth: 44, blemish: 40, skinToneEvens: 34,
            texturePreserve: 58, contrast: 12, blacks: 24, whites: -10,
            saturation: -6, vibrance: -4, clarity: 18)),
        Preset(id: .glow, group: .skin, adjustments: Adjustments(
            smooth: 34, blemish: 30, skinToneEvens: 28, darkCircles: 26,
            skinBrighten: 34, texturePreserve: 66,
            teethWhiten: 22, eyeBrighten: 20, eyeSharpen: 12,
            exposure: 5, whites: 18, vibrance: 10, warmth: 6)),
        Preset(id: .eventone, group: .skin, adjustments: Adjustments(
            smooth: 28, blemish: 44, skinToneEvens: 62, darkCircles: 46,
            skinBrighten: 12, texturePreserve: 70,
            contrast: 4, vibrance: 6, warmth: 3, clarity: 4)),
        Preset(id: .bronze, group: .skin, adjustments: Adjustments(
            smooth: 30, blemish: 26, skinToneEvens: 22, texturePreserve: 64,
            teethWhiten: 14, exposure: 2, contrast: 8, saturation: 6,
            vibrance: 10, warmth: 24, clarity: 10, vignette: 8)),
        Preset(id: .porcelain, group: .skin, adjustments: Adjustments(
            smooth: 54, blemish: 52, wrinkle: 40, skinToneEvens: 48,
            darkCircles: 38, skinBrighten: 30, texturePreserve: 48,
            teethWhiten: 26, eyeBrighten: 16,
            exposure: 8, contrast: 4, whites: 16, saturation: -6,
            vibrance: 4, warmth: -4)),

        // MARK: Beauty — full portraits, several groups at once

        Preset(id: .glamour, group: .beauty, adjustments: Adjustments(
            smooth: 42, blemish: 50, wrinkle: 34, skinToneEvens: 36,
            darkCircles: 30, texturePreserve: 62,
            teethWhiten: 34, eyeBrighten: 22, eyeSharpen: 28,
            eyeSize: 14, lipSize: 12, cheekSize: 8,
            exposure: 6, contrast: 10, vibrance: 14, warmth: 6, clarity: 10, vignette: 10,
            eyeshadow: 22, shadowColor: MakeupShade.champagneShadow.color,
            eyeliner: 14)),
        Preset(id: .studio, group: .beauty, adjustments: Adjustments(
            smooth: 55, blemish: 62, wrinkle: 44, skinToneEvens: 46,
            darkCircles: 38, texturePreserve: 52,
            teethWhiten: 44, eyeBrighten: 30, eyeSharpen: 38,
            eyeSize: 18, lipSize: 10, cheekSize: 14, jawWidth: -16, chinLength: 8,
            faceWidth: -8,
            exposure: 4, contrast: 16, vibrance: 10, warmth: 8, clarity: 16, vignette: 16)),
        Preset(id: .editorial, group: .beauty, adjustments: Adjustments(
            smooth: 12, blemish: 16, wrinkle: 24, skinToneEvens: 14,
            darkCircles: 20, texturePreserve: 92,
            teethWhiten: 6, eyeBrighten: 8, eyeSharpen: 26,
            cheekSize: -8, jawWidth: -20, chinLength: 10, faceWidth: -12,
            contrast: 20, blacks: 18, saturation: -10, vibrance: -4,
            warmth: -6, clarity: 24, vignette: 16)),
        Preset(id: .beauty, group: .beauty, adjustments: Adjustments(
            smooth: 38, blemish: 44, wrinkle: 26, skinToneEvens: 32,
            darkCircles: 30, skinBrighten: 16, texturePreserve: 66,
            teethWhiten: 28, eyeBrighten: 24, eyeSharpen: 24,
            eyeSize: 10, lipSize: 8,
            exposure: 4, contrast: 8, whites: 10, vibrance: 10, warmth: 4,
            clarity: 8, lipTint: 16, lipColor: MakeupShade.rose.color,
            eyeshadow: 14, shadowColor: MakeupShade.taupeShadow.color)),
        Preset(id: .bridal, group: .beauty, adjustments: Adjustments(
            smooth: 46, blemish: 48, wrinkle: 32, skinToneEvens: 40,
            darkCircles: 34, skinBrighten: 24, texturePreserve: 58,
            teethWhiten: 38, eyeBrighten: 20, eyeSharpen: 18,
            eyeSize: 8, cheekSize: 6,
            exposure: 7, contrast: 4, whites: 20, saturation: -4,
            vibrance: 8, warmth: 3, clarity: 6, vignette: 6,
            lipTint: 14, lipColor: MakeupShade.peach.color,
            blush: 16, blushColor: MakeupShade.cheekPeach.color)),
        Preset(id: .sculpt, group: .beauty, adjustments: Adjustments(
            smooth: 26, blemish: 30, skinToneEvens: 18, texturePreserve: 76,
            eyeSize: 8, cheekSize: -10, jawWidth: -18, chinLength: 6,
            faceWidth: -12, faceLength: 6,
            contrast: 14, blacks: 16, clarity: 20, vignette: 12)),
        Preset(id: .male, group: .beauty, adjustments: Adjustments(
            smooth: 14, blemish: 38, wrinkle: 10, skinToneEvens: 12,
            texturePreserve: 94, eyeBrighten: 8, eyeSharpen: 14,
            jawWidth: -8, chinLength: 6, faceWidth: -6,
            contrast: 14, blacks: 18, saturation: -6, warmth: -4, clarity: 18)),

        // MARK: Colour — the whole frame, no skin work

        Preset(id: .warmsun, group: .color, adjustments: Adjustments(
            exposure: 4, contrast: 6, whites: 10, vibrance: 12,
            warmth: 24, clarity: 4)),
        Preset(id: .cool, group: .color, adjustments: Adjustments(
            exposure: 2, contrast: 8, blacks: 10, saturation: -4,
            warmth: -22, clarity: 6)),
        Preset(id: .vibrant, group: .color, adjustments: Adjustments(
            exposure: 2, contrast: 12, blacks: 12, whites: 12,
            saturation: 8, vibrance: 24, clarity: 8)),
        Preset(id: .muted, group: .color, adjustments: Adjustments(
            contrast: 4, blacks: 12, saturation: -18, vibrance: -8,
            warmth: -3, clarity: 6)),
        Preset(id: .pastel, group: .color, adjustments: Adjustments(
            exposure: 9, contrast: -8, whites: 16, saturation: -12,
            vibrance: 4, warmth: 4)),
        Preset(id: .punchy, group: .color, adjustments: Adjustments(
            contrast: 26, blacks: 24, whites: 20, saturation: 4,
            vibrance: 12, clarity: 16)),
        Preset(id: .fade, group: .color, adjustments: Adjustments(
            exposure: 5, contrast: -12, blacks: -34, whites: -14,
            saturation: -8, vibrance: -4, warmth: 6)),
        Preset(id: .noir, group: .color, adjustments: Adjustments(
            exposure: -4, contrast: 30, blacks: 26, saturation: -100,
            clarity: 22, vignette: 26)),
        Preset(id: .monosoft, group: .color, adjustments: Adjustments(
            exposure: 5, contrast: 8, blacks: -16, whites: 10,
            saturation: -100, clarity: 6, grain: 26)),

        // MARK: Film — grade and grain, lightly supported by skin work

        Preset(id: .golden, group: .film, adjustments: Adjustments(
            smooth: 18, blemish: 20, skinBrighten: 10, texturePreserve: 80,
            exposure: 4, contrast: 6, whites: 12, vibrance: 10, warmth: 16,
            lookID: FilmLook.warmGold.rawValue, lookStrength: 55, grain: 10)),
        Preset(id: .portra, group: .film, adjustments: Adjustments(
            smooth: 22, blemish: 24, skinToneEvens: 16, texturePreserve: 84,
            exposure: 3, contrast: 4, whites: 8, saturation: -4, warmth: 6,
            lookID: FilmLook.portraitFilm.rawValue, lookStrength: 62, grain: 18)),
        Preset(id: .cinema, group: .film, adjustments: Adjustments(
            smooth: 16, blemish: 18, texturePreserve: 86, eyeSharpen: 12,
            contrast: 14, blacks: 16, warmth: -8, clarity: 8, vignette: 18,
            lookID: FilmLook.nightStock.rawValue, lookStrength: 45, grain: 14)),
        Preset(id: .faded, group: .film, adjustments: Adjustments(
            smooth: 14, texturePreserve: 88, exposure: 4, contrast: -6,
            blacks: -28, saturation: -6, warmth: 4,
            lookID: FilmLook.fadedMatte.rawValue, lookStrength: 65, grain: 22)),
        Preset(id: .cross, group: .film, adjustments: Adjustments(
            smooth: 10, texturePreserve: 90, contrast: 18, blacks: 14,
            saturation: 6, clarity: 10,
            lookID: FilmLook.crossProcess.rawValue, lookStrength: 45, grain: 12)),
        Preset(id: .kodachrome, group: .film, adjustments: Adjustments(
            smooth: 12, texturePreserve: 86, exposure: 2, contrast: 16,
            blacks: 18, saturation: 10, vibrance: 8, warmth: 10, clarity: 10,
            lookID: FilmLook.warmGold.rawValue, lookStrength: 38, grain: 20)),

        // MARK: Makeup — cosmetics, with the skin work kept minimal

        Preset(id: .rose, group: .makeup, adjustments: Adjustments(
            smooth: 20, blemish: 22, skinToneEvens: 16, skinBrighten: 12,
            texturePreserve: 78, eyeBrighten: 10, eyeSharpen: 12,
            contrast: 4, vibrance: 6, warmth: 8,
            lipTint: 48, lipColor: MakeupShade.rose.color,
            blush: 30, blushColor: MakeupShade.cheekRoseLight.color)),
        Preset(id: .coral, group: .makeup, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 18, skinBrighten: 14,
            texturePreserve: 74, teethWhiten: 22, eyeBrighten: 12,
            exposure: 3, vibrance: 12, warmth: 10,
            lipTint: 54, lipColor: MakeupShade.coral.color,
            blush: 34, blushColor: MakeupShade.cheekCoral.color)),
        Preset(id: .berry, group: .makeup, adjustments: Adjustments(
            smooth: 24, blemish: 28, skinToneEvens: 20, texturePreserve: 74,
            teethWhiten: 26, eyeBrighten: 12, eyeSharpen: 10,
            contrast: 8, blacks: 10, saturation: 4,
            lipTint: 38, lipColor: MakeupShade.berry.color,
            blush: 14, blushColor: MakeupShade.cheekBerry.color)),
        Preset(id: .redcarpet, group: .makeup, adjustments: Adjustments(
            smooth: 40, blemish: 46, wrinkle: 28, skinToneEvens: 38,
            darkCircles: 28, texturePreserve: 60,
            teethWhiten: 42, eyeBrighten: 22, eyeSharpen: 24, eyeSize: 10,
            contrast: 12, blacks: 14, saturation: 6, vibrance: 8, warmth: 4,
            clarity: 8, vignette: 12,
            lipTint: 48, lipColor: MakeupShade.berry.color,
            blush: 12, blushColor: MakeupShade.cheekRoseLight.color, browDefine: 18,
            eyeshadow: 26, shadowColor: MakeupShade.plumShadow.color,
            eyeliner: 22, linerColor: MakeupShade.inkLiner.color)),
        Preset(id: .nude, group: .makeup, adjustments: Adjustments(
            smooth: 12, blemish: 34, wrinkle: 8, skinToneEvens: 12,
            darkCircles: 26, texturePreserve: 94,
            teethWhiten: 16, eyeBrighten: 14, eyeSharpen: 18,
            exposure: 4, vibrance: 8, warmth: 4,
            lipTint: 26, lipColor: MakeupShade.peach.color,
            blush: 18, blushColor: MakeupShade.cheekPeach.color, browDefine: 28)),
        Preset(id: .brows, group: .makeup, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 14, texturePreserve: 84,
            eyeBrighten: 14, eyeSharpen: 22, contrast: 8, clarity: 10,
            lipTint: 8, lipColor: MakeupShade.peach.color, browDefine: 42)),
    ]
}
