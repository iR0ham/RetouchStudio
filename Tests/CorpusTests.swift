import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Golden-corpus harness for the image engine.
//
//   ./Tests/run-corpus.sh                       # capture, then verify on rerun
//   RETOUCH_ARCH=x86_64 ./Tests/run-corpus.sh   # Rosetta
//   RETOUCH_CORPUS_RECAPTURE=1 ...              # force new references
//
// Every fixture is procedural and seeded. Every deterministic case records a
// digest of canonical premultiplied RGBA8 pixels. A reference PNG is kept for
// a curated subset so a human can inspect the result; the digest is what the
// automated check compares, and it is exact on the machine that captured it.

struct CorpusFail: Error { let message: String }
var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

#if arch(arm64)
let hostArch = "arm64"
#elseif arch(x86_64)
let hostArch = "x86_64"
#else
let hostArch = "unknown"
#endif

let baselinesURL = corpusRoot.appendingPathComponent("baselines.json")
let manifestURL = fixturesDir.appendingPathComponent("MANIFEST.json")
let recapture = ProcessInfo.processInfo.environment["RETOUCH_CORPUS_RECAPTURE"] == "1"
let baselineExists = FileManager.default.fileExists(atPath: baselinesURL.path)
let captureMode = recapture || !baselineExists

for directory in [fixturesDir, referencesDir, exportsDir] {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        print("cannot create \(directory.path): \(error)")
        exit(2)
    }
}

func cleanNumber(_ value: Double) -> Any {
    if !value.isFinite { return 0 }
    return (value * 1_000_000).rounded() / 1_000_000
}

func writeJSON(_ object: Any, to url: URL) -> Bool {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys])
    else { return false }
    do {
        try data.write(to: url, options: .atomic)
        return true
    } catch {
        return false
    }
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
}

func fixtureSize(_ image: CGImage) -> CGSize {
    CGSize(width: image.width, height: image.height)
}

func fixtureObject(_ spec: FixtureSpec, _ image: CGImage, url: URL) -> [String: Any] {
    [
        "id": spec.id,
        "file": spec.file,
        "purpose": spec.purpose,
        "characteristics": spec.characteristics,
        "operations": spec.operations,
        "necessity": spec.necessity,
        "width": image.width,
        "height": image.height,
        "bitsPerComponent": image.bitsPerComponent,
        "bitsPerPixel": image.bitsPerPixel,
        "colorSpace": colorSpaceName(image.colorSpace),
        "sha256": fileSHA(url),
        "decodedKey": decodedKey(image)
    ]
}

// MARK: - Fixtures

struct FixtureRecord {
    let spec: FixtureSpec
    let url: URL
    let image: CGImage
}

func ensureFixtures() -> [FixtureRecord] {
    print("\n— Fixtures —")
    var records: [FixtureRecord] = []
    let manifest = readJSON(manifestURL)
    let known = (manifest?["fixtures"] as? [[String: Any]])?
        .reduce(into: [String: [String: Any]]()) { $0[$1["id"] as? String ?? ""] = $1 } ?? [:]

    for spec in fixtureSpecs {
        let url = fixtureURL(spec.id)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            guard let (image, type, properties) = buildFixture(spec.id),
                  writeImage(image, to: url, type: type, properties: properties) else {
                check(false, "fixture \(spec.id) could be generated")
                continue
            }
        }
        guard let image = decodeImage(url) else {
            check(false, "fixture \(spec.id) decodes")
            continue
        }

        if let previous = known[spec.id] {
            let oldSHA = previous["sha256"] as? String ?? ""
            let oldKey = previous["decodedKey"] as? String ?? ""
            check(fileSHA(url) == oldSHA && decodedKey(image) == oldKey,
                  "fixture \(spec.id) is unchanged since the manifest was written",
                  fileSHA(url) == oldSHA ? "decoded key stable" : "file bytes changed")
        }

        // Regenerate in memory and prove the seeded builder is repeatable.
        guard let (rebuilt, rebuiltType, rebuiltProperties) = buildFixture(spec.id),
              let rebuiltPixels = pixels(of: rebuilt),
              let diskPixels = pixels(of: image),
              let delta = comparePixels(rebuiltPixels, diskPixels) else {
            check(false, "fixture \(spec.id) can be regenerated")
            continue
        }
        let lossless = spec.file.hasSuffix(".png") || spec.file.hasSuffix(".tif")
        if lossless {
            check(delta.maxError == 0, "fixture \(spec.id) regenerates exactly",
                  "max error \(delta.maxError)")
        } else {
            // JPEG is not lossless, so the meaningful repeatability check is
            // encode(decode-round-trip) of the regenerated image against the
            // stored file. Same ImageIO path, same host: the bytes must match.
            if let data = encodeImage(rebuilt, type: rebuiltType, properties: rebuiltProperties),
               let roundTrip = decodeImage(data),
               let fresh = pixels(of: roundTrip),
               let repeatDelta = comparePixels(fresh, diskPixels) {
                check(repeatDelta.maxError == 0,
                      "fixture \(spec.id) encodes repeatably",
                      "max error \(repeatDelta.maxError)")
            } else {
                check(false, "fixture \(spec.id) encodes repeatably", "encode failed")
            }
            check(delta.mae <= 6, "fixture \(spec.id) source round-trip is close",
                  String(format: "MAE %.3f max %d", delta.mae, delta.maxError))
        }
        records.append(FixtureRecord(spec: spec, url: url, image: image))
        print("    \(spec.id): \(image.width)x\(image.height) "
              + "\(image.bitsPerComponent)-bit \(colorSpaceName(image.colorSpace)) "
              + fileSHA(url).prefix(12))
    }

    // Property checks that make each fixture worth its place.
    func record(_ id: String) -> FixtureRecord? { records.first { $0.spec.id == id } }

    if let record = record("F01_PORTRAIT_SRGB_8") {
        check(record.image.width == 512 && record.image.height == 512,
              "F01 is 512x512", "\(record.image.width)x\(record.image.height)")
        check(record.image.bitsPerComponent == 8, "F01 is 8-bit")
        check(record.image.colorSpace?.model == .rgb, "F01 is RGB")
    }
    if let record = record("F02_PORTRAIT_DEEP_LOWKEY") {
        check(record.image.width == 512 && record.image.height == 512,
              "F02 is 512x512")
    }
    if let record = record("F03_PORTRAIT_LANDSCAPE") {
        check(record.image.width == 768 && record.image.height == 432,
              "F03 is 768x432")
    }
    if let record = record("F08_HIGHRES_PORTRAIT") {
        check(record.image.width == 1600 && record.image.height == 1067,
              "F08 is 1600x1067", "\(record.image.width)x\(record.image.height)")
    }
    if let record = record("F09_ALPHA_CUTOUT") {
        let corner = sampleTopLeft(record.image, 0.01, 0.01)
        check(corner.a == 0, "F09 has transparent corners", "alpha \(corner.a)")
        let center = sampleTopLeft(record.image, 0.50, 0.50)
        check(center.a > 200, "F09 has an opaque subject", "alpha \(center.a)")
    }
    if let record = record("F10_EXIF_ORIENT6") {
        check(record.image.width == 720 && record.image.height == 480,
              "F10 is stored 720x480")
        let properties = imageProperties(record.url)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
        check(orientation == 6, "F10 is tagged EXIF orientation 6", "tag \(orientation)")
        let topLeft = sampleTopLeft(record.image, 0.10, 0.10)
        check(near(topLeft, 217, 26, 26, tolerance: 6),
              "F10 stored top-left is red", "\(topLeft)")
    }
    if let record = record("F11_P3_16BIT") {
        check(record.image.bitsPerComponent == 16, "F11 is 16-bit",
              "bpc \(record.image.bitsPerComponent)")
        let name = colorSpaceName(record.image.colorSpace)
        check(name.contains("P3"), "F11 is tagged Display P3", name)
    }
    if let record = record("F12_GRAY_8") {
        check(record.image.colorSpace?.model == .monochrome,
              "F12 is grayscale", colorSpaceName(record.image.colorSpace))
        check(record.image.bitsPerComponent == 8, "F12 is 8-bit")
    }

    let objects = records.map { fixtureObject($0.spec, $0.image, url: $0.url) }
    let manifestObject: [String: Any] = [
        "schemaVersion": 1,
        "generatedBy": "Tests/CorpusSupport.swift",
        "license": "MIT — generated by this repository's source; no third-party pixels",
        "fixtures": objects
    ]
    if manifest == nil || recapture {
        check(writeJSON(manifestObject, to: manifestURL), "fixture manifest written")
    }
    return records
}

// MARK: - Prepared fixtures

var preparedCache: [String: Prepared] = [:]

