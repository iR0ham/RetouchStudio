import AppKit
import CoreImage
import Foundation

// Verifies the new engine's core guarantees, each of which was a real defect:
//
//   1. Smoothing must KEEP more texture than a Gaussian blur of similar
//      strength (the old engine's whole problem).
//   2. Blemish removal must clear spots while leaving pore-level texture.
//   3. Texture Preserve must actually change how much texture survives.
//   4. Reshape must move features, and must not alter the image far outside the
//      face.
//   5. Each reshape slider must produce a distinct change (no dead sliders).
//   6. Every skin/reshape/colour field must be individually meaningful
//      (toggling it alone changes the output).

struct Fail: Error { let message: String }
var failures: [String] = []
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

let processor = ImageProcessor.shared
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - fixtures

func poly(_ r: CGRect) -> [CGPoint] {
    [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
     CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
}

/// A synthetic face with real pore-level noise and a few dark spots. The
/// parity fixtures scale the spots with the render size, because a blemish is
/// a fixed fraction of a face and not a fixed number of pixels.
func makeFace(size: Int, blemishScale: CGFloat = 1,
              pores: Bool = true, spots: Bool = true) -> (CIImage, CGImage, CGPoint) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.72, blue: 0.64, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    var gen = SystemRandomNumberGenerator()
    if pores {
        for _ in 0..<(size * size / 6) {
            let x = CGFloat.random(in: s * 0.22...s * 0.78, using: &gen)
            let y = CGFloat.random(in: s * 0.30...s * 0.88, using: &gen)
            // Realistic pore contrast: subtle, a few levels either side of the base tone.
            let v = Double.random(in: 0.80...0.94, using: &gen)
            ctx.setFillColor(CGColor(srgbRed: v, green: v * 0.86, blue: v * 0.78, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.35, blue: 0.33, alpha: 1))
    for (sx, sy, r) in [(0.34, 0.62, 7.0), (0.46, 0.46, 8.0), (0.60, 0.56, 6.5)] where spots {
        let radius = r * blemishScale
        ctx.fillEllipse(in: CGRect(x: s * sx - radius, y: s * sy - radius,
                                   width: radius * 2, height: radius * 2))
    }
    // The mouth opening holds warm-white teeth, so the enamel gate has
    // something real to whiten. A skin-coloured mouth correctly gates teeth
    // whitening off, which would make the per-slider test report a dead tool.
    ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.90, blue: 0.80, alpha: 1))
    ctx.fill(CGRect(x: s * 0.445, y: s * 0.596, width: s * 0.11, height: s * 0.026))
    let cg = ctx.makeImage()!
    return (CIImage(cgImage: cg), cg, CGPoint(x: size / 2, y: size / 2))
}

func face(_ size: Int) -> FaceGeometry {
    let s = CGFloat(size)
    var f = FaceGeometry.synthetic(
        boundingBox: CGRect(x: 0.18, y: 0.28, width: 0.64, height: 0.64),
        faceContour: poly(CGRect(x: 0.18, y: 0.28, width: 0.64, height: 0.64)),
        leftEye: poly(CGRect(x: 0.30, y: 0.66, width: 0.14, height: 0.07)),
        rightEye: poly(CGRect(x: 0.56, y: 0.66, width: 0.14, height: 0.07)),
        leftEyebrow: poly(CGRect(x: 0.29, y: 0.75, width: 0.16, height: 0.03)),
        rightEyebrow: poly(CGRect(x: 0.55, y: 0.75, width: 0.16, height: 0.03)),
        outerLips: poly(CGRect(x: 0.42, y: 0.36, width: 0.16, height: 0.06)),
        innerLips: poly(CGRect(x: 0.44, y: 0.375, width: 0.12, height: 0.03)),
        nose: poly(CGRect(x: 0.45, y: 0.52, width: 0.10, height: 0.08)))
    // Vision sets this from the mouth pixels; the fixture paints real teeth, so
    // the same gate is on for the test.
    f.hasVisibleTeeth = true
    _ = s
    return f
}

func texture(_ img: CGImage, _ rect: CGRect) -> Double {
    guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return -1 }
    let bpp = img.bitsPerPixel / 8
    let x0 = max(1, Int(rect.minX)), x1 = min(img.width - 2, Int(rect.maxX))
    let y0 = max(1, Int(rect.minY)), y1 = min(img.height - 2, Int(rect.maxY))
    guard x1 > x0, y1 > y0 else { return -1 }
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = y * img.bytesPerRow + x * bpp
        return 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2])
    }
    var total = 0.0, n = 0.0
    for y in y0..<y1 {
        for x in x0..<x1 {
            total += abs(lum(x, y) - lum(x + 1, y)) + abs(lum(x, y) - lum(x, y + 1))
            n += 2
        }
    }
    return n > 0 ? total / n : -1
}

/// Mean absolute difference between two renders inside one normalized region.
/// Effects are localized, so a whole-image mean hides them; measuring in the
/// effect's own region is the honest test.
func localDelta(_ a: CGImage, _ b: CGImage, normalized: CGRect) -> Double {
    guard let da = a.dataProvider?.data, let db = b.dataProvider?.data,
          let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return -1 }
    let ba = a.bitsPerPixel / 8, bb = b.bitsPerPixel / 8
    let x0 = max(0, Int(normalized.minX * CGFloat(a.width)))
    let x1 = min(a.width, Int(normalized.maxX * CGFloat(a.width)))
    let y0 = max(0, Int((1 - normalized.maxY) * CGFloat(a.height)))
    let y1 = min(a.height, Int((1 - normalized.minY) * CGFloat(a.height)))
    guard x1 > x0, y1 > y0 else { return -1 }
    var total = 0.0, n = 0.0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let ia = y * a.bytesPerRow + x * ba
            let ib = y * b.bytesPerRow + x * bb
            total += abs(Double(pa[ia]) - Double(pb[ib]))
                + abs(Double(pa[ia + 1]) - Double(pb[ib + 1]))
                + abs(Double(pa[ia + 2]) - Double(pb[ib + 2]))
            n += 3
        }
    }
    return n > 0 ? total / n : -1
}

/// Mean absolute difference between two renders, over the whole image.
func meanDelta(_ a: CGImage, _ b: CGImage) -> Double {
    guard let da = a.dataProvider?.data, let db = b.dataProvider?.data,
          let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return -1 }
    let ba = a.bitsPerPixel / 8, bb = b.bitsPerPixel / 8
    guard a.width == b.width, a.height == b.height else { return -1 }
    var total = 0.0, n = 0.0
    for y in stride(from: 0, to: a.height, by: 3) {
        for x in stride(from: 0, to: a.width, by: 3) {
            let ia = y * a.bytesPerRow + x * ba
            let ib = y * b.bytesPerRow + x * bb
            total += abs(Double(pa[ia]) - Double(pb[ib]))
                + abs(Double(pa[ia + 1]) - Double(pb[ib + 1]))
                + abs(Double(pa[ia + 2]) - Double(pb[ib + 2]))
            n += 3
        }
    }
    return n > 0 ? total / n : -1
}

let size = 420
let (source, baseCG, _) = makeFace(size: size)
let extent = CGRect(x: 0, y: 0, width: size, height: size)
let f = face(size)
guard let masks = processor.buildMasks(extent: extent, faces: [f]) else {
    print("could not build masks"); exit(1)
}
// The texture sample must sit on CLEAN skin: the engine's leftCheekRect
// overlaps blemish #1 at (0.34, 0.62), and removing that blemish legitimately
// lowers texture there. Measuring texture over a blemish would report correct
// blemish removal as texture loss.
//
// This patch is clear of all three fixture blemishes at (0.34,0.62),
// (0.46,0.46) and (0.60,0.56), and clear of the eyes and lips.
let fRef = face(size)
let cheekNorm = CGRect(x: 0.62, y: 0.34, width: 0.12, height: 0.11)
let cheek = CGRect(x: cheekNorm.minX * CGFloat(size),
                   y: (1 - cheekNorm.maxY) * CGFloat(size),
                   width: cheekNorm.width * CGFloat(size),
                   height: cheekNorm.height * CGFloat(size))

func render(_ a: Adjustments) -> CGImage? {
    processor.renderCGImage(processor.process(source, adjustments: a, masks: masks, faces: [f]), scale: 1)
}

print("\n[1] smoothing retains more texture than a plain blur")
var smooth = Adjustments(); smooth.smooth = 70; smooth.texturePreserve = 85
let blur = source.clampedToExtent()
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4.0]).cropped(to: extent)
if let sm = render(smooth), let bl = processor.renderCGImage(blur, scale: 1) {
    let base = texture(baseCG, cheek), smT = texture(sm, cheek), blT = texture(bl, cheek)
    check(smT / base > blT / base,
          "engine keeps more texture than a blur",
          String(format: "engine %.2f vs blur %.2f (base %.2f)", smT / base, blT / base, base))
    check(smT / base > 0.45, "smoothed skin still has texture", String(format: "%.2f of original", smT / base))
} else { check(false, "smoothing render") }

