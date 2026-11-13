import Foundation
import StudioCore

// StudioCore's focused regressions. This suite links only Foundation and the
// StudioCore module; it is the proof that the extracted domain types do not
// depend on AppKit, SwiftUI, Core Image, Vision or any other Apple framework.

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

let root = ProcessInfo.processInfo.environment["STUDIOCORE_ROOT"]
    ?? FileManager.default.currentDirectoryPath
let fixtureRoot = URL(fileURLWithPath: root)
    .appendingPathComponent("Tests/StudioCoreFixtures", isDirectory: true)
let conformanceRoot = URL(fileURLWithPath: root)
    .appendingPathComponent("Tests/Conformance/Fixtures/canonical", isDirectory: true)

func fixture(_ name: String) -> String {
    let url = fixtureRoot.appendingPathComponent(name)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing \(name)>"
}

func prettySorted<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(value)
    return String(data: data, encoding: .utf8)!
}

let defaults = Adjustments()
var full = Adjustments(
    smooth: 11, blemish: 12, wrinkle: 13, skinToneEvens: 14,
    darkCircles: 15, skinBrighten: 16, texturePreserve: 17,
    teethWhiten: 18, eyeBrighten: 19, eyeSharpen: 20,
    eyeSize: 21, noseSize: 22, noseTip: 23, lipSize: 24,
    cheekSize: 25, jawWidth: 26, chinLength: 27, faceWidth: 28,
    faceLength: 29,
    exposure: 30, contrast: 31, blacks: 32, whites: 33,
    saturation: 34, vibrance: 35, warmth: 36, clarity: 37,
    vignette: 38,
    lookID: "portraitFilm", lookStrength: 39, grain: 40,
    lipTint: 41, lipColor: MakeupShade.berry.color,
    blush: 42, blushColor: MakeupShade.cheekCoral.color,
    browDefine: 43, browColor: MakeupShade.warmBrow.color,
    eyeshadow: 44, shadowColor: MakeupShade.plumShadow.color,
    eyeliner: 45, linerColor: MakeupShade.navyLiner.color,
    skinFinish: 46, shine: 47, irisEnhance: 48, lashDarken: 49,
    lipGloss: 50, splitTone: 51,
    bodySmooth: 52, bodyTone: 53, bodySlim: 54,
    backgroundBlur: 55, backgroundTone: 56, backgroundSaturation: 57,
    bodyWaist: 58, bodyArms: 59, bodyLegs: 60,
    hairColor: 61, hairTint: MakeupShade.hairCaramel.color,
    hairShine: 62,
    contour: 63, contourColor: MakeupShade.contourDeep.color,
    curveShadows: 64, curveMidtones: 65, curveHighlights: 66,
    hslHue: [-70, -50, -30, -10, 10, 30, 50, 70],
    hslSaturation: [-65, -45, -25, -5, 5, 25, 45, 65],
    hslLuminance: [-60, -40, -20, 0, 20, 40, 60, 80],
    lensTint: 67, lensColor: MakeupColor(hue: 123, saturation: 0.33, value: 0.44),
    teethAlign: 68, hairVolume: 69,
    backgroundFill: 70,
    backgroundFillColor: MakeupColor(hue: 200, saturation: 0.2, value: 0.3),
    backgroundRemove: true,
    backgroundImage: "backdrop-1.heic",
    backgroundImageName: "Studio Backdrop",
    backgroundImageAmount: 71)
full.hslHue[0] = -100
full.hslHue[7] = 100

print("Construction and defaults")
check(defaults.isIdentity, "fresh Adjustments is identity")
check(defaults == Adjustments.zero, "zero equals a fresh value")
check(defaults.smooth == 0 && defaults.backgroundImageAmount == 100,
      "amounts default to no-op, image amount to 100")
check(defaults.lookID.isEmpty, "empty look identifier means no look")
check(defaults.hslHue == Array(repeating: 0, count: 8), "HSL arrays have one slot per band")
check(defaults.lipColor == MakeupShade.rose.color, "default lip colour is Rose")
check(defaults.blushColor == MakeupShade.cheekPeach.color, "default blush is fair Peach")
check(defaults.browColor == MakeupShade.taupeBrow.color, "default brow is Taupe")
check(defaults.shadowColor == MakeupShade.taupeShadow.color, "default shadow is Taupe")
check(defaults.linerColor == MakeupShade.inkLiner.color, "default liner is Ink")
check(defaults.hairTint == MakeupShade.hairEspresso.color, "default hair is Espresso")
check(defaults.contourColor == MakeupShade.contourSoft.color, "default contour is Soft")
check(defaults.lensColor == MakeupColor(hue: 210, saturation: 0.45, value: 0.48),
      "default lens colour is preserved")
check(defaults.backgroundFillColor == MakeupColor(hue: 0, saturation: 0, value: 0.96),
      "default background fill is preserved")
check(defaults.blackLevel == 0 && defaults.whiteLevel == 1, "levels are neutral")
check(Adjustments(smooth: 40, exposure: 20).smooth == 40
      && Adjustments(smooth: 40, exposure: 20).exposure == 20
      && Adjustments(smooth: 40, exposure: 20).blemish == 0,
      "partial construction keeps the other defaults")
check(Adjustments(lipColor: MakeupShade.berry.color).lipColor == MakeupShade.berry.color,
      "single-field construction works")

print("Equality and hashing")
var changed = defaults
changed.smooth = 1
check(changed != defaults, "a changed field breaks equality")
check(Set([MakeupColor(hue: 10, saturation: 0.5, value: 0.5),
           MakeupColor(hue: 10, saturation: 0.5, value: 0.5)]).count == 1,
      "MakeupColor is hashable")
check(MakeupShade.rose == MakeupShade.rose && MakeupShade.rose != MakeupShade.berry,
      "MakeupShade compares by value")
check(Set(MakeupShade.all).count == MakeupShade.all.count, "catalogue shades are unique values")

print("Validation and conversion")
check(MakeupColor(hue: -30, saturation: 0.5, value: 0.5).hue == 330, "hue wraps negative values")
check(MakeupColor(hue: 390, saturation: 0.5, value: 0.5).hue == 30, "hue wraps past 360")
check(MakeupColor(hue: 10, saturation: 1.5, value: -0.5).saturation == 1
      && MakeupColor(hue: 10, saturation: 1.5, value: -0.5).value == 0,
      "saturation and value clamp to 0...1")
let rounded = MakeupColor(rgb: 0.2, 0.4, 0.8).rgb
check(abs(rounded.r - 0.2) < 1e-9 && abs(rounded.g - 0.4) < 1e-9 && abs(rounded.b - 0.8) < 1e-9,
      "rgb conversion round-trips")
check(MakeupColor(hue: 10, saturation: 0.2, value: 0.3).with(hue: 20).hue == 20
      && MakeupColor(hue: 10, saturation: 0.2, value: 0.3).with(saturation: 0.9).saturation == 0.9,
      "with(hue:) and with(saturation:) keep the other components")
check(MakeupFamily.of(skinLuminance: 0.20) == .deep
      && MakeupFamily.of(skinLuminance: 0.35) == .tan
      && MakeupFamily.of(skinLuminance: 0.50) == .medium
      && MakeupFamily.of(skinLuminance: 0.60) == .light
      && MakeupFamily.of(skinLuminance: 0.80) == .fair,
      "skin luminance thresholds are unchanged")

print("Stable identifiers")
let expectedIDs: Set<String> = [
    "rose", "peach", "coral", "berry", "cheek-fair-peach", "cheek-light-rose",
    "cheek-light-coral", "cheek-deep-berry", "shadow-taupe", "liner-ink",
    "brow-taupe", "contour-soft", "hair-espresso",
]
check(expectedIDs.allSatisfy { MakeupShade(rawValue: $0) != nil },
      "legacy shade identifiers still resolve")
