import AppKit
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

// Deterministic golden-corpus fixtures and measurement helpers.
//
// Everything here is procedural: no third-party pixels, no camera files, no
// personal photos. The generator is seeded, so the same source file produces
// the same fixture on every run. The repository license covers the output.

let corpusRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RETOUCH_CORPUS_DIR"] ?? "Tests/Corpus", isDirectory: true)
let fixturesDir = corpusRoot.appendingPathComponent("Fixtures", isDirectory: true)
let referencesDir = corpusRoot.appendingPathComponent("References", isDirectory: true)
let exportsDir = corpusRoot.appendingPathComponent("Exports", isDirectory: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let graySpace = CGColorSpaceCreateDeviceGray()

let processor = ImageProcessor.shared

// MARK: - Deterministic randomness

struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func range(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    mutating func int(_ upper: Int) -> Int {
        upper <= 0 ? 0 : Int(next() % UInt64(upper))
    }
}

// MARK: - Hashing and image access

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fileSHA(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "missing" }
    return sha256(data)
}

func colorSpaceName(_ space: CGColorSpace?) -> String {
    guard let space else { return "none" }
    if let name = space.name { return name as String }
    return "unnamed-\(space.model.rawValue)"
}

func writeImage(_ image: CGImage, to url: URL, type: UTType,
                properties: [CFString: Any] = [:]) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, type.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image,
                               properties.isEmpty ? nil : properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

func decodeImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Encodes in memory with the same ImageIO path used to write fixtures, so a
/// lossy fixture can be checked for repeatable encoding rather than for being
/// lossless.
func encodeImage(_ image: CGImage, type: UTType,
                 properties: [CFString: Any] = [:]) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image,
                               properties.isEmpty ? nil : properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

func decodeImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func imageProperties(_ url: URL) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return [:] }
    return properties
}

/// Decoded identity: dimensions, storage depth, colour space and the bytes the
/// decoder hands back. Used to prove a generated fixture is reproducible
/// without depending on the encoder's byte-for-byte output.
func decodedKey(_ image: CGImage) -> String {
    var key = "\(image.width)x\(image.height)|bpc=\(image.bitsPerComponent)|bpp=\(image.bitsPerPixel)|cs=\(colorSpaceName(image.colorSpace))|"
    if let data = image.dataProvider?.data {
        key += sha256(data as Data)
    }
    return key
}

/// A canonical premultiplied RGBA8 copy of an image, used for hashes and
/// metrics. Drawing into the image's own colour space keeps P3 fixtures in P3;
/// two images from the same fixture are therefore always compared like for like.
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

func pixels(of image: CGImage) -> Pixels? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = image.colorSpace ?? sRGB
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return ok ? Pixels(width: width, height: height, bytes: bytes) : nil
}

func pixelDigest(_ pixels: Pixels, colorSpace: String, bits: Int = 8) -> String {
    var data = Data("\(pixels.width)x\(pixels.height)|\(colorSpace)|\(bits)|".utf8)
    data.append(contentsOf: pixels.bytes)
    return sha256(data)
}

/// Samples one pixel with a top-left origin, the orientation a viewer sees.
/// For lossy fixtures (JPEG) the caller applies a tolerance.
func sampleTopLeft(_ image: CGImage, _ nx: Double, _ ny: Double) -> (r: Int, g: Int, b: Int, a: Int) {
    let x = max(0, min(image.width - 1, Int(nx * Double(image.width))))
    let y = max(0, min(image.height - 1, Int(ny * Double(image.height))))
    guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
        return (-1, -1, -1, -1)
    }
    var bytes = [UInt8](repeating: 0, count: 4)
    _ = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
}

func near(_ sample: (r: Int, g: Int, b: Int, a: Int),
          _ r: Int, _ g: Int, _ b: Int, tolerance: Int) -> Bool {
    abs(sample.r - r) <= tolerance && abs(sample.g - g) <= tolerance && abs(sample.b - b) <= tolerance
}

// MARK: - Metrics

struct DiffMetrics {
    let mae: Double
    let rmse: Double
    let maxError: Int
    let psnr: Double
    let ssim: Double
    let changedFraction: Double
    let alphaMAE: Double
    let deltaE76Mean: Double
    let deltaE76Max: Double
}

func comparePixels(_ a: Pixels, _ b: Pixels) -> DiffMetrics? {
    guard a.width == b.width, a.height == b.height else { return nil }
    let count = a.width * a.height
    guard count > 0 else { return nil }

    var sum = 0.0
    var sumSquares = 0.0
    var maxError = 0
    var changed = 0
    var alphaSum = 0.0
    var deltaESum = 0.0
    var deltaEMax = 0.0
    var deltaECount = 0
    var lumaA = [Double](repeating: 0, count: count)
    var lumaB = [Double](repeating: 0, count: count)

    for index in 0..<count {
        let offset = index * 4
        let r1 = Double(a.bytes[offset]), g1 = Double(a.bytes[offset + 1]), b1 = Double(a.bytes[offset + 2])
        let r2 = Double(b.bytes[offset]), g2 = Double(b.bytes[offset + 1]), b2 = Double(b.bytes[offset + 2])
        let d0 = abs(r1 - r2), d1 = abs(g1 - g2), d2 = abs(b1 - b2)
        sum += d0 + d1 + d2
        sumSquares += d0 * d0 + d1 * d1 + d2 * d2
        let pixelMax = Int(max(d0, max(d1, d2)))
        maxError = max(maxError, pixelMax)
        if pixelMax >= 1 { changed += 1 }
        alphaSum += abs(Double(a.bytes[offset + 3]) - Double(b.bytes[offset + 3]))
        lumaA[index] = 0.2126 * r1 + 0.7152 * g1 + 0.0722 * b1
        lumaB[index] = 0.2126 * r2 + 0.7152 * g2 + 0.0722 * b2

        if index % 3 == 0 {
            let la = lab(r1 / 255, g1 / 255, b1 / 255)
            let lb = lab(r2 / 255, g2 / 255, b2 / 255)
            let de = sqrt(pow(la.L - lb.L, 2) + pow(la.a - lb.a, 2) + pow(la.b - lb.b, 2))
            deltaESum += de
            deltaEMax = max(deltaEMax, de)
            deltaECount += 1
        }
    }

    let channels = Double(count * 3)
    let mae = sum / channels
    let mse = sumSquares / channels
    let psnr = mse <= 1e-12 ? 99.0 : min(99.0, max(0.0, 10 * log10(255 * 255 / mse)))
    return DiffMetrics(mae: mae, rmse: sqrt(mse), maxError: maxError, psnr: psnr,
                       ssim: ssim(lumaA, lumaB, width: a.width, height: a.height),
                       changedFraction: Double(changed) / Double(count),
                       alphaMAE: alphaSum / Double(count),
                       deltaE76Mean: deltaECount > 0 ? deltaESum / Double(deltaECount) : 0,
                       deltaE76Max: deltaEMax)
}

