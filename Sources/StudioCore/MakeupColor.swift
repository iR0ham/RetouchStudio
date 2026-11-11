import Foundation

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
public struct MakeupColor: Hashable, Codable {
    public var hue: Double          // 0...360
    public var saturation: Double   // 0...1
    public var value: Double        // 0...1

    public init(hue: Double, saturation: Double, value: Double) {
        self.hue = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        self.saturation = min(1, max(0, saturation))
        self.value = min(1, max(0, value))
    }

    /// The colour a picker handed back.
    public init(rgb r: Double, _ g: Double, _ b: Double) {
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
    public var rgb: (r: Double, g: Double, b: Double) {
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

    public func with(hue: Double) -> MakeupColor {
        MakeupColor(hue: hue, saturation: saturation, value: value)
    }

    public func with(saturation: Double) -> MakeupColor {
        MakeupColor(hue: hue, saturation: saturation, value: value)
    }
}