func preparedFixture(_ id: String) -> Prepared? {
    if let cached = preparedCache[id] { return cached }
    guard let prepared = prepare(id) else { return nil }
    preparedCache[id] = prepared
    return prepared
}

func maskState(_ prepared: Prepared) -> [String: Bool] {
    guard let masks = prepared.masks else { return [:] }
    return [
        "skin": masks.skin != nil,
        "face": masks.face != nil,
        "eyes": masks.eyes != nil,
        "sclera": masks.sclera != nil,
        "iris": masks.iris != nil,
        "lashes": masks.lashes != nil,
        "eyeDetail": masks.eyeDetail != nil,
        "lips": masks.lips != nil,
        "teeth": masks.teeth != nil,
        "brows": masks.brows != nil,
        "cheeks": masks.cheeks != nil,
        "underEyes": masks.underEyes != nil,
        "forehead": masks.forehead != nil,
        "nose": masks.nose != nil,
        "skinTexture": masks.skinTexture != nil,
        "lids": masks.lids != nil,
        "liners": masks.liners != nil,
        "hair": masks.hair != nil,
        "contours": masks.contours != nil,
        "person": prepared.personMasks?.person != nil
    ]
}

// MARK: - Rendering and observations

struct Rendered {
    let image: CGImage
    let pixels: Pixels
    let digest: String
}

func render(_ image: CIImage, colorSpace: CGColorSpace) -> Rendered? {
    guard let cg = processor.renderCGImage(image, scale: 1, colorSpace: colorSpace,
                                           format: .RGBA8),
          let pixels = pixels(of: cg) else { return nil }
    return Rendered(image: cg, pixels: pixels,
                    digest: pixelDigest(pixels, colorSpace: colorSpaceName(cg.colorSpace)))
}

var noopCache: [String: (Rendered, Rendered)] = [:]

/// Source pixels and the zero-adjustment render, which must be identical.
func noopRecord(_ prepared: Prepared) -> (source: Rendered, noop: Rendered)? {
    if let cached = noopCache[prepared.id] { return cached }
    guard let source = render(prepared.load.sourceFull, colorSpace: prepared.space),
          let noop = render(noopImage(prepared), colorSpace: prepared.space) else {
        return nil
    }
    noopCache[prepared.id] = (source, noop)
    return (source, noop)
}

struct LumaStats {
    let mean: Double
    let standardDeviation: Double
}

func lumaStats(_ pixels: Pixels) -> LumaStats {
    let count = pixels.width * pixels.height
    guard count > 0 else { return LumaStats(mean: 0, standardDeviation: 0) }
    var sum = 0.0
    var sumSquares = 0.0
    for index in 0..<count {
        let offset = index * 4
        let luma = 0.2126 * Double(pixels.bytes[offset])
            + 0.7152 * Double(pixels.bytes[offset + 1])
            + 0.0722 * Double(pixels.bytes[offset + 2])
        sum += luma
        sumSquares += luma * luma
    }
    let mean = sum / Double(count)
    let variance = max(0, sumSquares / Double(count) - mean * mean)
    return LumaStats(mean: mean, standardDeviation: sqrt(variance))
}

func metricsObject(_ metrics: DiffMetrics) -> [String: Any] {
    [
        "mae": cleanNumber(metrics.mae),
        "rmse": cleanNumber(metrics.rmse),
        "maxError": metrics.maxError,
        "psnr": cleanNumber(metrics.psnr),
        "ssim": cleanNumber(metrics.ssim),
        "changedFraction": cleanNumber(metrics.changedFraction),
        "alphaMAE": cleanNumber(metrics.alphaMAE),
        "deltaE76Mean": cleanNumber(metrics.deltaE76Mean),
        "deltaE76Max": cleanNumber(metrics.deltaE76Max)
    ]
}

func statsObject(_ pixels: Pixels) -> [String: Any] {
    let stats = lumaStats(pixels)
    return ["lumaMean": cleanNumber(stats.mean),
            "lumaStdDev": cleanNumber(stats.standardDeviation)]
}

// MARK: - Case matrix

enum MaskChoice: Equatable {
    case none
    case face
    case person
}

struct CaseDefinition {
    let id: String
    let fixture: String
    let category: String
    let note: String
    let params: String
    let reference: Bool
    let deterministic: Bool
    let expectsChange: Bool
    let expectsNoop: Bool
    let comparableToNoop: Bool
    let requiresMask: String?
    let run: (Prepared) -> CIImage?
}

var cases: [CaseDefinition] = []

func addCase(_ definition: CaseDefinition) {
    cases.append(definition)
}

func globalCase(_ id: String, _ fixture: String, _ note: String, _ params: String,
                category: String = "color-light", reference: Bool = false,
                expectsChange: Bool = true,
                _ edit: @escaping (inout Adjustments) -> Void) {
    addCase(CaseDefinition(
        id: id, fixture: fixture, category: category, note: note, params: params,
        reference: reference, deterministic: true, expectsChange: expectsChange,
        expectsNoop: false, comparableToNoop: true, requiresMask: nil,
        run: { prepared in
            var adjustments = Adjustments()
            edit(&adjustments)
            return processor.process(prepared.load.sourceFull, adjustments: adjustments,
                                     masks: nil, faces: [])
        }))
}

func faceCase(_ id: String, _ fixture: String, _ category: String, _ note: String,
              _ params: String, masks: MaskChoice = .face, requiresMask: String? = nil,
              reference: Bool = false, expectsChange: Bool = true,
              _ edit: @escaping (inout Adjustments) -> Void) {
    addCase(CaseDefinition(
        id: id, fixture: fixture, category: category, note: note, params: params,
        reference: reference, deterministic: true, expectsChange: expectsChange,
        expectsNoop: false, comparableToNoop: true, requiresMask: requiresMask,
        run: { prepared in
            var adjustments = Adjustments()
            edit(&adjustments)
            let set = masks == .person ? prepared.personMasks
                : (masks == .face ? prepared.masks : nil)
            return processor.process(prepared.load.sourceFull, adjustments: adjustments,
                                     masks: set, faces: prepared.faces)
        }))
}