/// Global mean SSIM over non-overlapping 8x8 luma windows. Deliberately simple
/// and documented as such; MS-SSIM is not implemented here.
func ssim(_ a: [Double], _ b: [Double], width: Int, height: Int) -> Double {
    let window = 8
    guard width >= window, height >= window else { return 1 }
    let c1 = pow(0.01 * 255.0, 2.0)
    let c2 = pow(0.03 * 255.0, 2.0)
    var total = 0.0
    var windows = 0.0
    var y = 0
    while y + window <= height {
        var x = 0
        while x + window <= width {
            let n = Double(window * window)
            var meanA = 0.0, meanB = 0.0
            for yy in 0..<window {
                let row = (y + yy) * width + x
                for xx in 0..<window {
                    meanA += a[row + xx]
                    meanB += b[row + xx]
                }
            }
            meanA /= n; meanB /= n
            var varA = 0.0, varB = 0.0, covariance = 0.0
            for yy in 0..<window {
                let row = (y + yy) * width + x
                for xx in 0..<window {
                    let da = a[row + xx] - meanA
                    let db = b[row + xx] - meanB
                    varA += da * da
                    varB += db * db
                    covariance += da * db
                }
            }
            varA /= n; varB /= n; covariance /= n
            let numerator = (2 * meanA * meanB + c1) * (2 * covariance + c2)
            let denominator = (meanA * meanA + meanB * meanB + c1) * (varA + varB + c2)
            total += denominator == 0 ? 1 : numerator / denominator
            windows += 1
            x += window
        }
        y += window
    }
    return windows > 0 ? total / windows : 1
}

/// CIE L*a*b* (D65) from encoded sRGB. Colorimetric only for sRGB fixtures;
/// P3 captures are compared in encoded RGB and reported as such.
func lab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
    func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let rr = linear(r), gg = linear(g), bb = linear(b)
    let x = (0.4124564 * rr + 0.3575761 * gg + 0.1804375 * bb) / 0.95047
    let y = 0.2126729 * rr + 0.7151522 * gg + 0.0721750 * bb
    let z = (0.0193339 * rr + 0.1191920 * gg + 0.9503041 * bb) / 1.08883
    func f(_ t: Double) -> Double {
        t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
    }
    let fx = f(x), fy = f(y), fz = f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

// MARK: - Drawing helpers

func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

func p3Color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: p3, components: [r, g, b, a])!
}

func gray(_ value: Double, _ a: Double = 1) -> CGColor {
    CGColor(gray: value, alpha: a)
}

func makeContext(width: Int, height: Int, space: CGColorSpace = sRGB,
                 bits: Int = 8, alpha: Bool = true) -> CGContext? {
    CGContext(data: nil, width: width, height: height,
              bitsPerComponent: bits, bytesPerRow: 0, space: space,
              bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast
                                 : CGImageAlphaInfo.noneSkipLast).rawValue)
}

func fill(_ context: CGContext, _ rect: CGRect, _ color: CGColor, alpha: Double = 1) {
    context.saveGState()
    context.setAlpha(CGFloat(alpha))
    context.setFillColor(color)
    context.fill(rect)
    context.restoreGState()
}

func fillEllipse(_ context: CGContext, _ rect: CGRect, _ color: CGColor, alpha: Double = 1) {
    context.saveGState()
    context.setAlpha(CGFloat(alpha))
    context.setFillColor(color)
    context.fillEllipse(in: rect)
    context.restoreGState()
}

func fillRounded(_ context: CGContext, _ rect: CGRect, radius: CGFloat,
                 _ color: CGColor, alpha: Double = 1) {
    context.saveGState()
    context.setAlpha(CGFloat(alpha))
    context.setFillColor(color)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
    context.fillPath()
    context.restoreGState()
}

func verticalGradient(_ context: CGContext, _ rect: CGRect,
                      top: CGColor, bottom: CGColor) {
    guard let gradient = CGGradient(colorsSpace: sRGB,
                                    colors: [top, bottom] as CFArray,
                                    locations: [0, 1]) else { return }
    context.saveGState()
    context.clip(to: rect)
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
    context.restoreGState()
}

func radialGlow(_ context: CGContext, center: CGPoint, radius: CGFloat,
                inner: CGColor, outer: CGColor) {
    guard let gradient = CGGradient(colorsSpace: sRGB,
                                    colors: [inner, outer] as CFArray,
                                    locations: [0, 1]) else { return }
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
}

func drawVignette(_ context: CGContext, size: CGSize, strength: Double) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    radialGlow(context, center: center, radius: hypot(size.width, size.height) / 2,
               inner: rgba(0, 0, 0, 0), outer: rgba(0, 0, 0, strength))
}

func addNoise(_ context: CGContext, amplitude: Double, seed: UInt64) {
    guard let base = context.data, context.bitsPerComponent == 8 else { return }
    let width = context.width
    let height = context.height
    let rowBytes = context.bytesPerRow
    let bytesPerPixel = context.bitsPerPixel / 8
    guard bytesPerPixel >= 3 else { return }
    let pointer = base.assumingMemoryBound(to: UInt8.self)
    var rng = SeededRNG(seed: seed)
    for y in 0..<height {
        let row = y * rowBytes
        for x in 0..<width {
            let offset = row + x * bytesPerPixel
            // `amplitude` is a level count on the 0...255 scale, not a fraction.
            let delta = Int(((rng.unit() - 0.5) * 2 * amplitude).rounded())
            for channel in 0..<3 {
                pointer[offset + channel] = UInt8(clamping: Int(pointer[offset + channel]) + delta)
            }
        }
    }
}