print("\n[2] blemish removal clears spots")
var blem = Adjustments(); blem.blemish = 75
func spotProminence(_ img: CGImage, _ nx: CGFloat, _ ny: CGFloat) -> Double {
    guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return -1 }
    let bpp = img.bitsPerPixel / 8
    let cx = Int(nx * CGFloat(img.width)), cy = Int((1 - ny) * CGFloat(img.height))
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = y * img.bytesPerRow + x * bpp
        return (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3
    }
    var ring = 0.0, n = 0.0
    for dx in [-15, 0, 15] { for dy in [-15, 0, 15] where !(dx == 0 && dy == 0) {
        ring += lum(cx + dx, cy + dy); n += 1 } }
    return (ring / n) - lum(cx, cy)
}
if let bm = render(blem) {
    var cleared = 0
    for (nx, ny) in [(0.34, 0.62), (0.46, 0.46), (0.60, 0.56)] {
        let before = spotProminence(baseCG, nx, ny), after = spotProminence(bm, nx, ny)
        if after < before * 0.7 { cleared += 1 }
    }
    check(cleared >= 2, "spots cleared by median", "\(cleared)/3 cleared")
    let t = texture(bm, cheek) / texture(baseCG, cheek)
    check(t > 0.5, "pores survive blemish removal", String(format: "%.2f of original texture", t))
} else { check(false, "blemish render") }

print("\n[3] Texture Preserve changes how much texture survives")
var lowTP = Adjustments(); lowTP.smooth = 70; lowTP.texturePreserve = 10
var highTP = Adjustments(); highTP.smooth = 70; highTP.texturePreserve = 95
if let lo = render(lowTP), let hi = render(highTP) {
    let loT = texture(lo, cheek), hiT = texture(hi, cheek)
    check(hiT > loT * 1.05, "higher Texture Preserve keeps more texture",
          String(format: "%.2f vs %.2f", hiT, loT))
} else { check(false, "texture preserve render") }

print("\n[4] reshape moves features and stays local")
var reshape = Adjustments(); reshape.eyeSize = 70; reshape.lipSize = 60
if let rs = render(reshape) {
    let faceBox = f.boundingBox
    let facePx = CGRect(x: faceBox.minX * CGFloat(size),
                        y: (1 - faceBox.maxY) * CGFloat(size),
                        width: faceBox.width * CGFloat(size),
                        height: faceBox.height * CGFloat(size))
    // Magnitude outside the face, ignoring the feather band.
    guard let d = processor.renderCGImage(
        CIImage(cgImage: rs).applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: baseCG)]), scale: 1),
        let data = d.dataProvider?.data, let p = CFDataGetBytePtr(data) else {
        check(false, "reshape diff render"); exit(1)
    }
    let bpp = d.bitsPerPixel / 8
    var outSum = 0.0, outN = 0.0, inSum = 0.0, inN = 0.0
    for y in stride(from: 2, to: d.height - 2, by: 2) {
        for x in stride(from: 2, to: d.width - 2, by: 2) {
            let i = y * d.bytesPerRow + x * bpp
            let delta = Double(Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])) / 3.0
            // Exclude the 6% feather band around the face box.
            let band = facePx.insetBy(dx: -facePx.width * 0.06, dy: -facePx.height * 0.06)
            if band.contains(CGPoint(x: x, y: y)) { inSum += delta; inN += 1 }
            else { outSum += delta; outN += 1 }
        }
    }
    let inMean = inSum / max(inN, 1), outMean = outSum / max(outN, 1)
    check(inMean > 1.5, "reshape changes the face", String(format: "mean delta %.2f inside", inMean))
    check(outMean < 1.0, "reshape leaves the background alone",
          String(format: "mean delta %.2f outside", outMean))
} else { check(false, "reshape render") }

print("\n[5] every reshape slider has an independent effect")
// Each reshape slider is measured inside the region it is supposed to move,
// because a nose is ~1% of the frame and a whole-image mean would hide it.
let reshapeKeys: [(String, WritableKeyPath<Adjustments, Double>, CGRect)] = [
    ("eyeSize", \.eyeSize, fRef.leftEyeRect),
    ("noseSize", \.noseSize, fRef.noseRect),
    ("lipSize", \.lipSize, fRef.lipRect ?? fRef.noseRect),
    ("cheekSize", \.cheekSize, fRef.leftCheekRect),
    ("jawWidth", \.jawWidth, fRef.jawRects.left),
    ("chinLength", \.chinLength, fRef.chinRect),
    ("faceWidth", \.faceWidth, fRef.boundingBox),
    ("faceLength", \.faceLength, fRef.boundingBox)
]
for (name, key, region) in reshapeKeys {
    var a = Adjustments()
    a[keyPath: key] = 80
    if let out = render(a) {
        let d = localDelta(baseCG, out, normalized: region)
        check(d > 0.5, "\(name) moves its feature", String(format: "mean delta %.2f in region", d))
    } else { check(false, "\(name) render") }
}

// noseTip needs the nose crest, which the synthetic fixture does not provide,
// so it is verified on a real photo elsewhere. Assert the guard instead: with
// no crest data it must be a clean no-op rather than a crash or a whole-image
// change.
var tipNoData = Adjustments(); tipNoData.noseTip = 80
if let out = render(tipNoData) {
    let d = meanDelta(baseCG, out)
    check(d < 0.02, "noseTip is a safe no-op without crest data", String(format: "mean delta %.4f", d))
}

print("\n[6] every skin, detail and colour slider has an effect")
let skinKeys: [(String, WritableKeyPath<Adjustments, Double>, CGRect)] = [
    ("smooth", \.smooth, fRef.leftCheekRect),
    ("blemish", \.blemish, fRef.leftCheekRect),
    ("wrinkle", \.wrinkle, fRef.leftCheekRect),
    ("skinToneEvens", \.skinToneEvens, fRef.leftCheekRect),
    ("darkCircles", \.darkCircles, fRef.leftUnderEyeRect),
    ("skinBrighten", \.skinBrighten, fRef.leftCheekRect),
    ("teethWhiten", \.teethWhiten, fRef.teethRect ?? fRef.noseRect),
    ("eyeBrighten", \.eyeBrighten, fRef.leftEyeRect),
    ("eyeSharpen", \.eyeSharpen, fRef.leftEyeRect),
    ("exposure", \.exposure, fRef.boundingBox),
    ("contrast", \.contrast, fRef.boundingBox),
    ("saturation", \.saturation, fRef.boundingBox),
    ("vibrance", \.vibrance, fRef.boundingBox),
    ("warmth", \.warmth, fRef.boundingBox),
    ("clarity", \.clarity, fRef.boundingBox),
    ("vignette", \.vignette, CGRect(x: 0, y: 0, width: 1, height: 1))
]
for (name, key, region) in skinKeys {
    var a = Adjustments()
    a[keyPath: key] = 85
    if let out = render(a) {
        let d = localDelta(baseCG, out, normalized: region)
        check(d > 0.5, "\(name) has a real effect", String(format: "mean delta %.2f in region", d))
    } else { check(false, "\(name) render") }
}

print("\n[7] a fresh Adjustments() is a genuine no-op")
if let ident = render(Adjustments()) {
    let d = meanDelta(baseCG, ident)
    check(d < 0.01, "default settings change nothing", String(format: "mean delta %.4f", d))
} else { check(false, "identity render") }

print("\n[8] multi-face selection and landmarkless faces")
// Confidence and area are read from Vision's own numbers. A dim background
// face is excluded before it can contribute masks; a speck is not a subject.
check(!FaceAnalyzer.isAcceptable(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                 confidence: 0.2),
      "a low-confidence face is rejected")
check(!FaceAnalyzer.isAcceptable(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02),
                                 confidence: 0.99),
      "a face smaller than 0.2% of the frame is rejected")
check(FaceAnalyzer.isAcceptable(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                confidence: 0.9),
      "an ordinary face is accepted")

let smallFace = FaceGeometry.synthetic(
    boundingBox: CGRect(x: 0.02, y: 0.02, width: 0.2, height: 0.2),
    faceContour: poly(CGRect(x: 0.02, y: 0.02, width: 0.2, height: 0.2)))
let midFace = FaceGeometry.synthetic(
    boundingBox: CGRect(x: 0.38, y: 0.38, width: 0.3, height: 0.3),
    faceContour: poly(CGRect(x: 0.38, y: 0.38, width: 0.3, height: 0.3)))
let bigFace = FaceGeometry.synthetic(
    boundingBox: CGRect(x: 0.62, y: 0.60, width: 0.4, height: 0.4),
    faceContour: poly(CGRect(x: 0.62, y: 0.60, width: 0.4, height: 0.4)))