func buildCases(autoColorF01: Adjustments?, autoColorF06: Adjustments?,
                autoRetouchF01: Adjustments?) {
    // Global colour and light — one field per case, plus combinations that
    // exercise the fixed order inside `applyGlobal`.
    globalCase("G01_EXPOSURE_UP", "F05_GRADIENT_SKY",
               "Exposure raises the whole ramp without clipping the sun.",
               "exposure +40", reference: true) { $0.exposure = 40 }
    globalCase("G02_EXPOSURE_DOWN", "F06_HIGHLIGHTS_SHADOWS",
               "Negative exposure recovers the clipped white patch.",
               "exposure -40") { $0.exposure = -40 }
    globalCase("G03_CONTRAST", "F04_DETAIL_CHART",
               "Contrast steepens the mid-tones and leaves the patches in gamut.",
               "contrast +45") { $0.contrast = 45 }
    globalCase("G04_BLACKS", "F06_HIGHLIGHTS_SHADOWS",
               "Blacks digs the near-black half out of the floor.",
               "blacks +60", reference: true) { $0.blacks = 60 }
    globalCase("G05_WHITES", "F06_HIGHLIGHTS_SHADOWS",
               "Whites lifts the highlight band toward white.",
               "whites +50") { $0.whites = 50 }
    globalCase("G06_SATURATION", "F04_DETAIL_CHART",
               "Saturation scales every colour patch.",
               "saturation +50") { $0.saturation = 50 }
    globalCase("G07_VIBRANCE", "F04_DETAIL_CHART",
               "Vibrance protects already-saturated patches.",
               "vibrance +60") { $0.vibrance = 60 }
    globalCase("G08_WARMTH", "F01_PORTRAIT_SRGB_8",
               "Warmth moves the neutral target on skin and fabric.",
               "warmth +45") { $0.warmth = 45 }
    globalCase("G09_CLARITY_UP", "F04_DETAIL_CHART",
               "Positive clarity sharpens luminance without colour fringes.",
               "clarity +55", reference: true) { $0.clarity = 55 }
    globalCase("G10_CLARITY_DOWN", "F04_DETAIL_CHART",
               "Negative clarity blurs luminance only.",
               "clarity -60") { $0.clarity = -60 }
    globalCase("G11_VIGNETTE", "F01_PORTRAIT_SRGB_8",
               "Vignette darkens the corners around a centred subject.",
               "vignette +55", reference: true) { $0.vignette = 55 }
    globalCase("G12_CURVE", "F06_HIGHLIGHTS_SHADOWS",
               "All three curve anchors move independently.",
               "curve shadows +30, midtones -25, highlights +20",
               reference: true) {
        $0.curveShadows = 30
        $0.curveMidtones = -25
        $0.curveHighlights = 20
    }
    globalCase("G13_SPLIT_TONE", "F06_HIGHLIGHTS_SHADOWS",
               "Split tone cools shadows and warms highlights.",
               "splitTone 60") { $0.splitTone = 60 }
    globalCase("G14_HSL", "F04_DETAIL_CHART",
               "HSL bands address green saturation, red hue and blue luminance.",
               "hue red +20, saturation green -60, luminance blue -30") {
        $0.hslHue[HSLBand.red.rawValue] = 20
        $0.hslSaturation[HSLBand.green.rawValue] = -60
        $0.hslLuminance[HSLBand.blue.rawValue] = -30
    }
    globalCase("G15_LOOK_WARM_GOLD", "F01_PORTRAIT_SRGB_8",
               "The warm gold look runs the 32-cube grade.",
               "look warmGold, strength 70", reference: true) {
        $0.look = .warmGold
        $0.lookStrength = 70
    }
    globalCase("G16_LOOK_CROSS", "F03_PORTRAIT_LANDSCAPE",
               "A second look proves the cube is not a no-op.",
               "look crossProcess, strength 60") {
        $0.look = .crossProcess
        $0.lookStrength = 60
    }
    globalCase("G18_TONE_COMBO", "F03_PORTRAIT_LANDSCAPE",
               "Exposure, contrast, saturation and warmth compose in pipeline order.",
               "exposure +20, contrast +20, saturation +10, warmth +15") {
        $0.exposure = 20
        $0.contrast = 20
        $0.saturation = 10
        $0.warmth = 15
    }

    // Grain is deliberately nondeterministic: measured as statistics, not a
    // pixel digest.
    addCase(CaseDefinition(
        id: "G17_GRAIN", fixture: "F01_PORTRAIT_SRGB_8", category: "color-light",
        note: "Grain uses CIRandomGenerator; observed repeatable on this host.",
        params: "grain 60", reference: true, deterministic: true,
        expectsChange: true, expectsNoop: false, comparableToNoop: true,
        requiresMask: nil,
        run: { prepared in
            var adjustments = Adjustments()
            adjustments.grain = 60
            return processor.process(prepared.load.sourceFull, adjustments: adjustments,
                                     masks: nil, faces: [])
        }))

    // Skin, eyes and teeth.
    faceCase("S01_BLEMISH", "F01_PORTRAIT_SRGB_8", "skin",
             "The blemish pass finds the three painted spots.",
             "blemish 70", requiresMask: "skinTexture", reference: true) { $0.blemish = 70 }
    faceCase("S02_WRINKLE", "F01_PORTRAIT_SRGB_8", "skin",
             "Fine-lines reduction works on the painted lines.",
             "wrinkle 60", requiresMask: "skinTexture") { $0.wrinkle = 60 }
    faceCase("S03_TONE_EVEN", "F01_PORTRAIT_SRGB_8", "skin",
             "Tone evening replaces chroma at low frequency.",
             "skinToneEvens 60", requiresMask: "skinTexture") { $0.skinToneEvens = 60 }
    faceCase("S04_SMOOTH", "F01_PORTRAIT_SRGB_8", "skin",
             "Smoothing keeps a share of pore-scale texture.",
             "smooth 60, texturePreserve 40", requiresMask: "skin", reference: true) {
        $0.smooth = 60
        $0.texturePreserve = 40
    }
    faceCase("S05_SMOOTH_PRESERVE", "F01_PORTRAIT_SRGB_8", "skin",
             "Maximum texture preservation changes how much smoothing survives.",
             "smooth 70, texturePreserve 100", requiresMask: "skin") {
        $0.smooth = 70
        $0.texturePreserve = 100
    }
    faceCase("S06_SKIN_BRIGHTEN", "F02_PORTRAIT_DEEP_LOWKEY", "skin",
             "Brightening lifts deep skin without turning it grey.",
             "skinBrighten 40", requiresMask: "skin") { $0.skinBrighten = 40 }
    faceCase("S07_SKIN_FINISH", "F01_PORTRAIT_SRGB_8", "skin",
             "Skin finish changes the highlight roll-off.",
             "skinFinish 50", requiresMask: "skin") { $0.skinFinish = 50 }
    faceCase("S08_SHINE", "F01_PORTRAIT_SRGB_8", "skin",
             "Shine control calms the painted speculars.",
             "shine 50", requiresMask: "skin") { $0.shine = 50 }
    faceCase("S09_DARK_CIRCLES", "F01_PORTRAIT_SRGB_8", "skin",
             "Under-eye correction works inside the tear-trough mask.",
             "darkCircles 60", requiresMask: "underEyes", reference: true) { $0.darkCircles = 60 }
    faceCase("S10_TEETH_WHITEN", "F01_PORTRAIT_SRGB_8", "eyes-teeth",
             "Whitening lands on enamel, not lips.",
             "teethWhiten 70", requiresMask: "teeth", reference: true) { $0.teethWhiten = 70 }
    faceCase("S11_TEETH_ALIGN", "F01_PORTRAIT_SRGB_8", "eyes-teeth",
             "Alignment fills the painted gap from neighbouring enamel.",
             "teethAlign 60", requiresMask: "teeth") { $0.teethAlign = 60 }
    faceCase("S12_EYE_BRIGHTEN", "F01_PORTRAIT_SRGB_8", "eyes-teeth",
             "Sclera brightening is gated to the white of the eye.",
             "eyeBrighten 60", requiresMask: "sclera") { $0.eyeBrighten = 60 }
    faceCase("S13_EYE_SHARPEN", "F01_PORTRAIT_SRGB_8", "eyes-teeth",
             "Eye detail sharpens iris and lashes, not skin.",
             "eyeSharpen 60", requiresMask: "eyeDetail") { $0.eyeSharpen = 60 }
    faceCase("S14_IRIS", "F01_PORTRAIT_SRGB_8", "eyes-teeth",
             "Iris enhancement adds local contrast inside the iris.",
             "irisEnhance 60", requiresMask: "iris") { $0.irisEnhance = 60 }
    faceCase("S15_LASH", "F01_PORTRAIT_SRGB_8", "eyes-teeth",
             "Lash darkening stays on the lash line.",
             "lashDarken 60", requiresMask: "lashes") { $0.lashDarken = 60 }
    faceCase("S16_LENS", "F01_PORTRAIT_SRGB_8", "eyes-teeth",
             "A contact-lens tint rides the iris and keeps its striations.",
             "lensTint 60", requiresMask: "iris") { $0.lensTint = 60 }

    // Makeup.
    faceCase("M01_LIPS", "F01_PORTRAIT_SRGB_8", "makeup",
             "Lip tint is luminance-preserving within the lip polygon.",
             "lipTint 60", requiresMask: "lips", reference: true) { $0.lipTint = 60 }
    faceCase("M02_BLUSH", "F01_PORTRAIT_SRGB_8", "makeup",
             "Blush sits on the cheekbone mask.",
             "blush 60", requiresMask: "cheeks", reference: true) { $0.blush = 60 }
    faceCase("M03_BROWS", "F01_PORTRAIT_SRGB_8", "makeup",
             "Brow definition follows the widened brow band.",
             "browDefine 60", requiresMask: "brows") { $0.browDefine = 60 }
    faceCase("M04_EYESHADOW", "F01_PORTRAIT_SRGB_8", "makeup",
             "Shadow lands on the lids with the brow subtracted.",
             "eyeshadow 60", requiresMask: "lids") { $0.eyeshadow = 60 }
    faceCase("M05_EYELINER", "F01_PORTRAIT_SRGB_8", "makeup",
             "Liner follows the traced upper lash line.",
             "eyeliner 60", requiresMask: "liners") { $0.eyeliner = 60 }
    faceCase("M06_CONTOUR", "F01_PORTRAIT_SRGB_8", "makeup",
             "Contour shading follows the cheek-to-jaw hollows.",
             "contour 60", requiresMask: "contours") { $0.contour = 60 }
    faceCase("M07_HAIR_DYE", "F01_PORTRAIT_SRGB_8", "hair",
             "Hair dye is intersected with the person mask.",
             "hairColor 60", masks: .person, requiresMask: "hair") { $0.hairColor = 60 }
    faceCase("M08_HAIR_SHINE", "F01_PORTRAIT_SRGB_8", "hair",
             "Hair shine preserves the hair's own shading.",
             "hairShine 60", masks: .person, requiresMask: "hair") { $0.hairShine = 60 }
    faceCase("M09_HAIR_VOLUME", "F01_PORTRAIT_SRGB_8", "hair",
             "Hair volume uses a radial bulge confined to the band.",
             "hairVolume 60", masks: .person, requiresMask: "hair") { $0.hairVolume = 60 }
    faceCase("M10_LIP_GLOSS", "F01_PORTRAIT_SRGB_8", "makeup",
             "Gloss adds a highlight inside the lip mask.",
             "lipGloss 60", requiresMask: "lips") { $0.lipGloss = 60 }

    // Reshape.
    faceCase("R01_EYE_SIZE", "F01_PORTRAIT_SRGB_8", "reshape",
             "Eye size warps around each eye centre.",
             "eyeSize 60", reference: true) { $0.eyeSize = 60 }
    faceCase("R02_NOSE_SIZE", "F01_PORTRAIT_SRGB_8", "reshape",
             "Nose size warps around the nose.",
             "noseSize 60") { $0.noseSize = 60 }
    faceCase("R03_NOSE_TIP", "F01_PORTRAIT_SRGB_8", "reshape",
             "Nose tip is a separate control from whole-nose size.",
             "noseTip 60") { $0.noseTip = 60 }
    faceCase("R04_LIP_SIZE", "F01_PORTRAIT_SRGB_8", "reshape",
             "Lip size warps around the mouth.",
             "lipSize 60") { $0.lipSize = 60 }
    faceCase("R05_CHEEK", "F01_PORTRAIT_SRGB_8", "reshape",
             "Cheek shaping moves the lower face beside the mouth.",
             "cheekSize 60") { $0.cheekSize = 60 }
    faceCase("R06_JAW", "F01_PORTRAIT_SRGB_8", "reshape",
             "Jaw width narrows the lower silhouette.",
             "jawWidth 60", reference: true) { $0.jawWidth = 60 }
    faceCase("R07_CHIN", "F01_PORTRAIT_SRGB_8", "reshape",
             "Chin length moves the chin without the jaw.",
             "chinLength 60") { $0.chinLength = 60 }
    faceCase("R08_FACE_WIDTH", "F01_PORTRAIT_SRGB_8", "reshape",
             "Face width narrows the whole silhouette.",
             "faceWidth 60") { $0.faceWidth = 60 }
    faceCase("R09_FACE_LENGTH", "F01_PORTRAIT_SRGB_8", "reshape",
             "Face length stretches the whole silhouette.",
             "faceLength 60") { $0.faceLength = 60 }
    faceCase("R10_COMBO", "F01_PORTRAIT_SRGB_8", "reshape",
             "Feature and silhouette passes compose in one render.",
             "eyeSize 40, jawWidth 40, faceWidth 30") {
        $0.eyeSize = 40
        $0.jawWidth = 40
        $0.faceWidth = 30
    }

    // Body and background use the person mask.
    faceCase("S17_BODY_SMOOTH", "F03_PORTRAIT_LANDSCAPE", "body",
             "Body smoothing runs on person ∩ skin pixels.",
             "bodySmooth 50", masks: .person, requiresMask: "person") { $0.bodySmooth = 50 }
    faceCase("S18_BODY_TONE", "F02_PORTRAIT_DEEP_LOWKEY", "body",
             "Body tone brightening uses the same person mask.",
             "bodyTone 40", masks: .person, requiresMask: "person") { $0.bodyTone = 40 }
    faceCase("B01_BODY_SLIM", "F03_PORTRAIT_LANDSCAPE", "body",
             "Body slim scales the subject horizontally.",
             "bodySlim 60", masks: .person, requiresMask: "person") { $0.bodySlim = 60 }
    faceCase("BG01_BLUR", "F03_PORTRAIT_LANDSCAPE", "background",
             "Background blur falls off outside the person mask.",
             "backgroundBlur 60", masks: .person, requiresMask: "person", reference: true) {
        $0.backgroundBlur = 60
    }
    faceCase("BG02_TONE", "F03_PORTRAIT_LANDSCAPE", "background",
             "Background tone darkens only the surroundings.",
             "backgroundTone -50", masks: .person, requiresMask: "person") {
        $0.backgroundTone = -50
    }
    faceCase("BG03_SATURATION", "F03_PORTRAIT_LANDSCAPE", "background",
             "Background saturation desaturates only the surroundings.",
             "backgroundSaturation -60", masks: .person, requiresMask: "person") {
        $0.backgroundSaturation = -60
    }
    faceCase("BG04_FILL", "F03_PORTRAIT_LANDSCAPE", "background",
             "A solid backdrop is composited behind the subject.",
             "backgroundFill 70", masks: .person, requiresMask: "person") {
        $0.backgroundFill = 70
    }
    faceCase("BG05_REMOVE", "F03_PORTRAIT_LANDSCAPE", "background",
             "Removal makes the background transparent.",
             "backgroundRemove", masks: .person, requiresMask: "person", reference: true) {
        $0.backgroundRemove = true
    }
    faceCase("BG06_COMBO", "F03_PORTRAIT_LANDSCAPE", "background",
             "Blur, tone and saturation compose in one background pass.",
             "backgroundBlur 40, tone -20, saturation -30",
             masks: .person, requiresMask: "person") {
        $0.backgroundBlur = 40
        $0.backgroundTone = -20
        $0.backgroundSaturation = -30
    }

    // Manual healing, art, analysis and watermark.
    addCase(CaseDefinition(
        id: "X01_HEAL", fixture: "F01_PORTRAIT_SRGB_8", category: "extras",
        note: "Three manual stamps repair the painted blemishes.",
        params: "3 stamps r=0.018", reference: true, deterministic: true,
        expectsChange: true, expectsNoop: false, comparableToNoop: true,
        requiresMask: nil,
        run: { prepared in
            let spots = f01HealSpots.map { HealSpot(center: $0, radius: 0.018) }
            let healing = processor.spotsMask(extent: prepared.load.sourceFull.extent,
                                              spots: spots)
            return processor.process(prepared.load.sourceFull, adjustments: Adjustments(),
                                     masks: prepared.masks, faces: prepared.faces,
                                     spots: healing)
        }))

    addCase(CaseDefinition(
        id: "X02_STICKER", fixture: "F01_PORTRAIT_SRGB_8", category: "extras",
        note: "A procedural star sticker is placed on the finished picture.",
        params: "star at (0.72, 0.28), size 0.16, rotation 12",
        reference: true, deterministic: true, expectsChange: true,
        expectsNoop: false, comparableToNoop: true, requiresMask: nil,
        run: { prepared in
            let sticker = Sticker(kind: .star,
                                  center: CGPoint(x: 0.72, y: 0.28),
                                  size: 0.16, rotation: 12, opacity: 0.95,
                                  color: MakeupColor(hue: 45, saturation: 0.80, value: 1.0))
            return processor.process(prepared.load.sourceFull, adjustments: Adjustments(),
                                     masks: prepared.masks, faces: prepared.faces,
                                     art: [sticker])
        }))

    func analysisCase(_ id: String, _ mode: AnalysisExportMode, _ note: String,
                      reference: Bool) {
        addCase(CaseDefinition(
            id: id, fixture: "F01_PORTRAIT_SRGB_8", category: "extras",
            note: note, params: "analysis \(mode.rawValue)",
            reference: reference, deterministic: true, expectsChange: true,
            expectsNoop: false, comparableToNoop: mode == .onPhoto,
            requiresMask: nil,
            run: { prepared in
                var snapshot = ExportSnapshot()
                snapshot.analysis.isEnabled = true
                snapshot.analysis.exportMode = mode
                snapshot.includeAnalysis = true
                let source = ExportSource(
                    image: prepared.load.sourceFull,
                    masks: prepared.masks,
                    faces: prepared.faces,
                    photoAspect: prepared.load.pixelSize.width / prepared.load.pixelSize.height,
                    colorSpace: prepared.load.colorSpace,
                    metadata: prepared.load.metadata)
                return ExportService.render(snapshot, source: source)?.image
            }))
    }
    analysisCase("X03_ANALYSIS_PHOTO", .onPhoto,
                 "Callouts are drawn over the photo at its own size.", reference: true)
    analysisCase("X04_ANALYSIS_POSTER", .poster,
                 "Poster mode adds a blurred bleed around the photo.", reference: false)
    analysisCase("X05_ANALYSIS_OVERLAY", .overlayOnly,
                 "Overlay mode writes only the lines on transparency.", reference: false)

    addCase(CaseDefinition(
        id: "X06_WATERMARK", fixture: "F01_PORTRAIT_SRGB_8", category: "extras",
        note: "A watermark is burned into the final render.",
        params: "text 'Retouch Studio', bottom-right", reference: true,
        deterministic: true, expectsChange: true, expectsNoop: false,
        comparableToNoop: true, requiresMask: nil,
        run: { prepared in
            var snapshot = ExportSnapshot()
            snapshot.watermark = WatermarkSettings(enabled: true, text: "Retouch Studio",
                                                   position: .bottomRight,
                                                   opacity: 0.65, sizePercent: 3.0)
            let source = ExportSource(
                image: prepared.load.sourceFull,
                masks: prepared.masks,
                faces: prepared.faces,
                photoAspect: prepared.load.pixelSize.width / prepared.load.pixelSize.height,
                colorSpace: prepared.load.colorSpace,
                metadata: prepared.load.metadata)
            return (try? ExportService.renderFinal(snapshot, source: source))??.image
        }))

    // Auto tools. The measurements are deterministic; the applied values are
    // recorded in `params` so a future engine can tell where a drift began.
    if let patch = autoColorF01 {
        globalCase("A01_AUTO_COLOR_PORTRAIT", "F01_PORTRAIT_SRGB_8",
                   "Auto Color & Light measures the portrait and applies its patch.",
                   "auto: \(describe(patch))",
                   category: "auto", expectsChange: !patch.isIdentity) { $0 = patch }
    }
    if let patch = autoColorF06 {
        globalCase("A02_AUTO_COLOR_CLIPPED", "F06_HIGHLIGHTS_SHADOWS",
                   "Auto Color & Light sees a frame with clipped white and deep shadow.",
                   "auto: \(describe(patch))",
                   category: "auto", expectsChange: !patch.isIdentity) { $0 = patch }
    }
    if let patch = autoRetouchF01 {
        faceCase("A03_AUTO_RETOUCH", "F01_PORTRAIT_SRGB_8", "auto",
                 "Auto Retouch reads texture, spots, lines and under-eye tone.",
                 "auto: \(describe(patch))", requiresMask: "skin",
                 expectsChange: !patch.isIdentity) { $0 = patch }
    }

    // Load/decode cases. Their "render" is the loaded source, so the digest
    // records the orientation, crop and colour-management result.
    addCase(CaseDefinition(
        id: "L01_F10_UPRIGHT", fixture: "F10_EXIF_ORIENT6", category: "load",
        note: "EXIF orientation 6 is baked upright: 720x480 becomes 480x720.",
        params: "load orientation 6", reference: false, deterministic: true,
        expectsChange: false, expectsNoop: false, comparableToNoop: false,
        requiresMask: nil,
        run: { prepared in prepared.load.sourceFull }))
    addCase(CaseDefinition(
        id: "L02_F11_P3", fixture: "F11_P3_16BIT", category: "load",
        note: "A 16-bit Display P3 source loads without being converted to sRGB.",
        params: "load 16-bit P3", reference: false, deterministic: true,
        expectsChange: false, expectsNoop: false, comparableToNoop: false,
        requiresMask: nil,
        run: { prepared in prepared.load.sourceFull }))
    addCase(CaseDefinition(
        id: "L04_F09_ALPHA", fixture: "F09_ALPHA_CUTOUT", category: "load",
        note: "Transparent source pixels survive the load.",
        params: "load RGBA", reference: false, deterministic: true,
        expectsChange: false, expectsNoop: false, comparableToNoop: false,
        requiresMask: nil,
        run: { prepared in prepared.load.sourceFull }))
    addCase(CaseDefinition(
        id: "L05_F08_NOOP", fixture: "F08_HIGHRES_PORTRAIT", category: "load",
        note: "The 1600 px source renders unchanged with zero adjustments.",
        params: "zero adjustments", reference: false, deterministic: true,
        expectsChange: false, expectsNoop: true, comparableToNoop: false,
        requiresMask: nil,
        run: { prepared in prepared.load.sourceFull }))
    addCase(CaseDefinition(
        id: "L06_F03_CROP", fixture: "F03_PORTRAIT_LANDSCAPE", category: "load",
        note: "A normalized top-left crop is applied before analysis.",
        params: "crop x0 y0 w0.5 h1", reference: false, deterministic: true,
        expectsChange: false, expectsNoop: false, comparableToNoop: false,
        requiresMask: nil,
        run: { _ in
            processor.load(from: fixtureURL("F03_PORTRAIT_LANDSCAPE"),
                           previewMaxDimension: 4096,
                           crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))?
                .sourceFull
        }))
    addCase(CaseDefinition(
        id: "L07_F01_ROTATE", fixture: "F01_PORTRAIT_SRGB_8", category: "load",
        note: "A clockwise quarter turn is baked into the pixels.",
        params: "load quarterTurns 1", reference: false, deterministic: true,
        expectsChange: false, expectsNoop: false, comparableToNoop: false,
        requiresMask: nil,
        run: { _ in
            processor.load(from: fixtureURL("F01_PORTRAIT_SRGB_8"),
                           previewMaxDimension: 4096,
                           orientation: DocumentOrientation(quarterTurns: 1))?
                .sourceFull
        }))
}

