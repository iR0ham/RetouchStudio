import CoreImage
import Foundation

/// Turns a `LookGrade` into a colour cube, and lays film grain over the
/// result. Both are single passes so a look behaves exactly the same in the
/// preview, the export and a batch run.
enum LookEngine {

    static let cubeDimension = 32

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