let ordered = FaceAnalyzer.ordered([smallFace, bigFace, midFace])
check(ordered.map(\.boundingBox.width) == [0.4, 0.3, 0.2],
      "faces are ordered largest first",
      ordered.map { String(format: "%.2f", $0.boundingBox.width) }.joined(separator: ", "))

// Feature sizes: the median of everyone by default, the chosen face when
// there is one. 1000 px frame → 0.2/0.3/0.4 faces are 200/300/400 px wide.
let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
let medianWidth = ImageProcessor.faceWidthPixels(faces: [bigFace, smallFace, midFace],
                                                 focus: nil, extent: frame) ?? 0
let focusWidth = ImageProcessor.faceWidthPixels(faces: [bigFace, smallFace, midFace],
                                                focus: smallFace, extent: frame) ?? 0
check(abs(medianWidth - 300) < 0.5,
      "without a selection the median face sets the blemish class",
      String(format: "%.0f px", medianWidth))
check(abs(focusWidth - 200) < 0.5,
      "selecting a face switches the blemish class to its width",
      String(format: "%.0f px", focusWidth))

check(AnalysisRenderer.primaryFace([bigFace, midFace], focus: midFace)?.boundingBox
        == midFace.boundingBox,
      "the overlay follows the selected face")
check(AnalysisRenderer.primaryFace([smallFace, bigFace], focus: nil)?.boundingBox
        == bigFace.boundingBox,
      "with no selection the largest face carries the callouts")

// Every accepted face still gets the skin work, whichever one drives the
// callouts. The two boxes sit over skin-coloured pixels in the fixture.
let leftFace = FaceGeometry.synthetic(
    boundingBox: CGRect(x: 0.06, y: 0.20, width: 0.36, height: 0.40),
    faceContour: poly(CGRect(x: 0.06, y: 0.20, width: 0.36, height: 0.40)))
let rightFace = FaceGeometry.synthetic(
    boundingBox: CGRect(x: 0.58, y: 0.18, width: 0.34, height: 0.38),
    faceContour: poly(CGRect(x: 0.58, y: 0.18, width: 0.34, height: 0.38)))
if let bothMasks = processor.buildMasks(extent: extent, faces: [leftFace, rightFace]) {
    var all = Adjustments(); all.smooth = 70; all.texturePreserve = 80
    if let out = processor.renderCGImage(
        processor.process(source, adjustments: all, masks: bothMasks,
                          faces: [leftFace, rightFace], focus: rightFace), scale: 1) {
        let leftDelta = localDelta(baseCG, out, normalized: leftFace.boundingBox)
        let rightDelta = localDelta(baseCG, out, normalized: rightFace.boundingBox)
        check(leftDelta > 0.3, "the non-selected face is still smoothed",
              String(format: "mean delta %.2f", leftDelta))
        check(rightDelta > 0.3, "the selected face is smoothed too",
              String(format: "mean delta %.2f", rightDelta))
    } else { check(false, "two-face render") }
} else { check(false, "two-face masks") }

// A face Vision found but could not annotate. Missing outlines must not turn
// into null/infinite rectangles: no makeup shapes, no NaN, and smoothing still
// works inside the box.
let landless = FaceGeometry.synthetic(
    boundingBox: CGRect(x: 0.25, y: 0.22, width: 0.5, height: 0.56),
    hasLandmarks: false)
if let landlessMasks = processor.buildMasks(extent: extent, faces: [landless], image: source) {
    func finite(_ image: CIImage?) -> Bool {
        guard let e = image?.extent else { return true }
        return e.origin.x.isFinite && e.origin.y.isFinite
            && e.width.isFinite && e.height.isFinite
    }
    let allFinite = [landlessMasks.skin, landlessMasks.face, landlessMasks.forehead,
                     landlessMasks.hair].allSatisfy(finite)
    check(landlessMasks.skin != nil && allFinite,
          "a landmarkless face still gets finite skin masks")
    check(landlessMasks.cheeks == nil && landlessMasks.underEyes == nil
            && landlessMasks.teeth == nil && landlessMasks.eyes == nil
            && landlessMasks.nose == nil && landlessMasks.lips == nil,
          "no makeup or feature shapes without landmarks")

    var smoothBox = Adjustments(); smoothBox.smooth = 70; smoothBox.texturePreserve = 80
    if let out = processor.renderCGImage(
        processor.process(source, adjustments: smoothBox, masks: landlessMasks,
                          faces: [landless]), scale: 1) {
        check(out.width == size && out.height == size,
              "the landmarkless render has a finite extent")
        let d = localDelta(baseCG, out, normalized: landless.foreheadRect)
        check(d > 0.1, "smoothing still works inside its box",
              String(format: "mean delta %.2f in the forehead band", d))
    } else { check(false, "landmarkless render") }
} else { check(false, "landmarkless masks") }

print("\n[9] a blemish is the same fraction of a face at every resolution")

// The spot radius is derived from face width over the short side, so the same
// face photographed at two resolutions must ask for the same fraction.
let smallFrame = CGRect(x: 0, y: 0, width: 400, height: 400)
let largeFrame = CGRect(x: 0, y: 0, width: 1600, height: 1600)
let smallFraction = ImageProcessor.blemishRadiusFraction(faces: [face(400)], focus: nil,
                                                         extent: smallFrame)
let largeFraction = ImageProcessor.blemishRadiusFraction(faces: [face(1600)], focus: nil,
                                                         extent: largeFrame)
check(abs(smallFraction - largeFraction) < 0.02 * largeFraction,
      "a 400 px and a 1600 px face ask for the same normalized radius",
      String(format: "%.5f vs %.5f", smallFraction, largeFraction))
let smallPx = smallFraction * smallFrame.width
let largePx = largeFraction * largeFrame.width
check(abs(smallPx * 4 - largePx) < 0.02 * largePx,
      "the pixel radius grows with the frame",
      String(format: "%.2f px vs %.2f px", smallPx, largePx))

let bigFraction = ImageProcessor.blemishRadiusFraction(faces: [bigFace, smallFace],
                                                       focus: smallFace, extent: frame)
check(bigFraction < ImageProcessor.blemishRadiusFraction(faces: [bigFace, smallFace],
                                                          focus: nil, extent: frame),
      "the chosen face still sets the radius")

// A photo with no spots must come out untouched at any size: the gate is what
// protects clean skin, and it does not know about resolution.
func cleanRenderDelta(size: Int) -> Double? {
    let (cleanSource, cleanBase, _) = makeFace(size: size, pores: false, spots: false)
    let cleanFace = face(size)
    let cleanExtent = CGRect(x: 0, y: 0, width: size, height: size)
    guard let cleanMasks = processor.buildMasks(extent: cleanExtent, faces: [cleanFace]) else {
        return nil
    }
    var cleanAdj = Adjustments(); cleanAdj.blemish = 75
    guard let out = processor.renderCGImage(
        processor.process(cleanSource, adjustments: cleanAdj, masks: cleanMasks,
                          faces: [cleanFace]), scale: 1) else { return nil }
    return localDelta(cleanBase, out, normalized: CGRect(x: 0, y: 0, width: 1, height: 1))
}
if let smallClean = cleanRenderDelta(size: 600), let largeClean = cleanRenderDelta(size: 1800) {
    check(smallClean < 1.0 && largeClean < 1.0,
          "blemish removal leaves clean skin alone at both sizes",
          String(format: "%.3f / %.3f levels", smallClean, largeClean))
} else {
    check(false, "clean blemish renders")
}

// The same photo at 3000 px and at the preview size must heal the same spot.
let fullSize = 3000
let previewSize = 1800
let previewScale = CGFloat(previewSize) / CGFloat(fullSize)
let (fullSource, fullBase, _) = makeFace(size: fullSize,
                                         blemishScale: CGFloat(fullSize) / 420,
                                         pores: false)
let previewSource = fullSource
    .applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: previewScale,
        kCIInputAspectRatioKey: 1.0
    ])
    .cropped(to: CGRect(x: 0, y: 0, width: previewSize, height: previewSize))
let fullFace = face(fullSize), previewFace = face(previewSize)
let fullExtent = CGRect(x: 0, y: 0, width: fullSize, height: fullSize)
let previewExtent = CGRect(x: 0, y: 0, width: previewSize, height: previewSize)
var parity = Adjustments(); parity.blemish = 75
let spotRegion = CGRect(x: 0.26, y: 0.54, width: 0.18, height: 0.18)

