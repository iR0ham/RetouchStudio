// Mask quality harness (W5-4): makes the existing geometric face/mask
// pipeline measurable before any learned mask exists or is approved.
//
// What this suite measures
// ------------------------
// 1. Scene regions on committed synthetic portraits. The reference for each
//    region is the shape the fixture generator actually drew (face oval, eye
//    openings, mouth, brow bands), transcribed in
//    Tests/Fixtures/MaskQuality/reference-regions.json from
//    Tests/CorpusSupport.swift. The mask under test is the product's
//    ImageProcessor.buildMasks, fed the fixture's authored landmark layout.
//    Reported per region: IoU, precision, recall and a 2-pixel boundary F1.
//    Gated per region: IoU and the coverage contract's recall/precision floors
//    (a guard mask must cover the drawn feature and cannot grow without bound);
//    boundary F1 is gated for drift between tiers, because the product's masks
//    are deliberately wider than the features and exact tracing was never the
//    contract. Measured at the native tier (mask rasterised at the photo's own
//    pixel size) and at 0.5x (mask rasterised at half size and upscaled, which
//    is what the 1024 px preview cap does to a larger photo).
//
// 2. Analytic shapes. Rect, ellipse, rounded rect, a concave ten-point star,
//    a rect with an erased ellipse, and union/intersection/subtraction of two
//    primitives. The reference is an independent supersampled rasteriser in
//    this file, not Core Graphics and not MaskBuilder, so the comparison is
//    against the mathematical shape rather than against another renderer of
//    the same code.
//
// What this suite deliberately does NOT measure
// ---------------------------------------------
// - Vision detection accuracy. VNDetectFaceLandmarksRequest returns 0 faces on
//   every committed portrait fixture (F01, F02, F03, F08, checked 2026-11-19).
//   No real-face photo is committed and none may be imported from the owner's
//   private library, so the harness measures the pipeline from the fixture's
//   authored landmarks and says so rather than inventing a detector score.
// - Hair, teeth, sclera, iris, lashes, forehead, cheeks, under-eyes, nose,
//   lids, liners and contours. The fixture generator draws hair and teeth from
//   product-derived rects (comparing those masks against the drawing would be
//   circular) and never draws the others as regions. They get invariant checks
//   only and are printed as NO REFERENCE.
//
// Tautology rules
// ---------------
// - The reference regions come from the fixture generator's authored
//   constants, never from FaceGeometry/MaskBuilder outputs.
// - Analytic truth is computed by an independent rasteriser and independent
//   boolean set logic.
// - The mask input is the authored landmark layout, so the measured pipeline
//   is "landmarks -> derived geometry -> raster"; the detector is out of scope
//   and flagged above.
//
// Output: one line per measurement plus a final "MASK QUALITY TESTS: PASS" or
// "... FAIL (n)" line; Tests/run.sh fails on a non-zero exit.

import AppKit
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

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
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"]
               ?? FileManager.default.currentDirectoryPath)
let fixturesDir = root.appendingPathComponent("Tests/Corpus/Fixtures", isDirectory: true)
let referenceURL = root.appendingPathComponent("Tests/Fixtures/MaskQuality/reference-regions.json")

// MARK: - Reference document

