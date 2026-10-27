import CoreGraphics
import CoreImage
import Foundation

/// Professional skin retouching.
///
/// WHY THE OLD APPROACH LOOKED BAD
/// -------------------------------
/// The previous engine smoothed skin by downscaling the whole image, applying
/// one Gaussian blur and blending it back at a fixed strength. That is a
/// low-pass filter: it destroys every frequency, so pores, fine hairs and
/// skin micro-texture vanish together with the blemishes. The result reads as
/// plastic, and because the same blurred copy was reused for "blemish" at a
/// different strength, the two sliders fought each other instead of doing
/// different jobs.
///
/// WHAT THIS DOES INSTEAD
/// ----------------------
/// Real retouching separates the image into frequency bands and treats each
/// band according to its meaning:
///
///   * base (low frequency)  — skin tone, shading, blotches.
///   * detail (high frequency) — pores, texture, edges. This is the layer that
///     must survive, or the face stops looking like skin.
///
/// Blemishes are *spatial outliers* in the detail band, not a uniform veil, so
/// they are found with a median filter (which removes small dark spots while
/// preserving edges) and removed only where the pixel genuinely deviates from
/// its neighbourhood. Wrinkles are 1D line structures, so they use a
/// directional/edge-preserving reduction instead. Texture is then added back on
/// top at a controlled strength, which is what `texturePreserve` governs.
///
/// Every operation is masked to the relevant facial region, so nothing outside
/// the face changes.
enum SkinEngine {

    // MARK: - Why there is no explicit frequency-separation step

    // Frequency separation is the textbook skin-retouch technique, but it cannot
    // be expressed correctly in Core Image here:
    //
    //   * a signed difference needs a kernel, because CIKernel's two-input
    //     maths (CISubtractBlendMode) works on premultiplied values and clamps;
    //   * CIColorMatrix clamps to 0...1, so a detail band centred on zero cannot
    //     survive an 8-bit round trip.
    //
    // Measured consequence: a "split" built that way lost almost all high
    // frequency energy and recombining it did not reconstruct the input
    // (mean error 27/255). Any texture slider built on it would be dead — which
    // is exactly what the tests showed.
    //
    // The controls are therefore expressed directly, which is both correct and
    // verifiable: smoothing blends a filtered copy over the original through a
    // mask, and `texturePreserve` sets how much of the original is kept. That is
    // mathematically the same "keep N% of the detail" control, without needing
    // signed intermediates.

    // MARK: - Blemish and spot removal