if let fullMasks = processor.buildMasks(extent: fullExtent, faces: [fullFace]),
   let previewMasks = processor.buildMasks(extent: previewExtent, faces: [previewFace]),
   let fullOut = processor.renderCGImage(
        processor.process(fullSource, adjustments: parity, masks: fullMasks,
                          faces: [fullFace]), scale: 1),
   let previewOut = processor.renderCGImage(
        processor.process(previewSource, adjustments: parity, masks: previewMasks,
                          faces: [previewFace]), scale: 1),
   let fullSmall = processor.renderCGImage(
        CIImage(cgImage: fullOut)
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: previewScale,
                kCIInputAspectRatioKey: 1.0
            ])
            .cropped(to: previewExtent), scale: 1) {
    let d = localDelta(fullSmall, previewOut, normalized: spotRegion)
    check(d >= 0 && d < 5.1,
          "preview and full export heal the spot alike",
          String(format: "mean delta %.2f/255 in the spot region", d))
    let fullSpot = texture(fullOut, CGRect(x: 0.30 * CGFloat(fullSize),
                                           y: (1 - 0.66) * CGFloat(fullSize),
                                           width: 0.08 * CGFloat(fullSize),
                                           height: 0.08 * CGFloat(fullSize)))
    let baseSpot = texture(fullBase, CGRect(x: 0.30 * CGFloat(fullSize),
                                            y: (1 - 0.66) * CGFloat(fullSize),
                                            width: 0.08 * CGFloat(fullSize),
                                            height: 0.08 * CGFloat(fullSize)))
    check(fullSpot < baseSpot,
          "the full export actually repaired the spot",
          String(format: "texture %.2f → %.2f", baseSpot, fullSpot))
} else {
    check(false, "preview/export parity renders")
}

print("\n[10] heal stamps stay round on non-square photos")

// A stamp's radius is a fraction of the short side, so a square normalized
// rect becomes an ellipse whose aspect equals the photo's. The mask must be a
// circle in pixels, and the repair it drives must stay as effective.
func makeHealFixture(width: Int, height: Int, blemishRadius: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.72, blue: 0.64, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    let cx = CGFloat(width) / 2, cy = CGFloat(height) / 2
    ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.35, blue: 0.33, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: cx - blemishRadius, y: cy - blemishRadius,
                               width: blemishRadius * 2, height: blemishRadius * 2))
    return ctx.makeImage()!
}

/// Bounding box of a mask's lit pixels, in image pixels. The 50% contour of a
/// blurred disc sits on the unblurred edge, so feathering does not bias it.
func maskBounds(_ image: CGImage, threshold: UInt8 = 128) -> CGRect? {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
    let bpp = image.bitsPerPixel / 8
    var minX = image.width, minY = image.height, maxX = -1, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width where p[y * image.bytesPerRow + x * bpp] >= threshold {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let roundStamp = HealSpot(center: CGPoint(x: 0.5, y: 0.5), radius: 0.08)
for (label, width, height) in [("3:2", 600, 400), ("2:3", 400, 600), ("1:1", 400, 400)] {
    let frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    guard let healing = processor.spotsMask(extent: frame, spots: [roundStamp]),
          let pass = healing.passes.first,
          let mask = processor.renderCGImage(pass.mask, scale: 1),
          let box = maskBounds(mask) else {
        check(false, "\(label) stamp mask"); continue
    }
    let ratio = box.width / box.height
    check(abs(ratio - 1) <= 0.02,
          "\(label) stamp footprint is round in pixels",
          String(format: "%.0f×%.0f px (ratio %.3f)", box.width, box.height, ratio))
    let expected = 2 * roundStamp.radius * CGFloat(min(width, height))
    check(abs(box.width - expected) <= 2 && abs(box.height - expected) <= 2,
          "\(label) stamp keeps its short-side size",
          String(format: "%.0f×%.0f px, %.0f px expected", box.width, box.height, expected))
}

// A square photo must keep the shape it had before the aspect correction.
if case .ellipse(let squareRect) = HealGeometry.shapes(for: [roundStamp], aspect: 1)[0].kind {
    let legacy = CGRect(x: roundStamp.center.x - roundStamp.radius,
                        y: 1 - roundStamp.center.y - roundStamp.radius,
                        width: roundStamp.radius * 2, height: roundStamp.radius * 2)
    check(squareRect == legacy, "a square photo keeps the original stamp shape")
} else {
    check(false, "a square photo keeps the original stamp shape")
}

for (label, width, height) in [("3:2", 600, 400), ("2:3", 400, 600)] {
    let fixture = makeHealFixture(width: width, height: height, blemishRadius: 10)
    let frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    let before = spotProminence(fixture, 0.5, 0.5)
    guard let healing = processor.spotsMask(extent: frame, spots: [roundStamp]),
          let out = processor.renderCGImage(
            processor.process(CIImage(cgImage: fixture), adjustments: .zero,
                              masks: nil, spots: healing), scale: 1) else {
        check(false, "\(label) stamped heal"); continue
    }
    let after = spotProminence(out, 0.5, 0.5)
    check(after < before * 0.4,
          "\(label) a stamped blemish is cleared",
          String(format: "prominence %.1f → %.1f", before, after))
}

print("\n[11] a 1024 px preview mask set is visually indistinguishable")

// Masks are rasterized at a capped size and upscaled. The preview target is
// 1024 instead of 1600: 40% of the pixels, same edge in output space because
// the feather is scaled with the raster.
let maskSide = 1800
let maskExtent = CGRect(x: 0, y: 0, width: maskSide, height: maskSide)
let maskFace = face(maskSide)
if let fullMasks = processor.buildMasks(extent: maskExtent, faces: [maskFace],
                                        maskDimension: MaskBuilder.maxMaskDimension),
   let lightMasks = processor.buildMasks(extent: maskExtent, faces: [maskFace],
                                         maskDimension: MaskBuilder.previewMaskDimension),
   let fullSkin = fullMasks.skin.flatMap({ processor.renderCGImage($0, scale: 1) }),
   let lightSkin = lightMasks.skin.flatMap({ processor.renderCGImage($0, scale: 1) }),
   let dataA = fullSkin.dataProvider?.data, let dataB = lightSkin.dataProvider?.data {
    let pa = CFDataGetBytePtr(dataA)!, pb = CFDataGetBytePtr(dataB)!
    let bpp = fullSkin.bitsPerPixel / 8
    var differing = 0.0, total = 0.0, sum = 0.0
    for y in stride(from: 0, to: fullSkin.height, by: 2) {
        for x in stride(from: 0, to: fullSkin.width, by: 2) {
            let index = y * fullSkin.bytesPerRow + x * bpp
            total += 1
            let delta = abs(Int(pa[index]) - Int(pb[index]))
            sum += Double(delta)
            if delta > 8 { differing += 1 }
        }
    }
    let fraction = differing / max(total, 1)
    check(fraction < 0.005,
          "shrinking the mask raster moves fewer than 0.5% of pixels",
          String(format: "%.3f%% differ by >8/255, mean %.2f/255",
                 fraction * 100, sum / max(total, 1)))
} else {
    check(false, "preview mask set builds")
}

let rasterRatio = MaskBuilder.previewMaskDimension / MaskBuilder.maxMaskDimension
check(rasterRatio * rasterRatio <= 0.45,
      "the preview mask raster is 40% of the full one",
      String(format: "%.0f%%", rasterRatio * rasterRatio * 100))

print("\n[12] export masks are built at export resolution")

// A preview set is rasterized at 1024 no matter how large the photo is; an
// export set is rasterized at the photo's own resolution up to the cap. The
// feather is expressed in output pixels, so the same normalized edge must
// stay the same width after scaling — measured here as the distance between
// two fixed levels on the mask's ramp, which is resolution-independent.

/// Width in pixels between the 25% and 75% levels of a left-to-right mask
/// edge. The mask bitmap is gamma-encoded, but a fixed pair of levels on a
/// monotone ramp scales with the feather, which is what the ratio needs.
func edgeWidth(_ image: CGImage, row: Int, x0: Int, x1: Int) -> Double? {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data),
          row >= 0, row < image.height else { return nil }
    let bpp = image.bitsPerPixel / 8
    func value(_ x: Int) -> Double { Double(p[row * image.bytesPerRow + x * bpp]) / 255 }
    var low: Double?, high: Double?
    for x in max(1, x0)...min(image.width - 1, x1) {
        let v = value(x), previous = value(x - 1)
        guard v - previous > 0.0001 else { continue }
        if low == nil, previous < 0.25, v >= 0.25 {
            low = Double(x - 1) + (0.25 - previous) / (v - previous)
        }
        if high == nil, previous < 0.75, v >= 0.75 {
            high = Double(x - 1) + (0.75 - previous) / (v - previous)
        }
    }
    guard let low, let high else { return nil }
    return high - low
}

let previewSide = 1100
let exportSide = 2200
if let previewMasks = processor.buildMasks(extent: CGRect(x: 0, y: 0, width: previewSide, height: previewSide),
                                           faces: [face(previewSide)],
                                           maskDimension: MaskBuilder.previewMaskDimension),
   let exportMasks = processor.buildMasks(extent: CGRect(x: 0, y: 0, width: exportSide, height: exportSide),
                                          faces: [face(exportSide)],
                                          maskDimension: MaskBuilder.exportMaskDimension),
   let previewEdge = previewMasks.face.flatMap({ processor.renderCGImage($0, scale: 1) }),
   let exportEdge = exportMasks.face.flatMap({ processor.renderCGImage($0, scale: 1) }),
   let previewWidth = edgeWidth(previewEdge, row: Int(0.4 * Double(previewSide)),
                                x0: Int(0.10 * Double(previewSide)), x1: Int(0.30 * Double(previewSide))),
   let exportWidth = edgeWidth(exportEdge, row: Int(0.4 * Double(exportSide)),
                               x0: Int(0.10 * Double(exportSide)), x1: Int(0.30 * Double(exportSide))) {
    let ratio = exportWidth / previewWidth
    let expected = Double(exportSide) / Double(previewSide)
    check(abs(ratio - expected) / expected < 0.05,
          "the export edge is the preview edge scaled by the resolution ratio",
          String(format: "%.2f× (expect %.2f×): %.1f → %.1f px",
                 ratio, expected, previewWidth, exportWidth))
} else {
    check(false, "export mask edge renders")
}

// A photo larger than the preview is the case that matters: the preview set
// is actually raster-capped there, so the two sets really differ.
check(CGFloat(previewSide) > MaskBuilder.previewMaskDimension,
      "the preview edge fixture is larger than the preview raster")

// Rendering at export resolution with the export set must change pixels only
// near mask boundaries. A global shift would show as differences in the
// background, far from the face.
let localSide = 1600
let (localSource, _, _) = makeFace(size: localSide, blemishScale: 0, pores: true, spots: false)
let localExtent = CGRect(x: 0, y: 0, width: localSide, height: localSide)
let localFace = face(localSide)
if let previewMasks = processor.buildMasks(extent: localExtent, faces: [localFace],
                                           image: localSource,
                                           maskDimension: MaskBuilder.previewMaskDimension),
   let exportMasks = processor.buildMasks(extent: localExtent, faces: [localFace],
                                          image: localSource,
                                          maskDimension: MaskBuilder.exportMaskDimension),
   let previewRender = processor.renderCGImage(
        processor.process(localSource, adjustments: smooth, masks: previewMasks,
                          faces: [localFace]), scale: 1),
   let exportRender = processor.renderCGImage(
        processor.process(localSource, adjustments: smooth, masks: exportMasks,
                          faces: [localFace]), scale: 1),
   let dataA = previewRender.dataProvider?.data, let dataB = exportRender.dataProvider?.data {
    let pa = CFDataGetBytePtr(dataA)!, pb = CFDataGetBytePtr(dataB)!
    let bpp = previewRender.bitsPerPixel / 8
    let faceBox = localFace.boundingBox
    let outsideLeft = Int((faceBox.minX - 0.04) * CGFloat(localSide))
    let outsideRight = Int((faceBox.maxX + 0.04) * CGFloat(localSide))
    let outsideTop = Int((1 - faceBox.maxY - 0.04) * CGFloat(localSide))
    let outsideBottom = Int((1 - faceBox.minY + 0.04) * CGFloat(localSide))
    var differing = 0, outside = 0, maxDelta = 0
    for y in 0..<previewRender.height {
        for x in 0..<previewRender.width {
            let index = y * previewRender.bytesPerRow + x * bpp
            let delta = max(abs(Int(pa[index]) - Int(pb[index])),
                            abs(Int(pa[index + 1]) - Int(pb[index + 1])),
                            abs(Int(pa[index + 2]) - Int(pb[index + 2])))
            maxDelta = max(maxDelta, delta)
            guard delta > 0 else { continue }
            differing += 1
            if x < outsideLeft || x > outsideRight || y < outsideTop || y > outsideBottom {
                outside += 1
            }
        }
    }
    // The old path's baseline was a 1024-raster set stretched over the export
    // frame; this is that same baseline. The frame must not move, and the
    // change has to stay at the level of mask-edge noise.
    check(differing > 0 && outside == 0 && maxDelta <= 4,
          "export masks leave the frame alone and differ only at edge noise",
          "\(differing) pixels differ, \(outside) outside the face, max \(maxDelta)/255")
} else {
    check(false, "export-vs-preview render")
}

print("\n[13] Even Skin Tone keeps luminance and evens chroma")

// Even Skin Tone used to blend the blurred copy over the original, which
// flattened blotches but also dragged their brightness toward the blur. It now
// takes only the blurred copy's chroma, so a darker or lighter patch keeps its
// lightness and only its colour evens out.

func channels(_ image: CGImage, normalized: CGRect) -> [(r: Double, g: Double, b: Double)] {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return [] }
    let bpp = image.bitsPerPixel / 8
    let x0 = max(0, Int(normalized.minX * CGFloat(image.width)))
    let x1 = min(image.width, Int(normalized.maxX * CGFloat(image.width)))
    let y0 = max(0, Int((1 - normalized.maxY) * CGFloat(image.height)))
    let y1 = min(image.height, Int((1 - normalized.minY) * CGFloat(image.height)))
    var pixels: [(r: Double, g: Double, b: Double)] = []
    for y in y0..<y1 {
        for x in x0..<x1 {
            let i = y * image.bytesPerRow + x * bpp
            pixels.append((Double(p[i]), Double(p[i + 1]), Double(p[i + 2])))
        }
    }
    return pixels
}