struct RectF: Decodable {
    let x: Double, y: Double, width: Double, height: Double
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct RegionRef: Decodable {
    let name: String
    let mask: String
    let shape: String
    let rect: RectF
    let secondRect: RectF?
    let radiusFractionOfHeight: Double?
    let inflatePixels: Double?
    let windowed: Bool?
    let minIouNative: Double
    let minIouHalf: Double
    let source: String
}

/// What every scene region must satisfy at both tiers. A region mask here is a
/// guard, not a tracing: the product widens eyes, brows and the face oval on
/// purpose (shield rects, 1.06x brows, contour plus forehead), so the promise
/// being measured is "covers the drawn feature and does not grow without
/// bound", not "lands exactly on the drawn outline". Boundary F1 is reported
/// per region and gated for stability across tiers, not for an absolute value
/// the product never contracted.
struct CoverageContract: Decodable {
    let minRecallNative: Double
    let minRecallHalf: Double
    let minPrecisionNative: Double
    let minPrecisionHalf: Double
    let maxBoundaryF1Drift: Double
}

struct FixtureRef: Decodable {
    let id: String
    let file: String
    let width: Int
    let height: Int
    let sha256: String
    let faceBox: RectF
    let regions: [RegionRef]
    let skinLeakRegions: [String]
    let coverage: CoverageContract
}

struct AnalyticRef: Decodable {
    let name: String
    let shape: String
    let rect: RectF?
    let hole: RectF?
    let radiusFraction: Double?
    let points: [[Double]]?
}

struct ReferenceDoc: Decodable {
    let schema: String
    let fixtures: [FixtureRef]
    let analytic: [AnalyticRef]
}

guard let docData = try? Data(contentsOf: referenceURL),
      let doc = try? JSONDecoder().decode(ReferenceDoc.self, from: docData) else {
    print("MASK QUALITY TESTS: FAIL (reference document unreadable at \(referenceURL.path))")
    exit(1)
}
print("reference schema \(doc.schema) — \(doc.fixtures.count) fixtures, \(doc.analytic.count) analytic shapes")

// MARK: - Fixture loading

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func sha256Hex(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Geometry helpers

/// The authored landmark layout of the committed portrait generator
/// (Tests/CorpusSupport.swift:423-450). Fractions of the face box, bottom-left
/// origin. This is scene truth for the fixture, not a product derivation.
func authoredFace(box: CGRect) -> FaceGeometry {
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: box.minX + x * box.width, y: box.minY + y * box.height,
               width: w * box.width, height: h * box.height)
    }
    func poly(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    return FaceGeometry.synthetic(
        boundingBox: box,
        faceContour: poly(box),
        leftEye: poly(rect(0.1875, 0.59375, 0.21875, 0.109375)),
        rightEye: poly(rect(0.59375, 0.59375, 0.21875, 0.109375)),
        leftEyebrow: poly(rect(0.171875, 0.734375, 0.25, 0.046875)),
        rightEyebrow: poly(rect(0.578125, 0.734375, 0.25, 0.046875)),
        outerLips: poly(rect(0.34, 0.115, 0.32, 0.115)),
        innerLips: poly(rect(0.36, 0.135, 0.28, 0.09)),
        nose: poly(rect(0.421875, 0.375, 0.15625, 0.125)),
        hasLandmarks: true)
}

/// Normalised (image-space, bottom-left) rect from a face-box fraction.
func place(_ fraction: CGRect, in box: CGRect) -> CGRect {
    CGRect(x: box.minX + fraction.minX * box.width,
           y: box.minY + fraction.minY * box.height,
           width: fraction.width * box.width,
           height: fraction.height * box.height)
}

// MARK: - Independent reference rasteriser

enum RefShape {
    case ellipse(CGRect)
    case roundedRect(CGRect, CGFloat)   // radius as a fraction of the short side
    case polygon([CGPoint])

    func contains(_ x: CGFloat, _ y: CGFloat) -> Bool {
        switch self {
        case .ellipse(let r):
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (x - r.midX) / (r.width / 2)
            let ny = (y - r.midY) / (r.height / 2)
            return nx * nx + ny * ny <= 1
        case .roundedRect(let r, let radiusFraction):
            guard r.width > 0, r.height > 0 else { return false }
            let radius = radiusFraction * min(r.width, r.height)
            if radius <= 0 { return r.contains(CGPoint(x: x, y: y)) }
            let inner = r.insetBy(dx: radius, dy: radius)
            if inner.contains(CGPoint(x: x, y: y)) { return true }
            let clampedX = min(max(x, inner.minX), inner.maxX)
            let clampedY = min(max(y, inner.minY), inner.maxY)
            let dx = x - clampedX
            let dy = y - clampedY
            return dx * dx + dy * dy <= radius * radius
        case .polygon(let points):
            guard points.count >= 3 else { return false }
            var inside = false
            var j = points.count - 1
            for i in 0..<points.count {
                let pi = points[i], pj = points[j]
                if (pi.y > y) != (pj.y > y) {
                    let t = (y - pi.y) / (pj.y - pi.y)
                    if x < pi.x + t * (pj.x - pi.x) { inside.toggle() }
                }
                j = i
            }
            return inside
        }
    }
}

struct ShapeOp {
    let shape: RefShape
    let add: Bool
}

/// Rasterises add/erase shape operations with 8x8 supersampling, foreground at
/// coverage >= 0.5. 8x8 resolves an edge to 1/8 px, well inside the 2 px
/// boundary tolerance, so reference noise cannot masquerade as mask error.
/// Row 0 is the TOP row, matching CGImage/CIBitmap order.
func rasterise(_ ops: [ShapeOp], width: Int, height: Int, clip: CGRect? = nil) -> [Bool] {
    var out = [Bool](repeating: false, count: width * height)
    let clipPixels: (Int, Int, Int, Int)? = clip.map { c in
        let x0 = max(0, Int(floor(c.minX * CGFloat(width))))
        let x1 = min(width, Int(ceil(c.maxX * CGFloat(width))))
        let y0 = max(0, height - Int(ceil(c.maxY * CGFloat(height))))
        let y1 = min(height, height - Int(floor(c.minY * CGFloat(height))))
        return (x0, x1, y0, y1)
    }
    let (cx0, cx1, cy0, cy1) = clipPixels ?? (0, width, 0, height)
    guard cx1 > cx0, cy1 > cy0 else { return out }
    let steps = 8
    let offsets: [CGFloat] = (0..<steps).map { (CGFloat($0) + 0.5) / CGFloat(steps) - 0.5 }
    for row in cy0..<cy1 {
        for col in cx0..<cx1 {
            var hits = 0
            for oy in offsets {
                for ox in offsets {
                    let x = (CGFloat(col) + 0.5 + ox) / CGFloat(width)
                    let y = (CGFloat(height - 1 - row) + 0.5 + oy) / CGFloat(height)
                    var state = false
                    for op in ops where op.shape.contains(x, y) {
                        state = op.add
                    }
                    if state { hits += 1 }
                }
            }
            out[row * width + col] = hits * 2 >= steps * steps
        }
    }
    return out
}

// MARK: - Mask rendering

/// Renders a mask CIImage to per-pixel linear-light coverage, row 0 = top.
/// Core Image blends a mask in linear light, so linear 0.5 is the contour where
/// the effect is half applied - the only contour with a physical meaning for
/// both a blurred guard and a hard edge. Core Graphics antialiases in code
/// space, so a hard edge's linear-0.5 contour lands 0.2-0.4 px inside the
/// geometric edge; that bias is below the 2 px boundary band and is why the
/// analytic IoU floors are 0.97 rather than 0.99.
func renderCoverage(_ image: CIImage, width: Int, height: Int) -> [Double] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    bytes.withUnsafeMutableBytes { buffer in
        processor.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                                 bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                                 format: .RGBA8, colorSpace: sRGB)
    }
    func linear(_ code: UInt8) -> Double {
        let c = Double(code) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    var out = [Double](repeating: 0, count: width * height)
    for i in 0..<(width * height) {
        out[i] = linear(bytes[i * 4])
    }
    return out
}