// MARK: - Face geometry and portrait drawing

/// The same landmark layout the engine's synthetic tests use, expressed as
/// fractions of a face box so a portrait can sit anywhere in the frame. The
/// mouth is drawn as a natural open smile and the nose carries a crest, which
/// the reshape engine needs for `noseTip` (Vision supplies one per real face).
func faceGeometry(box: CGRect) -> FaceGeometry {
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: box.minX + x * box.width,
               y: box.minY + y * box.height,
               width: w * box.width, height: h * box.height)
    }
    func poly(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
    }
    let nose = poly(rect(0.421875, 0.375, 0.15625, 0.125))
    return FaceGeometry(
        boundingBox: box,
        faceContour: poly(box),
        leftEye: poly(rect(0.1875, 0.59375, 0.21875, 0.109375)),
        rightEye: poly(rect(0.59375, 0.59375, 0.21875, 0.109375)),
        leftPupil: [],
        rightPupil: [],
        leftEyebrow: poly(rect(0.171875, 0.734375, 0.25, 0.046875)),
        rightEyebrow: poly(rect(0.578125, 0.734375, 0.25, 0.046875)),
        outerLips: poly(rect(0.34, 0.115, 0.32, 0.115)),
        innerLips: poly(rect(0.36, 0.135, 0.28, 0.09)),
        nose: nose,
        noseCrest: [point(0.50, 0.375), point(0.50, 0.43), point(0.50, 0.49)],
        medianLine: [point(0.50, 0.50), point(0.50, 0.72)],
        hasLandmarks: true)
}

struct PortraitPalette {
    let skin: CGColor
    let shadow: CGColor
    let hair: CGColor
    let clothing: CGColor
    let lip: CGColor
    let iris: CGColor
    let teeth: CGColor
    let backgroundTop: CGColor
    let backgroundBottom: CGColor
}

let lightPalette = PortraitPalette(
    skin: rgba(0.86, 0.72, 0.64), shadow: rgba(0.46, 0.30, 0.26),
    hair: rgba(0.16, 0.11, 0.09), clothing: rgba(0.16, 0.28, 0.32),
    lip: rgba(0.60, 0.30, 0.32), iris: rgba(0.25, 0.38, 0.40),
    teeth: rgba(0.93, 0.90, 0.80),
    backgroundTop: rgba(0.24, 0.28, 0.34), backgroundBottom: rgba(0.44, 0.48, 0.54))

let deepPalette = PortraitPalette(
    skin: rgba(0.42, 0.28, 0.22), shadow: rgba(0.18, 0.10, 0.08),
    hair: rgba(0.06, 0.05, 0.05), clothing: rgba(0.12, 0.10, 0.16),
    lip: rgba(0.42, 0.18, 0.20), iris: rgba(0.18, 0.24, 0.26),
    teeth: rgba(0.88, 0.85, 0.76),
    backgroundTop: rgba(0.05, 0.06, 0.09), backgroundBottom: rgba(0.14, 0.12, 0.14))

/// The three manual-heal sites, in top-left normalized photo coordinates so
/// the same values can be handed to `HealSpot` without a flip.
let f01HealSpots: [CGPoint] = [
    CGPoint(x: 0.40, y: 0.38),
    CGPoint(x: 0.55, y: 0.30),
    CGPoint(x: 0.47, y: 0.55),
]

func drawEye(_ context: CGContext, rect: CGRect, palette: PortraitPalette, size: CGSize) {
    fillEllipse(context, rect, rgba(0.97, 0.97, 0.95))
    let radius = rect.height * 0.42
    let iris = CGRect(x: rect.midX - radius, y: rect.midY - radius,
                      width: radius * 2, height: radius * 2)
    fillEllipse(context, iris, palette.iris)
    let pupilRadius = radius * 0.45
    fillEllipse(context, CGRect(x: rect.midX - pupilRadius, y: rect.midY - pupilRadius,
                                width: pupilRadius * 2, height: pupilRadius * 2),
                rgba(0.06, 0.06, 0.07))
    let glint = radius * 0.20
    fillEllipse(context, CGRect(x: rect.midX - radius * 0.30 - glint,
                                y: rect.midY + radius * 0.25 - glint,
                                width: glint * 2, height: glint * 2), rgba(1, 1, 1))
    context.saveGState()
    context.setStrokeColor(palette.hair)
    // Both lids carry a lash line: a single thin stroke covers too few pixels
    // for the engine's per-eye gate-coverage check at portrait scale.
    context.setLineWidth(max(2.0, rect.height * 0.26))
    context.move(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.10))
    context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.03))
    context.strokePath()
    context.setLineWidth(max(1.5, rect.height * 0.10))
    context.move(to: CGPoint(x: rect.minX + rect.width * 0.10,
                             y: rect.minY + rect.height * 0.07))
    context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.10,
                                y: rect.minY + rect.height * 0.04))
    context.strokePath()
    context.restoreGState()
    _ = size
}