func displayLuma(_ pixel: (r: Double, g: Double, b: Double)) -> Double {
    0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b
}

/// Spatial unevenness of colour across a patch. A uniform patch has a small
/// variation even when its own colour is strongly saturated; this is what
/// "uneven tone" means, unlike the per-pixel channel spread which mostly
/// tracks saturation.
func chromaVariation(_ pixels: [(r: Double, g: Double, b: Double)]) -> Double {
    guard !pixels.isEmpty else { return 0 }
    func deviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
    return deviation(pixels.map { $0.r - $0.g }) + deviation(pixels.map { $0.b - $0.g })
}

var est = Adjustments(); est.skinToneEvens = 100
if let estOut = render(est) {
    let patch = fRef.leftCheekRect
    let before = channels(baseCG, normalized: patch)
    let after = channels(estOut, normalized: patch)
    let beforeLuma = before.map(displayLuma).reduce(0, +) / Double(max(before.count, 1))
    let afterLuma = after.map(displayLuma).reduce(0, +) / Double(max(after.count, 1))
    check(abs(afterLuma - beforeLuma) < 0.5,
          "the skin patch keeps its mean luminance",
          String(format: "%.1f → %.1f (Δ %.2f/255)", beforeLuma, afterLuma, afterLuma - beforeLuma))

    let beforeVariation = chromaVariation(before), afterVariation = chromaVariation(after)
    check(afterVariation < beforeVariation * 0.92,
          "chroma unevenness drops measurably",
          String(format: "variation %.2f → %.2f", beforeVariation, afterVariation))

    // Luma is preserved per pixel, so even the mask feather cannot create a
    // light or dark halo around the face.
    let boxPixels = channels(baseCG, normalized: fRef.boundingBox)
    let outPixels = channels(estOut, normalized: fRef.boundingBox)
    var maxLumaShift = 0.0
    var clipped = 0
    for (a, b) in zip(boxPixels, outPixels) {
        maxLumaShift = max(maxLumaShift, abs(displayLuma(a) - displayLuma(b)))
        if max(b.r, max(b.g, b.b)) >= 255 { clipped += 1 }
    }
    check(maxLumaShift < 1.0,
          "no luminance step at the mask feather",
          String(format: "max pixel shift %.2f/255", maxLumaShift))
    check(clipped == 0, "slider 100 does not clip", "\(clipped) clipped pixels")
} else {
    check(false, "Even Skin Tone render")
}

let zeroTone = SkinEngine.evenSkinTone(source, strength: 0, mask: masks.skin ?? source, scale: 1)
if let zeroOut = processor.renderCGImage(zeroTone, scale: 1) {
    check(meanDelta(baseCG, zeroOut) < 0.001,
          "slider 0 is an exact no-op", String(format: "mean delta %.4f", meanDelta(baseCG, zeroOut)))
} else {
    check(false, "zero-strength render")
}

print("\n[14] teeth alignment never reaches the lips")

