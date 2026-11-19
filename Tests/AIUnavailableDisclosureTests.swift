import Foundation
import CoreImage
import StudioCore

// The export path used to collapse every AI failure into
// `StatusToken.exportFailed`, so an owner who asked for a 4× pass on a build
// without the helper read "Could not save the export." This suite pins the
// three facts that keep that from coming back: the unavailable class is
// distinct, the two AI classes are distinct from each other, and the manager
// names a model with no runnable helper instead of implying it is active.

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

// MARK: - The unavailable class wins before the helper is asked anything

check(EditorModel.exportUpscaleRefusal(helperInstalled: false, state: .supported)
        == .exportUpscaleUnavailable,
      "a missing helper refuses the 4x export as unavailable")
check(EditorModel.exportUpscaleRefusal(helperInstalled: false, state: nil)
        == .exportUpscaleUnavailable,
      "the refusal does not depend on a capability report that cannot exist")
check(EditorModel.exportUpscaleRefusal(helperInstalled: false, state: .supported)
        != .exportFailed,
      "the AI-specific refusal is not the generic save failure")

// The capability verdicts that already existed must survive the new check.
check(EditorModel.exportUpscaleRefusal(helperInstalled: true, state: .blocked)
        == .aiCapabilityBlocked("upscale.4x"),
      "a blocked capability keeps its own sentence")
check(EditorModel.exportUpscaleRefusal(helperInstalled: true, state: .requiresModel)
        == .aiModelMissing,
      "a missing model keeps its own sentence")
check(EditorModel.exportUpscaleRefusal(helperInstalled: true, state: .supported) == nil
        && EditorModel.exportUpscaleRefusal(helperInstalled: true, state: .unsupported) == nil
        && EditorModel.exportUpscaleRefusal(helperInstalled: true, state: nil) == nil,
      "a runnable or unsupported helper still lets the render decide")

// MARK: - A failed pass is a different class from a failed save

check(EditorModel.exportFailureStatus(.upscaleFailed) == .exportUpscaleFailed,
      "an upscale that failed during the job names that class")
check(EditorModel.exportFailureStatus(.renderFailed) == .exportFailed
        && EditorModel.exportFailureStatus(.writeFailed) == .exportFailed
        && EditorModel.exportFailureStatus(.imageTooLarge) == .exportFailed,
      "render, write and size failures stay generic")
check(EditorModel.exportFailureStatus(.cancelled) == .exportCancelled
        && EditorModel.exportFailureStatus(.sourceIsDestination) == .exportRefusedOriginal,
      "cancel and the original-file refusal are unchanged")

check(StatusToken.exportUpscaleUnavailable != .exportUpscaleFailed
        && StatusToken.exportUpscaleFailed != .exportFailed
        && StatusToken.exportUpscaleUnavailable != .exportFailed,
      "three failure classes, three tokens")

// MARK: - The words say what happened, and never promise a fallback

let english = L10n.shared
let persian = PersianL10n.table

let unavailableEN = english.statusText(.exportUpscaleUnavailable)
let failedEN = english.statusText(.exportUpscaleFailed)
let failedGenericEN = english.statusText(.exportFailed)
let unavailableFA = persian.statusText(.exportUpscaleUnavailable)
let failedFA = persian.statusText(.exportUpscaleFailed)
let failedGenericFA = persian.statusText(.exportFailed)

check(unavailableEN != failedGenericEN && unavailableEN != failedEN,
      "the English unavailable sentence is its own")
check(unavailableFA != failedGenericFA && unavailableFA != failedFA,
      "the Persian unavailable sentence is its own")
check(unavailableEN.contains("nothing was exported")
        && unavailableEN.contains("turn off AI upscale"),
      "English names the outcome and the way forward")
check(unavailableFA.contains("هیچ فایلی ذخیره نشد")
        && unavailableFA.contains("خاموش کن"),
      "Persian names the outcome and the way forward")
check(failedEN.contains("Nothing was exported") && failedEN.contains("try again"),
      "English for a failed pass names the outcome and the retry")
check(failedFA.contains("چیزی ذخیره نشد"),
      "Persian for a failed pass says nothing was written")