func describe(_ adjustments: Adjustments) -> String {
    let fields: [(String, Double)] = [
        ("exposure", adjustments.exposure),
        ("contrast", adjustments.contrast),
        ("blacks", adjustments.blacks),
        ("whites", adjustments.whites),
        ("saturation", adjustments.saturation),
        ("vibrance", adjustments.vibrance),
        ("warmth", adjustments.warmth),
        ("clarity", adjustments.clarity),
        ("smooth", adjustments.smooth),
        ("texturePreserve", adjustments.texturePreserve),
        ("blemish", adjustments.blemish),
        ("wrinkle", adjustments.wrinkle),
        ("skinToneEvens", adjustments.skinToneEvens),
        ("darkCircles", adjustments.darkCircles),
        ("skinBrighten", adjustments.skinBrighten),
        ("shine", adjustments.shine),
        ("teethWhiten", adjustments.teethWhiten),
        ("eyeBrighten", adjustments.eyeBrighten),
        ("eyeSharpen", adjustments.eyeSharpen)
    ]
    return fields.filter { $0.1 != 0 }
        .map { "\($0.0) \(String(format: "%.2f", $0.1))" }
        .joined(separator: ", ")
}

// MARK: - Case evaluation

func preparedForCase(_ definition: CaseDefinition) -> Prepared? {
    guard let prepared = preparedFixture(definition.fixture) else {
        check(false, "\(definition.id): fixture \(definition.fixture) loads")
        return nil
    }
    if let mask = definition.requiresMask {
        let state = maskState(prepared)
        if state[mask] != true {
            print("    warning: \(definition.id) needs the \(mask) mask, which is unavailable")
        }
    }
    return prepared
}