func binarise(_ coverage: [Double]) -> [Bool] {
    coverage.map { $0 >= 0.5 }
}

// MARK: - Metrics

struct Metrics {
    let iou: Double
    let precision: Double
    let recall: Double
    let boundaryF1: Double
    let boundaryPrecision: Double
    let boundaryRecall: Double
    let maskArea: Int
    let refArea: Int
}

func boundary(_ fg: [Bool], width: Int, height: Int) -> [Bool] {
    var out = [Bool](repeating: false, count: width * height)
    for row in 0..<height {
        for col in 0..<width {
            guard fg[row * width + col] else { continue }
            let up = row > 0 ? fg[(row - 1) * width + col] : false
            let down = row < height - 1 ? fg[(row + 1) * width + col] : false
            let left = col > 0 ? fg[row * width + col - 1] : false
            let right = col < width - 1 ? fg[row * width + col + 1] : false
            out[row * width + col] = !(up && down && left && right)
        }
    }
    return out
}

/// Summed-area table of a binary image, for "any set pixel within radius r".
func integral(_ set: [Bool], width: Int, height: Int) -> [Int] {
    var table = [Int](repeating: 0, count: (width + 1) * (height + 1))
    for row in 0..<height {
        var rowSum = 0
        for col in 0..<width {
            rowSum += set[row * width + col] ? 1 : 0
            table[(row + 1) * (width + 1) + (col + 1)] = table[row * (width + 1) + (col + 1)] + rowSum
        }
    }
    return table
}

func windowSum(_ table: [Int], _ width: Int, _ height: Int, _ r: Int,
               _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
    let a = max(0, x0), b = max(0, y0)
    let c = min(width, x1), d = min(height, y1)
    guard c > a, d > b else { return 0 }
    let stride = width + 1
    return table[d * stride + c] - table[b * stride + c] - table[d * stride + a] + table[b * stride + a]
}

func score(mask: [Bool], reference: [Bool], width: Int, height: Int,
           window: CGRect? = nil) -> Metrics {
    let maskB = boundary(mask, width: width, height: height)
    let refB = boundary(reference, width: width, height: height)
    let maskIntegral = integral(maskB, width: width, height: height)
    let refIntegral = integral(refB, width: width, height: height)
    let tolerance = 2

    var x0 = 0, y0 = 0, x1 = width, y1 = height
    if let w = window {
        x0 = max(0, Int(floor(w.minX * CGFloat(width))))
        x1 = min(width, Int(ceil(w.maxX * CGFloat(width))))
        y0 = max(0, height - Int(ceil(w.maxY * CGFloat(height))))
        y1 = min(height, height - Int(floor(w.minY * CGFloat(height))))
    }
    guard x1 > x0, y1 > y0 else {
        return Metrics(iou: 0, precision: 0, recall: 0, boundaryF1: 0,
                       boundaryPrecision: 0, boundaryRecall: 0, maskArea: 0, refArea: 0)
    }

    var inter = 0, union = 0, maskArea = 0, refArea = 0
    var maskEdge = 0, refEdge = 0, maskNear = 0, refNear = 0
    for row in y0..<y1 {
        for col in x0..<x1 {
            let index = row * width + col
            let m = mask[index], r = reference[index]
            if m && r { inter += 1 }
            if m || r { union += 1 }
            if m { maskArea += 1 }
            if r { refArea += 1 }
            if maskB[index] {
                maskEdge += 1
                if windowSum(refIntegral, width, height, tolerance,
                             col - tolerance, row - tolerance,
                             col + tolerance + 1, row + tolerance + 1) > 0 { maskNear += 1 }
            }
            if refB[index] {
                refEdge += 1
                if windowSum(maskIntegral, width, height, tolerance,
                             col - tolerance, row - tolerance,
                             col + tolerance + 1, row + tolerance + 1) > 0 { refNear += 1 }
            }
        }
    }
    let iou = union == 0 ? 1 : Double(inter) / Double(union)
    let precision = maskArea == 0 ? 1 : Double(inter) / Double(maskArea)
    let recall = refArea == 0 ? 1 : Double(inter) / Double(refArea)
    let boundaryPrecision = maskEdge == 0 ? 1 : Double(maskNear) / Double(maskEdge)
    let boundaryRecall = refEdge == 0 ? 1 : Double(refNear) / Double(refEdge)
    let boundaryF1 = boundaryPrecision + boundaryRecall == 0 ? 0
        : 2 * boundaryPrecision * boundaryRecall / (boundaryPrecision + boundaryRecall)
    return Metrics(iou: iou, precision: precision, recall: recall,
                   boundaryF1: boundaryF1, boundaryPrecision: boundaryPrecision,
                   boundaryRecall: boundaryRecall, maskArea: maskArea, refArea: refArea)
}