// A bright enamel band with dark gaps, framed by a red lip and pink gum.
// The alignment mask used to grow past the enamel and blend enamel-coloured
// fill into the lip; the fill must stay inside the mouth opening.
func makeMouthFixture(size: Int, enamel: CGRect) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    context.setFillColor(CGColor(srgbRed: 0.82, green: 0.66, blue: 0.58, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: s, height: s))
    // Lip band, larger than the traced lip outline on purpose.
    context.setFillColor(CGColor(srgbRed: 0.55, green: 0.15, blue: 0.18, alpha: 1))
    context.fill(CGRect(x: s * 0.405, y: s * 0.330, width: s * 0.190, height: s * 0.120))
    // Gum above and below the enamel.
    context.setFillColor(CGColor(srgbRed: 0.80, green: 0.52, blue: 0.55, alpha: 1))
    context.fill(CGRect(x: s * 0.41, y: s * (enamel.maxY + 0.002), width: s * 0.18, height: s * 0.020))
    context.fill(CGRect(x: s * 0.41, y: s * (enamel.minY - 0.022), width: s * 0.18, height: s * 0.020))
    // Enamel.
    context.setFillColor(CGColor(srgbRed: 0.80, green: 0.78, blue: 0.72, alpha: 1))
    context.fill(CGRect(x: s * enamel.minX, y: s * enamel.minY,
                        width: s * enamel.width, height: s * enamel.height))
    // Dark gaps between the teeth.
    context.setFillColor(CGColor(srgbRed: 0.26, green: 0.23, blue: 0.21, alpha: 1))
    for x in [0.460, 0.491, 0.522] {
        context.fill(CGRect(x: s * CGFloat(x), y: s * enamel.minY,
                            width: s * 0.008, height: s * enamel.height))
    }
    return context.makeImage()!
}

func point(_ image: CGImage, _ nx: CGFloat, _ ny: CGFloat) -> (r: Double, g: Double, b: Double)? {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
    let bpp = image.bitsPerPixel / 8
    let x = min(image.width - 1, max(0, Int(nx * CGFloat(image.width))))
    let y = min(image.height - 1, max(0, Int((1 - ny) * CGFloat(image.height))))
    let i = y * image.bytesPerRow + x * bpp
    return (Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
}

let mouthSide = 320
let mouthFace = face(mouthSide)
if let enamel = mouthFace.enamelRect {
    let mouthFixture = makeMouthFixture(size: mouthSide, enamel: enamel)
    let mouthSource = CIImage(cgImage: mouthFixture)
    let mouthExtent = CGRect(x: 0, y: 0, width: mouthSide, height: mouthSide)
    guard let mouthMasks = processor.buildMasks(extent: mouthExtent, faces: [mouthFace],
                                                image: mouthSource) else {
        print("could not build the mouth masks"); exit(1)
    }
    var align = Adjustments(); align.teethAlign = 80
    if let before = processor.renderCGImage(mouthSource, scale: 1),
       let after = processor.renderCGImage(
            processor.process(mouthSource, adjustments: align, masks: mouthMasks,
                              faces: [mouthFace]), scale: 1),
       let gapBefore = point(before, 0.495, enamel.midY),
       let gapAfter = point(after, 0.495, enamel.midY),
       let lipBefore = point(before, 0.575, enamel.midY),
       let lipAfter = point(after, 0.575, enamel.midY),
       let gumBefore = point(before, 0.50, enamel.maxY + 0.012),
       let gumAfter = point(after, 0.50, enamel.maxY + 0.012) {
        let gapLift = displayLuma(gapAfter) - displayLuma(gapBefore)
        let lipDelta = max(abs(lipAfter.r - lipBefore.r),
                           max(abs(lipAfter.g - lipBefore.g), abs(lipAfter.b - lipBefore.b)))
        let gumDelta = max(abs(gumAfter.r - gumBefore.r),
                           max(abs(gumAfter.g - gumBefore.g), abs(gumAfter.b - gumBefore.b)))
        check(gapLift > 15,
              "the gap between teeth still closes",
              String(format: "+%.1f levels", gapLift))
        check(lipDelta < 1,
              "the lip keeps its colour",
              String(format: "max channel Δ%.2f/255", lipDelta))
        check(gumDelta < 1,
              "no halo at the gum line",
              String(format: "max channel Δ%.2f/255", gumDelta))
    } else {
        check(false, "teeth alignment render")
    }
} else {
    check(false, "mouth fixture geometry")
}

if let teethMask = masks.teeth,
   let zeroAligned = processor.renderCGImage(
        SkinEngine.alignTeeth(source, strength: 0, mask: teethMask, radius: 6), scale: 1) {
    check(meanDelta(baseCG, zeroAligned) < 0.001,
          "alignment slider 0 is an exact no-op",
          String(format: "mean delta %.4f", meanDelta(baseCG, zeroAligned)))
} else {
    check(false, "zero-strength teeth alignment")
}

print("\n[15] a landmarkless face still gets usable analysis callouts")
// Vision can return a face box with no feature points. Everything the overlay
// draws has to come from that box: finite anchors, leader ends inside the
// frame, and actual ink on a non-square canvas.
let landlessAnalysis = FaceGeometry.synthetic(
    boundingBox: CGRect(x: 0.25, y: 0.22, width: 0.5, height: 0.56),
    hasLandmarks: false)
var allRegions = AnalysisSettings()
allRegions.isEnabled = true
allRegions.regions = Set(AnalysisRegion.allCases)

func inFrame(_ p: CGPoint) -> Bool {
    p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y)
}

let landlessAnchors = AnalysisRegion.allCases.map {
    (region: $0, point: AnalysisRenderer.anchor($0, face: landlessAnalysis))
}
let badAnchors = landlessAnchors.filter { !inFrame($0.point) }
check(badAnchors.isEmpty,
      "every callout anchor is finite and inside the photo",
      badAnchors.map { String(format: "%@ (%.2f, %.2f)", $0.region.rawValue,
                              $0.point.x, $0.point.y) }.joined(separator: ", "))

let landlessEnds = AnalysisRenderer.layout(face: landlessAnalysis, settings: allRegions)
check(landlessEnds.count == AnalysisRegion.allCases.count,
      "every region gets a leader end",
      "\(landlessEnds.count) ends")
let badEnds = landlessEnds.filter { !inFrame($0.value) }
check(badEnds.isEmpty,
      "every leader end is finite and inside the photo",
      badEnds.map { $0.key.rawValue }.joined(separator: ", "))

func inkPixels(_ image: CGImage) -> Int {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
    let bpp = image.bitsPerPixel / 8
    var count = 0
    for y in stride(from: 0, to: image.height, by: 2) {
        for x in stride(from: 0, to: image.width, by: 2)
        where p[y * image.bytesPerRow + x * bpp + 3] > 8 {
            count += 1
        }
    }
    return count
}

let analysisCanvas = CGSize(width: 600, height: 800)
if let outline = AnalysisRenderer.render(size: analysisCanvas, faces: [landlessAnalysis],
                                         settings: allRegions) {
    let ink = inkPixels(outline)
    check(ink > 100, "the dashed overlay draws from the face box alone",
          "\(ink) sampled ink pixels")
} else { check(false, "landmarkless analysis overlay") }

var meshSettings = allRegions
meshSettings.showsMesh = true
if let mesh = AnalysisRenderer.render(size: analysisCanvas, faces: [landlessAnalysis],
                                      settings: meshSettings) {
    check(mesh.width == 600 && mesh.height == 800, "the mesh mode renders without landmarks",
          "\(inkPixels(mesh)) sampled ink pixels")
} else { check(false, "landmarkless analysis mesh") }

print("\n[16] exports drop location and camera identity")
// The writer's default is privacy-preserving; the snapshot only decides
// whether the export pipeline applies it. Non-identifying EXIF, orientation,
// DPI and the colour profile must all survive.
let privacySide = 96
let privacyContext = CGContext(data: nil, width: privacySide, height: privacySide,
                               bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
privacyContext.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
privacyContext.fill(CGRect(x: 0, y: 0, width: privacySide, height: privacySide))
let privacySource = CIImage(cgImage: privacyContext.makeImage()!)
let privacyMetadata: [CFString: Any] = [
    kCGImagePropertyDPIWidth: 300,
    kCGImagePropertyDPIHeight: 300,
    kCGImagePropertyOrientation: 6,
    kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: NSNumber(value: 35.7),
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: NSNumber(value: 51.4),
        kCGImagePropertyGPSLongitudeRef: "E"
    ],
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifCameraOwnerName: "Roham",
        kCGImagePropertyExifBodySerialNumber: "BODY-123",
        kCGImagePropertyExifLensSerialNumber: "LENS-456",
        kCGImagePropertyExifUserComment: "private note",
        kCGImagePropertyExifImageUniqueID: "ABCDEF0123456789",
        kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"
    ],
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFArtist: "Retouch SelfTest",
        kCGImagePropertyTIFFMake: "CameraCo"
    ]
]
let privacyDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-privacy-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: privacyDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: privacyDirectory) }

func exportedProperties(_ name: String) -> [CFString: Any] {
    let url = privacyDirectory.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return [:] }
    return props
}

let privacyRendered = RenderedExport(image: privacySource, carriesSourceMetadata: true)
var privacySnapshot = ExportSnapshot()
privacySnapshot.format = .jpeg
privacySnapshot.quality = 0.95
let wroteStripped = ExportService.write(
    privacyRendered, snapshot: privacySnapshot,
    to: privacyDirectory.appendingPathComponent("stripped.jpg"),
    colorSpace: sRGB, metadata: privacyMetadata)
