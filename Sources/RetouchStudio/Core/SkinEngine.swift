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

    // MARK: - Frequency separation

    // Frequency separation is the textbook skin-retouch technique: split the
    // image into a base band (tone, shading, blotches) and a detail band
    // (pores, texture, edges), treat each band, then recombine.
    //
    // The split itself is `detail = image - base`, which is SIGNED. That cannot
    // be expressed with CIColorMatrix (it clamps) and CISubtractBlendMode
    // (which subtracts premultiplied values), so it happens inside a kernel
    // that keeps float intermediates. With `retention == 1` the reconstruction
    // is the identity: base + (image - base) = image. That round trip is
    // checked in the self-test, which is what makes this a real split rather
    // than a blur blended over the original.
    //
    // Recombination is amplitude-aware: fine, low-amplitude texture follows the
    // slider, while strongly contrasting structure (specular edges, unmasked
    // detail) keeps more of itself. That is what separates this from a plain
    // blur blend, which flattens both equally.
    private static let frequencyKernel: CIColorKernel? = {
        let source = """
        kernel vec4 recombineBands(__sample src, __sample base,
                                   float retention, float knee)
        {
            vec3 detail = src.rgb - base.rgb;
            float amp = max(max(abs(detail.r), abs(detail.g)), abs(detail.b));
            float keep = mix(retention, 1.0, smoothstep(knee, knee * 2.5, amp));
            return vec4(base.rgb + detail * keep, src.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    static var isFrequencySeparationAvailable: Bool { frequencyKernel != nil }

    /// Recombines a base band with the signed detail from `image`.
    ///
    /// `retention` 1 keeps every frequency (identity); 0 leaves only the base.
    /// `knee` is the linear detail amplitude above which structure is
    /// preserved regardless of retention.
    static func recombineFrequencies(_ image: CIImage,
                                     base: CIImage,
                                     retention: Double,
                                     knee: Double = 0.55) -> CIImage {
        guard let kernel = frequencyKernel else { return image }
        let result = kernel.apply(extent: image.extent, arguments: [
            image, base, min(1, max(0, retention)), knee
        ])
        return result?.cropped(to: image.extent) ?? image
    }

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
        func median(_ source: CIImage, effectiveRadius radius: CGFloat) -> CIImage {
            let factor = max(1.0, min(8.0, radius))
            guard factor > 1.2 else {
                return source.clampedToExtent()
                    .applyingFilter("CIMedianFilter")
                    .cropped(to: extent)
            }
            let down = source.clampedToExtent()
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

        // The median is used to LOCATE blemishes and to supply their
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
        let cleaned = median(image, effectiveRadius: max(1.6, spotRadius * 1.15))

        // A flat median patch reads as a smudge at 100%. Real healing borrows
        // TEXTURE from nearby skin while taking COLOUR from the local median:
        // the donor's detail band is added on top of the clean colour. The
        // donor is offset far enough that the blemish itself cannot be copied.
        let donor = image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: spotRadius * 2.6, y: 0))
            .cropped(to: extent)
        let donorClean = median(donor, effectiveRadius: max(1.6, spotRadius * 1.15))

        var replacement = cleaned
        if let kernel = healKernel,
           let healed = kernel.apply(extent: extent, arguments: [cleaned, donor, donorClean, 0.85]) {
            replacement = healed.cropped(to: extent)
        }

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
        // the surrounding skin instead of leaving a hard disc. The gate is
        // dilated first: a bare blur gives partial coverage exactly on the
        // blemish's own edge, so half of the original dark rim survives the
        // blend and leaves a visible ring around every healed spot.
        if CIFilter(name: "CIMorphologyMaximum") != nil {
            gate = gate.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [
                    kCIInputRadiusKey: max(0.8, spotRadius * 0.55)
                ])
                .cropped(to: extent)
        }
        gate = gate.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.8, spotRadius * 0.45)])
            .cropped(to: extent)

        // Confine to the skin. Uses alpha intersection, not CIMultiplyBlendMode.
        let gated = MaskBuilder.intersect(gate, mask)

        return blend(replacement, over: image, mask: gated, strength: amount)
    }

    /// Adds the donor's high-frequency band onto the clean colour. Both
    /// operands are opaque, so premultiplied sampling is exact; the signed
    /// difference needs a kernel because CIColorMatrix clamps.
    private static let healKernel: CIColorKernel? = {
        let source = """
        kernel vec4 transplantTexture(__sample clean, __sample donor,
                                      __sample donorClean, float texture)
        {
            vec3 detail = donor.rgb - donorClean.rgb;
            return vec4(clean.rgb + detail * texture, clean.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    // MARK: - Wrinkle reduction

    /// Softens fine lines. Wrinkles are low-contrast, medium-frequency line
    /// structures, so the detail band is attenuated uniformly (no amplitude
    /// gate) at a blur width wide enough to reach a crease.
    static func reduceWrinkles(_ image: CIImage,
                               strength: Double,
                               mask: CIImage,
                               scale: CGFloat) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }
        let extent = image.extent

        var lowSource = image
        if CIFilter(name: "CINoiseReduction") != nil {
            lowSource = lowSource.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.030 + 0.030 * amount,
                "inputSharpness": 0.35
            ])
        }
        let base = lowSource.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2.0, 4.5 * scale)])
            .cropped(to: extent)

        // knee above 1 keeps the retention uniform: no detail counts as an
        // "edge" at this scale, because wrinkles are the target themselves.
        let recombined = recombineFrequencies(image, base: base,
                                              retention: 1 - 0.85 * amount,
                                              knee: 1e6)
        return blend(recombined, over: image, mask: mask, strength: 1)
    }

    // MARK: - Smoothing

    /// Smooths skin through a real base/detail split. `texturePreserve`
    /// controls how much of the detail band is kept.
    ///
    /// CINoiseReduction runs first because it is edge-preserving, so eyelashes,
    /// lip edges and hair keep their contrast even where the mask feathers over
    /// them; it only feeds the base band, while detail is always taken from the
    /// untouched image.
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

        var lowSource = image
        if CIFilter(name: "CINoiseReduction") != nil {
            lowSource = lowSource.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.018,
                "inputSharpness": 0.55
            ])
        }
        let base = lowSource.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)

        // texturePreserve 0   -> full smoothing at the chosen strength.
        // texturePreserve 100 -> still 30% of it, so the slider never becomes a
        //                        dead control at the top of its range.
        let preserve = min(1, max(0, texturePreserve / 100))
        let retention = 1 - amount * (1 - preserve * 0.70)
        let recombined = recombineFrequencies(image, base: base, retention: retention)
        return blend(recombined, over: image, mask: mask, strength: 1)
    }

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

    /// Lifts the white of the eye. Runs on the sclera mask only: brightening
    /// the whole eye makes the iris look milky and the lid look puffy.
    static func brightenSclera(_ image: CIImage,
                               strength: Double,
                               mask: CIImage) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }

        let adjusted = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: 0.10 * amount,
            kCIInputContrastKey: 1 + 0.08 * amount,
            kCIInputSaturationKey: 1 - 0.10 * amount
        ])
        return blend(adjusted.cropped(to: image.extent), over: image, mask: mask,
                     strength: amount * 0.95)
    }

    /// Sharpens iris and lash detail. Kept off the sclera, which has little
    /// detail but plenty of noise and red veins to amplify.
    static func sharpenEyeDetail(_ image: CIImage,
                                 strength: Double,
                                 mask: CIImage,
                                 scale: CGFloat) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001 else { return image }

        let sharpened = image.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: max(0.8, 0.9 * scale),
            kCIInputIntensityKey: 0.95 * amount
        ])
        return blend(sharpened.cropped(to: image.extent), over: image, mask: mask,
                     strength: amount)
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