func describe(_ m: Metrics) -> String {
    String(format: "IoU %.4f (P %.4f R %.4f) boundaryF1 %.4f (P %.4f R %.4f) area %d/%d",
           m.iou, m.precision, m.recall, m.boundaryF1, m.boundaryPrecision, m.boundaryRecall,
           m.maskArea, m.refArea)
}

/// Mean linear coverage of a mask over the reference foreground, used to check
/// that a mask does not leak into a region it must protect.
func meanCoverage(_ coverage: [Double], over reference: [Bool], width: Int, height: Int,
                  window: CGRect? = nil) -> Double {
    var x0 = 0, y0 = 0, x1 = width, y1 = height
    if let w = window {
        x0 = max(0, Int(floor(w.minX * CGFloat(width))))
        x1 = min(width, Int(ceil(w.maxX * CGFloat(width))))
        y0 = max(0, height - Int(ceil(w.maxY * CGFloat(height))))
        y1 = min(height, height - Int(floor(w.minY * CGFloat(height))))
    }
    var total = 0.0
    var count = 0
    for row in y0..<y1 {
        for col in x0..<x1 {
            let index = row * width + col
            if reference[index] {
                total += coverage[index]
                count += 1
            }
        }
    }
    return count == 0 ? 0 : total / Double(count)
}

func windowFor(_ rect: CGRect, pixels: Int) -> CGRect {
    let margin = max(0.02, 8.0 / CGFloat(pixels))
    return rect.insetBy(dx: -margin, dy: -margin)
}

// MARK: - Fixture checks and scene regions

func regionShape(_ region: RegionRef, box: CGRect, width: Int, height: Int) -> (RefShape, CGRect) {
    let placed = place(region.rect.cg, in: box)
    switch region.shape {
    case "ellipse":
        return (.ellipse(placed), placed)
    case "rounded_rect_pair":
        // Both brows; the caller scores each brow inside its own window.
        return (.roundedRect(placed, CGFloat(region.radiusFractionOfHeight ?? 0.45)), placed)
    case "rect":
        return (.polygon([CGPoint(x: placed.minX, y: placed.minY),
                          CGPoint(x: placed.maxX, y: placed.minY),
                          CGPoint(x: placed.maxX, y: placed.maxY),
                          CGPoint(x: placed.minX, y: placed.maxY)]), placed)
    default:
        return (.ellipse(placed), placed)
    }
}

func maskImage(_ set: MaskSet, _ name: String) -> CIImage? {
    switch name {
    case "face": return set.face
    case "leftEye": return set.leftEye
    case "rightEye": return set.rightEye
    case "lips": return set.lips
    case "brows": return set.brows
    case "skin": return set.skin
    case "forehead": return set.forehead
    case "cheeks": return set.cheeks
    case "nose": return set.nose
    case "underEyes": return set.underEyes
    case "lids": return set.lids
    case "liners": return set.liners
    case "hair": return set.hair
    case "contours": return set.contours
    case "teeth": return set.teeth
    case "eyes": return set.eyes
    default: return nil
    }
}

var sceneScores: [(id: String, tier: Int, region: String, metrics: Metrics)] = []

