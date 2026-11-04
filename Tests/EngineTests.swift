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

print("\n" + String(repeating: "-", count: 60))
if failures.isEmpty {
    print("ENGINE TESTS: PASS")
    exit(0)
} else {
    print("ENGINE TESTS: FAIL (\(failures.count))")
    for f in failures { print("   - \(f)") }
    exit(1)
}