func drawPortrait(_ context: CGContext, size: CGSize, box: CGRect,
                  palette: PortraitPalette, seed: UInt64, lowKey: Bool) {
    let width = size.width
    let height = size.height
    func px(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * width, y: rect.minY * height,
               width: rect.width * width, height: rect.height * height)
    }
    let face = faceGeometry(box: box)

    verticalGradient(context, CGRect(origin: .zero, size: size),
                     top: palette.backgroundTop, bottom: palette.backgroundBottom)
    if !lowKey {
        radialGlow(context, center: CGPoint(x: box.midX * width, y: box.maxY * height),
                   radius: max(width, height) * 0.55,
                   inner: rgba(0.95, 0.88, 0.78, 0.16), outer: rgba(0.95, 0.88, 0.78, 0))
    }
    drawVignette(context, size: size, strength: lowKey ? 0.55 : 0.30)

    // Shoulders and neck sit behind the head.
    fillEllipse(context, px(CGRect(x: box.minX - 0.28, y: -0.16,
                                   width: box.width + 0.56, height: box.minY + 0.24)),
                palette.clothing)
    fill(context, px(CGRect(x: box.midX - box.width * 0.13, y: box.minY - 0.08,
                            width: box.width * 0.26, height: box.height * 0.14)),
         palette.skin)
    // Fabric weave on the shoulder band.
    context.saveGState()
    context.setStrokeColor(rgba(1, 1, 1, 0.055))
    context.setLineWidth(1)
    var weave = 0.0
    while weave < width {
        context.move(to: CGPoint(x: weave, y: 0))
        context.addLine(to: CGPoint(x: weave + height * 0.25, y: height * 0.22))
        weave += 7
    }
    context.strokePath()
    context.restoreGState()

    // Hair behind the face.
    fillEllipse(context, px(face.hairRect), palette.hair)
    for side in face.hairSideRects {
        fillEllipse(context, px(side), palette.hair)
    }

    // Ears.
    fillEllipse(context, px(CGRect(x: box.minX - box.width * 0.085,
                                   y: box.minY + box.height * 0.43,
                                   width: box.width * 0.14, height: box.height * 0.18)),
                palette.skin)
    fillEllipse(context, px(CGRect(x: box.maxX - box.width * 0.055,
                                   y: box.minY + box.height * 0.43,
                                   width: box.width * 0.14, height: box.height * 0.18)),
                palette.skin)

    // Face with directional shading, pores and speculars clipped to it.
    fillEllipse(context, px(box), palette.skin)
    context.saveGState()
    context.addEllipse(in: px(box))
    context.clip()
    fillEllipse(context, px(CGRect(x: box.minX - box.width * 0.25,
                                   y: box.minY - box.height * 0.10,
                                   width: box.width * 0.70, height: box.height * 0.95)),
                palette.shadow, alpha: 0.22)
    var poreRNG = SeededRNG(seed: seed &+ 1)
    let area = box.width * width * box.height * height
    let pores = min(12_000, max(2_000, Int(area / 18)))
    for _ in 0..<pores {
        let nx = box.minX + poreRNG.range(0.03, 0.97) * box.width
        let ny = box.minY + poreRNG.range(0.03, 0.97) * box.height
        let tone = poreRNG.range(-0.07, 0.07)
        let color = CGColor(colorSpace: sRGB,
                            components: [clamp01(0.86 + tone), clamp01(0.72 + tone),
                                         clamp01(0.64 + tone), 1])!
        fill(context, CGRect(x: nx * width, y: ny * height, width: 1.3, height: 1.3), color)
    }
    fillEllipse(context, px(CGRect(x: box.minX + box.width * 0.16, y: box.minY + box.height * 0.66,
                                   width: box.width * 0.20, height: box.height * 0.10)),
                rgba(1, 1, 1), alpha: lowKey ? 0.20 : 0.16)
    fillEllipse(context, px(CGRect(x: box.minX + box.width * 0.10, y: box.minY + box.height * 0.30,
                                   width: box.width * 0.18, height: box.height * 0.12)),
                rgba(1, 1, 1), alpha: 0.10)
    context.restoreGState()

    // Blemishes, converted from the top-left coordinates the heal brush uses.
    for spot in f01HealSpots {
        let y = 1 - spot.y
        fillEllipse(context, px(CGRect(x: spot.x - 0.011, y: y - 0.011,
                                       width: 0.022, height: 0.022)),
                    palette.shadow, alpha: 0.90)
    }

    // Brows.
    for brow in [face.leftEyebrow, face.rightEyebrow] {
        let rect = px(FaceGeometry.boundingBox(of: brow)).insetBy(dx: -0.6, dy: -0.6)
        fillRounded(context, rect, radius: rect.height * 0.45, palette.hair)
    }
    // Under-eye bands.
    for eye in [face.leftEyeRect, face.rightEyeRect] {
        let band = CGRect(x: eye.minX, y: eye.minY - eye.height * 0.55,
                          width: eye.width, height: eye.height * 0.48)
        fillEllipse(context, px(band), palette.shadow, alpha: 0.30)
    }
    // Fine lines near the eye corners and on the forehead.
    context.saveGState()
    context.setStrokeColor(palette.shadow)
    context.setAlpha(0.45)
    context.setLineWidth(1.0)
    for eye in [face.leftEyeRect, face.rightEyeRect] {
        for index in 0..<3 {
            let x0 = eye.maxX + eye.width * 0.04
            let y0 = eye.midY - eye.height * 0.10 + CGFloat(index) * 2.2
            context.move(to: CGPoint(x: x0, y: y0))
            context.addLine(to: CGPoint(x: x0 + eye.width * 0.22, y: y0 + 1.5))
        }
    }
    for index in 0..<4 {
        let y = box.minY + box.height * (0.80 + CGFloat(index) * 0.025)
        context.move(to: CGPoint(x: box.minX + box.width * 0.30, y: y))
        context.addLine(to: CGPoint(x: box.minX + box.width * 0.70, y: y + 1.0))
    }
    context.strokePath()
    context.restoreGState()

    // Nose shading: bridge light, side shadow, nostrils.
    fillEllipse(context, px(CGRect(x: face.noseRect.minX + face.noseRect.width * 0.12,
                                   y: face.noseRect.minY - face.noseRect.height * 0.35,
                                   width: face.noseRect.width * 0.28,
                                   height: face.noseRect.height * 0.55)),
                palette.shadow, alpha: 0.22)
    let noseBox = FaceGeometry.boundingBox(of: face.nose)
    fillEllipse(context, px(CGRect(x: noseBox.midX - noseBox.width * 0.09,
                                   y: noseBox.minY + noseBox.height * 0.28,
                                   width: noseBox.width * 0.18,
                                   height: noseBox.height * 0.62)),
                rgba(1, 1, 1), alpha: 0.12)
    for side in [-1.0, 1.0] {
        let centerX = noseBox.midX + CGFloat(side) * noseBox.width * 0.20
        fillEllipse(context, px(CGRect(x: centerX - noseBox.width * 0.06,
                                       y: noseBox.minY + noseBox.height * 0.05,
                                       width: noseBox.width * 0.12,
                                       height: noseBox.height * 0.10)),
                    palette.shadow, alpha: 0.75)
    }

    // Mouth: lips, dark opening, enamel with two gaps for teeth alignment.
    if let lips = face.lipRect {
        fillEllipse(context, px(lips), palette.lip)
    }
    if let inner = face.innerLipRect {
        fillEllipse(context, px(inner), rgba(0.20, 0.08, 0.10))
    }
    if let teeth = face.teethRect {
        fill(context, px(teeth), palette.teeth)
        context.saveGState()
        context.setStrokeColor(rgba(0.45, 0.40, 0.32))
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: teeth.midX * width, y: teeth.minY * height))
        context.addLine(to: CGPoint(x: teeth.midX * width, y: teeth.maxY * height))
        context.strokePath()
        context.restoreGState()
    }

    // Eyes last so lashes stay crisp.
    for eye in [face.leftEyeRect, face.rightEyeRect] {
        drawEye(context, rect: px(eye), palette: palette, size: size)
    }
}