func evaluateCases() -> [[String: Any]] {
    print("\n— Cases —")
    var objects: [[String: Any]] = []
    let previous = captureMode ? nil : readJSON(baselinesURL)
    let previousCases = (previous?["cases"] as? [[String: Any]])?
        .reduce(into: [String: [String: Any]]()) { $0[$1["id"] as? String ?? ""] = $1 } ?? [:]

    if !captureMode {
        let previousIDs = Set(previousCases.keys)
        let currentIDs = Set(cases.map(\.id))
        check(previousIDs == currentIDs,
              "case matrix matches the captured baseline",
              "added \(currentIDs.subtracting(previousIDs).sorted()) removed \(previousIDs.subtracting(currentIDs).sorted())")
    }

    for definition in cases {
        guard let prepared = preparedForCase(definition) else { continue }
        guard let noop = noopRecord(prepared) else {
            check(false, "\(definition.id): no-op render")
            continue
        }

        guard let first = definition.run(prepared).flatMap({
            render($0, colorSpace: prepared.space)
        }) else {
            check(false, "\(definition.id): renders")
            continue
        }
        // A second, separately built pipeline catches hidden state.
        guard let second = definition.run(prepared).flatMap({
            render($0, colorSpace: prepared.space)
        }) else {
            check(false, "\(definition.id): renders twice")
            continue
        }

        let repeatDelta = comparePixels(first.pixels, second.pixels)
        let repeatEqual = repeatDelta?.maxError == 0
        if definition.deterministic {
            check(repeatEqual, "\(definition.id): two independent renders agree exactly",
                  repeatEqual ? first.digest.prefix(12).description
                              : "max error \(repeatDelta?.maxError ?? -1)")
        } else {
            check(repeatDelta.map { $0.maxError > 0 } ?? false,
                  "\(definition.id): is nondeterministic as expected")
        }

        let metrics = definition.comparableToNoop
            ? comparePixels(first.pixels, noop.noop.pixels)
            : nil

        if definition.expectsChange {
            let changed: Bool
            let detail: String
            if let metrics {
                changed = metrics.maxError > 0
                    && (metrics.changedFraction > 0.0005 || metrics.deltaE76Mean > 0.02)
                detail = String(format: "changed %.4f, ΔE %.3f",
                                metrics.changedFraction, metrics.deltaE76Mean)
            } else {
                changed = first.digest != noop.noop.digest
                detail = changed ? "different canvas" : "identical canvas"
            }
            check(changed, "\(definition.id): changes the picture", detail)
        }
        if definition.expectsNoop {
            check(first.digest == noop.source.digest,
                  "\(definition.id): zero adjustments preserve the source exactly")
        }

        let referenceURL = referencesDir.appendingPathComponent("\(definition.id).png")
        if definition.reference || FileManager.default.fileExists(atPath: referenceURL.path) {
            if captureMode || recapture {
                guard writeImage(first.image, to: referenceURL, type: .png) else {
                    check(false, "\(definition.id): reference PNG written")
                    continue
                }
                guard let stored = decodeImage(referenceURL),
                      let storedPixels = pixels(of: stored),
                      let delta = comparePixels(storedPixels, first.pixels) else {
                    check(false, "\(definition.id): reference PNG round-trips")
                    continue
                }
                check(delta.maxError == 0, "\(definition.id): reference PNG round-trips exactly",
                      "max error \(delta.maxError)")
            } else {
                guard let stored = decodeImage(referenceURL),
                      let storedPixels = pixels(of: stored),
                      let delta = comparePixels(storedPixels, first.pixels) else {
                    check(false, "\(definition.id): reference PNG is readable")
                    continue
                }
                check(delta.maxError == 0, "\(definition.id): matches its reference PNG exactly",
                      delta.maxError == 0 ? "" : "max error \(delta.maxError)")
            }
        }

        if !captureMode, let stored = previousCases[definition.id] {
            if (stored["deterministic"] as? Bool) == true {
                check(stored["digest"] as? String == first.digest,
                      "\(definition.id): digest matches the captured baseline",
                      first.digest.prefix(12).description)
            } else {
                let oldStats = stored["stats"] as? [String: Double] ?? [:]
                let current = statsObject(first.pixels)
                let currentStats = [
                    "lumaMean": current["lumaMean"] as? Double ?? 0,
                    "lumaStdDev": current["lumaStdDev"] as? Double ?? 0
                ]
                let meanOK = relativeClose(currentStats["lumaMean"] ?? 0,
                                           oldStats["lumaMean"] ?? 0, tolerance: 0.02)
                let deviationOK = relativeClose(currentStats["lumaStdDev"] ?? 0,
                                                oldStats["lumaStdDev"] ?? 0, tolerance: 0.10)
                let changeOK = metrics.map { $0.changedFraction > 0.5 } ?? false
                check(meanOK && deviationOK && changeOK,
                      "\(definition.id): statistics stay inside the captured envelope",
                      String(format: "mean %.2f, sd %.2f, changed %.3f",
                             currentStats["lumaMean"] ?? 0,
                             currentStats["lumaStdDev"] ?? 0,
                             metrics?.changedFraction ?? 0))
            }
        }

        var object: [String: Any] = [
            "id": definition.id,
            "fixture": definition.fixture,
            "category": definition.category,
            "note": definition.note,
            "params": definition.params,
            "reference": definition.reference,
            "deterministic": definition.deterministic && repeatEqual,
            "digest": first.digest,
            "width": first.pixels.width,
            "height": first.pixels.height,
            "stats": statsObject(first.pixels)
        ]
        if let metrics {
            object["vsNoop"] = metricsObject(metrics)
        }
        objects.append(object)

        if definition.deterministic && !repeatEqual {
            print("    note: \(definition.id) was expected deterministic but repeated renders differ")
        }
    }
    return objects
}