print("\n== Scene regions: mask vs the shape the committed fixture drew ==")
for fixture in doc.fixtures {
    let url = fixturesDir.appendingPathComponent(fixture.file)
    guard loadImage(url) != nil else {
        check(false, "\(fixture.id): fixture image loads", url.path)
        continue
    }
    let digest = sha256Hex(url) ?? ""
    check(digest == fixture.sha256, "\(fixture.id): fixture is the committed image",
          String(digest.prefix(12)) + "…")
    let width = fixture.width, height = fixture.height
    let box = fixture.faceBox.cg
    let face = authoredFace(box: box)
    let extent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

    for tier in [width, width / 2] {
        guard let set = processor.buildMasks(extent: extent, faces: [face], image: nil,
                                             maskDimension: CGFloat(tier)) else {
            check(false, "\(fixture.id): buildMasks returns a set at \(tier) px")
            continue
        }
        let label = tier == width ? "native" : "half"
        print("-- \(fixture.id) \(width)x\(height) \(label) tier (mask raster \(tier)x\(Int(Double(tier) * Double(height) / Double(width))))")

        for region in fixture.regions {
            let (shape, placed) = regionShape(region, box: box, width: width, height: height)
            guard let image = maskImage(set, region.mask) else {
                check(false, "\(fixture.id) \(label) \(region.name): mask \(region.mask) exists")
                continue
            }
            let coverage = renderCoverage(image, width: width, height: height)
            let mask = binarise(coverage)

            if region.shape == "rounded_rect_pair", let second = region.secondRect {
                let secondPlaced = place(second.cg, in: box)
                let radius = CGFloat(region.radiusFractionOfHeight ?? 0.45)
                let browserRects: [(String, CGRect, RefShape)] = [
                    ("left", placed, .roundedRect(placed, radius)),
                    ("right", secondPlaced, .roundedRect(secondPlaced, radius)),
                ]
                for (side, sideRect, sideShape) in browserRects {
                    let window = windowFor(sideRect, pixels: width)
                    let reference = rasterise([ShapeOp(shape: sideShape, add: true)],
                                              width: width, height: height, clip: window)
                    let metrics = score(mask: mask, reference: reference,
                                        width: width, height: height, window: window)
                    sceneScores.append((fixture.id, tier, "brows[\(side)]", metrics))
                    print("   \(region.name)[\(side)] \(label): \(describe(metrics))")
                    let floor = tier == width ? region.minIouNative : region.minIouHalf
                    check(metrics.iou >= floor, "\(fixture.id) \(label) \(region.name)[\(side)] IoU >= \(floor)",
                          String(format: "%.4f", metrics.iou))
                    let recallFloor = tier == width ? fixture.coverage.minRecallNative : fixture.coverage.minRecallHalf
                    let precisionFloor = tier == width ? fixture.coverage.minPrecisionNative : fixture.coverage.minPrecisionHalf
                    check(metrics.recall >= recallFloor,
                          "\(fixture.id) \(label) \(region.name)[\(side)] covers the drawn shape (recall >= \(recallFloor))",
                          String(format: "%.4f", metrics.recall))
                    check(metrics.precision >= precisionFloor,
                          "\(fixture.id) \(label) \(region.name)[\(side)] spill is bounded (precision >= \(precisionFloor))",
                          String(format: "%.4f", metrics.precision))
                }
                continue
            }

            let window: CGRect? = region.windowed == true ? windowFor(placed, pixels: width) : nil
            let reference = rasterise([ShapeOp(shape: shape, add: true)],
                                      width: width, height: height, clip: window)
            let metrics = score(mask: mask, reference: reference,
                                width: width, height: height, window: window)
            sceneScores.append((fixture.id, tier, region.name, metrics))
            print("   \(region.name) \(label): \(describe(metrics))")
            let floor = tier == width ? region.minIouNative : region.minIouHalf
            check(metrics.iou >= floor, "\(fixture.id) \(label) \(region.name) IoU >= \(floor)",
                  String(format: "%.4f", metrics.iou))
            let recallFloor = tier == width ? fixture.coverage.minRecallNative : fixture.coverage.minRecallHalf
            let precisionFloor = tier == width ? fixture.coverage.minPrecisionNative : fixture.coverage.minPrecisionHalf
            check(metrics.recall >= recallFloor,
                  "\(fixture.id) \(label) \(region.name) covers the drawn shape (recall >= \(recallFloor))",
                  String(format: "%.4f", metrics.recall))
            check(metrics.precision >= precisionFloor,
                  "\(fixture.id) \(label) \(region.name) spill is bounded (precision >= \(precisionFloor))",
                  String(format: "%.4f", metrics.precision))
        }

        // Skin must not leak into the regions the shields protect.
        if let skin = set.skin {
            let skinCoverage = renderCoverage(skin, width: width, height: height)
            for name in fixture.skinLeakRegions {
                guard let region = fixture.regions.first(where: { $0.name == name }) else { continue }
                let (shape, placed) = regionShape(region, box: box, width: width, height: height)
                let reference = rasterise([ShapeOp(shape: shape, add: true)],
                                          width: width, height: height, clip: placed)
                let leak = meanCoverage(skinCoverage, over: reference, width: width, height: height,
                                        window: placed)
                print(String(format: "   skin leak into %@ %@: mean coverage %.4f", name, label, leak))
                check(leak <= 0.03, "\(fixture.id) \(label) skin does not leak into \(name)",
                      String(format: "%.4f", leak))
            }
        }
    }

    // Resolution sensitivity: the boundary measure is reported per tier above;
    // here it must not move by more than the contract allows, which catches a
    // half-tier raster that loses thin features even when IoU stays flat.
    let scoredRegions = Set(sceneScores.filter { $0.id == fixture.id }.map(\.region))
    for name in scoredRegions.sorted() {
        guard let native = sceneScores.first(where: { $0.id == fixture.id && $0.tier == width && $0.region == name }),
              let half = sceneScores.first(where: { $0.id == fixture.id && $0.tier == width / 2 && $0.region == name }) else {
            continue
        }
        let drift = abs(native.metrics.boundaryF1 - half.metrics.boundaryF1)
        check(drift <= fixture.coverage.maxBoundaryF1Drift,
              "\(fixture.id) \(name): boundary F1 drift across tiers <= \(fixture.coverage.maxBoundaryF1Drift)",
              String(format: "%.4f", drift))
    }

    // Invariant checks for regions that have no independent reference.
    if let set = processor.buildMasks(extent: extent, faces: [face], image: nil,
                                      maskDimension: CGFloat(width)) {
        let required: [(String, CIImage?)] = [
            ("skin", set.skin), ("face", set.face), ("eyes", set.eyes), ("lips", set.lips),
            ("brows", set.brows), ("cheeks", set.cheeks), ("forehead", set.forehead),
            ("underEyes", set.underEyes), ("nose", set.nose), ("lids", set.lids),
            ("liners", set.liners), ("hair", set.hair), ("contours", set.contours),
        ]
        let missing = required.filter { $0.1 == nil }.map(\.0)
        check(missing.isEmpty, "\(fixture.id): every geometric region is produced", missing.joined(separator: ","))
        check(set.teeth == nil, "\(fixture.id): teeth is absent without a measured enamel flag")
        check(set.sclera != nil && set.iris != nil && set.lashes != nil,
              "\(fixture.id): eye detail regions exist for the authored eyes")

        func meanPoint(_ image: CIImage) -> CGPoint? {
            let coverage = renderCoverage(image, width: width, height: height)
            var sx = 0.0, sy = 0.0, total = 0.0
            for row in 0..<height {
                for col in 0..<width {
                    let value = coverage[row * width + col]
                    guard value > 0.01 else { continue }
                    sx += Double(col) * value
                    sy += Double(height - 1 - row) * value
                    total += value
                }
            }
            guard total > 0 else { return nil }
            return CGPoint(x: sx / total / Double(width), y: sy / total / Double(height))
        }
        let eyeY = (place(CGRect(x: 0.1875, y: 0.59375, width: 0.21875, height: 0.109375), in: box).maxY
                    + place(CGRect(x: 0.59375, y: 0.59375, width: 0.21875, height: 0.109375), in: box).maxY) / 2
        if let forehead = set.forehead.flatMap(meanPoint) {
            check(forehead.y > eyeY, "\(fixture.id): forehead sits above the eye line",
                  String(format: "y %.3f vs %.3f", forehead.y, eyeY))
        }
        if let cheeks = set.cheeks.flatMap(meanPoint) {
            check(abs(cheeks.x - box.midX) < box.width * 0.25,
                  "\(fixture.id): cheek mask is centred on the face",
                  String(format: "x %.3f vs %.3f", cheeks.x, box.midX))
        }
        if let hair = set.hair.flatMap(meanPoint) {
            check(hair.y > box.midY, "\(fixture.id): hair mask sits on the upper head",
                  String(format: "y %.3f vs %.3f", hair.y, box.midY))
        }
        for name in ["skin", "face", "eyes", "lips", "brows", "cheeks", "forehead",
                     "underEyes", "nose", "lids", "liners", "hair", "contours"] {
            guard let image = maskImage(set, name) else { continue }
            let coverage = renderCoverage(image, width: width, height: height)
            let bad = coverage.filter { $0 < -0.001 || $0 > 1.001 }.count
            check(bad == 0, "\(fixture.id): \(name) coverage stays inside 0...1", "\(bad) outliers")
        }
    }
    print("   NO REFERENCE (not measurable from the committed corpus): hair, teeth, forehead, cheeks, under-eyes, nose, lids, liners, contours, sclera, iris, lashes")
}