func clamp01(_ value: Double) -> Double {
    min(1, max(0, value))
}

// MARK: - Fixture builders

struct FixtureSpec {
    let id: String
    let file: String
    let purpose: String
    let characteristics: String
    let operations: String
    let necessity: String
}

let fixtureSpecs: [FixtureSpec] = [
    FixtureSpec(id: "F01_PORTRAIT_SRGB_8", file: "F01_portrait_srgb_8.png",
                purpose: "Baseline portrait for local retouch and global colour.",
                characteristics: "512x512, 8-bit sRGB, one synthetic face with landmarks, pores, blemishes, teeth, hair, fabric.",
                operations: "skin, eyes, teeth, makeup, reshape, healing, global colour, stickers, analysis overlay.",
                necessity: "Every face-masked operation needs one shared, reproducible subject."),
    FixtureSpec(id: "F02_PORTRAIT_DEEP_LOWKEY", file: "F02_portrait_deep_lowkey.png",
                purpose: "Deep skin tone under low-key light.",
                characteristics: "512x512, 8-bit sRGB, deep tone, dark background, visible shadow noise.",
                operations: "skin brightening, tone evening, under-eye, exposure, highlight/shadow, clarity.",
                necessity: "Colour and tone controls must not be calibrated on light skin only."),
    FixtureSpec(id: "F03_PORTRAIT_LANDSCAPE", file: "F03_portrait_landscape.png",
                purpose: "Off-centre subject in a wide frame.",
                characteristics: "768x432, 8-bit sRGB, 16:9 landscape, subject on the left, sky gradient and bokeh.",
                operations: "background blur/fill/remove, watermark, person tools, crop/aspect mapping.",
                necessity: "Background and batch behaviour depends on an off-centre subject in a non-square frame."),
    FixtureSpec(id: "F04_DETAIL_CHART", file: "F04_detail_chart.png",
                purpose: "High-frequency structure and colour patches.",
                characteristics: "512x512, 8-bit sRGB, line pairs, checkerboards, weave, colour patches, smooth ramp.",
                operations: "clarity, sharpening, blur, saturation, HSL, grain comparison.",
                necessity: "Texture-preserving operations need measurable fine detail, not only skin."),
    FixtureSpec(id: "F05_GRADIENT_SKY", file: "F05_gradient_sky.png",
                purpose: "Smooth gradients and a highlight.",
                characteristics: "768x384, 8-bit sRGB, vertical sky gradient, sun disc, no noise.",
                operations: "exposure, levels, contrast, curves, split tone, banding checks.",
                necessity: "Tonal operations are judged on smooth ramps where banding is visible."),
    FixtureSpec(id: "F06_HIGHLIGHTS_SHADOWS", file: "F06_highlights_shadows.png",
                purpose: "Clipped highlights, deep shadows and a grey ramp.",
                characteristics: "640x480, 8-bit sRGB, split exposure, clipped white patch, 256-step ramp, colour checker.",
                operations: "highlight recovery, shadow lift, whites/blacks, vignette, auto colour and light.",
                necessity: "Endpoint recovery and clipping behaviour need known clipped and near-black regions."),
    FixtureSpec(id: "F07_LOWLIGHT_NOISE", file: "F07_lowlight_noise.png",
                purpose: "Low light with deterministic luminance noise.",
                characteristics: "512x384, 8-bit sRGB, dark scene, seeded +/-18 level noise, dim highlight.",
                operations: "clarity, noise reduction side effects, grain, exposure lift.",
                necessity: "Noise handling must be visible in a controlled, repeatable frame."),
    FixtureSpec(id: "F08_HIGHRES_PORTRAIT", file: "F08_highres_portrait.png",
                purpose: "Full-resolution behaviour.",
                characteristics: "1600x1067, 8-bit sRGB, synthetic portrait plus detail patch.",
                operations: "load dimensions, preview/export scale, hash-only no-op; masked cases are not captured at this size.",
                necessity: "Radius scaling and preview/export parity require an image well above 1400 px."),
    FixtureSpec(id: "F09_ALPHA_CUTOUT", file: "F09_alpha_cutout.png",
                purpose: "Transparency and alpha export.",
                characteristics: "512x512, 8-bit sRGB with alpha, soft radial alpha, opaque star, semi-transparent ring.",
                operations: "load alpha, PNG alpha export, JPEG flatten, background removal comparison.",
                necessity: "Alpha handling and JPEG flattening cannot be verified on opaque photos."),
    FixtureSpec(id: "F10_EXIF_ORIENT6", file: "F10_exif_orient6.jpg",
                purpose: "EXIF orientation handling.",
                characteristics: "Stored 720x480 JPEG tagged orientation 6; four coloured quadrants plus a diagonal marker.",
                operations: "decode, upright baking, dimension swap, quadrant mapping, export orientation tag.",
                necessity: "Camera files are commonly stored rotated; the corpus must prove the mapping."),
    FixtureSpec(id: "F11_P3_16BIT", file: "F11_p3_16bit.png",
                purpose: "Wide gamut and deep storage.",
                characteristics: "512x512, 16-bit PNG tagged Display P3, saturated patches and smooth ramps.",
                operations: "16-bit decode, P3 colour space preservation, 16-bit PNG export.",
                necessity: "Colour management and bit-depth behaviour need a non-sRGB, non-8-bit source."),
    FixtureSpec(id: "F12_GRAY_8", file: "F12_gray_8.png",
                purpose: "Grayscale source.",
                characteristics: "640x480, 8-bit grayscale PNG, gradient, bars and discs.",
                operations: "decode, grayscale colour model, export to colour formats.",
                necessity: "A grayscale source exercises a colour model the RGB fixtures cannot."),
]