// The old string claimed a fallback that does not exist. Neither language may
// bring it back.
check(!unavailableEN.lowercased().contains("standard resampler")
        && !unavailableFA.contains("بازنمونه‌برداری استاندارد")
        && !unavailableEN.lowercased().contains("is used")
        && !unavailableFA.contains("استفاده می‌شود"),
      "no sentence promises a silent standard-resampler fallback")

// MARK: - The manager separates weights from a runnable helper

check(ModelRunState.resolve(weightsInstalled: true, helperCanRun: false)
        == .installedNotRunnable,
      "installed weights with no runnable helper are not called runnable")
check(ModelRunState.resolve(weightsInstalled: true, helperCanRun: true) == .runnable,
      "installed weights with a runnable helper are runnable")
check(ModelRunState.resolve(weightsInstalled: false, helperCanRun: false) == .missing
        && ModelRunState.resolve(weightsInstalled: false, helperCanRun: true) == .missing,
      "no weights is missing whatever the helper can do")
check(ModelRunState.installedNotRunnable.hasWeights
        && !ModelRunState.installedNotRunnable.isRunnable
        && ModelRunState.runnable.isRunnable,
      "the state answers both questions separately")

check(english.modelsInstalledNoRuntime != english.modelsInstalled
        && persian.modelsInstalledNoRuntime != persian.modelsInstalled,
      "the chip cannot read as plain Installed in either language")
check(english.modelsInstalledNoRuntime.contains("can't run")
        && persian.modelsInstalledNoRuntime.contains("قابل اجرا نیست"),
      "the chip says the model cannot run")

// MARK: - A slider row states the number its control actually holds

// The watermark opacity holds 0.05…1. The shared row used to print "%.0f", so
// 0.65 read "1": a label naming a value the control did not hold. The row now
// takes its unit and precision from the call site instead of guessing from the
// magnitude, so every strength row keeps its bare number and only the rows
// that mean a percentage say so.
let previousLanguage = AppLanguage.current

AppLanguage.current = .english

check(ParameterValueFormat.whole.text(for: 45) == "45"
        && ParameterValueFormat.whole.text(for: 70) == "70"
        && ParameterValueFormat.whole.text(for: 360) == "360"
        && ParameterValueFormat.whole.text(for: -12) == "-12",
      "a strength row keeps the bare whole number it always showed")
check(!ParameterValueFormat.whole.text(for: 45).contains("%")
        && ParameterValueFormat.whole.accessibilityScale == nil
        && ParameterValueFormat.percent.accessibilityScale == nil,
      "and gains neither a unit nor a changed accessibility scale")

check(ParameterValueFormat.fractionAsPercent.text(for: 0.65) == "65%",
      "an opacity of 0.65 reads 65%",
      ParameterValueFormat.fractionAsPercent.text(for: 0.65))
check(ParameterValueFormat.fractionAsPercent.text(for: 0.05) == "5%"
        && ParameterValueFormat.fractionAsPercent.text(for: 1) == "100%",
      "the ends of the opacity range read 5% and 100%")

check(ParameterValueFormat.percent.text(for: 3) == "3%"
        && ParameterValueFormat.percent.text(for: 10) == "10%",
      "the size row carries the percent unit its setting means")

// The opacity row steps in 0.05. Whole percent is the fewest digits that still
// names every reachable step, so the readout can never collapse two positions
// onto one number.
let opacitySteps = (1...20).map { Double($0) * 0.05 }
let opacityTexts = opacitySteps.map { ParameterValueFormat.fractionAsPercent.text(for: $0) }
check(opacityTexts == (1...20).map { "\($0 * 5)%" },
      "every 0.05 step has its own text",
      "\(opacityTexts.first ?? "?")…\(opacityTexts.last ?? "?")")
check(Set(opacityTexts).count == opacitySteps.count,
      "and no two steps share a text")

let opacityScale = ParameterValueFormat.fractionAsPercent.accessibilityScale
check(opacityScale?.display(0.65) == 65
        && opacityScale?.stored(65) == 0.65
        && opacityScale?.range == 5...100
        && opacityScale?.step == 5,
      "the slider exposes the number the row shows — 65, on the same 5-point step")
check(opacityScale.map { scale in
        opacitySteps.allSatisfy { scale.display($0) == ($0 * 100).rounded() }
      } ?? false,
      "every opacity step reports the same number its text names")