let strippedProps = exportedProperties("stripped.jpg")
let strippedExif = strippedProps[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
let strippedTIFF = strippedProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
check(wroteStripped && strippedProps[kCGImagePropertyGPSDictionary] == nil,
      "GPS is left out of the export")
check(strippedExif[kCGImagePropertyExifCameraOwnerName] == nil
        && strippedExif[kCGImagePropertyExifBodySerialNumber] == nil
        && strippedExif[kCGImagePropertyExifLensSerialNumber] == nil
        && strippedExif[kCGImagePropertyExifUserComment] == nil
        && strippedExif[kCGImagePropertyExifImageUniqueID] == nil
        && strippedTIFF[kCGImagePropertyTIFFArtist] == nil,
      "owner, serials, comments and artist are left out")
check((strippedExif[kCGImagePropertyExifDateTimeOriginal] as? String) == "2026:01:02 03:04:05"
        && (strippedTIFF[kCGImagePropertyTIFFMake] as? String) == "CameraCo",
      "the rest of EXIF still describes the shot")
let privacyOrientation = (strippedProps[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
let privacyDPI = (strippedProps[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
check(privacyOrientation == 1 && abs(privacyDPI - 300) < 1
        && (strippedProps[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == privacySide,
      "orientation, DPI and size are preserved",
      "orientation \(privacyOrientation), \(Int(privacyDPI)) dpi, \(privacySide) px")
if let source = CGImageSourceCreateWithURL(
        privacyDirectory.appendingPathComponent("stripped.jpg") as CFURL, nil),
   let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
   let data = decoded.dataProvider?.data, let p = CFDataGetBytePtr(data) {
    let bpp = decoded.bitsPerPixel / 8
    let i = (decoded.height / 2) * decoded.bytesPerRow + (decoded.width / 2) * bpp
    let green = Int(p[i + 1])
    check(decoded.colorSpace != nil && abs(green - 128) <= 2,
          "the colour profile and the colour itself survive",
          "mid-grey \(green)/128, profile \(decoded.colorSpace != nil ? "yes" : "no")")
} else { check(false, "privacy export decode") }

// Turning the policy off is the old behaviour: every key travels again.
var keepSnapshot = privacySnapshot
keepSnapshot.stripsPrivacyMetadata = false
let wroteKept = ExportService.write(
    privacyRendered, snapshot: keepSnapshot,
    to: privacyDirectory.appendingPathComponent("kept.jpg"),
    colorSpace: sRGB, metadata: privacyMetadata)
let keptProps = exportedProperties("kept.jpg")
let keptExif = keptProps[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
let keptTIFF = keptProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
check(wroteKept && keptProps[kCGImagePropertyGPSDictionary] != nil
        && (keptExif[kCGImagePropertyExifCameraOwnerName] as? String) == "Roham"
        && (keptExif[kCGImagePropertyExifBodySerialNumber] as? String) == "BODY-123"
        && (keptTIFF[kCGImagePropertyTIFFArtist] as? String) == "Retouch SelfTest",
      "turning the setting off keeps the identity keys")

// One snapshot covers a batch, but each file brings its own metadata.
var secondMetadata = privacyMetadata
secondMetadata[kCGImagePropertyExifDictionary] = [
    kCGImagePropertyExifCameraOwnerName: "Second Owner",
    kCGImagePropertyExifBodySerialNumber: "BODY-999"
]
_ = ExportService.write(privacyRendered, snapshot: keepSnapshot,
                        to: privacyDirectory.appendingPathComponent("second.jpg"),
                        colorSpace: sRGB, metadata: secondMetadata)
let secondExif = exportedProperties("second.jpg")[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
check((secondExif[kCGImagePropertyExifCameraOwnerName] as? String) == "Second Owner"
        && (secondExif[kCGImagePropertyExifBodySerialNumber] as? String) == "BODY-999",
      "a batch row uses its own file's metadata")

for (name, format) in [("stripped.png", ExportFormat.png), ("stripped.tif", .tiff)] {
    var snap = privacySnapshot
    snap.format = format
    snap.quality = 1
    let url = privacyDirectory.appendingPathComponent(name)
    let wrote = ExportService.write(privacyRendered, snapshot: snap, to: url,
                                    colorSpace: sRGB, metadata: privacyMetadata)
    let props = exportedProperties(name)
    guard wrote, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        check(false, "\(name) export")
        continue
    }
    check(image.bitsPerComponent >= 16 && image.colorSpace != nil
            && props[kCGImagePropertyGPSDictionary] == nil,
          "\(name) keeps 16-bit depth and its profile without GPS",
          "\(image.bitsPerComponent)-bit")
}

// MARK: - Orientation

print("\n[O1] orientation maps coordinates and pixels the same way")
func orientationFixture(width: Int, height: Int) -> CIImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width) / 2, height: CGFloat(height)))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: CGFloat(width) / 2, y: 0,
                    width: CGFloat(width) / 2, height: CGFloat(height)))
    return CIImage(cgImage: ctx.makeImage()!)
}

func pixel(_ image: CGImage, x: Int, yFromTop: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
        return (0, 0, 0, 0)
    }
    let offset = yFromTop * image.bytesPerRow + x * 4
    return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255,
            Double(bytes[offset + 2]) / 255, Double(bytes[offset + 3]) / 255)
}

let base = CGSize(width: 200, height: 100)
let quarters = DocumentOrientation(quarterTurns: 1)
check(quarters.outputSize(base: base) == CGSize(width: 100, height: 200),
      "a quarter turn swaps the frame's sides")
let topLeft = quarters.mapPoint(CGPoint(x: 0, y: 0), base: base)
let bottomLeft = quarters.mapPoint(CGPoint(x: 0, y: 1), base: base)
check(abs(topLeft.x - 1) < 0.0001 && abs(topLeft.y) < 0.0001,
      "the old top-left lands on the new top-right", "\(topLeft)")
check(abs(bottomLeft.x) < 0.0001 && abs(bottomLeft.y) < 0.0001,
      "the old bottom-left lands on the new top-left", "\(bottomLeft)")

let roundTrip = quarters.rotatedClockwise().rotatedClockwise().rotatedClockwise()
let original = CGPoint(x: 0.23, y: 0.71)
let back = roundTrip.mapPoint(original, base: base)
check(roundTrip == .identity
        && abs(back.x - original.x) < 0.0001 && abs(back.y - original.y) < 0.0001,
      "four clockwise turns are the identity")

let mirrored = DocumentOrientation(flipped: true).flippedHorizontally()
check(mirrored == .identity, "two flips are the identity")
let flippedPoint = DocumentOrientation(flipped: true)
    .mapPoint(CGPoint(x: 0.1, y: 0.3), base: base)
check(abs(flippedPoint.x - 0.9) < 0.0001 && abs(flippedPoint.y - 0.3) < 0.0001,
      "a flip moves the point across the centre line", "\(flippedPoint)")

let topRightQuarter = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
let mappedCrop = quarters.mapRect(topRightQuarter, base: base)
check(abs(mappedCrop.minX - 0.5) < 0.0001 && abs(mappedCrop.minY - 0.5) < 0.0001
        && abs(mappedCrop.width - 0.5) < 0.0001 && abs(mappedCrop.height - 0.5) < 0.0001,
      "a crop rectangle turns with the frame", "\(mappedCrop)")

let straight = DocumentOrientation(angle: 12)
let centre = straight.mapPoint(CGPoint(x: 0.5, y: 0.5), base: base)
check(abs(centre.x - 0.5) < 0.0001 && abs(centre.y - 0.5) < 0.0001,
      "straighten keeps the centre fixed")
check(straight.mapShortSideFraction(0.1, base: base) > 0.1,
      "straighten enlarges a stamp fraction by the same scale as the pixels",
      "\(straight.mapShortSideFraction(0.1, base: base))")
check(straight.coverScale(base: base) > 1,
      "the cover scale is above one so no corner goes transparent")

if let turned = processor.renderCGImage(quarters.applied(to: orientationFixture(width: 40, height: 20)), scale: 1) {
    let top = pixel(turned, x: 10, yFromTop: 5)
    let bottom = pixel(turned, x: 10, yFromTop: 35)
    check(turned.width == 20 && turned.height == 40,
          "the turned pixels have the swapped size")
    check(top.r > 0.8 && top.b < 0.2,
          "the old left half is the new top half (clockwise)", "\(top)")
    check(bottom.b > 0.8 && bottom.r < 0.2,
          "the old right half is the new bottom half", "\(bottom)")
} else {
    check(false, "quarter turn render")
}

if let flippedImage = processor.renderCGImage(
        DocumentOrientation(flipped: true).applied(to: orientationFixture(width: 40, height: 20)),
        scale: 1) {
    let left = pixel(flippedImage, x: 5, yFromTop: 10)
    let right = pixel(flippedImage, x: 35, yFromTop: 10)
    check(left.b > 0.8 && left.r < 0.2 && right.r > 0.8 && right.b < 0.2,
          "a flip moves the left half to the right", "L\(left) R\(right)")
} else {
    check(false, "flip render")
}