func fixtureURL(_ id: String) -> URL {
    let spec = fixtureSpecs.first { $0.id == id }
    return fixturesDir.appendingPathComponent(spec?.file ?? "\(id).png")
}

func buildFixture(_ id: String) -> (CGImage, UTType, [CFString: Any])? {
    switch id {
    case "F01_PORTRAIT_SRGB_8":
        guard let context = makeContext(width: 512, height: 512) else { return nil }
        drawPortrait(context, size: CGSize(width: 512, height: 512),
                     box: CGRect(x: 0.22, y: 0.20, width: 0.56, height: 0.64),
                     palette: lightPalette, seed: 0x01A1, lowKey: false)
        addNoise(context, amplitude: 2.0, seed: 0x01A2)
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F02_PORTRAIT_DEEP_LOWKEY":
        guard let context = makeContext(width: 512, height: 512) else { return nil }
        drawPortrait(context, size: CGSize(width: 512, height: 512),
                     box: CGRect(x: 0.22, y: 0.20, width: 0.56, height: 0.64),
                     palette: deepPalette, seed: 0x02A1, lowKey: true)
        addNoise(context, amplitude: 6.0, seed: 0x02A2)
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F03_PORTRAIT_LANDSCAPE":
        let size = CGSize(width: 768, height: 432)
        guard let context = makeContext(width: 768, height: 432) else { return nil }
        verticalGradient(context, CGRect(origin: .zero, size: size),
                         top: rgba(0.18, 0.34, 0.58), bottom: rgba(0.86, 0.66, 0.48))
        var bokeh = SeededRNG(seed: 0x03A1)
        for _ in 0..<24 {
            let x = bokeh.range(0.35, 0.98) * size.width
            let y = bokeh.range(0.45, 0.95) * size.height
            let radius = bokeh.range(6, 32)
            fillEllipse(context, CGRect(x: x - radius, y: y - radius,
                                        width: radius * 2, height: radius * 2),
                        rgba(1, 0.92, 0.76), alpha: bokeh.range(0.04, 0.14))
        }
        drawPortrait(context, size: size,
                     box: CGRect(x: 0.08, y: 0.20, width: 0.30, height: 0.68),
                     palette: lightPalette, seed: 0x03A2, lowKey: false)
        addNoise(context, amplitude: 1.5, seed: 0x03A3)
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F04_DETAIL_CHART":
        guard let context = makeContext(width: 512, height: 512) else { return nil }
        drawDetailChart(context, rect: CGRect(x: 0, y: 0, width: 512, height: 512),
                        seed: 0x04A1)
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F05_GRADIENT_SKY":
        let size = CGSize(width: 768, height: 384)
        guard let context = makeContext(width: 768, height: 384) else { return nil }
        verticalGradient(context, CGRect(origin: .zero, size: size),
                         top: rgba(0.08, 0.14, 0.32), bottom: rgba(0.94, 0.72, 0.52))
        radialGlow(context, center: CGPoint(x: size.width * 0.72, y: size.height * 0.28),
                   radius: size.height * 0.55,
                   inner: rgba(1, 0.96, 0.82, 0.95), outer: rgba(1, 0.96, 0.82, 0))
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F06_HIGHLIGHTS_SHADOWS":
        guard let context = makeContext(width: 640, height: 480) else { return nil }
        verticalGradient(context, CGRect(x: 0, y: 0, width: 320, height: 480),
                         top: rgba(0.08, 0.09, 0.11), bottom: rgba(0.01, 0.01, 0.02))
        verticalGradient(context, CGRect(x: 320, y: 0, width: 320, height: 480),
                         top: rgba(0.99, 0.98, 0.94), bottom: rgba(0.72, 0.70, 0.66))
        fill(context, CGRect(x: 400, y: 300, width: 180, height: 120), rgba(1, 1, 1))
        let ramp = CGRect(x: 40, y: 40, width: 560, height: 60)
        for step in 0..<256 {
            let value = Double(step) / 255
            fill(context, CGRect(x: ramp.minX + CGFloat(step) * ramp.width / 256,
                                 y: ramp.minY, width: ramp.width / 256 + 0.5,
                                 height: ramp.height),
                 CGColor(colorSpace: sRGB, components: [value, value, value, 1])!)
        }
        let patches: [CGColor] = [rgba(0.80, 0.12, 0.10), rgba(0.10, 0.62, 0.18),
                                  rgba(0.10, 0.22, 0.75), rgba(0.86, 0.72, 0.12),
                                  rgba(0.70, 0.18, 0.72), rgba(0.86, 0.72, 0.64)]
        for (index, color) in patches.enumerated() {
            fill(context, CGRect(x: 60 + CGFloat(index) * 90, y: 140, width: 72, height: 72), color)
        }
        for (index, radius) in [10.0, 18.0, 28.0].enumerated() {
            fillEllipse(context, CGRect(x: 420 - radius + CGFloat(index) * 90, y: 240 - radius,
                                        width: radius * 2, height: radius * 2),
                        rgba(1, 1, 1), alpha: 0.92)
        }
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F07_LOWLIGHT_NOISE":
        let size = CGSize(width: 512, height: 384)
        guard let context = makeContext(width: 512, height: 384) else { return nil }
        verticalGradient(context, CGRect(origin: .zero, size: size),
                         top: rgba(0.03, 0.035, 0.05), bottom: rgba(0.10, 0.085, 0.07))
        fillEllipse(context, CGRect(x: 300, y: 120, width: 120, height: 160),
                    rgba(0.32, 0.22, 0.14), alpha: 0.55)
        fillEllipse(context, CGRect(x: 330, y: 210, width: 60, height: 60),
                    rgba(0.96, 0.66, 0.30), alpha: 0.75)
        context.saveGState()
        context.setStrokeColor(rgba(0.65, 0.50, 0.35, 0.35))
        context.setLineWidth(1)
        for index in 0..<12 {
            let x = 80.0 + Double(index) * 9
            context.move(to: CGPoint(x: x, y: 90))
            context.addLine(to: CGPoint(x: x + 30, y: 260))
        }
        context.strokePath()
        context.restoreGState()
        addNoise(context, amplitude: 16.0, seed: 0x07A1)
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F08_HIGHRES_PORTRAIT":
        let size = CGSize(width: 1600, height: 1067)
        guard let context = makeContext(width: 1600, height: 1067) else { return nil }
        drawPortrait(context, size: size,
                     box: CGRect(x: 0.30, y: 0.12, width: 0.38, height: 0.76),
                     palette: lightPalette, seed: 0x08A1, lowKey: false)
        drawDetailChart(context, rect: CGRect(x: 1120, y: 90, width: 380, height: 300),
                        seed: 0x08A2)
        addNoise(context, amplitude: 1.8, seed: 0x08A3)
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F09_ALPHA_CUTOUT":
        guard let context = makeContext(width: 512, height: 512) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: 512, height: 512))
        radialGlow(context, center: CGPoint(x: 256, y: 256), radius: 230,
                   inner: rgba(0.12, 0.55, 0.62, 0.95), outer: rgba(0.12, 0.55, 0.62, 0))
        let star = CGMutablePath()
        for index in 0..<10 {
            let radius = index % 2 == 0 ? 120.0 : 52.0
            let angle = -Double.pi / 2 + Double(index) * Double.pi / 5
            let point = CGPoint(x: 256 + cos(angle) * radius, y: 256 + sin(angle) * radius)
            if index == 0 { star.move(to: point) } else { star.addLine(to: point) }
        }
        star.closeSubpath()
        context.saveGState()
        context.setAlpha(0.88)
        context.setFillColor(rgba(0.96, 0.72, 0.18))
        context.addPath(star)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.setStrokeColor(rgba(0.95, 0.20, 0.35, 0.55))
        context.setLineWidth(14)
        context.strokeEllipse(in: CGRect(x: 90, y: 90, width: 332, height: 332))
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F10_EXIF_ORIENT6":
        let stored = CGSize(width: 720, height: 480)
        guard let context = makeContext(width: 720, height: 480, alpha: false) else { return nil }
        func visual(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x * stored.width, y: (1 - y - h) * stored.height,
                   width: w * stored.width, height: h * stored.height)
        }
        fill(context, visual(0, 0, 0.5, 0.5), rgba(0.85, 0.10, 0.10))
        fill(context, visual(0.5, 0, 0.5, 0.5), rgba(0.10, 0.70, 0.20))
        fill(context, visual(0, 0.5, 0.5, 0.5), rgba(0.10, 0.20, 0.80))
        fill(context, visual(0.5, 0.5, 0.5, 0.5), rgba(0.92, 0.82, 0.10))
        context.saveGState()
        context.setStrokeColor(rgba(1, 1, 1))
        context.setLineWidth(6)
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 720, y: 480))
        context.strokePath()
        context.restoreGState()
        for (x, y) in [(0.10, 0.10), (0.60, 0.10), (0.10, 0.60), (0.60, 0.60)] {
            let dot = visual(x, y, 0.06, 0.10)
            fillEllipse(context, dot, rgba(0.05, 0.05, 0.05))
        }
        guard let image = context.makeImage() else { return nil }
        return (image, .jpeg, [kCGImagePropertyOrientation: 6])

    case "F11_P3_16BIT":
        guard let context = makeContext(width: 512, height: 512, space: p3, bits: 16) else { return nil }
        for step in 0..<512 {
            let t = Double(step) / 511
            fill(context, CGRect(x: CGFloat(step), y: 256, width: 1, height: 256),
                 p3Color(0.90 * (1 - t) + 0.05 * t, 0.08 * (1 - t) + 0.85 * t, 0.10 + 0.75 * t))
            fill(context, CGRect(x: CGFloat(step), y: 0, width: 1, height: 256),
                 p3Color(0.05 + 0.10 * t, 0.10 + 0.70 * t, 0.30 + 0.60 * t))
        }
        let patches: [CGColor] = [p3Color(0.95, 0.08, 0.08), p3Color(0.08, 0.95, 0.18),
                                  p3Color(0.10, 0.18, 0.98), p3Color(0.05, 0.95, 0.95),
                                  p3Color(0.98, 0.10, 0.90), p3Color(0.95, 0.80, 0.05)]
        for (index, color) in patches.enumerated() {
            fill(context, CGRect(x: 40 + CGFloat(index) * 72, y: 210, width: 60, height: 60), color)
        }
        radialGlow(context, center: CGPoint(x: 380, y: 380), radius: 160,
                   inner: p3Color(1, 0.95, 0.85, 0.9), outer: p3Color(1, 0.95, 0.85, 0))
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    case "F12_GRAY_8":
        guard let context = makeContext(width: 640, height: 480, space: graySpace,
                                        bits: 8, alpha: false) else { return nil }
        for step in 0..<640 {
            let value = Double(step) / 639
            fill(context, CGRect(x: CGFloat(step), y: 0, width: 1, height: 480),
                 gray(value))
        }
        for index in 0..<8 {
            let value = Double(index) / 7
            fill(context, CGRect(x: 40 + CGFloat(index) * 70, y: 300, width: 56, height: 80),
                 gray(value))
        }
        for index in 0..<5 {
            let radius = 18.0 + Double(index) * 10
            fillEllipse(context, CGRect(x: 110 + CGFloat(index) * 105, y: 120,
                                        width: radius * 2, height: radius * 2),
                        gray(index % 2 == 0 ? 0.16 : 0.84))
        }
        guard let image = context.makeImage() else { return nil }
        return (image, .png, [:])

    default:
        return nil
    }
}

