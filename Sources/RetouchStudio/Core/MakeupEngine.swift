import CoreGraphics
import CoreImage
import Foundation

/// Colour cosmetics: lips, cheeks, lids, lash line and brows.
///
/// Makeup is a *tint over live skin*, not paint on top of it, so every effect
/// keeps the luminance of the region it covers. That is what separates a
/// convincing result from a flat patch of colour:
///
///   * lips  — the shade is carried on the mouth's own luminance, so the
///     cupid's-bow shadow and the highlight on the lower lip survive inside one
///     consistent colour, and the self-test measures that the shading really
///     does come through.
///   * cheeks and lids — `CISoftLightBlendMode`, which colours the area while
///     darkening or lifting with the underlying shading, exactly like a sheer
///     powder.
///   * liner — a multiply of the pigment over the lash-line band: a drawn line
///     has to be darker than the skin under it, and the eye opening keeps the
///     shape of the lid.
///   * brows — no flat colour layer. A brow is hair, so it is darkened,
///     sharpened and warmed in place; laying a colour over it reads as a tattoo.
///
/// Colours arrive as display-referred sRGB in `MakeupColor`; Core Image
/// composites in linear light, so they are encoded before they reach a blend
/// filter — the same rule the pixel gates follow.
enum MakeupEngine {

    static let defaultLipStrength: Double = 55
    static let defaultBlushStrength: Double = 40
    static let defaultBrowStrength: Double = 45
    static let defaultShadowStrength: Double = 35
    static let defaultLinerStrength: Double = 45

    /// A solid colour layer over the extent, in linear light.
    private static func shadeLayer(_ color: MakeupColor, extent: CGRect) -> CIImage? {
        let c = linearRGB(color)
        let tint = CIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        return CIImage(color: tint).cropped(to: extent)
    }

    private static func linearRGB(_ color: MakeupColor) -> (r: Double, g: Double, b: Double) {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let c = color.rgb
        return (linear(c.r), linear(c.g), linear(c.b))
    }

    /// The shade carried on the region's own luminance.
    ///
    /// Each pixel becomes `luma * shade / luminance(shade)`: a `CIColorMatrix`
    /// collapses the image to its luminance scaled by 1/luminance(shade), and a
    /// multiply against the flat colour puts that scalar back into the shade's
    /// channels. The result has one consistent hue and saturation while every
    /// highlight and crease of the original keeps its place, which is what a
    /// real coat of lipstick does. `tone` pulls the brightness back, because
    /// concentrating a pixel's light into the shade's dominant channel reads as
    /// lighter than the bare surface it replaces.
    private static func tinted(_ image: CIImage, color: MakeupColor, tone: Double) -> CIImage? {
        let c = linearRGB(color)
        let lumaOfShade = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        guard lumaOfShade > 0.001,
              let layer = shadeLayer(color, extent: image.extent) else { return nil }
        let g = tone / lumaOfShade
        let weights = CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0)
        guard let gray = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: image,
            "inputRVector": weights,
            "inputGVector": weights,
            "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])?.outputImage?.cropped(to: image.extent) else { return nil }
        return CIFilter(name: "CIMultiplyBlendMode", parameters: [
            kCIInputImageKey: gray,
            kCIInputBackgroundImageKey: layer
        ])?.outputImage?.cropped(to: image.extent)
    }

    /// A colour laid over an image the way powder sits on skin.
    private static func softened(_ image: CIImage, color: MakeupColor) -> CIImage? {
        guard let layer = shadeLayer(color, extent: image.extent) else { return nil }
        return CIFilter(name: "CISoftLightBlendMode", parameters: [
            kCIInputImageKey: layer,
            kCIInputBackgroundImageKey: image
        ])?.outputImage?.cropped(to: image.extent)
    }

    /// Lipstick. `strength` is the percentage on the slider.
    static func tintLips(_ image: CIImage,
                         strength: Double,
                         mask: CIImage,
                         color: MakeupColor) -> CIImage {
        let amount = clamp(strength)
        guard amount > 0.001,
              let finished = tinted(image, color: color, tone: 0.86)
        else { return image }

        // Capped well below 1 so the lip keeps some of its own colour and the
        // transition out of the painted area stays gradual.
        return SkinEngine.blend(finished, over: image, mask: mask, strength: 0.10 + 0.62 * amount)
    }

    /// Blush across the cheeks.
    static func applyBlush(_ image: CIImage,
                           strength: Double,
                           mask: CIImage,
                           color: MakeupColor) -> CIImage {
        let amount = clamp(strength)
        guard amount > 0.001, let flushed = softened(image, color: color) else { return image }

        // Soft light already tracks the shading underneath it, so the blend
        // strength only has to stay low enough to keep the flush sheer.
        return SkinEngine.blend(flushed, over: image, mask: mask, strength: 0.10 + 0.55 * amount)
    }

    /// Eyeshadow across the lid, between the lash line and the brow.
    static func applyShadow(_ image: CIImage,
                            strength: Double,
                            mask: CIImage,
                            color: MakeupColor) -> CIImage {
        let amount = clamp(strength)
        guard amount > 0.001, let shadowed = softened(image, color: color) else { return image }
        return SkinEngine.blend(shadowed, over: image, mask: mask, strength: 0.10 + 0.5 * amount)
    }

    /// Eyeliner along the lash line. A line has to be darker than the skin it
    /// sits on, so this is a multiply rather than a soft-light wash.
    static func applyLiner(_ image: CIImage,
                           strength: Double,
                           mask: CIImage,
                           color: MakeupColor) -> CIImage {
        let amount = clamp(strength)
        let extent = image.extent
        guard amount > 0.001,
              let layer = shadeLayer(color, extent: extent),
              let lined = CIFilter(name: "CIMultiplyBlendMode", parameters: [
                  kCIInputImageKey: layer,
                  kCIInputBackgroundImageKey: image
              ])?.outputImage?.cropped(to: extent)
        else { return image }
        return SkinEngine.blend(lined, over: image, mask: mask, strength: 0.15 + 0.6 * amount)
    }

    /// Denser, better-defined eyebrows in the chosen pigment.
    static func defineBrows(_ image: CIImage,
                            strength: Double,
                            mask: CIImage,
                            color: MakeupColor,
                            scale: CGFloat) -> CIImage {
        let amount = clamp(strength)
        guard amount > 0.001 else { return image }
        let extent = image.extent

        let filled = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: -0.055 * amount,
            kCIInputContrastKey: 1 + 0.10 * amount,
            kCIInputSaturationKey: 1 + 0.05 * amount
        ]).cropped(to: extent)

        // Definition is the individual hair, so the mask pass is narrow: a wide
        // unsharp on skin-coloured pixels would ring the brow.
        let crisp = filled.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: max(0.7, 1.1 * scale),
            kCIInputIntensityKey: 0.45 * amount
        ]).cropped(to: extent)

        // The pigment warms or cools the hair instead of painting it: soft
        // light follows the strands, so the brow still reads as hair.
        let pigmented = softened(crisp, color: color) ?? crisp

        // Every number here is small on purpose. Brow hair is already close to
        // black, so darkening it harder clips the whole band to one flat slab
        // and the effect stops reading as hair.
        return SkinEngine.blend(pigmented, over: image, mask: mask, strength: 0.15 + 0.4 * amount)
    }

    private static func clamp(_ strength: Double) -> Double {
        min(1, max(0, strength / 100))
    }
}