if let straightened = processor.renderCGImage(straight.applied(to: orientationFixture(width: 40, height: 20)), scale: 1) {
    let corner = pixel(straightened, x: 0, yFromTop: 0)
    check(straightened.width == 40 && straightened.height == 20 && corner.a > 0.99,
          "straighten keeps the frame size and covers the corner", "\(corner)")
} else {
    check(false, "straighten render")
}

if let patchTurned = processor.renderCGImage(
        AICompositor.oriented(orientationFixture(width: 40, height: 20),
                              by: DocumentOrientation(quarterTurns: 1)),
        scale: 1) {
    let top = pixel(patchTurned, x: patchTurned.width / 2, yFromTop: 5)
    check(top.r > 0.8 && top.b < 0.2,
          "an AI patch turns with the photo", "\(top)")
} else {
    check(false, "patch turn render")
}

let encoded = try? JSONEncoder().encode(DocumentOrientation(quarterTurns: 1, flipped: true, angle: -7.5))
let decoded = encoded.flatMap { try? JSONDecoder().decode(DocumentOrientation.self, from: $0) }
check(decoded == DocumentOrientation(quarterTurns: 1, flipped: true, angle: -7.5),
      "orientation survives a project write and read")

// MARK: - Watermark

print("\n[W1] the watermark lands where it is asked and nowhere else")

func solidFixture(width: Int, height: Int, value: CGFloat = 0.5) -> CIImage {
    CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

func brightPixels(_ image: CGImage, x: Range<Int>, y: Range<Int>) -> Int {
    var count = 0
    for row in y {
        for column in x where pixel(image, x: column, yFromTop: row).r > 0.65 {
            count += 1
        }
    }
    return count
}

let watermarkCanvas = solidFixture(width: 400, height: 300)
let mark = WatermarkSettings(enabled: true, text: "Retouch",
                             position: .bottomRight, opacity: 1, sizePercent: 6)
if let plain = processor.renderCGImage(watermarkCanvas, scale: 1),
   let marked = processor.renderCGImage(WatermarkRenderer.apply(mark, to: watermarkCanvas), scale: 1) {
    let corner = brightPixels(marked, x: 250..<400, y: 200..<300)
    let farSide = brightPixels(marked, x: 0..<150, y: 0..<150)
    check(corner > 30, "the signature is drawn in the chosen corner", "\(corner) px")
    check(farSide == 0 && brightPixels(plain, x: 250..<400, y: 200..<300) == 0,
          "the rest of the photo is untouched", "\(farSide) px")
} else {
    check(false, "watermark render")
}

var topLeftMark = mark
topLeftMark.position = .topLeft
if let marked = processor.renderCGImage(WatermarkRenderer.apply(topLeftMark, to: watermarkCanvas), scale: 1) {
    check(brightPixels(marked, x: 0..<150, y: 0..<120) > 30
          && brightPixels(marked, x: 250..<400, y: 200..<300) == 0,
          "the position control moves the signature")
} else {
    check(false, "watermark position render")
}

var blank = mark
blank.text = "   "
if let plain = processor.renderCGImage(watermarkCanvas, scale: 1),
   let marked = processor.renderCGImage(WatermarkRenderer.apply(blank, to: watermarkCanvas), scale: 1) {
    check(brightPixels(marked, x: 0..<400, y: 0..<300) == 0
          && plain.width == marked.width,
          "a blank signature draws nothing")
} else {
    check(false, "blank watermark render")
}

var off = mark
off.enabled = false
if let marked = processor.renderCGImage(WatermarkRenderer.apply(off, to: watermarkCanvas), scale: 1) {
    check(brightPixels(marked, x: 0..<400, y: 0..<300) == 0,
          "the switch turns the signature off")
} else {
    check(false, "disabled watermark render")
}

let watermarkEncoded = try? JSONEncoder().encode(mark)
let watermarkDecoded = watermarkEncoded.flatMap {
    try? JSONDecoder().decode(WatermarkSettings.self, from: $0)
}
check(watermarkDecoded == mark, "watermark preferences survive a settings write and read")

// MARK: - Histogram

print("\n[W2] the histogram reads the preview's tones")

func twoToneFixture(width: Int, height: Int, dark: CGFloat, light: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: dark, green: dark, blue: dark, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) / 2, height: CGFloat(height)))
    context.setFillColor(CGColor(srgbRed: light, green: light, blue: light, alpha: 1))
    context.fill(CGRect(x: CGFloat(width) / 2, y: 0,
                        width: CGFloat(width) / 2, height: CGFloat(height)))
    return context.makeImage()!
}

let histogramImage = NSImage(cgImage: twoToneFixture(width: 400, height: 300,
                                                     dark: 0.05, light: 0.95),
                             size: NSSize(width: 400, height: 300))
let histogram = HistogramSampler.bins(from: histogramImage)
check(histogram.red.count == 64 && histogram.luma.count == 64,
      "the histogram has 64 bins per channel")
check(histogram.luma[0...8].reduce(0, +) > 0
      && histogram.luma[50...62].reduce(0, +) > 0,
      "both a dark and a bright tone are counted",
      histogram.luma.enumerated().filter { $0.element > 0 }.map { "\($0.offset)" }.joined(separator: ","))
check(histogram.red == histogram.green && histogram.green == histogram.blue,
      "a neutral image produces equal channel shapes")

// MARK: - Backdrop replacement

print("\n[B1] a chosen backdrop covers the frame and keeps the subject")

func personMaskFixture(width: Int, height: Int) -> CIImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: CGFloat(width) * 0.3, y: CGFloat(height) * 0.3,
                        width: CGFloat(width) * 0.4, height: CGFloat(height) * 0.4))
    return CIImage(cgImage: context.makeImage()!)
}

let subjectCanvas = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
let backdropCanvas = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
let personMask = personMaskFixture(width: 200, height: 100)

if let replaced = processor.renderCGImage(
        SceneEngine.replaceBackground(subjectCanvas, person: personMask,
                                      backdrop: backdropCanvas, amount: 100),
        scale: 1) {
    let corner = pixel(replaced, x: 10, yFromTop: 10)
    let centre = pixel(replaced, x: 100, yFromTop: 50)
    check(corner.b > 0.8 && corner.r < 0.2,
          "the backdrop covers the background", "\(corner)")
    check(centre.r > 0.8 && centre.b < 0.2,
          "the subject is kept", "\(centre)")
} else {
    check(false, "backdrop render")
}

if let untouched = processor.renderCGImage(
        SceneEngine.replaceBackground(subjectCanvas, person: personMask,
                                      backdrop: backdropCanvas, amount: 0),
        scale: 1) {
    let corner = pixel(untouched, x: 10, yFromTop: 10)
    check(corner.r > 0.8 && corner.b < 0.2, "zero strength leaves the photo alone", "\(corner)")
} else {
    check(false, "backdrop strength render")
}

if let filled = processor.renderCGImage(
        SceneEngine.aspectFill(backdropCanvas,
                               to: CGRect(x: 0, y: 0, width: 200, height: 100)),
        scale: 1) {
    let corner = pixel(filled, x: 5, yFromTop: 5)
    check(corner.b > 0.8 && corner.a > 0.99,
          "aspect fill covers the frame without bars", "\(corner)")
} else {
    check(false, "aspect fill render")
}

var backdropAdjustments = Adjustments()
backdropAdjustments.backgroundImage = "abc.png"
backdropAdjustments.backgroundImageName = "studio.png"
backdropAdjustments.backgroundImageAmount = 65
let backdropRoundTrip = (try? JSONEncoder().encode(backdropAdjustments))
    .flatMap { try? JSONDecoder().decode(Adjustments.self, from: $0) }
check(backdropRoundTrip == backdropAdjustments,
      "a backdrop choice survives a project write and read")

if let png = NSBitmapImageRep(cgImage: twoToneFixture(width: 40, height: 30,
                                                     dark: 0.2, light: 0.8))
        .representation(using: .png, properties: [:]) {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("backdrop-\(UUID().uuidString).png")
    try? png.write(to: temporary)
    if let storedName = try? BackdropStore.store(temporary) {
        let stored = BackdropStore.url(for: storedName)
        check(stored != nil && BackdropStore.image(named: storedName) != nil,
              "the chosen file is copied into the backdrop store")
        if let stored { try? FileManager.default.removeItem(at: stored) }
    } else {
        check(false, "backdrop store copy")
    }
    try? FileManager.default.removeItem(at: temporary)
} else {
    check(false, "backdrop fixture png")
}

print("\n" + String(repeating: "-", count: 60))
if failures.isEmpty {
    print("ENGINE TESTS: PASS")
    exit(0)
} else {
    print("ENGINE TESTS: FAIL (\(failures.count))")
    for f in failures { print("   - \(f)") }
    exit(1)
}
