import CoreImage
import Foundation
import StudioCore

/// Turns a `LookGrade` into a colour cube, and lays film grain over the
/// result. Both are single passes so a look behaves exactly the same in the
/// preview, the export and a batch run.
enum LookEngine {

    static let cubeDimension = 32

    // MARK: - Levels

    /// Sends the picture's own black and white endpoints to 0 and 1 *without
    /// moving the mid-tones*.
    ///
    /// A plain linear stretch — the textbook histogram move — is what makes an
    /// auto tone look faded: recovering a highlight at 0.86 brightens a face at
    /// 0.50 by the same ratio. So the correction is applied only where the
    /// luminance actually sits, in the band below 0.48 and the band above 0.52,
    /// normalised so that the measured endpoint still lands exactly on 0 and 1
    /// whenever it is inside the band it belongs to. The flat core in between
    /// keeps skin and clothing where the photographer put them.
    ///
    /// A kernel rather than `CIColorMatrix` because Core Image works in linear
    /// light while the endpoints come off a histogram of *displayed* pixels. The
    /// encode/apply/decode below is the same convention the pixel gates in
    /// `MaskBuilder` use, so a black point of 0.06 means the same thing to the
    /// analysis that asked for it and to the renderer that applies it.
    static func applyLevels(_ image: CIImage, black: Double, white: Double) -> CIImage {
        let stretched = abs(black) > 0.001 || abs(white - 1) > 0.001
        guard stretched, let kernel = levelsKernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, black, white])?
            .cropped(to: image.extent) ?? image
    }

    private static let levelsKernel: CIColorKernel? = {
        let source = """
        kernel vec4 toneLevels(__sample s, float black, float white)
        {
            vec3 c = pow(clamp(s.rgb, 0.0, 1.0), vec3(0.4545));
            float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
            float shadowW = 1.0 - smoothstep(0.0, 0.48, l);
            float highlightW = smoothstep(0.52, 1.0, l);
            float shadowK = max(0.30, 1.0 - smoothstep(0.0, 0.48, black));
            float highlightK = max(0.30, smoothstep(0.52, 1.0, white));
            float delta = -black * shadowW / shadowK + (1.0 - white) * highlightW / highlightK;
            c = clamp(c + delta, 0.0, 1.0);
            return vec4(pow(c, vec3(2.2)), 1.0);
        }
        """
        return CIColorKernel(source: source)
    }()

    // MARK: - Split tone

    /// Cool shadows, warm highlights — the classic two-colour grade. Applied on
    /// display values so the split lands where the eye sees the tonality, and
    /// weighted by luminance so the mid-tones keep their balance.
    static func applySplitTone(_ image: CIImage, strength: Double) -> CIImage {
        let amount = min(1, max(0, strength / 100))
        guard amount > 0.001, let kernel = splitToneKernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, amount])?
            .cropped(to: image.extent) ?? image
    }

    private static let splitToneKernel: CIColorKernel? = {
        let source = """
        kernel vec4 splitTone(__sample s, float amount)
        {
            vec3 c = pow(clamp(s.rgb, 0.0, 1.0), vec3(0.4545));
            float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
            float shadows = 1.0 - smoothstep(0.16, 0.52, l);
            float highlights = smoothstep(0.46, 0.86, l);
            c += vec3(-0.012, 0.004, 0.055) * shadows * amount;
            c += vec3(0.048, 0.018, -0.030) * highlights * amount;
            return vec4(pow(clamp(c, 0.0, 1.0), vec3(2.2)), s.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    // MARK: - Tone curve

    /// A three-anchor tone curve applied to luminance only.
    ///
    /// The anchors are shadows, mid-tones and highlights; each one lifts or
    /// lowers a smooth band of the tonal range, and the bands overlap the way a
    /// hand-drawn curve does rather than splitting the histogram into steps.
    /// Scaling RGB by the luminance ratio keeps the photo's colour intact: a
    /// curve is a tonal move, not a saturation move.
    static func applyToneCurve(_ image: CIImage,
                               shadows: Double,
                               midtones: Double,
                               highlights: Double) -> CIImage {
        let s = min(1, max(-1, shadows / 100))
        let m = min(1, max(-1, midtones / 100))
        let h = min(1, max(-1, highlights / 100))
        guard abs(s) > 0.001 || abs(m) > 0.001 || abs(h) > 0.001,
              let kernel = curveKernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, s, m, h])?
            .cropped(to: image.extent) ?? image
    }

    private static let curveKernel: CIColorKernel? = {
        let source = """
        kernel vec4 toneCurve(__sample s, float shadows, float midtones, float highlights)
        {
            vec3 c = pow(clamp(s.rgb, 0.0, 1.0), vec3(0.4545));
            float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
            float wS = exp(-pow((l - 0.14) / 0.18, 2.0));
            float wM = exp(-pow((l - 0.50) / 0.20, 2.0));
            float wH = exp(-pow((l - 0.86) / 0.18, 2.0));
            float delta = 0.26 * shadows * wS + 0.22 * midtones * wM + 0.26 * highlights * wH;
            float nl = clamp(l + delta, 0.0, 1.0);
            float ratio = l > 0.0001 ? nl / l : 1.0;
            c = clamp(c * ratio, 0.0, 1.0);
            return vec4(pow(c, vec3(2.2)), s.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    // MARK: - HSL

    /// Per-hue-band hue, saturation and luminance, the way a colourist targets
    /// "the reds" or "the greens" without touching skin or sky.
    ///
    /// Bands overlap and their weights are normalised by the sum, so a colour
    /// between two centres receives a share of both and the result has no hard
    /// seam where one band ends. Values arrive in -1...1; hue moves up to 30°,
    /// saturation up to 80%, luminance up to 22% of the display range.
    static func applyHSL(_ image: CIImage,
                         hue: [Double],
                         saturation: [Double],
                         luminance: [Double]) -> CIImage {
        let count = HSLBand.allCases.count
        guard hue.count >= count, saturation.count >= count, luminance.count >= count else { return image }
        let active = (0..<count).contains {
            abs(hue[$0]) > 0.001 || abs(saturation[$0]) > 0.001 || abs(luminance[$0]) > 0.001
        }
        guard active, let kernel = hslKernel else { return image }

        func quartet(_ values: [Double]) -> CIVector {
            let v = values.prefix(4).map { min(1, max(-1, $0 / 100)) }
            return CIVector(x: v[0], y: v[1], z: v[2], w: v[3])
        }
        let centers0 = CIVector(x: CGFloat(HSLBand.red.centerHue),
                                y: CGFloat(HSLBand.orange.centerHue),
                                z: CGFloat(HSLBand.yellow.centerHue),
                                w: CGFloat(HSLBand.green.centerHue))
        let centers1 = CIVector(x: CGFloat(HSLBand.cyan.centerHue),
                                y: CGFloat(HSLBand.blue.centerHue),
                                z: CGFloat(HSLBand.purple.centerHue),
                                w: CGFloat(HSLBand.magenta.centerHue))
        let widths0 = CIVector(x: CGFloat(HSLBand.red.halfWidth),
                               y: CGFloat(HSLBand.orange.halfWidth),
                               z: CGFloat(HSLBand.yellow.halfWidth),
                               w: CGFloat(HSLBand.green.halfWidth))
        let widths1 = CIVector(x: CGFloat(HSLBand.cyan.halfWidth),
                               y: CGFloat(HSLBand.blue.halfWidth),
                               z: CGFloat(HSLBand.purple.halfWidth),
                               w: CGFloat(HSLBand.magenta.halfWidth))
        let arguments: [Any] = [
            image,
            centers0, centers1, widths0, widths1,
            quartet(hue), quartet(Array(hue.dropFirst(4))),
            quartet(saturation), quartet(Array(saturation.dropFirst(4))),
            quartet(luminance), quartet(Array(luminance.dropFirst(4)))
        ]
        return kernel.apply(extent: image.extent, arguments: arguments)?
            .cropped(to: image.extent) ?? image
    }

    private static let hslKernel: CIColorKernel? = {
        let source = """
        vec3 rgbToHsl(vec3 c)
        {
            float mx = max(c.r, max(c.g, c.b));
            float mn = min(c.r, min(c.g, c.b));
            float l = (mx + mn) * 0.5;
            float d = mx - mn;
            float h = 0.0;
            float s = 0.0;
            if (d > 0.00001) {
                s = l > 0.5 ? d / max(2.0 - mx - mn, 0.0001) : d / max(mx + mn, 0.0001);
                if (mx == c.r) {
                    h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
                } else if (mx == c.g) {
                    h = (c.b - c.r) / d + 2.0;
                } else {
                    h = (c.r - c.g) / d + 4.0;
                }
                h /= 6.0;
            }
            return vec3(h, s, l);
        }

        float hueChannel(float p, float q, float t)
        {
            if (t < 0.0) { t += 1.0; }
            if (t > 1.0) { t -= 1.0; }
            if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
            if (t < 0.5) { return q; }
            if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
            return p;
        }

        vec3 hslToRgb(vec3 hsl)
        {
            if (hsl.y < 0.00001) { return vec3(hsl.z); }
            float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
            float p = 2.0 * hsl.z - q;
            return vec3(hueChannel(p, q, hsl.x + 1.0 / 3.0),
                        hueChannel(p, q, hsl.x),
                        hueChannel(p, q, hsl.x - 1.0 / 3.0));
        }

        float bandWeight(float hueDeg, float center, float halfWidth)
        {
            float d = abs(mod(hueDeg - center + 540.0, 360.0) - 180.0);
            return 1.0 - smoothstep(halfWidth * 0.55, halfWidth, d);
        }

        kernel vec4 hueBands(__sample s,
                             vec4 centers0, vec4 centers1, vec4 widths0, vec4 widths1,
                             vec4 hue0, vec4 hue1, vec4 sat0, vec4 sat1, vec4 lum0, vec4 lum1)
        {
            vec3 c = pow(clamp(s.rgb, 0.0, 1.0), vec3(0.4545));
            vec3 hsl = rgbToHsl(c);
            float hueDeg = hsl.x * 360.0;

            // No arrays: the kernel language has no dynamic indexing, so the
            // eight bands are unrolled into named weights.
            float w0 = bandWeight(hueDeg, centers0.x, widths0.x);
            float w1 = bandWeight(hueDeg, centers0.y, widths0.y);
            float w2 = bandWeight(hueDeg, centers0.z, widths0.z);
            float w3 = bandWeight(hueDeg, centers0.w, widths0.w);
            float w4 = bandWeight(hueDeg, centers1.x, widths1.x);
            float w5 = bandWeight(hueDeg, centers1.y, widths1.y);
            float w6 = bandWeight(hueDeg, centers1.z, widths1.z);
            float w7 = bandWeight(hueDeg, centers1.w, widths1.w);
            float sum = w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7;
            if (sum < 0.0001) { return s; }

            float dHue = (w0 * hue0.x + w1 * hue0.y + w2 * hue0.z + w3 * hue0.w
                        + w4 * hue1.x + w5 * hue1.y + w6 * hue1.z + w7 * hue1.w) / sum;
            float dSat = (w0 * sat0.x + w1 * sat0.y + w2 * sat0.z + w3 * sat0.w
                        + w4 * sat1.x + w5 * sat1.y + w6 * sat1.z + w7 * sat1.w) / sum;
            float dLum = (w0 * lum0.x + w1 * lum0.y + w2 * lum0.z + w3 * lum0.w
                        + w4 * lum1.x + w5 * lum1.y + w6 * lum1.z + w7 * lum1.w) / sum;

            hsl.x = fract(hsl.x + dHue * (30.0 / 360.0) + 1.0);
            hsl.y = clamp(hsl.y * (1.0 + dSat * 0.80), 0.0, 1.0);
            hsl.z = clamp(hsl.z + dLum * 0.22, 0.0, 1.0);
            vec3 graded = clamp(hslToRgb(hsl), 0.0, 1.0);
            return vec4(pow(graded, vec3(2.2)), s.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    // MARK: - Colour cube

    private static var cache: [String: Data] = [:]
    private static let cacheLock = NSLock()

    /// Cube data for a look blended `strength` of the way toward the identity.
    /// The blend happens here rather than as a second compositing pass, so the
    /// strength slider costs nothing.
    static func cubeData(look: FilmLook, strength: Double) -> Data {
        let t = min(1, max(0, strength))
        let key = "\(look.rawValue)|\(Int((t * 50).rounded()))"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }

        let d = cubeDimension
        let steps = Double(d - 1)
        var floats = [Float](repeating: 0, count: d * d * d * 4)
        var i = 0
        for b in 0..<d {
            for g in 0..<d {
                for r in 0..<d {
                    // A colour cube is sampled in Core Image's linear working
                    // space, but a film grade is something you judge on a
                    // displayed picture, so the grade runs on encoded values
                    // and only the table itself is linear.
                    let linear = SIMD3(Double(r) / steps, Double(g) / steps, Double(b) / steps)
                    let encoded = SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
                    let graded = look.grade.apply(to: encoded)
                    let blended = encoded + (graded - encoded) * t
                    let out = SIMD3(decode(blended.x), decode(blended.y), decode(blended.z))
                    floats[i] = Float(out.x)
                    floats[i + 1] = Float(out.y)
                    floats[i + 2] = Float(out.z)
                    floats[i + 3] = 1
                    i += 4
                }
            }
        }
        // Rebuilding on every slider tick would grow the cache without bound;
        // the working set is a couple of looks, so starting over is cheap.
        if cache.count > 24 { cache.removeAll(keepingCapacity: true) }
        let blob = Data(bytes: floats, count: floats.count * MemoryLayout<Float>.size)
        cache[key] = blob
        return blob
    }

    /// sRGB transfer curve, and its inverse.
    private static func encode(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    private static func decode(_ encoded: Double) -> Double {
        let c = min(1, max(0, encoded))
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func applyLook(_ image: CIImage, look: FilmLook, strength: Double) -> CIImage {
        guard look != .none, strength > 0.001 else { return image }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": cubeData(look: look, strength: strength) as NSData
        ])
    }

    // MARK: - Grain

    /// CIRandomGenerator writes a random value into every channel *and* the
    /// alpha, and Core Image reads those channels unpremultiplied, so the red
    /// channel arrives skewed and the division leaves a tail above white. The
    /// alpha channel is the clean uniform draw: copy it into grey, force the
    /// layer opaque and clamp it, and the flecks stay inside 0...1.
    private static let noiseLayer: CIImage? = {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let grey = random.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
        return grey.applyingFilter("CIMinimumCompositing", parameters: [
            kCIInputImageKey: grey,
            "inputBackgroundImage": white
        ])
    }()

    /// The noise averages 0.69 rather than mid grey, so the multiplier is
    /// centred on that and the picture keeps its density as grain is added.
    private static let noiseMean = 0.69

    /// `amount` is 0...1. The flecks are softened by a radius that tracks image
    /// size so a preview and a full-size export show the same apparent grain.
    static func addGrain(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        guard amount > 0.001, let noise = noiseLayer else { return image }

        let shortSide = min(extent.width, extent.height)
        let radius = min(1.5, max(0, shortSide / 1600 * 0.5))
        var field = noise.cropped(to: extent)
        // A full slider is meant to be a heavy 35 mm push, so the multiplier
        // only spans roughly 0.4...1 at the top of the range.
        var slope = amount * 0.6
        if radius > 0.05 {
            field = field.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                       .cropped(to: extent)
            // Blurring averages neighbours and flattens the flecks; this gives
            // back the contrast the blur removed.
            slope *= 1 + radius
        }
        let bias = 1 - noiseMean * slope
        let layer = field.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: slope, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: slope, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: slope, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ]).cropped(to: extent)

        // Multiplied rather than added: the pipeline works in linear light, so
        // a proportional fleck keeps the same contrast in the shadows as in the
        // highlights.
        guard let mixed = CIFilter(name: "CIMultiplyCompositing", parameters: [
            kCIInputImageKey: image,
            "inputBackgroundImage": layer
        ])?.outputImage else { return image }
        return mixed.cropped(to: extent)
    }
}