// Persian follows the table's own convention: Persian-Indic digits and the
// Persian percent sign, with no Latin character left to reorder inside an RTL
// run. The code points below are what the app draws; the QA capture in the PR
// shows the rendered line.
AppLanguage.current = .persian
let persianOpacity = ParameterValueFormat.fractionAsPercent.text(for: 0.65)
check(persianOpacity == "۶۵٪",
      "the Persian opacity reads ۶۵٪",
      persianOpacity)
check(ParameterValueFormat.percent.text(for: 3) == "۳٪",
      "the Persian size reads ۳٪",
      ParameterValueFormat.percent.text(for: 3))
check(ParameterValueFormat.whole.text(for: 45) == "۴۵",
      "a strength row still converts its digits in Persian")
check(persianOpacity.allSatisfy { !$0.isASCII }
        && !persianOpacity.contains("%")
        && persianOpacity.last == "٪",
      "the Persian readout has Persian digits and the Persian unit, no Latin run")
check(opacityScale?.display(0.65) == 65 && opacityScale?.stored(65) == 0.65,
      "the slider value and the visible text cannot drift apart in scale")

AppLanguage.current = previousLanguage

// MARK: - The watermark rows declare the step their readout can name

// #98 fixed the readout, but the call site's `step` is the other half of the
// released defect: on a 0.05…1 range a 1-point step lets a drag commit only 0
// and 1, and 0 is outside the declared range. Both rows now read one declared
// set of values the sheet and this test share, so reverting either the format
// or the step fails here instead of returning silently.
let watermarkOpacityRow = ExportSheet.opacityRow
let watermarkSizeRow = ExportSheet.sizeRow

check(watermarkOpacityRow.range == 0.05...1
        && watermarkOpacityRow.valueFormat == .fractionAsPercent
        && watermarkOpacityRow.step == 0.05
        && watermarkOpacityRow.reset == 0.65,
      "the opacity row declares 0.05…1, percent text, a 0.05 step and its reset",
      "\(watermarkOpacityRow.range) step \(watermarkOpacityRow.step)")
check(watermarkSizeRow.range == 1...10
        && watermarkSizeRow.valueFormat == .percent
        && watermarkSizeRow.step == 1
        && watermarkSizeRow.reset == 3,
      "the size row declares 1…10, percent text, whole steps and its reset")

// What the sheet passes reaches the row the sheet draws.
let wiredOpacityRow = ParameterRow(title: "opacity", value: .constant(0.65),
                                   range: watermarkOpacityRow.range,
                                   valueFormat: watermarkOpacityRow.valueFormat,
                                   step: watermarkOpacityRow.step)
check(wiredOpacityRow.step == 0.05
        && wiredOpacityRow.valueFormat == .fractionAsPercent
        && wiredOpacityRow.valueFormat.accessibilityScale != nil,
      "the drawn row receives the 0.05 step and the percent scale")

// The drag maths a test drives is the maths the slider runs, not a copy of it.
func reachablePositions(in range: ClosedRange<Double>, step: Double) -> [Double] {
    var found: [Double] = []
    for tick in 0...2000 {
        let fraction = Double(tick) / 2000
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        if let next = BipolarSlider.committed(raw, from: -1, in: range, step: step),
           !found.contains(next) { found.append(next) }
    }
    return found.sorted()
}

let opacityPositions = reachablePositions(in: watermarkOpacityRow.range,
                                          step: watermarkOpacityRow.step)
check(opacityPositions.count == 20
        && opacityPositions.first == 0.05
        && opacityPositions.last == 1,
      "a drag across the opacity row reaches exactly 20 positions",
      "\(opacityPositions.count)")
let releasedPositions = reachablePositions(in: watermarkOpacityRow.range, step: 1)
check(releasedPositions.count == 2
        && releasedPositions.first == 0
        && releasedPositions.last == 1,
      "the pre-#98 1-point step reached only 0 and 1, 0 lying outside the range",
      "\(releasedPositions)")