func drawDetailChart(_ context: CGContext, rect: CGRect, seed: UInt64) {
    fill(context, rect, rgba(0.50, 0.50, 0.50))
    let quarter = rect.width / 4
    let periods: [Double] = [2, 3, 5, 8]
    for (band, period) in periods.enumerated() {
        let x0 = rect.minX + CGFloat(band) * quarter
        var x = x0
        while x < x0 + quarter {
            fill(context, CGRect(x: x, y: rect.minY + rect.height * 0.60,
                                 width: period, height: rect.height * 0.36),
                 rgba(0.04, 0.04, 0.05))
            x += period * 2
        }
    }
    for (band, period) in periods.enumerated() {
        let x0 = rect.minX + CGFloat(band) * quarter
        var y = rect.minY + rect.height * 0.10
        while y < rect.minY + rect.height * 0.45 {
            fill(context, CGRect(x: x0, y: y, width: quarter, height: period),
                 rgba(0.95, 0.95, 0.95))
            y += period * 2
        }
    }
    // Checkerboards and a weave-like block.
    for (bx, by, tile) in [(0.0, 0.46, 2.0), (0.25, 0.46, 4.0), (0.50, 0.46, 2.0)] {
        let x0 = rect.minX + rect.width * bx
        let y0 = rect.minY + rect.height * by
        let side = rect.width * 0.20
        var y = y0
        while y < y0 + rect.height * 0.12 {
            var x = x0
            while x < x0 + side {
                let on = (Int((x - x0) / tile) + Int((y - y0) / tile)) % 2 == 0
                fill(context, CGRect(x: x, y: y, width: tile, height: tile),
                     on ? rgba(0.92, 0.92, 0.92) : rgba(0.08, 0.08, 0.08))
                x += tile
            }
            y += tile
        }
    }
    var rng = SeededRNG(seed: seed)
    for _ in 0..<900 {
        let x = rect.minX + rng.range(0.02, 0.98) * rect.width
        let y = rect.minY + rng.range(0.52, 0.58) * rect.height
        let length = rng.range(2, 16)
        fill(context, CGRect(x: x, y: y, width: length, height: 1),
             rgba(0.10, 0.10, 0.10), alpha: rng.range(0.2, 0.8))
    }
    let patches: [CGColor] = [rgba(0.85, 0.15, 0.12), rgba(0.12, 0.68, 0.22),
                              rgba(0.12, 0.24, 0.82), rgba(0.90, 0.76, 0.12),
                              rgba(0.74, 0.16, 0.74), rgba(0.88, 0.72, 0.62),
                              rgba(0.15, 0.15, 0.15), rgba(0.95, 0.95, 0.95)]
    for (index, color) in patches.enumerated() {
        fill(context, CGRect(x: rect.minX + 8 + CGFloat(index) * rect.width * 0.12,
                             y: rect.minY + 8, width: rect.width * 0.10, height: rect.height * 0.07),
             color)
    }
}

