import Foundation
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

print("")
if failures.isEmpty {
    print("AI DISCLOSURE TESTS: PASS (\(checks) checks)")
    exit(0)
} else {
    print("AI DISCLOSURE TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