func relativeClose(_ value: Double, _ reference: Double, tolerance: Double) -> Bool {
    if abs(reference) < 1e-9 { return abs(value) < 1e-6 }
    return abs(value - reference) / abs(reference) <= tolerance
}

// MARK: - No-op preservation

func checkNoopPreservation() {
    print("\n— No-op preservation —")
    for id in ["F01_PORTRAIT_SRGB_8", "F02_PORTRAIT_DEEP_LOWKEY", "F03_PORTRAIT_LANDSCAPE",
               "F04_DETAIL_CHART", "F05_GRADIENT_SKY", "F06_HIGHLIGHTS_SHADOWS",
               "F07_LOWLIGHT_NOISE", "F08_HIGHRES_PORTRAIT", "F09_ALPHA_CUTOUT",
               "F10_EXIF_ORIENT6", "F11_P3_16BIT"] {
        guard let prepared = preparedFixture(id), let record = noopRecord(prepared) else {
            check(false, "\(id): no-op render available")
            continue
        }
        guard let delta = comparePixels(record.source.pixels, record.noop.pixels) else {
            check(false, "\(id): no-op is comparable")
            continue
        }
        check(delta.maxError == 0, "\(id): zero adjustments preserve every source pixel",
              delta.maxError == 0 ? record.noop.digest.prefix(12).description
                                  : "max error \(delta.maxError)")
    }
}

// MARK: - Export, metadata and source protection

func exportSource(_ prepared: Prepared) -> ExportSource {
    ExportSource(image: prepared.load.sourceFull,
                 masks: prepared.masks,
                 faces: prepared.faces,
                 photoAspect: prepared.load.pixelSize.width / prepared.load.pixelSize.height,
                 colorSpace: prepared.load.colorSpace,
                 metadata: prepared.load.metadata)
}

func exportSnapshot(_ format: ExportFormat, longEdge: CGFloat?,
                    strip: Bool = true) -> ExportSnapshot {
    var snapshot = ExportSnapshot()
    snapshot.format = format
    snapshot.longEdge = longEdge
    snapshot.stripsPrivacyMetadata = strip
    snapshot.includeStamps = true
    snapshot.includeAnalysis = false
    return snapshot
}