// MARK: - Resolution sensitivity across the scene scores

for fixture in doc.fixtures {
    for region in Set(sceneScores.filter { $0.id == fixture.id }.map(\.region)).sorted() {
        let rows = sceneScores.filter { $0.id == fixture.id && $0.region == region }
        guard let native = rows.first(where: { $0.tier == fixture.width }),
              let half = rows.first(where: { $0.tier != fixture.width }) else { continue }
        let drop = native.metrics.iou - half.metrics.iou
        print(String(format: "   %@ %@ native-half IoU drop %.4f", fixture.id, region, drop))
        check(drop <= 0.05, "\(fixture.id) \(region): half-resolution IoU stays within 0.05",
              String(format: "%.4f", drop))
    }
}

// MARK: - Analytic shapes

print("\n== Analytic shapes: MaskBuilder vs an independent supersampled rasteriser ==")

func analyticShape(_ ref: AnalyticRef) -> [ShapeOp] {
    switch ref.shape {
    case "rect":
        let r = ref.rect!.cg
        return [ShapeOp(shape: .polygon([CGPoint(x: r.minX, y: r.minY),
                                         CGPoint(x: r.maxX, y: r.minY),
                                         CGPoint(x: r.maxX, y: r.maxY),
                                         CGPoint(x: r.minX, y: r.maxY)]), add: true)]
    case "ellipse":
        return [ShapeOp(shape: .ellipse(ref.rect!.cg), add: true)]
    case "rounded_rect":
        return [ShapeOp(shape: .roundedRect(ref.rect!.cg, CGFloat(ref.radiusFraction ?? 0.25)), add: true)]
    case "polygon":
        return [ShapeOp(shape: .polygon((ref.points ?? []).map { CGPoint(x: $0[0], y: $0[1]) }), add: true)]
    case "rect_minus_ellipse":
        let r = ref.rect!.cg
        return [ShapeOp(shape: .polygon([CGPoint(x: r.minX, y: r.minY),
                                         CGPoint(x: r.maxX, y: r.minY),
                                         CGPoint(x: r.maxX, y: r.maxY),
                                         CGPoint(x: r.minX, y: r.maxY)]), add: true),
                ShapeOp(shape: .ellipse(ref.hole!.cg), add: false)]
    default:
        return []
    }
}