// MARK: - Prepared fixtures

struct Prepared {
    let id: String
    let load: LoadResult
    let faces: [FaceGeometry]
    let masks: MaskSet?
    let personMasks: MaskSet?
    let space: CGColorSpace
}

func portraitBox(_ id: String) -> CGRect? {
    switch id {
    case "F01_PORTRAIT_SRGB_8", "F02_PORTRAIT_DEEP_LOWKEY":
        return CGRect(x: 0.22, y: 0.20, width: 0.56, height: 0.64)
    case "F03_PORTRAIT_LANDSCAPE":
        return CGRect(x: 0.08, y: 0.20, width: 0.30, height: 0.68)
    default:
        return nil
    }
}

func prepare(_ id: String) -> Prepared? {
    let url = fixtureURL(id)
    guard let result = processor.load(from: url, previewMaxDimension: 4096) else { return nil }
    var faces: [FaceGeometry] = []
    if let box = portraitBox(id) {
        faces = [faceGeometry(box: box)]
        if let buffer = AutoAnalyzer.analysisBuffer(result.sourceFull) {
            faces = AutoAnalyzer.annotateTeeth(faces: faces, buffer: buffer)
            faces = AutoAnalyzer.annotateEyes(faces: faces, buffer: buffer)
        }
    }
    let masks = faces.isEmpty ? nil : processor.buildMasks(
        extent: result.sourceFull.extent, faces: faces, image: result.sourceFull,
        maskDimension: MaskBuilder.exportMaskDimension)

    var personMasks = masks
    if let box = portraitBox(id), var set = masks {
        let extent = result.sourceFull.extent
        let shortSide = min(extent.width, extent.height)
        let head = MaskShape(ellipse: CGRect(x: box.minX - 0.04, y: box.minY - 0.04,
                                             width: box.width + 0.08, height: box.height + 0.10))
        let torso = MaskShape(ellipse: CGRect(x: max(0, box.minX - 0.24), y: -0.05,
                                              width: min(1, box.width + 0.48),
                                              height: box.minY + 0.22))
        if let person = MaskBuilder.makeMask(extent: extent, shapes: [head, torso],
                                             feather: max(2, shortSide * 0.004)) {
            set.person = person
        }
        personMasks = set
    }
    return Prepared(id: id, load: result, faces: faces, masks: masks,
                    personMasks: personMasks, space: result.colorSpace)
}

func noopImage(_ prepared: Prepared) -> CIImage {
    processor.process(prepared.load.sourceFull, adjustments: Adjustments(),
                      masks: prepared.masks, faces: prepared.faces)
}