// Display and stored are the same number in both directions, for every position
// the drag can produce and every value the assistive slider can write.
let declaredScale = watermarkOpacityRow.valueFormat.accessibilityScale
check(declaredScale.map { scale in
        opacityPositions.allSatisfy { position in
            scale.display(position) == (position * 100).rounded()
                && scale.stored(scale.display(position)) == position
        }
      } ?? false,
      "all 20 reachable positions survive display→stored bit for bit")
check(declaredScale.map { scale in
        stride(from: 5.0, through: 100.0, by: 5).allSatisfy { percent in
            scale.display(scale.stored(percent)) == percent
        }
      } ?? false,
      "every assistive value survives stored→display exactly")
check(declaredScale.map { scale in
        stride(from: 5.0, through: 100.0, by: 5).map { scale.stored($0) }
            == opacityPositions
      } ?? false,
      "assistive technology writes the same 20 doubles a drag commits")

// MARK: - Legacy stored values keep their pixels and only move when touched

// Documents written before #98 can hold 0.0 (the old step-1 drag committed it)
// or an off-grid value (the reset writes 0.65; saved settings keep whatever
// they hold). #98 changes the label and what the next interaction writes. It
// does not rewrite the stored value on its own and it does not touch the
// renderer, so an untouched document exports the pixels it always did.
let legacyLanguage = AppLanguage.current
AppLanguage.current = .english

let legacyOpacity: [(stored: Double, text: String)] = [
    (0.0, "0%"), (0.07, "7%"), (0.5, "50%"),
    (0.63, "63%"), (0.65, "65%"), (1.0, "100%"),
]
for sample in legacyOpacity {
    check(watermarkOpacityRow.valueFormat.text(for: sample.stored) == sample.text,
          "a stored opacity of \(sample.stored) reads \(sample.text)",
          watermarkOpacityRow.valueFormat.text(for: sample.stored))
}

AppLanguage.current = .persian
check(watermarkOpacityRow.valueFormat.text(for: 0) == "۰٪"
        && watermarkOpacityRow.valueFormat.text(for: 0.63) == "۶۳٪",
      "legacy values read in Persian too")
AppLanguage.current = legacyLanguage

// What the next interaction writes. A drag that lands where the value already
// is (or within half a step of it) is pointer jitter and writes nothing; a real
// drag lands on the nearest reachable position. A legacy 0.0 sits left of the
// track's own left edge, so the first drag (even at the edge) writes 0.05.
check(BipolarSlider.committed(watermarkOpacityRow.range.lowerBound, from: 0.0,
                              in: watermarkOpacityRow.range,
                              step: watermarkOpacityRow.step)
        == opacityPositions.first,
      "a legacy 0.0 moves onto the first reachable position on a drag")
check(BipolarSlider.committed(0.63, from: 0.63, in: watermarkOpacityRow.range,
                              step: watermarkOpacityRow.step) == nil
        && BipolarSlider.committed(0.65, from: 0.63, in: watermarkOpacityRow.range,
                                   step: watermarkOpacityRow.step) == nil,
      "a drag within half a step of 0.63 is jitter and leaves the value alone")
check(BipolarSlider.committed(0.70, from: 0.63, in: watermarkOpacityRow.range,
                              step: watermarkOpacityRow.step) == opacityPositions[13],
      "the next real drag writes the nearest reachable position")
check(declaredScale?.stored(65) == opacityPositions[12],
      "the assistive slider writes the same 0.65 double the drag commits")