check(MakeupShade(rawValue: "not-a-shade") == nil, "unknown shade identifiers return nil")
check(MakeupShade(rawValue: "rose")?.color == MakeupShade.rose.color,
      "rawValue lookup returns the catalogue colour")
check(MakeupShade.all.count == 58, "catalogue size is 58", "\(MakeupShade.all.count)")
check(MakeupShade.all.first?.id == "lip-fair-petal"
      && MakeupShade.all.last?.id == "hair-caramel",
      "catalogue order is stable")
check(MakeupShade.shades(.lips).count == 20 && MakeupShade.shades(.cheeks).count == 15,
      "region filtering keeps its catalogue split")
check(MakeupShade.shades(.lips, family: .deep).allSatisfy { $0.family == .deep },
      "family filtering works")
check(MakeupRegion.lips.defaultAmount == 55 && MakeupRegion.cheeks.defaultAmount == 40,
      "region default amounts are unchanged")
var pathProbe = Adjustments()
pathProbe[keyPath: MakeupRegion.lips.colorPath] = MakeupShade.berry.color
pathProbe[keyPath: MakeupRegion.lips.amountPath] = 42
check(pathProbe.lipColor == MakeupShade.berry.color && pathProbe.lipTint == 42,
      "region key paths address the same fields")
check(HSLBand.allCases.count == 8
      && HSLBand.red.centerHue == 0 && HSLBand.blue.centerHue == 240
      && HSLBand.magenta.halfWidth == 26,
      "HSL band geometry is unchanged")
check(HSLBand.allCases.map(\.rawValue) == Array(0...7), "HSL raw values are stable")
check(AdjustmentGroup.allCases == [.skin, .reshape, .makeup, .colorLight, .look, .body, .background],
      "adjustment group order is stable")

print("v3 serialization")
check(prettySorted(defaults) == fixture("v3-adjustments-defaults.json"),
      "default Adjustments encodes byte-identically to the pre-extraction output")
check(prettySorted(full) == fixture("v3-adjustments-full.json"),
      "fully populated Adjustments encodes byte-identically to the pre-extraction output")

let legacyJSON = """
{
  "lipShadeID": "berry",
  "blushShadeID": "cheek-light-coral",
  "hslHue": [11, -12, 13],
  "hslSaturation": [21],
  "hslLuminance": [],
  "smooth": 5,
  "backgroundRemove": true
}
"""
let legacy = try! JSONDecoder().decode(Adjustments.self, from: legacyJSON.data(using: .utf8)!)
check(prettySorted(legacy) == fixture("v3-adjustments-legacy-decoded.json"),
      "legacy shade keys migrate byte-identically to the pre-extraction output")
check(legacy.lipColor == MakeupShade.berry.color
      && legacy.blushColor == MakeupShade.cheekCoral.color,
      "legacy shade identifiers become their catalogue colours")
check(legacy.hslHue == [11, -12, 13, 0, 0, 0, 0, 0]
      && legacy.hslSaturation == [21, 0, 0, 0, 0, 0, 0, 0]
      && legacy.hslLuminance == Array(repeating: 0, count: 8),
      "short HSL arrays pad to the current band count")