/// The product-side input for an analytic reference (what the builder is told
/// to draw), as opposed to the reference itself (what the shape is).
func analyticShapes(_ ref: AnalyticRef) -> [MaskShape] {
    switch ref.shape {
    case "rect":
        // cornerRadius 0: the MaskShape init defaults to 0.25, which would draw
        // a rounded rect and make a fair comparison to a sharp reference
        // impossible.
        return [MaskShape(rect: ref.rect!.cg, cornerRadius: 0)]
    case "ellipse":
        return [MaskShape(ellipse: ref.rect!.cg)]
    case "rounded_rect":
        return [MaskShape(rect: ref.rect!.cg, cornerRadius: CGFloat(ref.radiusFraction ?? 0.25))]
    case "polygon":
        return [MaskShape(points: (ref.points ?? []).map { CGPoint(x: $0[0], y: $0[1]) })]
    case "rect_minus_ellipse":
        return [MaskShape(rect: ref.rect!.cg, cornerRadius: 0),
                MaskShape(mode: .erase, ellipse: ref.hole!.cg)]
    default:
        return []
    }
}

let analyticExtent = CGRect(x: 0, y: 0, width: 512, height: 512)
let analyticWidth = 512, analyticHeight = 512

for tier in [512, 256] {
    let label = tier == 512 ? "native" : "half"
    for ref in doc.analytic {
        let ops = analyticShape(ref)
        guard let mask = MaskBuilder.makeMask(extent: analyticExtent, shapes: analyticShapes(ref),
                                              feather: 0, maxDimension: CGFloat(tier)) else {
            check(false, "analytic \(ref.name) \(label): mask builds")
            continue
        }
        let coverage = renderCoverage(mask, width: analyticWidth, height: analyticHeight)
        let reference = rasterise(ops, width: analyticWidth, height: analyticHeight)
        let metrics = score(mask: binarise(coverage), reference: reference,
                            width: analyticWidth, height: analyticHeight)
        print("   analytic \(ref.name) \(label): \(describe(metrics))")
        let iouFloor = tier == 512 ? 0.97 : 0.95
        let boundaryFloor = tier == 512 ? 0.95 : 0.90
        check(metrics.iou >= iouFloor, "analytic \(ref.name) \(label) IoU >= \(iouFloor)",
              String(format: "%.4f", metrics.iou))
        check(metrics.boundaryF1 >= boundaryFloor, "analytic \(ref.name) \(label) boundary F1 >= \(boundaryFloor)",
              String(format: "%.4f", metrics.boundaryF1))
    }

    // Boolean operations (product union/intersect/subtract) against set algebra.
    let r = CGRect(x: 0.10, y: 0.15, width: 0.60, height: 0.45)
    let e = CGRect(x: 0.35, y: 0.25, width: 0.40, height: 0.30)
    let rectMask = MaskBuilder.makeMask(extent: analyticExtent,
                                        shapes: [MaskShape(rect: r, cornerRadius: 0)],
                                        feather: 0, maxDimension: CGFloat(tier))
    let ellipseMask = MaskBuilder.makeMask(extent: analyticExtent, shapes: [MaskShape(ellipse: e)],
                                           feather: 0, maxDimension: CGFloat(tier))
    if let rectMask, let ellipseMask {
        let rectRef = rasterise([ShapeOp(shape: .roundedRect(r, 0), add: true)],
                                width: analyticWidth, height: analyticHeight)
        let ellipseRef = rasterise([ShapeOp(shape: .ellipse(e), add: true)],
                                   width: analyticWidth, height: analyticHeight)
        let operations: [(String, CIImage, [Bool])] = [
            ("union", MaskBuilder.union(rectMask, ellipseMask), zip(rectRef, ellipseRef).map { $0.0 || $0.1 }),
            ("intersect", MaskBuilder.intersect(rectMask, ellipseMask), zip(rectRef, ellipseRef).map { $0.0 && $0.1 }),
            ("subtract", MaskBuilder.subtract(ellipseMask, from: rectMask), zip(rectRef, ellipseRef).map { $0.0 && !$0.1 }),
        ]
        for (name, image, reference) in operations {
            let coverage = renderCoverage(image, width: analyticWidth, height: analyticHeight)
            let metrics = score(mask: binarise(coverage), reference: reference,
                                width: analyticWidth, height: analyticHeight)
            print("   operation \(name) \(label): \(describe(metrics))")
            let floor = tier == 512 ? 0.95 : 0.92
            check(metrics.iou >= floor, "operation \(name) \(label) IoU >= \(floor)",
                  String(format: "%.4f", metrics.iou))
            let boundaryFloor = tier == 512 ? 0.95 : 0.90
            check(metrics.boundaryF1 >= boundaryFloor,
                  "operation \(name) \(label) boundary F1 >= \(boundaryFloor)",
                  String(format: "%.4f", metrics.boundaryF1))
        }
    } else {
        check(false, "operation primitives build at \(label)")
    }
}

