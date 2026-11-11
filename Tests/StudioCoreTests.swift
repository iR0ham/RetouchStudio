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

print("")
print(failures.isEmpty
      ? "StudioCore: \(checks) checks passed"
      : "StudioCore: \(checks - failures.count)/\(checks) passed, \(failures.count) failed")
if !failures.isEmpty {
    for failure in failures { print("  failed: \(failure)") }
    exit(1)
}