let overlong = try! JSONDecoder().decode(
    Adjustments.self,
    from: #"{"hslHue":[10,20,30,40,50,60,70,80,90,100]}"#.data(using: .utf8)!)
check(overlong.hslHue == [10, 20, 30, 40, 50, 60, 70, 80],
      "overlong HSL arrays trim to the current band count")
let clamped = try! JSONDecoder().decode(
    Adjustments.self,
    from: #"{"hslSaturation":[200,-200]}"#.data(using: .utf8)!)
check(clamped.hslSaturation[0] == 100 && clamped.hslSaturation[1] == -100,
      "HSL values clamp on decode")
let missing = try! JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
// The hand-written decoder has always read a missing amount as 0, including
// `backgroundImageAmount`, whose declared default is 100. That asymmetry is
// part of the v3 contract, so it is asserted rather than "fixed".
var emptyDecoded = Adjustments()
emptyDecoded.backgroundImageAmount = 0
check(missing == emptyDecoded, "an empty object decodes to the pre-extraction defaults")
let roundTrip = try! JSONDecoder().decode(Adjustments.self,
                                         from: prettySorted(full).data(using: .utf8)!)
check(roundTrip == full, "full Adjustments round-trips through JSON")

print("UserPreset")
let preset = UserPreset(id: "fixture-id", name: "Fixture", adjustments: full)
check(prettySorted(preset) == fixture("v3-user-preset.json"),
      "UserPreset encodes byte-identically to the pre-extraction output")
let fresh = UserPreset(name: "Fresh")
check(!fresh.id.isEmpty && fresh.adjustments == Adjustments(),
      "UserPreset defaults its id and adjustments")
check((try! JSONDecoder().decode(UserPreset.self,
                                 from: prettySorted(preset).data(using: .utf8)!)) == preset,
      "UserPreset round-trips through JSON")

print("R1 fixture compatibility")
let renderPlanURL = conformanceRoot.appendingPathComponent("render-plan-masks.json")
var r1Result = false
if let data = try? Data(contentsOf: renderPlanURL),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let parameters = object["parameters"],
   let parameterData = try? JSONSerialization.data(withJSONObject: parameters) {
    let decoded = try? JSONDecoder().decode(Adjustments.self, from: parameterData)
    r1Result = decoded?.smooth == 18
        && decoded?.teethWhiten == 12
        && decoded?.backgroundFill == 25
        && decoded?.contrast == 0
}
check(r1Result, "the R1 render-plan parameters object decodes as Adjustments")

print("Portable geometry: construction and equality")
let point = StudioPoint(x: 0.25, y: 0.5)
check(StudioPoint.zero == StudioPoint(x: 0, y: 0), "zero is the origin")
check(StudioPoint(x: 0, y: 0).distance(to: StudioPoint(x: 3, y: 4)) == 5,
      "distance is Euclidean")
check(point.distance(to: point) == 0, "a point is zero away from itself")
check(Set([point, StudioPoint(x: 0.25, y: 0.5)]).count == 1, "points hash by value")
var movedPoint = point
movedPoint.x = 0.75
check(point.x == 0.25 && movedPoint != point, "points have value semantics")

let size = StudioSize(width: 0.3, height: 0.4)
check(size.isValid && !size.isEmpty, "a positive size is valid and not empty")
let zeroWidth = StudioSize(width: 0, height: 0.4)
check(zeroWidth.isValid && zeroWidth.isEmpty, "a zero side is valid and empty")
let negativeSize = StudioSize(width: -0.3, height: 0.4)
check(!negativeSize.isValid && negativeSize.isEmpty,
      "a negative side is representable but invalid")
check(StudioSize(width: 0, height: 0).isValid, "a fully zero size is valid")
check(Set([size, StudioSize(width: 0.3, height: 0.4)]).count == 1, "sizes hash by value")

let rect = StudioRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
check(rect.minX == 0.1 && rect.midX == 0.25 && rect.maxX == 0.4,
      "x edges match the stored origin and width")
check(abs(rect.minY - 0.2) < 1e-12 && abs(rect.midY - 0.4) < 1e-12
      && abs(rect.maxY - 0.6) < 1e-12,
      "y edges match the stored origin and height")
check(rect.origin == StudioPoint(x: 0.1, y: 0.2)
      && rect.size == StudioSize(width: 0.3, height: 0.4),
      "origin and size expose the stored fields")
check(StudioRect(origin: rect.origin, size: rect.size) == rect,
      "the origin/size initializer round-trips")
check(StudioRect.unit == StudioRect(x: 0, y: 0, width: 1, height: 1),
      "the unit rectangle is the normalized full frame")
check(StudioRect.zero.isEmpty && StudioRect.unit.isEmpty == false,
      "zero is empty and unit is not")
check(StudioRect(x: 0, y: 0, width: -0.3, height: 0.2).isValid == false,
      "a negative extent makes a rectangle invalid")
var resized = rect
resized.size = StudioSize(width: 0.5, height: 0.6)
check(resized.width == 0.5 && resized.height == 0.6 && resized.x == 0.1,
      "setting the size keeps the origin")
var shifted = rect
shifted.origin = StudioPoint(x: 0, y: 0)
check(shifted.x == 0 && shifted.y == 0 && shifted.size == rect.size,
      "setting the origin keeps the size")
let flippedRect = StudioRect(x: 0.75, y: 0.9, width: -0.25, height: -0.4)
check(flippedRect.standardized() == StudioRect(x: 0.5, y: 0.5, width: 0.25, height: 0.4),
      "standardizing flips a negative extent onto its min corner")
check(flippedRect.x == 0.75 && flippedRect.width == -0.25,
      "standardizing returns a new value and leaves the original alone")

print("Portable geometry: boundaries and non-finite values")
check(rect.contains(StudioPoint(x: 0.1, y: 0.2)), "the min corner belongs to the rectangle")
check(rect.contains(StudioPoint(x: 0.3999, y: 0.5999)), "the interior belongs to the rectangle")
check(!rect.contains(StudioPoint(x: rect.maxX, y: rect.midY)),
      "the max x edge is excluded")
check(!rect.contains(StudioPoint(x: rect.midX, y: rect.maxY)),
      "the max y edge is excluded")
check(!rect.contains(StudioPoint(x: 0.05, y: 0.3)), "a point left of the rectangle is outside")
check(!rect.contains(StudioPoint(x: .nan, y: 0.3)),
      "a non-finite point is never contained")
check(!StudioRect(x: 0, y: 0, width: 0, height: 1).contains(StudioPoint(x: 0, y: 0.5)),
      "an empty rectangle contains nothing")
check(!StudioPoint(x: .nan, y: 0).isFinite
      && !StudioPoint(x: 0, y: .infinity).isFinite,
      "points report non-finite components")
check(!StudioSize(width: .infinity, height: 1).isValid
      && !StudioRect(x: 0, y: 0, width: .infinity, height: 1).isValid,
      "sizes and rectangles reject non-finite extents")
let geometryEncoder = JSONEncoder()
check((try? geometryEncoder.encode(StudioPoint(x: .nan, y: 0))) == nil,
      "a non-finite point is not encodable")
check((try? geometryEncoder.encode(
        StudioRect(x: 0, y: 0, width: .infinity, height: 1))) == nil,
      "a non-finite rectangle is not encodable")
check((try? JSONDecoder().decode(StudioPoint.self,
                                 from: Data(#"{"x":NaN,"y":0}"#.utf8))) == nil,
      "the decoder rejects a NaN literal")

print("Portable geometry: coordinate spaces")
let topLeft = StudioCoordinateSpace.sourceNormalizedTopLeft
let bottomLeft = StudioCoordinateSpace.sourceNormalizedBottomLeft
check(topLeft.rawValue == "source_normalized",
      "the canonical raw value is unchanged")
check(topLeft.isNormalized && topLeft.hasTopLeftOrigin
      && bottomLeft.isNormalized && !bottomLeft.hasTopLeftOrigin,
      "normalized spaces differ only by origin")
check(topLeft.sameUnit(as: bottomLeft) && !topLeft.sameUnit(as: .sourcePixelTopLeft),
      "spaces compare by unit, not by origin")
check(topLeft.convert(StudioPoint(x: 0.25, y: 0.1), to: bottomLeft)
      == StudioPoint(x: 0.25, y: 0.9),
      "a normalized point flips y")
check(topLeft.convert(StudioPoint(x: 0.25, y: 0), to: bottomLeft)
      == StudioPoint(x: 0.25, y: 1),
      "the top edge maps to the bottom edge")
check(topLeft.convert(StudioPoint(x: 0.25, y: 1), to: bottomLeft)
      == StudioPoint(x: 0.25, y: 0),
      "the bottom edge maps to the top edge")
check(topLeft.convert(StudioPoint(x: 0.25, y: 1.25), to: bottomLeft)
      == StudioPoint(x: 0.25, y: -0.25),
      "values outside 0...1 are flipped, not clamped")
let restoredPoint = bottomLeft.convert(StudioPoint(x: 0.25, y: 0.9), to: topLeft)
check(restoredPoint.map { abs($0.x - 0.25) < 1e-12 && abs($0.y - 0.1) < 1e-12 } ?? false,
      "the reverse flip returns the original point")
let canonicalBox = StudioRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2)
let flippedBox = topLeft.convert(canonicalBox, to: bottomLeft)
check(flippedBox.map { abs($0.x - 0.1) < 1e-12 && abs($0.y - 0.6) < 1e-12
        && $0.width == 0.3 && $0.height == 0.2 } ?? false,
      "a normalized rectangle flips its min edge")
let roundTrippedBox = flippedBox.flatMap { bottomLeft.convert($0, to: topLeft) }
check(roundTrippedBox.map { abs($0.x - canonicalBox.x) < 1e-12
        && abs($0.y - canonicalBox.y) < 1e-12
        && $0.width == canonicalBox.width && $0.height == canonicalBox.height } ?? false,
      "a normalized rectangle round-trips")
check(topLeft.convert(StudioPoint(x: 0.1, y: 0.1), to: .sourcePixelTopLeft) == nil,
      "a normalized point never converts to pixels without a frame")
check(StudioCoordinateSpace.sourcePixelTopLeft.convert(
        StudioPoint(x: 10, y: 40), to: .sourcePixelBottomLeft, frameHeight: 200)
      == StudioPoint(x: 10, y: 160),
      "a pixel point flips against the frame height")
check(StudioCoordinateSpace.sourcePixelTopLeft.convert(
        StudioPoint(x: 10, y: 0), to: .sourcePixelBottomLeft, frameHeight: 200)
      == StudioPoint(x: 10, y: 200),
      "the pixel top edge maps to the frame height")
check(StudioCoordinateSpace.sourcePixelTopLeft.convert(
        StudioPoint(x: 10, y: 200), to: .sourcePixelBottomLeft, frameHeight: 200)
      == StudioPoint(x: 10, y: 0),
      "the pixel bottom edge maps to zero")
check(StudioCoordinateSpace.sourcePixelTopLeft.convert(
        StudioPoint(x: 10, y: 40), to: .sourcePixelBottomLeft, frameHeight: 0) == nil,
      "a zero frame height is refused")
check(StudioCoordinateSpace.sourcePixelTopLeft.convert(
        StudioPoint(x: 10, y: 40), to: .sourcePixelBottomLeft, frameHeight: .nan) == nil,
      "a non-finite frame height is refused")
check(topLeft.convert(StudioPoint(x: .nan, y: 0), to: bottomLeft) == nil,
      "a non-finite point is refused")
check(topLeft.convert(StudioRect(x: 0, y: 0, width: -1, height: 1), to: bottomLeft) == nil,
      "an unstandardized rectangle is refused")
check(topLeft.convert(point, to: topLeft) == point,
      "converting to the same space is identity")
check(topLeft.convert(StudioRect(x: 0.75, y: 0.9, width: -0.25, height: -0.4),
                      to: topLeft)
      == StudioRect(x: 0.75, y: 0.9, width: -0.25, height: -0.4),
      "identity conversion keeps an unstandardized rectangle")
check(topLeft.convert(StudioPoint(x: .infinity, y: 0), to: topLeft)
      == StudioPoint(x: .infinity, y: 0),
      "identity conversion keeps a non-finite point")
check(Set([topLeft, bottomLeft, bottomLeft]).count == 2, "spaces hash by value")

print("Portable geometry: Codable")
func compactJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(data: try! encoder.encode(value), encoding: .utf8)!
}
check(compactJSON(point) == #"{"x":0.25,"y":0.5}"#,
      "a point encodes as a keyed x/y object")
check(compactJSON(size) == #"{"height":0.4,"width":0.3}"#,
      "a size encodes as a keyed width/height object")
check(compactJSON(rect) == #"{"height":0.4,"width":0.3,"x":0.1,"y":0.2}"#,
      "a rectangle encodes with the canonical keys")
let decodedPoint = try! JSONDecoder().decode(StudioPoint.self,
                                            from: compactJSON(point).data(using: .utf8)!)
check(decodedPoint == point, "a point round-trips through JSON")
let decodedSize = try! JSONDecoder().decode(StudioSize.self,
                                            from: compactJSON(size).data(using: .utf8)!)
check(decodedSize == size, "a size round-trips through JSON")
let decodedRect = try! JSONDecoder().decode(StudioRect.self,
                                            from: compactJSON(rect).data(using: .utf8)!)
check(decodedRect == rect, "a rectangle round-trips through JSON")
let extraKeys = try? JSONDecoder().decode(
    StudioPoint.self, from: Data(#"{"x":1,"y":2,"z":3}"#.utf8))
check(extraKeys == StudioPoint(x: 1, y: 2), "unknown keys are ignored")
check((try? JSONDecoder().decode(StudioPoint.self, from: Data("[0.1,0.2]".utf8))) == nil,
      "the legacy unkeyed point shape is not accepted")
check((try? JSONDecoder().decode(StudioRect.self,
                                 from: Data("[[0.1,0.2],[0.3,0.4]]".utf8))) == nil,
      "the legacy unkeyed rectangle shape is not accepted")
let tricky = StudioRect(x: 0.1 / 3, y: -0.7, width: 1e-300,
                        height: 1.7976931348623157e308)
let trickyBack = try! JSONDecoder().decode(
    StudioRect.self, from: try! JSONEncoder().encode(tricky))
check(trickyBack.x.bitPattern == tricky.x.bitPattern
      && trickyBack.y.bitPattern == tricky.y.bitPattern
      && trickyBack.width.bitPattern == tricky.width.bitPattern
      && trickyBack.height.bitPattern == tricky.height.bitPattern,
      "doubles round-trip bit-exactly")

print("Document history: shared rules")

struct CoreState: HistoryState, Equatable {
    var value = 0
    init() {}
    init(_ value: Int) { self.value = value }
}

extension DocumentHistory where State == CoreState {
    init() { self.init(CoreState()) }
}

var history = DocumentHistory<CoreState>()
check(!history.canUndo(current: CoreState()) && !history.canRedo(current: CoreState()),
      "a fresh history has no steps")
check(history.undoStack.isEmpty && history.redoStack.isEmpty,
      "a fresh history starts with empty stacks")
check(history.lastCommitted == CoreState() && history.cleanState == CoreState(),
      "a fresh history starts on an empty baseline")

history.commit(CoreState(1))
check(history.undoStack == [CoreState()], "a first commit records the empty baseline")
check(history.canUndo(current: CoreState(1)), "an edit is undoable")
check(history.undo(current: CoreState(1)) == CoreState(), "undo returns the baseline")
check(history.redo(current: CoreState()) == CoreState(1), "redo returns the edit")
check(history.cleanState == CoreState(), "undo and redo leave the clean baseline alone")

let unchanged = history.undoStack.count
history.commit(CoreState(1))
check(history.undoStack.count == unchanged, "committing the recorded state adds no step")

_ = history.undo(current: CoreState(1))
check(history.canRedo(current: CoreState()), "undo opens a redo branch")
history.commit(CoreState(2))
check(!history.canRedo(current: CoreState(2)), "a new edit discards the redo branch")
check(history.redo(current: CoreState(2)) == nil, "the discarded branch cannot be replayed")

var capped = DocumentHistory<CoreState>()
for value in 1...(DocumentHistory<CoreState>.stepLimit + 20) {
    capped.commit(CoreState(value))
}
check(capped.undoStack.count == DocumentHistory<CoreState>.stepLimit,
      "history keeps at most \(DocumentHistory<CoreState>.stepLimit) steps")
var walked = CoreState(DocumentHistory<CoreState>.stepLimit + 20)
var steps: [Int] = []
while let previous = capped.undo(current: walked) {
    steps.append(previous.value)
    walked = previous
}
check(steps.count == DocumentHistory<CoreState>.stepLimit, "the kept steps are all reachable")
check(steps.first == DocumentHistory<CoreState>.stepLimit + 19 && steps.last == 20,
      "the oldest steps are dropped first")

var reset = DocumentHistory<CoreState>()
reset.commit(CoreState(1))
reset.commit(CoreState(2))
reset.reset(to: CoreState(7))
check(reset.undoStack.isEmpty && reset.redoStack.isEmpty, "reset clears both stacks")
check(reset.lastCommitted == CoreState(7) && reset.cleanState == CoreState(7),
      "reset makes the state both baselines")

var cleaned = DocumentHistory<CoreState>()
cleaned.commit(CoreState(1))
cleaned.markClean(CoreState(1))
check(cleaned.cleanState == CoreState(1), "markClean moves the clean baseline")
check(cleaned.undoStack.count == 1, "markClean leaves history intact")

var original = DocumentHistory<CoreState>()
original.commit(CoreState(1))
var copy = original
copy.commit(CoreState(2))
check(original.undoStack.count == 1 && copy.undoStack.count == 2,
      "two histories never share a stack")

print("Recovery rules: shared decisions")

var epoch = RecoveryRules.AutosaveEpoch()
let captured = epoch.value
check(epoch.accepts(captured), "a captured generation is accepted before invalidation")
epoch.invalidate()
check(!epoch.accepts(captured), "invalidation refuses work captured earlier")
check(epoch.accepts(epoch.value), "the current generation is accepted")

check(RecoveryRules.isCandidateFileName("0000000000000-abc.retouch"),
      "a candidate copy is recognized by extension")
check(!RecoveryRules.isCandidateFileName(".hidden.retouch"),
      "a dotfile is never a candidate")
check(!RecoveryRules.isCandidateFileName("snapshot.json"),
      "another extension is not a candidate")
check(!RecoveryRules.isCandidateFileName(".retouch"),
      "a bare extension is not a candidate")

let orderBase = Date(timeIntervalSince1970: 1_000)
check(RecoveryRules.olderFirst(.init(savedAt: orderBase, name: "a"),
                               .init(savedAt: orderBase, name: "b")),
      "the same millisecond orders by name")
check(RecoveryRules.olderFirst(.init(savedAt: orderBase, name: "z"),
                               .init(savedAt: orderBase.addingTimeInterval(1), name: "a")),
      "an older date wins before the name")

check(RecoveryRules.monotonic(orderBase, after: nil) == orderBase,
      "the first legacy copy keeps its date")
check(RecoveryRules.monotonic(orderBase, after: orderBase) == orderBase.addingTimeInterval(0.001),
      "a tie moves forward by a millisecond")
let laterDate = orderBase.addingTimeInterval(5)
check(RecoveryRules.monotonic(laterDate, after: orderBase) == laterDate,
      "a later date is kept")

let quarantineID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
check(RecoveryRules.quarantineFileName(base: "snap", pathExtension: "retouch", id: quarantineID)
      == "snap-11111111-2222-3333-4444-555555555555.retouch",
      "quarantine keeps the base and extension")
check(RecoveryRules.quarantineFileName(base: "snap", pathExtension: "", id: quarantineID)
      == "snap-11111111-2222-3333-4444-555555555555",
      "an empty extension adds no dot")
check(RecoveryRules.quarantineFileName(base: "snap", pathExtension: "retouch", id: UUID())
      != RecoveryRules.quarantineFileName(base: "snap", pathExtension: "retouch", id: UUID()),
      "two quarantines cannot collide")

print("Project platform ports")

struct CoreSources: ProjectSourceAccess {
    var existing: Set<String>
    func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
}

struct CoreBookmarks: ProjectBookmarkStore {
    var stored: [URL: Data] = [:]
    func bookmark(for url: URL) -> Data? { stored[url] }
    func resolveBookmark(_ data: Data) -> URL? { stored.first { $0.value == data }?.key }
}

let photoURL = URL(fileURLWithPath: "/tmp/photo.jpg")
let coreSources = CoreSources(existing: [photoURL.path])
let coreBookmarks = CoreBookmarks(stored: [photoURL: Data([1, 2, 3])])
check(coreSources.fileExists(at: photoURL), "a host answers path existence")
check(coreBookmarks.resolveBookmark(coreBookmarks.bookmark(for: photoURL)!) == photoURL,
      "a host round-trips its own bookmark")

print("Document value: portable stamps, stickers, edits and analysis")

let stamp = HealSpot(center: StudioPoint(x: 0.42, y: 0.37), radius: 0.018)
check(stamp.radius == 0.018 && stamp.center.x == 0.42,
      "a healing stamp keeps its normalized value")

let sticker = Sticker(kind: .heart, center: StudioPoint(x: 0.72, y: 0.28), size: 0.12)
check(sticker.kind == .heart && sticker.size == 0.12 && sticker.opacity == 1,
      "a sticker carries its shape, size and default opacity")
check(sticker.rotation == 0 && sticker.color == Sticker.defaultColor,
      "an unrotated sticker uses the default colour")
check(Sticker.defaultSize == 0.14, "the default sticker size is 14% of the short side")

let edit = AIEdit(preset: "removeObject", prompt: "remove the sign", seed: 7,
                  patchFile: "patch.png", alphaFile: "alpha.png",
                  box: StudioRect(x: 0.2, y: 0.25, width: 0.1, height: 0.03),
                  imagePixels: StudioSize(width: 1024, height: 768),
                  seconds: 4.25, outsidePixelsIdentical: true)
check(edit.box.width == 0.1 && edit.imagePixels.width == 1024,
      "an AI edit keeps its authorized box and job size")
check(edit.patchOrientation == nil && edit.outsidePixelsIdentical,
      "an edit starts unrotated and trusts the worker's outside report")

var analysis = AnalysisSettings()
check(!analysis.isEnabled && analysis.showsFaceOutline && analysis.glow,
      "analysis starts off with the outline on")
check(analysis.regions == [.forehead, .eyeArea, .texture, .pigmentation, .jawline],
      "the default analysis chooses five regions")
check(analysis.primaryCallouts == [.forehead, .eyeArea, .texture, .pigmentation, .jawline],
      "callouts follow the catalogue order, not set order")
analysis.setEndpoint(StudioPoint(x: 0.5, y: 0.2), for: .forehead)
analysis.setAnchor(StudioPoint(x: 0.48, y: 0.26), for: .forehead)
check(analysis.endpoint(for: .forehead) == StudioPoint(x: 0.5, y: 0.2)
      && analysis.anchor(for: .forehead) == StudioPoint(x: 0.48, y: 0.26),
      "dragged pins are stored per region")
analysis.resetEndpoints()
analysis.resetAnchors()
check(analysis.endpoints.isEmpty && analysis.anchors.isEmpty,
      "resetting pins clears both kinds")
check(AnalysisRegion.forehead.defaultsToRight && !AnalysisRegion.jawline.defaultsToRight,
      "leader sides keep their default directions")
check(AnalysisTint.ink.isDark && !AnalysisTint.chalk.isDark,
      "only the ink tint is marked dark")

let emptySettings = try! JSONDecoder().decode(AnalysisSettings.self,
                                             from: Data("{}".utf8))
check(emptySettings == AnalysisSettings(),
      "a project written before the analysis tool opens with the defaults")

print("Document value: orientation is a portable value")

let turned = DocumentOrientation(quarterTurns: 1, flipped: false, angle: 3.5)
check(turned.outputSize(base: StudioSize(width: 400, height: 300))
      == StudioSize(width: 300, height: 400),
      "a quarter turn swaps the frame size")
check(DocumentOrientation(quarterTurns: 2).outputSize(base: StudioSize(width: 400, height: 300))
      == StudioSize(width: 400, height: 300),
      "a half turn keeps the frame size")
check(turned.rotationDegrees == 93.5, "rotation totals the quarter turns and the angle")
check(DocumentOrientation.compose(DocumentOrientation(quarterTurns: 1), over: turned)
      == DocumentOrientation(quarterTurns: 2, flipped: false, angle: 3.5),
      "composing adds turns in the new frame and keeps the angle")
check(DocumentOrientation.compose(DocumentOrientation(flipped: true), over: turned)
      == DocumentOrientation(quarterTurns: turned.quarterTurns,
                             flipped: true, angle: turned.angle),
      "mirroring composes without changing the turn")
check(DocumentOrientation(quarterTurns: 1).inverted
      == DocumentOrientation(quarterTurns: 3, angle: 0),
      "the inverse of a turn is the opposite quarter")
check(DocumentOrientation(quarterTurns: 1, flipped: true).inverted
      == DocumentOrientation(quarterTurns: 1, flipped: true),
      "a mirrored turn is its own inverse")
check(DocumentOrientation(quarterTurns: 3).rotatedClockwise().quarterTurns == 0,
      "turning clockwise wraps past three")
check(DocumentOrientation(quarterTurns: -1).quarterTurns == 3,
      "negative turns normalize into 0...3")
check(DocumentOrientation(angle: 10).straightened(to: 4).angle == 4,
      "straighten sets the angle directly")
let mirroredStraighten = DocumentOrientation(flipped: true, angle: 10).straightened(to: 4)
check(mirroredStraighten.angle == 4 && mirroredStraighten.flipped,
      "a mirrored frame reaches the straighten target and stays mirrored")
let partialOrientation = try! JSONDecoder().decode(
    DocumentOrientation.self, from: Data("{\"quarterTurns\":1}".utf8))
check(partialOrientation == DocumentOrientation(quarterTurns: 1),
      "a partial orientation decodes with the missing keys at their defaults")
check(DocumentOrientation(quarterTurns: 4) == DocumentOrientation()
      && !DocumentOrientation(angle: 0.5).isIdentity
      && !DocumentOrientation(flipped: true).isIdentity
      && DocumentOrientation().isIdentity,
      "a full turn wraps to identity while a real turn, mirror or angle does not")

print("Document value: portable JSON and shared history")

let portable = DocumentState(
    healSpots: [stamp],
    stickers: [sticker],
    aiEdits: [edit],
    analysis: analysis,
    crop: StudioRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6),
    orientation: turned,
    selectedFaceIndex: 2)
let encoded = prettySorted(portable)
check(encoded.contains("\"center\" : {") && encoded.contains("\"x\" : 0.42"),
      "portable points write named coordinates, not Core Graphics arrays")
check(!encoded.contains("[["),
      "no Core Graphics array shape appears in the portable form")
let decoded = try! JSONDecoder().decode(DocumentState.self, from: Data(encoded.utf8))
check(decoded == portable, "a document state round-trips through portable JSON")
check(DocumentState() == DocumentState(adjustments: Adjustments()),
      "a fresh state is the identity document")
var documentHistory = DocumentHistory(DocumentState())
documentHistory.commit(portable)
check(documentHistory.undoStack.count == 1 && documentHistory.cleanState == DocumentState(),
      "a document state is a history step in the shared history")
check(documentHistory.undo(current: portable) == DocumentState()
      && documentHistory.canRedo(current: DocumentState()),
      "undo returns the previous document")
check(documentHistory.redo(current: DocumentState()) == portable,
      "redo returns the edited document")

print("Project document: the v3 fixture and the portable ports")

/// A host's byte storage without a file system: the store's order of
/// operations must be observable without one.
final class MemoryProjectBytes: ProjectByteStore {
    var files: [URL: Data] = [:]
    var readFailure: ProjectIOError?
    var writeFailure: ProjectIOError?

    func readProjectData(at url: URL) throws -> Data {
        if let readFailure { throw readFailure }
        guard let data = files[url] else { throw ProjectIOError.readFailed }
        return data
    }

    func writeProjectData(_ data: Data, to url: URL) throws {
        if let writeFailure { throw writeFailure }
        files[url] = data
    }
}

struct MissingProjectSources: ProjectSourceAccess {
    func fileExists(at url: URL) -> Bool { false }
}

struct EmptyProjectBookmarks: ProjectBookmarkStore {
    func bookmark(for url: URL) -> Data? { nil }
    func resolveBookmark(_ data: Data) -> URL? { nil }
}

let v3FixtureURL = URL(fileURLWithPath: root)
    .appendingPathComponent("Tests/Fixtures/ProjectV3/project-v3-full.retouch")
if let fixtureBytes = try? Data(contentsOf: v3FixtureURL),
   let fixtureProject = try? ProjectCodec.decode(fixtureBytes) {
    check((try? ProjectCodec.encode(fixtureProject)) == fixtureBytes,
          "StudioCore reproduces the v3 fixture byte for byte")
    check(fixtureProject.crop == StudioRect(x: 0.08, y: 0.12, width: 0.76, height: 0.74),
          "the v3 array crop decodes to portable geometry")
    check(fixtureProject.healSpots?.first?.center == StudioPoint(x: 0.42, y: 0.37),
          "the v3 array point decodes to a portable point")
    check(fixtureProject.aiEdits?.first?.imagePixels == StudioSize(width: 1024, height: 768),
          "the v3 array size decodes to a portable size")
    check(fixtureProject.stickers?.first?.color == MakeupColor(hue: 330, saturation: 0.65, value: 0.95),
          "the v3 sticker keeps its colour")
} else {
    check(false, "the v3 fixture is readable", v3FixtureURL.path)
}

let memory = MemoryProjectBytes()
let store = ProjectStore(bytes: memory, sources: MissingProjectSources(),
                         bookmarks: EmptyProjectBookmarks())
let projectURL = URL(fileURLWithPath: "/portable/project.retouch")
var ported = RetouchProject(imagePath: "/portable/photo.heic", adjustments: Adjustments(),
                            exportFormat: "jpeg", exportQuality: 0.9,
                            autoRetouchStrength: 70,
                            crop: StudioRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
ported.adjustments.exposure = 8
try! store.write(ported, context: .v3, to: projectURL)
check(memory.files[projectURL] == (try? ProjectCodec.encode(ported)),
      "the store writes the codec's exact v3 bytes")
let loaded = try? store.read(at: projectURL)
check(loaded?.project.crop == ported.crop && loaded?.project.adjustments == ported.adjustments,
      "the store reads back the project through the port")
check(loaded?.context == ProjectWriteContext.v3,
      "a v3 file keeps a v3 write context")

let v4Context = ProjectWriteContext(version: 4,
                                    unknownFields: ["futureFlag": .string("kept")],
                                    requiredFeatures: ["portable_geometry"])
_ = try! store.write(ported, context: v4Context, to: projectURL)
let v4Bytes = memory.files[projectURL]!
let reread = try? store.read(at: projectURL)
check(reread?.context.isV4 == true
      && reread?.context.unknownFields["futureFlag"] == .string("kept")
      && reread?.context.requiredFeatures == ["portable_geometry"],
      "a v4 file keeps its version, unknown field and required feature")
_ = try! store.write(reread!.project, context: reread!.context, to: projectURL)
check(memory.files[projectURL] == v4Bytes,
      "saving a read v4 document reproduces its bytes")

memory.readFailure = .readFailed
do {
    _ = try store.read(at: projectURL)
    check(false, "a failed read is reported")
} catch ProjectIOError.readFailed {
    check(true, "a failed read is reported as a read failure")
} catch {
    check(false, "a failed read keeps the port's error domain", "\(error)")
}
memory.readFailure = nil

memory.writeFailure = .writeFailed
do {
    _ = try store.write(ported, context: .v3, to: projectURL)
    check(false, "a failed write is reported")
} catch ProjectIOError.writeFailed {
    check(true, "a failed write is reported as a write failure")
} catch {
    check(false, "a failed write keeps the port's error domain", "\(error)")
}
memory.writeFailure = nil
check(memory.files[projectURL] == v4Bytes,
      "a refused write leaves the previous project untouched")

print("\n[M7] unknown data nested in a v4 document survives the store")

/// The store's read-modify-write path end to end: a file with unknown data at
/// several depths is read, a known field is edited, and the write keeps the
/// unknown data without disturbing the edit.
let nestedStoreChecks: () -> Void = {
    var nestedProject = RetouchProject(
        imagePath: "/portable/nested.heic", adjustments: Adjustments(),
        exportFormat: "png", exportQuality: 0.9, autoRetouchStrength: 60,
        crop: StudioRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
        healSpots: [HealSpot(center: StudioPoint(x: 0.25, y: 0.35), radius: 0.02)],
        stickers: [Sticker(kind: .heart, center: StudioPoint(x: 0.6, y: 0.4), size: 0.1)])
    nestedProject.adjustments.exposure = 4

    let jsonEncoder = JSONEncoder()
    jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let encoded = try? ProjectCodec.encodeV4(nestedProject),
          var nestedObject = try? JSONDecoder().decode([String: ProjectJSONValue].self,
                                                       from: encoded),
          case .object(var nestedAdjustments)? = nestedObject["adjustments"],
          case .array(var nestedSpots)? = nestedObject["healSpots"],
          case .object(var nestedSpot)? = nestedSpots.first,
          case .array(var nestedStickers)? = nestedObject["stickers"],
          case .object(var nestedSticker)? = nestedStickers.first else {
        check(false, "the nested store fixture is built")
        return
    }
    let tree: ProjectJSONValue = .object([
        "rows": .array([.object(["label": .string("first"), "value": .null])])
    ])
    nestedAdjustments["futureTree"] = tree
    nestedObject["adjustments"] = .object(nestedAdjustments)
    nestedSpot["futureFeather"] = .double(0.5)
    nestedSpots[0] = .object(nestedSpot)
    nestedObject["healSpots"] = .array(nestedSpots)
    nestedSticker["futureStyle"] = .string("dashed")
    nestedStickers[0] = .object(nestedSticker)
    nestedObject["stickers"] = .array(nestedStickers)
    nestedObject["futureFlag"] = .bool(true)
    guard let staged = try? jsonEncoder.encode(nestedObject) else {
        check(false, "the nested store fixture encodes")
        return
    }

    let nestedURL = URL(fileURLWithPath: "/portable/nested.retouch")
    memory.files[nestedURL] = staged
    guard let readBack = try? store.read(at: nestedURL) else {
        check(false, "the store reads a nested v4 document")
        return
    }
    var edited = readBack.project
    edited.adjustments.exposure = 12
    guard (try? store.write(edited, context: readBack.context, to: nestedURL)) != nil,
          let savedData = memory.files[nestedURL],
          let savedObject = try? JSONDecoder().decode([String: ProjectJSONValue].self,
                                                      from: savedData),
          case .object(let savedAdjustments)? = savedObject["adjustments"],
          case .array(let savedSpots)? = savedObject["healSpots"],
          case .object(let savedSpot)? = savedSpots.first,
          case .array(let savedStickers)? = savedObject["stickers"],
          case .object(let savedSticker)? = savedStickers.first else {
        check(false, "the store writes the nested v4 document")
        return
    }
    check(savedObject["version"] == .int(4), "the store keeps the file v4")
    check(savedObject["futureFlag"] == .bool(true),
          "the store keeps a top-level unknown key")
    check(savedAdjustments["futureTree"] == tree,
          "the store keeps unknown data nested in a known object")
    check(savedSpot["futureFeather"] == .double(0.5),
          "the store keeps unknown data on an array element")
    check(savedSticker["futureStyle"] == .string("dashed"),
          "the store keeps unknown data on an identified array element")
    check(savedAdjustments["exposure"] == .int(12),
          "the store writes the edit made since the read")

    guard let secondRead = try? store.read(at: nestedURL),
          (try? store.write(secondRead.project, context: secondRead.context,
                            to: nestedURL)) != nil,
          let rewrittenData = memory.files[nestedURL] else {
        check(false, "the store rewrites the nested v4 document")
        return
    }
    check(rewrittenData == savedData,
          "an unchanged read-modify-write is byte identical")

    memory.writeFailure = .writeFailed
    var failing = secondRead.project
    failing.adjustments.exposure = 99
    do {
        _ = try store.write(failing, context: secondRead.context, to: nestedURL)
        check(false, "a failed nested write is reported")
    } catch ProjectIOError.writeFailed {
        check(true, "a failed nested write is reported as a write failure")
    } catch {
        check(false, "a failed nested write keeps the port's error domain", "\(error)")
    }
    memory.writeFailure = nil
    check(memory.files[nestedURL] == rewrittenData,
          "a failed write leaves the nested document and its unknown data untouched")
}
nestedStoreChecks()

// The recovery snapshot stores the write context as JSON, so the nested
// overlay has to survive that encoding unchanged.
let overlayContext = ProjectWriteContext(
    version: 4,
    unknownFields: ["futureFlag": .string("kept")],
    requiredFeatures: ["portable_geometry"],
    nestedUnknowns: .object([
        "adjustments": .object(["futureNested": .value(.string("kept"))]),
        "healSpots": .array([
            .init(index: 0, id: nil,
                  known: .object(["radius": .double(0.02)]),
                  unknown: .object(["futureFeather": .value(.double(0.5))]))
        ])
    ]))
let overlayData = try? JSONEncoder().encode(overlayContext)
let overlayReread = overlayData.flatMap {
    try? JSONDecoder().decode(ProjectWriteContext.self, from: $0)
}
check(overlayReread == overlayContext,
      "the write context round-trips its nested overlay")
let overlayJSON = overlayData
    .flatMap { try? JSONDecoder().decode([String: ProjectJSONValue].self, from: $0) }
check(overlayJSON?["nestedUnknowns"] != nil,
      "a context with an overlay writes the nested key")
let legacyContextData = Data("""
    {"version": 4, "unknownFields": {}, "requiredFeatures": ["portable_geometry"]}
    """.utf8)
let legacyContext = try? JSONDecoder().decode(ProjectWriteContext.self,
                                              from: legacyContextData)
check(legacyContext?.nestedUnknowns == nil
      && legacyContext?.requiredFeatures == ["portable_geometry"],
      "a context written before the overlay decodes with none")

// MARK: - Renderer contract and policy

print("\n[M8] the renderer contract is portable and its policy is exact")

check(ExportFormat.jpeg.fileExtension == "jpg"
        && ExportFormat.tiff.fileExtension == "tif"
        && ExportFormat.heic.uniformTypeIdentifier == "public.heic",
      "formats carry their extension and portable type name")
check(ExportFormat.jpeg.supportsQuality && ExportFormat.heic.supportsQuality
        && !ExportFormat.png.supportsQuality && !ExportFormat.tiff.supportsQuality,
      "only JPEG and HEIC take a quality value")
check(ExportFormat.png.bitsPerChannel == 16 && ExportFormat.tiff.bitsPerChannel == 16
        && ExportFormat.jpeg.bitsPerChannel == 8 && ExportFormat.heic.bitsPerChannel == 8,
      "PNG/TIFF stay 16-bit and JPEG/HEIC stay 8-bit")
check(ExportFormat.jpeg.flattensAlpha && ExportFormat.heic.flattensAlpha
        && !ExportFormat.png.flattensAlpha && !ExportFormat.tiff.flattensAlpha,
      "only the opaque containers flatten transparency")

var blankWatermark = WatermarkSettings()
check(!blankWatermark.isActive, "an empty watermark is inactive")
blankWatermark.enabled = true
check(!blankWatermark.isActive, "an enabled but blank watermark is still inactive")
blankWatermark.text = "  Studio  "
check(blankWatermark.isActive, "a non-blank signature is active")
let decodedWatermark = try! JSONDecoder().decode(WatermarkSettings.self,
                                                 from: Data("{}".utf8))
check(decodedWatermark == WatermarkSettings(),
      "older preference payloads decode to the same defaults")

let emptyAnalysis = AnalysisSettings()
let overlayAnalysis = AnalysisSettings()
var overlay = overlayAnalysis
overlay.isEnabled = true
overlay.exportMode = .overlayOnly

let baseSource = RenderSourceDescription(pixelSize: StudioSize(width: 800, height: 600),
                                         photoAspect: 4.0 / 3.0, faceCount: 2)
let baseRequest = RenderRequest()
let basePlan = RenderPolicy.plan(baseRequest, source: baseSource)
check(basePlan.format == .jpeg && basePlan.pixelSize == StudioSize(width: 800, height: 600)
        && !basePlan.upscales && !basePlan.appliesAnalysis && !basePlan.appliesWatermark,
      "a plain export keeps the photo size and draws nothing extra")
check(basePlan.flattensAlpha && basePlan.bitsPerChannel == 8
        && basePlan.colorSpace == .source && basePlan.carriesSourceMetadata,
      "a plain JPEG keeps the source profile and 8-bit opaque output")

var linesRequest = baseRequest
linesRequest.analysis = overlay
linesRequest.watermark = WatermarkSettings(enabled: true, text: "Studio")
let linesPlan = RenderPolicy.plan(linesRequest, source: baseSource)
check(linesPlan.format == .png && !linesPlan.flattensAlpha && linesPlan.bitsPerChannel == 16,
      "an overlay-only export is transparent 16-bit PNG")
check(linesPlan.appliesAnalysis && !linesPlan.appliesWatermark
        && !linesPlan.carriesSourceMetadata,
      "lines carry callouts, no signature and no source EXIF")

let noFaceSource = RenderSourceDescription(pixelSize: StudioSize(width: 800, height: 600),
                                           photoAspect: 4.0 / 3.0, faceCount: 0)
let noFacePlan = RenderPolicy.plan(linesRequest, source: noFaceSource)
check(noFacePlan.format == .jpeg && !noFacePlan.appliesAnalysis
        && noFacePlan.appliesWatermark && noFacePlan.carriesSourceMetadata,
      "without a face the photo keeps its format and can still take a signature")

var upscaleRequest = baseRequest
upscaleRequest.longEdge = 1600
upscaleRequest.aiUpscale = true
let upscalePlan = RenderPolicy.plan(upscaleRequest, source: baseSource)
check(upscalePlan.upscales && upscalePlan.pixelSize == StudioSize(width: 1600, height: 1200),
      "a requested edge caps the 4x pass")
check(upscalePlan.colorSpace == .sRGB,
      "upscaled pixels are written with the upscaler's working profile")
check(RenderPolicy.plan(upscaleRequest, source: baseSource).bitsPerChannel == 8,
      "the output contract reports the encoded depth")

var past4x = upscaleRequest
past4x.longEdge = 5000
check(RenderPolicy.plan(past4x, source: baseSource).pixelSize
        == StudioSize(width: 3200, height: 2400),
      "past 4x the output stops at the model's factor")

var downscaleRequest = baseRequest
downscaleRequest.longEdge = 400
check(RenderPolicy.plan(downscaleRequest, source: baseSource).pixelSize
        == StudioSize(width: 400, height: 300),
      "a smaller edge downscales without the upscaler")

check(RenderPolicy.effectiveFormat(chosen: .jpeg, analysis: overlay,
                                   includeAnalysis: true, faceCount: 1) == .png,
      "overlay-only forces PNG when a face exists")
check(RenderPolicy.effectiveFormat(chosen: .jpeg, analysis: overlay,
                                   includeAnalysis: false, faceCount: 1) == .jpeg,
      "a batch that draws no callouts keeps the chosen format")
check(RenderPolicy.effectiveFormat(chosen: .jpeg, analysis: overlay,
                                   includeAnalysis: true, faceCount: 0) == .jpeg,
      "without a face the chosen format stays")

check(RenderPolicy.suggestedFileName(imageName: "portrait.jpg", format: .jpeg,
                                     analysis: AnalysisSettings(), faceCount: 2)
        == "portrait-retouched.jpg", "a plain export keeps the extension")
check(RenderPolicy.suggestedFileName(imageName: "", format: .png,
                                     analysis: AnalysisSettings(), faceCount: 2)
        == "retouched.png", "an unnamed photo gets a fallback name")
check(RenderPolicy.suggestedFileName(imageName: "portrait.jpg", format: .jpeg,
                                     analysis: overlay, faceCount: 2)
        == "portrait-retouched-analysis-lines.png",
      "overlay-only names its PNG even when JPEG was chosen")
check(RenderPolicy.suggestedFileName(imageName: "portrait.jpg", format: .jpeg,
                                     analysis: overlay, faceCount: 0)
        == "portrait-retouched.jpg",
      "a name must not promise analysis the file cannot carry")

check(RenderPolicy.upscaleAvailable(source: StudioSize(width: 800, height: 600),
                                    longEdge: 1600),
      "the 4x pass is offered for a small photo")
check(!RenderPolicy.upscaleAvailable(source: StudioSize(width: 800, height: 600),
                                     longEdge: 400),
      "a downscale never offers the upscaler")
check(!RenderPolicy.upscaleAvailable(source: StudioSize(width: 4000, height: 3000),
                                     longEdge: 5000),
      "a photo past the output ceiling cannot upscale")

var fitted = upscaleRequest
fitted = RenderPolicy.fittingUpscale(fitted, to: StudioSize(width: 2000, height: 1500))
check(!fitted.aiUpscale, "a file that already reaches the edge skips the pass")
var unrequested = baseRequest
unrequested.aiUpscale = false
check(!RenderPolicy.fittingUpscale(unrequested,
                                   to: StudioSize(width: 400, height: 300)).aiUpscale,
      "an unrequested upscale stays off")

var batchBase = baseRequest
batchBase.crop = StudioRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
batchBase.orientation = DocumentOrientation(quarterTurns: 1)
batchBase.selectedFaceIndex = 1
batchBase.aiEdits = [AIEdit(preset: "p", prompt: "q", seed: 1,
                            patchFile: "patch.png", alphaFile: "alpha.png",
                            box: StudioRect(x: 0, y: 0, width: 1, height: 1),
                            imagePixels: StudioSize(width: 10, height: 10))]
batchBase.analysis = overlay
batchBase.analysis.setEndpoint(StudioPoint(x: 0.2, y: 0.3), for: .forehead)
batchBase.analysis.setAnchor(StudioPoint(x: 0.4, y: 0.5), for: .forehead)

let documentURL = URL(fileURLWithPath: "/batch/document.jpg")
let own = BatchRenderPolicy.request(batchBase, fileURL: documentURL,
                                    documentURL: documentURL,
                                    documentAspect: 1.5, fileAspect: 1.5)
check(own == batchBase, "the open document keeps its exact request")

let other = BatchRenderPolicy.request(batchBase,
                                      fileURL: URL(fileURLWithPath: "/batch/other.jpg"),
                                      documentURL: documentURL,
                                      documentAspect: 1.5, fileAspect: 1.5)
check(other.crop == nil && other.aiEdits.isEmpty && other.orientation.isIdentity
        && other.selectedFaceIndex == nil,
      "a turned document's frame never leaks to another photo")
check(other.analysis.endpoints.isEmpty && other.analysis.anchors.isEmpty,
      "dragged callout ends stay with their photo")
check(other.adjustments == batchBase.adjustments && other.format == batchBase.format
        && other.watermark == batchBase.watermark,
      "the shared look, format and signature travel")

var upright = batchBase
upright.orientation = .identity
let sameShape = BatchRenderPolicy.request(upright,
                                          fileURL: URL(fileURLWithPath: "/batch/other.jpg"),
                                          documentURL: documentURL,
                                          documentAspect: 1.5, fileAspect: 1.5)
check(sameShape.crop == upright.crop,
      "an unturned document's crop travels to a same-shape file")
let differentShape = BatchRenderPolicy.request(upright,
                                               fileURL: URL(fileURLWithPath: "/batch/wide.jpg"),
                                               documentURL: documentURL,
                                               documentAspect: 1.5, fileAspect: 2.0)
check(differentShape.crop == nil, "a different-shape file exports whole")
check(BatchRenderPolicy.cropApplies(StudioRect(x: 0, y: 0, width: 1, height: 1),
                                    documentAspect: 1.5, fileAspect: 1.5),
      "the same aspect keeps the crop")
check(!BatchRenderPolicy.cropApplies(StudioRect(x: 0, y: 0, width: 1, height: 1),
                                     documentAspect: 1.5, fileAspect: 1.0),
      "a different aspect refuses the crop")
check(!BatchRenderPolicy.cropApplies(nil, documentAspect: 1.5, fileAspect: 1.5),
      "no crop means nothing to apply")

let folderURL = URL(fileURLWithPath: "/batch/out")
let inputURL = URL(fileURLWithPath: "/batch/photo.jpg")
var taken: Set<String> = ["/batch/out/photo-retouched.png"]
let unique = BatchRenderPolicy.uniqueOutputURL(for: inputURL, in: folderURL,
                                               format: .png) { taken.contains($0.path) }
check(unique.lastPathComponent == "photo-retouched-2.png",
      "a taken batch name gains a counter", unique.lastPathComponent)
taken.insert("/batch/out/photo-retouched-2.png")
let third = BatchRenderPolicy.uniqueOutputURL(for: inputURL, in: folderURL,
                                              format: .tiff) { _ in false }
check(third.lastPathComponent == "photo-retouched.tif",
      "a fresh format starts at the plain name")

let progress = RenderProgress(stage: .upscaling, completed: 3, total: 12)
check(progress.fraction == 0.25, "completed tiles expose a real fraction")
check(RenderProgress(stage: .rendering).fraction == nil,
      "an uncountable stage has no fake percentage")
check(RenderProgress(stage: .upscaling, completed: 20, total: 12).fraction == 1,
      "a fraction never passes the end")

final class RecordingRenderer: DocumentRenderPipeline {
    typealias Source = String
    typealias Output = String

    var renderedRequest: RenderRequest?
    var renderedSource: String?
    var writtenRequest: RenderRequest?
    var writtenSource: String?
    var writtenOutput: String?
    var reported: [RenderProgress] = []

    func render(_ request: RenderRequest, source: String,
                progress: ((RenderProgress) -> Void)?) throws -> String {
        renderedRequest = request
        renderedSource = source
        progress?(RenderProgress(stage: .rendering))
        return "pixels"
    }

    func write(_ output: String, request: RenderRequest, source: String,
               to destination: URL, protecting protectedURL: URL?) throws -> RenderResult {
        writtenRequest = request
        writtenSource = source
        writtenOutput = output
        return RenderResult(destination: destination,
                            pixelSize: StudioSize(width: 10, height: 10),
                            format: request.format,
                            colorSpace: .source,
                            colorProfileName: "Test RGB",
                            carriedSourceMetadata: true)
    }
}

let recorder = RecordingRenderer()
let testDestination = URL(fileURLWithPath: "/renderer/lines.png")
let testResult = try! recorder.renderAndWrite(linesRequest, source: "decoded",
                                              to: testDestination)
check(recorder.renderedRequest == linesRequest && recorder.renderedSource == "decoded",
      "the port receives the request and the host's source")
check(recorder.writtenRequest == linesRequest && recorder.writtenSource == "decoded"
        && recorder.writtenOutput == "pixels",
      "the write step receives the same request and the rendered output")
check(testResult.destination == testDestination
        && testResult.format == linesRequest.format
        && testResult.colorProfileName == "Test RGB",
      "the port returns the written result")

print("")
print(failures.isEmpty
      ? "StudioCore: \(checks) checks passed"
      : "StudioCore: \(checks - failures.count)/\(checks) passed, \(failures.count) failed")
if !failures.isEmpty {
    for failure in failures { print("  failed: \(failure)") }
    exit(1)
}