// MARK: - Edge behaviour and orientation guard

print("\n== Edge behaviour and orientation ==")

if let soft = MaskBuilder.makeMask(extent: analyticExtent,
                                    shapes: [MaskShape(rect: CGRect(x: 0.25, y: 0.10, width: 0.50, height: 0.80),
                                                       cornerRadius: 0)],
                                    feather: 4, maxDimension: 512) {
    let coverage = renderCoverage(soft, width: 512, height: 512)
    let row = 256
    var transition = 0
    for col in 0..<512 {
        let value = coverage[row * 512 + col]
        if value > 0.1 && value < 0.9 { transition += 1 }
    }
    // The rect's left edge sits between columns 127 and 128 (0.25 * 512).
    // The linear-0.5 contour must land there; the code stored at the edge sits
    // below 0.5 because the blur runs in linear light while storage is sRGB.
    let contour = (0..<512).first { coverage[row * 512 + $0] >= 0.5 } ?? -1
    let offset = abs(contour - 128)
    let atEdge = coverage[row * 512 + 127]
    let outside = coverage[row * 512 + 96]
    let inside = coverage[row * 512 + 200]
    print(String(format: "   feather 4 px: half-coverage contour at column %d (drawn edge 128), coverage at the edge %.3f, 10-90%% ramp %d px, outside %.4f, inside %.3f",
                 contour, atEdge, transition, outside, inside))
    check(transition >= 4 && transition <= 28, "soft edge spans a measured ramp", "\(transition) px")
    check(offset <= 3, "half-coverage contour holds the drawn edge within 3 px", "\(offset) px")
    check(outside < 0.02, "outside the feathered edge stays clear", String(format: "%.4f", outside))
    check(inside > 0.98, "mask interior is fully covered", String(format: "%.3f", inside))

    // Orientation guard: a bottom-anchored strip must match the unflipped
    // reference much better than the vertically flipped one. A silent row-order
    // flip in either renderer would show up here. The floor is a contrast
    // check, not an exactness claim: a 0.10-high strip loses a sliver to
    // antialiasing at its own edges, so upright is expected just under 1.0.
    if let probe = MaskBuilder.makeMask(extent: analyticExtent,
                                        shapes: [MaskShape(rect: CGRect(x: 0.10, y: 0.06, width: 0.55, height: 0.10),
                                                           cornerRadius: 0)],
                                        feather: 0, maxDimension: 512) {
        let probeCoverage = binarise(renderCoverage(probe, width: 512, height: 512))
        let ref = rasterise([ShapeOp(shape: .roundedRect(CGRect(x: 0.10, y: 0.06, width: 0.55, height: 0.10), 0), add: true)],
                            width: 512, height: 512)
        let flipped = (0..<512).map { 511 - $0 }
        let flippedRef = (0..<512).flatMap { row in (0..<512).map { col in ref[flipped[row] * 512 + col] } }
        let upright = score(mask: probeCoverage, reference: ref, width: 512, height: 512)
        let mirror = score(mask: probeCoverage, reference: flippedRef, width: 512, height: 512)
        print(String(format: "   orientation probe: upright IoU %.4f, flipped IoU %.4f",
                     upright.iou, mirror.iou))
        check(upright.iou >= 0.95 && mirror.iou <= 0.6,
              "orientation: bottom-anchored probe matches the upright reference only",
              String(format: "upright %.4f flipped %.4f", upright.iou, mirror.iou))
    }
}

// MARK: - Summary

print("\n" + String(repeating: "-", count: 60))
if failures.isEmpty {
    print("MASK QUALITY TESTS: PASS")
    exit(0)
} else {
    print("MASK QUALITY TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