// The export path, driven the way the export drives it: the stored value goes
// straight into the renderer, whose own 0…1 clamp predates #98.
func watermarkExportBytes(opacity: Double, enabled: Bool = true) -> Data? {
    let width = 120, height = 90
    let canvas = CIImage(color: CIColor(red: 0.30, green: 0.35, blue: 0.40, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let settings = WatermarkSettings(enabled: enabled, text: "WM", position: .center,
                                     opacity: opacity, sizePercent: 8)
    let rendered = WatermarkRenderer.apply(settings, to: canvas)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CIContext(options: [CIContextOption.workingColorSpace: NSNull()])
    bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        context.render(rendered, toBitmap: base, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: space)
    }
    return Data(bytes)
}

let renderedPositions = opacityPositions.compactMap {
    watermarkExportBytes(opacity: $0)
}
check(renderedPositions.count == opacityPositions.count
        && Set(renderedPositions).count == renderedPositions.count,
      "every one of the 20 reachable positions draws its own pixels",
      "\(renderedPositions.count) renders")

if let invisible = watermarkExportBytes(opacity: 0),
   let unwritten = watermarkExportBytes(opacity: 0, enabled: false) {
    check(invisible == unwritten,
          "a legacy 0.0 exports the same pixels as a watermark that never drew")
} else {
    check(false, "legacy 0.0 render")
}
if let offGrid = watermarkExportBytes(opacity: 0.63),
   let below = watermarkExportBytes(opacity: opacityPositions[11]),
   let above = watermarkExportBytes(opacity: opacityPositions[12]) {
    check(offGrid != below && offGrid != above,
          "an off-grid 0.63 exports its own strength, not the nearest step")
} else {
    check(false, "off-grid render")
}

// MARK: - The other 63 rows still print exactly what they printed before #98

// Census of ParameterRow call sites at #98 (2026-11-20, Sources/RetouchStudio/
// Views): 65 rows in 10 distinct (range, format) combinations. Eight
// combinations, 63 rows, use the whole-number default; only the two watermark
// rows changed. Every whole value is checked against the pre-#98 expression,
// and a row that names no format is checked to still get that default, so a
// changed default cannot repaint one of the 63 silently.
struct ReadoutCensus {
    let range: ClosedRange<Double>
    let format: ParameterValueFormat
    let rows: Int
}
let census: [ReadoutCensus] = [
    ReadoutCensus(range: -100...100, format: .whole, rows: 28),
    ReadoutCensus(range: 0...100, format: .whole, rows: 29),
    ReadoutCensus(range: 0...360, format: .whole, rows: 1),
    ReadoutCensus(range: 2...60, format: .whole, rows: 1),
    ReadoutCensus(range: -180...180, format: .whole, rows: 1),
    ReadoutCensus(range: 60...240, format: .whole, rows: 1),
    ReadoutCensus(range: 5...100, format: .whole, rows: 1),
    ReadoutCensus(range: 4...30, format: .whole, rows: 1),
    ReadoutCensus(range: 0.05...1, format: .fractionAsPercent, rows: 1),
    ReadoutCensus(range: 1...10, format: .percent, rows: 1),
]
check(census.count == 10
        && census.filter { $0.format == .whole }.reduce(0) { $0 + $1.rows } == 63
        && census.reduce(0) { $0 + $1.rows } == 65,
      "the census lists the 65 rows the sweep covered, 63 of them whole")

var censusMismatch: String?
for entry in census where entry.format == .whole {
    var value = entry.range.lowerBound
    while value <= entry.range.upperBound {
        let before = Digits.convert(String(format: "%.0f", value))
        let now = entry.format.text(for: value)
        if now != before || entry.format.accessibilityScale != nil {
            censusMismatch = "\(entry.range) at \(value): \(now) ≠ \(before)"
            break
        }
        value += 1
    }
    if censusMismatch != nil { break }
}
check(censusMismatch == nil,
      "all 63 strength rows still print the pre-#98 expression, value for value",
      censusMismatch ?? "")

let fractionalWhole = [0.5, 1.5, -0.5, 44.6, -44.6]
check(fractionalWhole.allSatisfy {
        ParameterValueFormat.whole.text(for: $0)
            == Digits.convert(String(format: "%.0f", $0))
      },
      "and the rounding of a stored fraction is unchanged")

let defaultRow = ParameterRow(title: "strength", value: .constant(45))
check(defaultRow.valueFormat == .whole
        && defaultRow.step == 1
        && defaultRow.range == -100...100
        && defaultRow.valueFormat.accessibilityScale == nil,
      "a row that names no format keeps the whole-number default the 63 rows use")

check(ParameterValueFormat.fractionAsPercent.text(for: 0.65)
        != Digits.convert(String(format: "%.0f", 0.65))
        && ParameterValueFormat.percent.text(for: 3)
        != Digits.convert(String(format: "%.0f", 3)),
      "the only rows whose text changed are the two percent rows")

print("")
if failures.isEmpty {
    print("AI DISCLOSURE TESTS: PASS (\(checks) checks)")
    exit(0)
} else {
    print("AI DISCLOSURE TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