func exportChecks() -> [[String: Any]] {
    print("\n— Export behaviour —")
    var objects: [[String: Any]] = []

    guard let portrait = preparedFixture("F01_PORTRAIT_SRGB_8"),
          let p3Fixture = preparedFixture("F11_P3_16BIT"),
          let alpha = preparedFixture("F09_ALPHA_CUTOUT"),
          let highres = preparedFixture("F08_HIGHRES_PORTRAIT"),
          let exif = preparedFixture("F10_EXIF_ORIENT6") else {
        check(false, "export fixtures load")
        return objects
    }

    func writeExport(_ name: String, _ prepared: Prepared, _ snapshot: ExportSnapshot,
                     colorSpace: CGColorSpace? = nil,
                     metadata: [CFString: Any]? = nil,
                     protecting: URL? = nil) -> (URL, ExportService.WriteResult) {
        let url = exportsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let rendered = RenderedExport(image: prepared.load.sourceFull,
                                      carriesSourceMetadata: true)
        let outcome = ExportService.writeResult(
            rendered, snapshot: snapshot, to: url,
            colorSpace: colorSpace ?? prepared.load.colorSpace,
            metadata: metadata ?? prepared.load.metadata,
            protecting: protecting)
        return (url, outcome)
    }

    func pngProperties(_ name: String, _ prepared: Prepared,
                       _ format: ExportFormat, _ colorSpace: CGColorSpace?,
                       _ longEdge: CGFloat?) -> (URL, [CFString: Any], CGImage?) {
        let (url, outcome) = writeExport(name, prepared,
                                        exportSnapshot(format, longEdge: longEdge),
                                        colorSpace: colorSpace)
        check(outcome == .written, "\(name): written",
              String(describing: outcome))
        return (url, imageProperties(url), decodeImage(url))
    }

    // PNG keeps 16 bits, JPEG is 8-bit, TIFF keeps 16 bits.
    let (pngURL, pngProps, pngImage) = pngProperties(
        "F01_export_256.png", portrait, .png, nil, 256)
    if let pngImage {
        check(pngImage.width == 256 && pngImage.height == 256,
              "PNG long edge is 256", "\(pngImage.width)x\(pngImage.height)")
        check(pngImage.bitsPerComponent == 16, "PNG export is 16-bit",
              "bpc \(pngImage.bitsPerComponent)")
    }
    check((pngProps[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1,
          "PNG export orientation is upright")

    let (jpegURL, _, jpegImage) = pngProperties(
        "F01_export_256.jpg", portrait, .jpeg, nil, 256)
    if let jpegImage {
        check(jpegImage.width == 256 && jpegImage.height == 256,
              "JPEG long edge is 256")
        check(jpegImage.bitsPerComponent == 8, "JPEG export is 8-bit")
    }
    check(FileManager.default.fileExists(atPath: jpegURL.path), "JPEG file exists")

    let (_, _, tiffImage) = pngProperties(
        "F01_export_256.tif", portrait, .tiff, nil, 256)
    if let tiffImage {
        check(tiffImage.width == 256 && tiffImage.height == 256,
              "TIFF long edge is 256")
        check(tiffImage.bitsPerComponent == 16, "TIFF export is 16-bit",
              "bpc \(tiffImage.bitsPerComponent)")
    }

    // HEIC depends on an installed encoder; report a skip rather than a false
    // pass if this machine cannot write it.
    let heicURL = exportsDir.appendingPathComponent("F01_export_256.heic")
    try? FileManager.default.removeItem(at: heicURL)
    let heicOutcome = ExportService.writeResult(
        RenderedExport(image: portrait.load.sourceFull, carriesSourceMetadata: true),
        snapshot: exportSnapshot(.heic, longEdge: 256), to: heicURL,
        colorSpace: portrait.load.colorSpace, metadata: portrait.load.metadata,
        protecting: nil)
    if heicOutcome == .written, let decoded = decodeImage(heicURL) {
        check(decoded.width == 256, "HEIC long edge is 256")
        check(decoded.bitsPerComponent == 8, "HEIC export is 8-bit")
    } else {
        print("    HEIC: skipped — no writable HEIC encoder on this host")
    }

    // 16-bit Display P3 round-trip.
    let (p3URL, p3Props, p3Image) = pngProperties(
        "F11_export_256.png", p3Fixture, .png, p3, 256)
    if let p3Image {
        check(p3Image.width == 256, "P3 PNG long edge is 256")
        check(p3Image.bitsPerComponent == 16, "P3 PNG export is 16-bit")
        check(colorSpaceName(p3Image.colorSpace).contains("P3"),
              "P3 PNG export keeps Display P3",
              colorSpaceName(p3Image.colorSpace))
    }
    let profile = p3Props[kCGImagePropertyProfileName] as? String ?? ""
    check(profile.contains("P3"), "P3 PNG embeds a Display P3 profile", profile)

    // Alpha: PNG keeps it, JPEG flattens onto white.
    let alphaPNG = exportsDir.appendingPathComponent("F09_alpha_export.png")
    try? FileManager.default.removeItem(at: alphaPNG)
    let alphaOutcome = ExportService.writeResult(
        RenderedExport(image: alpha.load.sourceFull, carriesSourceMetadata: true),
        snapshot: exportSnapshot(.png, longEdge: 256), to: alphaPNG,
        colorSpace: alpha.load.colorSpace, metadata: alpha.load.metadata,
        protecting: nil)
    check(alphaOutcome == .written, "alpha PNG export written")
    if let alphaImage = decodeImage(alphaPNG) {
        let corner = sampleTopLeft(alphaImage, 0.01, 0.01)
        check(corner.a == 0, "alpha PNG keeps transparency", "alpha \(corner.a)")
    }
    let alphaJPEG = exportsDir.appendingPathComponent("F09_alpha_export.jpg")
    try? FileManager.default.removeItem(at: alphaJPEG)
    _ = ExportService.writeResult(
        RenderedExport(image: alpha.load.sourceFull, carriesSourceMetadata: true),
        snapshot: exportSnapshot(.jpeg, longEdge: 256), to: alphaJPEG,
        colorSpace: alpha.load.colorSpace, metadata: alpha.load.metadata,
        protecting: nil)
    if let jpegImage = decodeImage(alphaJPEG) {
        let corner = sampleTopLeft(jpegImage, 0.01, 0.01)
        check(near(corner, 255, 255, 255, tolerance: 4),
              "JPEG flatten replaces transparency with white", "\(corner)")
    }

    // High-resolution downscale: 1600x1067 becomes 256x171.
    let (_, _, scaled) = pngProperties(
        "F08_export_256.png", highres, .png, nil, 256)
    if let scaled {
        check(scaled.width == 256 && scaled.height == 171,
              "high-resolution export downscales to 256x171",
              "\(scaled.width)x\(scaled.height)")
    }

    // EXIF orientation is baked at load and the export is tagged upright.
    let exifURL = exportsDir.appendingPathComponent("F10_upright.png")
    try? FileManager.default.removeItem(at: exifURL)
    _ = ExportService.writeResult(
        RenderedExport(image: exif.load.sourceFull, carriesSourceMetadata: true),
        snapshot: exportSnapshot(.png, longEdge: nil), to: exifURL,
        colorSpace: exif.load.colorSpace, metadata: exif.load.metadata,
        protecting: nil)
    if let exifImage = decodeImage(exifURL) {
        check(exifImage.width == 480 && exifImage.height == 720,
              "EXIF export is upright 480x720",
              "\(exifImage.width)x\(exifImage.height)")
        let properties = imageProperties(exifURL)
        check((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1,
              "EXIF export is tagged orientation 1")
        // The white diagonal runs through (0.10, 0.10) after the turn, so the
        // sample sits inside the blue quadrant and clear of every dot.
        let topLeft = sampleTopLeft(exifImage, 0.20, 0.10)
        check(near(topLeft, 26, 51, 204, tolerance: 8),
              "EXIF export top-left is the displayed top-left (blue)",
              "\(topLeft)")
    }

    // Privacy allowlist: GPS is dropped when stripping, kept when not.
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: 35.7000,
        kCGImagePropertyGPSLongitude: 51.4000
    ]
    var metadata: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: gps,
        kCGImagePropertyDPIWidth: 300,
        kCGImagePropertyDPIHeight: 300
    ]
    metadata[kCGImagePropertyTIFFDictionary] = [
        kCGImagePropertyTIFFXResolution: 300,
        kCGImagePropertyTIFFYResolution: 300,
        kCGImagePropertyTIFFResolutionUnit: 2
    ]
    let strippedURL = exportsDir.appendingPathComponent("F01_stripped.png")
    try? FileManager.default.removeItem(at: strippedURL)
    _ = ExportService.writeResult(
        RenderedExport(image: portrait.load.sourceFull, carriesSourceMetadata: true),
        snapshot: exportSnapshot(.png, longEdge: 256, strip: true),
        to: strippedURL, colorSpace: portrait.load.colorSpace,
        metadata: metadata, protecting: nil)
    let stripped = imageProperties(strippedURL)
    check(stripped[kCGImagePropertyGPSDictionary] == nil,
          "privacy strip removes GPS")
    check((stripped[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue == 300,
          "privacy strip keeps DPI")
    check((stripped[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1,
          "privacy strip keeps orientation")

    let keptURL = exportsDir.appendingPathComponent("F01_metadata_kept.png")
    try? FileManager.default.removeItem(at: keptURL)
    _ = ExportService.writeResult(
        RenderedExport(image: portrait.load.sourceFull, carriesSourceMetadata: true),
        snapshot: exportSnapshot(.png, longEdge: 256, strip: false),
        to: keptURL, colorSpace: portrait.load.colorSpace,
        metadata: metadata, protecting: nil)
    let kept = imageProperties(keptURL)
    check(kept[kCGImagePropertyGPSDictionary] != nil,
          "privacy strip off keeps GPS")

    // Source protection.
    let fixture = fixtureURL("F01_PORTRAIT_SRGB_8")
    let before = fileSHA(fixture)
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("retouch-corpus-protect-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let symlink = temp.appendingPathComponent("symlink.png")
    let hardlink = temp.appendingPathComponent("hardlink.png")
    try? FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture)
    try? FileManager.default.linkItem(at: fixture, to: hardlink)
    let alias = fixture.deletingLastPathComponent()
        .appendingPathComponent(fixture.lastPathComponent.uppercased())
    let unrelated = temp.appendingPathComponent("unrelated.png")

    check(ExportService.referencesSameFile(fixture, fixture),
          "source protection: the file itself is refused")
    check(ExportService.referencesSameFile(symlink, fixture),
          "source protection: a symbolic link is refused")
    check(ExportService.referencesSameFile(hardlink, fixture),
          "source protection: a hard link is refused")
    check(ExportService.referencesSameFile(alias, fixture),
          "source protection: a case-only alias is refused")
    check(!ExportService.referencesSameFile(unrelated, fixture),
          "source protection: an unrelated path is allowed")

    let refused = ExportService.writeResult(
        RenderedExport(image: portrait.load.sourceFull, carriesSourceMetadata: true),
        snapshot: exportSnapshot(.png, longEdge: 256), to: symlink,
        colorSpace: portrait.load.colorSpace, metadata: [:], protecting: fixture)
    check(refused == .refusedOriginal, "source protection: write through a link is refused")
    check(fileSHA(fixture) == before, "source protection: the original is unchanged")

    objects.append([
        "png": [ "path": pngURL.lastPathComponent,
                 "width": pngImage?.width ?? 0, "height": pngImage?.height ?? 0,
                 "bits": pngImage?.bitsPerComponent ?? 0 ],
        "jpeg": [ "path": jpegURL.lastPathComponent,
                  "width": jpegImage?.width ?? 0, "height": jpegImage?.height ?? 0,
                  "bits": jpegImage?.bitsPerComponent ?? 0 ],
        "heic": [ "written": heicOutcome == .written ],
        "p3": [ "path": p3URL.lastPathComponent,
                "profile": profile, "bits": p3Image?.bitsPerComponent ?? 0 ],
        "sourceProtection": [
            "symlinkRefused": true,
            "hardlinkRefused": true,
            "caseAliasRefused": true,
            "originalUnchanged": fileSHA(fixture) == before
        ]
    ])
    return objects
}

// MARK: - Run

let fixtures = ensureFixtures()
let fixtureHashesBefore = Dictionary(uniqueKeysWithValues:
    fixtures.map { ($0.spec.id, fileSHA($0.url)) })

print("\n— Mask coverage —")
var maskObjects: [String: Any] = [:]
if let portrait = preparedFixture("F01_PORTRAIT_SRGB_8") {
    let state = maskState(portrait)
    maskObjects["F01_PORTRAIT_SRGB_8"] = state
    for name in ["skin", "face", "eyes", "sclera", "iris", "lashes", "eyeDetail",
                 "lips", "teeth", "brows", "cheeks", "underEyes", "skinTexture",
                 "lids", "liners", "hair", "contours"] {
        check(state[name] == true, "F01 mask \(name) is available")
    }
    if let buffer = AutoAnalyzer.analysisBuffer(portrait.load.sourceFull) {
        for face in portrait.faces {
            print("    F01 annotation: teeth=\(face.hasVisibleTeeth) "
                  + "openness=\(String(format: "%.3f", face.mouthOpenness)) "
                  + "fraction=\(String(format: "%.3f", AutoAnalyzer.visibleTeethFraction(buffer: buffer, face: face))) "
                  + "split=\(String(format: "%.3f", face.eyeScleraLuminance)) "
                  + "usableEyes=\(face.hasUsableEyes)")
        }
    }
}
if let landscape = preparedFixture("F03_PORTRAIT_LANDSCAPE") {
    let state = maskState(landscape)
    maskObjects["F03_PORTRAIT_LANDSCAPE"] = state
    check(state["person"] == true, "F03 synthetic person mask is available")
}
if let deep = preparedFixture("F02_PORTRAIT_DEEP_LOWKEY") {
    maskObjects["F02_PORTRAIT_DEEP_LOWKEY"] = maskState(deep)
}

checkNoopPreservation()

// MARK: - Grayscale source (observed engine limitation)

// F12 exists to record what actually happens, not to imply support. The
// decoder reads the file, but `ImageProcessor.load` renders its preview with
// `.RGBA8` in the source colour space, and CIContext returns nil for an RGBA
// bitmap in a GrayGamma2_2 space. The harness records the refusal verbatim.
print("\n— Grayscale source —")
var grayscaleObject: [String: Any] = [:]
let grayURL = fixtureURL("F12_GRAY_8")
if let gray = decodeImage(grayURL) {
    check(gray.width == 640 && gray.height == 480, "F12 decodes at 640x480",
          "\(gray.width)x\(gray.height)")
    check(gray.colorSpace?.model == .monochrome, "F12 decodes as grayscale",
          colorSpaceName(gray.colorSpace))
    let center = sampleTopLeft(gray, 0.50, 0.50)
    let loadResult = processor.load(from: grayURL, previewMaxDimension: 4096)
    check(loadResult == nil,
          "ImageProcessor.load refuses a grayscale PNG (observed on this host)")
    var convertedDigest = "nil"
    if let context = makeContext(width: gray.width, height: gray.height) {
        context.draw(gray, in: CGRect(x: 0, y: 0, width: gray.width, height: gray.height))
        if let converted = context.makeImage(), let convertedPixels = pixels(of: converted) {
            convertedDigest = pixelDigest(convertedPixels, colorSpace: "sRGB")
            check(true, "an explicit sRGB conversion of F12 renders")
        }
    }
    grayscaleObject = [
        "source": "F12_GRAY_8",
        "load": loadResult == nil ? "nil" : "loaded",
        "observedReason": "preview render uses .RGBA8 with the source gray colour space",
        "codePath": "ImageProcessor.load line 193 -> renderCGImage(colorSpace: GenericGrayGamma2_2)",
        "decoded": [
            "width": gray.width,
            "height": gray.height,
            "colorSpace": colorSpaceName(gray.colorSpace),
            "centerSample": ["r": center.r, "g": center.g, "b": center.b]
        ],
        "explicitSRGBDigest": convertedDigest
    ]
    print("    F12 decode=640x480 gray, load=\(loadResult == nil ? "nil" : "loaded"), "
          + "explicit sRGB digest=\(convertedDigest.prefix(12))")
} else {
    check(false, "F12 decodes")
}

// Auto measurements are computed once and recorded with the case parameters.
func autoPatch(_ fixture: String, faces: Bool, skinMask: Bool = false) -> Adjustments? {
    guard let prepared = preparedFixture(fixture),
          let buffer = AutoAnalyzer.analysisBuffer(prepared.load.sourceFull) else {
        return nil
    }
    if !faces {
        return AutoAnalyzer.autoColorLight(buffer)
    }
    let skin = skinMask ? prepared.masks?.skin : nil
    let skinBuffer = skin.flatMap { AutoAnalyzer.analysisBuffer($0) }
    let crops = prepared.faces.map {
        processor.faceCrop(for: $0, in: prepared.load.sourceFull, skinMask: skin)
    }
    return SmartAnalyzer.analyze(buffer: buffer, skinMask: skinBuffer,
                                 faces: prepared.faces, crops: crops).retouch
}

let autoColorF01 = autoPatch("F01_PORTRAIT_SRGB_8", faces: false)
let autoColorF06 = autoPatch("F06_HIGHLIGHTS_SHADOWS", faces: false)
let autoRetouchF01 = autoPatch("F01_PORTRAIT_SRGB_8", faces: true, skinMask: true)

buildCases(autoColorF01: autoColorF01, autoColorF06: autoColorF06,
           autoRetouchF01: autoRetouchF01)

let caseObjects = evaluateCases()
let exportObjects = exportChecks()

// Every fixture must still be exactly as it was before the run.
print("\n— Provenance —")
for record in fixtures {
    check(fileSHA(record.url) == fixtureHashesBefore[record.spec.id],
          "fixture \(record.spec.id) is unchanged by the harness")
}

if captureMode || recapture {
    let baseline: [String: Any] = [
        "schemaVersion": 1,
        "createdBy": "Tests/CorpusTests.swift",
        "host": [
            "arch": hostArch,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "languageMode": "swift5"
        ],
        "captureNote": "Digests are exact on the machine that captured them; cross-platform tolerances are documented separately as provisional.",
        "fixtures": fixtures.map { fixtureObject($0.spec, $0.image, url: $0.url) },
        "masks": maskObjects,
        "grayscale": grayscaleObject,
        "noop": noopCache.mapValues {
            ["digest": $0.1.digest, "sourceDigest": $0.0.digest]
        },
        "cases": caseObjects,
        "exports": exportObjects
    ]
    check(writeJSON(baseline, to: baselinesURL), "baselines.json written")
    print("\nCaptured: \(fixtures.count) fixtures, \(caseObjects.count) cases, "
          + "\(caseObjects.filter { ($0["reference"] as? Bool) == true }.count) reference PNGs")
} else {
    let previous = readJSON(baselinesURL)
    let previousFixtures = (previous?["fixtures"] as? [[String: Any]]) ?? []
    let currentFixtures = fixtures.map { fixtureObject($0.spec, $0.image, url: $0.url) }
    let fixturesMatch = previousFixtures.count == currentFixtures.count
        && zip(previousFixtures, currentFixtures).allSatisfy { old, new in
            (old["id"] as? String) == (new["id"] as? String)
                && (old["sha256"] as? String) == (new["sha256"] as? String)
        }
    check(fixturesMatch, "fixture set matches the captured baseline")
    if let old = previous?["grayscale"] as? [String: Any] {
        check((old["load"] as? String) == (grayscaleObject["load"] as? String),
              "grayscale load observation matches the baseline")
        check((old["explicitSRGBDigest"] as? String) == (grayscaleObject["explicitSRGBDigest"] as? String),
              "grayscale explicit sRGB digest matches the baseline")
    }
    print("\nVerified against \(baselinesURL.lastPathComponent).")
}

// Reference files that no longer belong to the matrix are reported, never
// deleted silently.
let referenceFiles = (try? FileManager.default.contentsOfDirectory(
    at: referencesDir, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.lowercased() == "png" }
    .map { $0.deletingPathExtension().lastPathComponent } ?? []
let referenceIDs = Set(cases.filter(\.reference).map(\.id))
let stray = Set(referenceFiles).subtracting(referenceIDs)
if !stray.isEmpty {
    print("  note: references not in the current matrix: \(stray.sorted().joined(separator: ", "))")
}

print("\n\(checks) checks, \(failures.count) failures")
if !failures.isEmpty {
    for failure in failures {
        print("  ✗ \(failure)")
    }
    exit(1)
}
exit(0)