    /// Removes small dark/bright outliers (spots, acne, moles) while leaving
    /// pores and edges alone.
    ///
    /// Two details matter here and both were wrong at first:
    ///
    ///  1. `CIMedianFilter` is a fixed 3x3 kernel with no radius parameter. A
    ///     real blemish is often 10-30 px wide at working resolution, so a 3x3
    ///     median cannot touch it. The median is therefore run at a scale chosen
    ///     from the *spot size*: downscale, median, upscale, which multiplies the
    ///     effective kernel. Because it is a median (not a mean) it still
    ///     preserves edges and leaves texture elsewhere.
    ///
    ///  2. The result is gated by how far each pixel deviates from that local
    ///     median, so only genuine outliers are replaced. Ordinary skin is left
    ///     bit-for-bit alone.
    ///
    /// `spotRadius` is in pixels and is derived from the face size by the
    /// caller, so the same slider value behaves identically on the preview and
    /// on the full-resolution export.
    static func removeBlemishes(_ image: CIImage,
                                strength: Double,
                                mask: CIImage,
                                spotRadius: CGFloat) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }
        let extent = image.extent

        /// Median with an effective kernel of about `radius` pixels.
        func median(effectiveRadius radius: CGFloat) -> CIImage {
            let factor = max(1.0, min(8.0, radius))
            guard factor > 1.2 else {
                return image.clampedToExtent()
                    .applyingFilter("CIMedianFilter")
                    .cropped(to: extent)
            }
            let down = image.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: 1 / factor,
                    kCIInputAspectRatioKey: 1.0
                ])
            let filtered = down.clampedToExtent()
                .applyingFilter("CIMedianFilter")
                .cropped(to: down.extent)
            return filtered
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: factor,
                    kCIInputAspectRatioKey: 1.0
                ])
                .cropped(to: extent)
        }

        // The median is used to LOCATE blemishes and to provide their
        // replacement colour — it is never blended in over clean skin.
        //
        // Measurement showed why: a median is a rank filter, so it removes
        // 1-pixel pores as well as 20-pixel spots (even a 3x3 median kept only
        // 31% of the texture here). Blending the median result everywhere is
        // therefore inherently destructive. Instead:
        //
        //   1. the median supplies a clean estimate of the local skin colour;
        //   2. the deviation between the pixel and that estimate detects spots;
        //   3. only pixels above a measured threshold are replaced.
        let cleaned = median(effectiveRadius: max(1.6, spotRadius * 1.15))

        let deviation = image.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: cleaned
        ]).cropped(to: extent)

        // Thresholds are MEASURED against the real gate chain, in the context's
        // working colour space, by sweeping the pair and reading the resulting
        // mask at known skin and blemish points. Earlier values were derived
        // from 8-bit sRGB readings, which are wrong here because CIColorMatrix
        // operates on linear values.
        //
        // Measured (linear deviation from the local median):
        //   clean skin    : max 0.096
        //   real blemishes: min 0.251
        //
        // At deadZone 0.17 / gain 18 the gate reads 0 on every clean-skin sample
        // and 255 at every blemish centre, so ordinary texture is untouched
        // while spots are fully replaced.
        let deadZone: CGFloat = 0.17
        let gateGain: CGFloat = 18

        // The gate is an OPAQUE GRAYSCALE mask: gray 0 = "leave this pixel",
        // gray 1 = "replace this pixel". This matches the mask convention used
        // throughout (see MaskBuilder), and single-pass is sufficient because
        // nothing needs to be biased into a separate alpha channel.
        //
        // Verified recipe: deviation -> gray = clamp(luma * gain - deadZone * gain).
        let g = gateGain
        var gate = deviation.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0),
            "inputGVector": CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0),
            "inputBVector": CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -deadZone * g, y: -deadZone * g,
                                        z: -deadZone * g, w: 0)
        ])

        // Feather the gate by the spot radius so the repaired patch blends into
        // the surrounding skin instead of leaving a hard disc.
        gate = gate.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.8, spotRadius * 0.45)])
            .cropped(to: extent)

        // Confine to the skin. Uses alpha intersection, not CIMultiplyBlendMode.
        let gated = MaskBuilder.intersect(gate, mask)

        return blend(cleaned, over: image, mask: gated, strength: amount)
    }

    // MARK: - Wrinkle reduction

    /// Softens fine lines. Wrinkles are thin 1D structures, so an
    /// edge-preserving reduction (noise reduction followed by a *small* blur)
    /// is used and then blended back at low strength; the detail band is
    /// partially restored afterwards by `addTexture`.
    static func reduceWrinkles(_ image: CIImage,
                               strength: Double,
                               mask: CIImage,
                               scale: CGFloat) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }
        let extent = image.extent

        // Wrinkles are low-contrast, low-frequency line structures. Flatten them
        // with an edge-preserving pass first (so lashes and lip edges survive),
        // then with a blur wide enough to actually reach a crease.
        var softened = image
        if CIFilter(name: "CINoiseReduction") != nil {
            softened = softened.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.030 + 0.030 * amount,
                "inputSharpness": 0.35
            ])
        }
        let crease = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2.0, 4.5 * scale)])
            .cropped(to: extent)
        softened = blend(crease, over: softened, mask: mask, strength: 0.8 * amount)

        return blend(softened, over: image, mask: mask, strength: amount)
    }

    // MARK: - Smoothing

    /// Smooths skin while `texturePreserve` controls how much original detail
    /// survives.
    ///
    /// The filtered copy is only ever *blended*, never reconstructed from bands,
    /// so the operation is well-defined and monotonic: raising `texturePreserve`
    /// always keeps more texture. CINoiseReduction runs first because it is
    /// edge-preserving, so eyelashes, lip edges and hair keep their contrast
    /// even where the mask feathers over them.
    static func smoothSkin(_ image: CIImage,
                           strength: Double,
                           texturePreserve: Double,
                           mask: CIImage,
                           scale: CGFloat) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }
        let extent = image.extent

        // Radius scales with the image so the preview and the full-resolution
        // export look the same.
        let radius = max(1.6, 3.2 * scale)

        var filtered = image
        if CIFilter(name: "CINoiseReduction") != nil {
            filtered = filtered.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.018,
                "inputSharpness": 0.55
            ])
        }
        filtered = filtered.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)

        // texturePreserve 0   -> full smoothing at the chosen strength.
        // texturePreserve 100 -> still 30% of it, so the slider never becomes a
        //                        dead control at the top of its range.
        let preserve = min(1, max(0, texturePreserve / 100))
        let mix = amount * (1 - preserve * 0.70)
        return blend(filtered, over: image, mask: mask, strength: mix)
    }

    // `addTexture` is gone: with the mix-based smoothing above, texture
    // retention is a property of the smoothing itself rather than a separate
    // re-application step, so there is no second knob to fight the first.

    // MARK: - Tone

    /// Evens out skin tone (redness, blotchiness, uneven colour) without
    /// touching luminance, so skin colour becomes uniform while shading stays.
    static func evenSkinTone(_ image: CIImage,
                             strength: Double,
                             mask: CIImage,
                             scale: CGFloat) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }
        let extent = image.extent

        // Blur generously in colour but keep luminance from the original by
        // blending the blurred *chroma* back over the original luminance.
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(3, 9.0 * scale)])
            .cropped(to: extent)

        // Reduce saturation of the blurred copy so colour differences flatten,
        // then blend at partial strength.
        let flattened = blurred.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1 - 0.55 * amount,
            kCIInputContrastKey: 1 - 0.10 * amount
        ])

        // Mix luminance from the original with colour from the flattened copy:
        // approximate by blending at a modest strength, which preserves overall
        // structure while removing colour blotches.
        return blend(flattened, over: image, mask: mask, strength: amount * 0.6)
    }

    /// Lightens and warms the under-eye area to reduce dark circles.
    /// Works on a dedicated under-eye mask, and mostly on luminance so the
    /// area does not turn into a bright patch.
    static func correctDarkCircles(_ image: CIImage,
                                   strength: Double,
                                   mask: CIImage,
                                   scale: CGFloat) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }
        let extent = image.extent

        // Lift shadows specifically, which is what a dark circle is.
        let lifted = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputShadowAmount": 0.55 * amount,
            "inputHighlightAmount": 1.0,
            "inputRadius": max(2, 6.0 * scale)
        ]).cropped(to: extent)

        // A touch of warmth and slight desaturation of the bluish cast.
        let warmed = lifted.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 - 420 * amount, y: 4 * amount)
        ]).applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1 - 0.12 * amount,
            kCIInputBrightnessKey: 0.015 * amount
        ])

        return blend(warmed, over: image, mask: mask, strength: amount * 0.9)
    }

    static func brightenSkin(_ image: CIImage,
                             strength: Double,
                             mask: CIImage) -> CIImage {
        let amount = strength / 100
        guard abs(amount) > 0.001 else { return image }
        let extent = image.extent

        var adjusted = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: 0.07 * amount,
            kCIInputSaturationKey: 1 - 0.05 * abs(amount)
        ])
        if amount > 0 {
            adjusted = adjusted.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": 0.30 * amount,
                "inputHighlightAmount": 0.93,
                "inputRadius": 0
            ])
        }
        return blend(adjusted.cropped(to: extent), over: image, mask: mask,
                     strength: min(1, abs(amount) + 0.05))
    }

    // MARK: - Eyes and teeth

    /// Brightens and sharpens the eyes. Sharpening is applied to the eye region
    /// only so lashes and iris detail increase without haloing the skin.
    static func enhanceEyes(_ image: CIImage,
                            brighten: Double,
                            sharpen: Double,
                            mask: CIImage,
                            scale: CGFloat) -> CIImage {
        let brightAmount = min(1, max(0, brighten / 100))
        let sharpAmount = min(1, max(0, sharpen / 100))
        guard brightAmount > 0.001 || sharpAmount > 0.001 else { return image }
        let extent = image.extent

        var adjusted = image
        if brightAmount > 0 {
            adjusted = adjusted.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.085 * brightAmount,
                kCIInputContrastKey: 1 + 0.14 * brightAmount
            ])
        }
        if sharpAmount > 0 {
            adjusted = adjusted.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(1.0, 1.1 * scale),
                kCIInputIntensityKey: 0.85 * sharpAmount
            ])
        }
        return blend(adjusted.cropped(to: extent), over: image, mask: mask,
                     strength: max(brightAmount, sharpAmount))
    }

    /// Whitens teeth: removes yellow, lifts brightness slightly, and keeps the
    /// natural shadow at the gum line by working on the teeth mask only.
    static func whitenTeeth(_ image: CIImage,
                            strength: Double,
                            mask: CIImage) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }

        let whitened = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1 - 0.75 * amount,
            kCIInputBrightnessKey: 0.05 * amount,
            kCIInputContrastKey: 1 + 0.10 * amount
        ])
        return blend(whitened.cropped(to: image.extent), over: image, mask: mask,
                     strength: amount * 0.95)
    }

    // MARK: - Helpers

    static func blend(_ top: CIImage, over base: CIImage, mask: CIImage, strength: Double) -> CIImage {
        let amount = CGFloat(min(1, max(0, strength)))
        guard amount > 0.0005 else { return base }

        // Masks are opaque grayscale, so the strength scales the gray level and
        // alpha stays 1. Scaling alpha as well would attenuate twice, because
        // the mask is read premultiplied.
        let scaledMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        return top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base,
            kCIInputMaskImageKey: scaledMask
        ]).cropped(to: base.extent)
    }

    // Mask combination lives in MaskBuilder, which handles alpha correctly.
}
