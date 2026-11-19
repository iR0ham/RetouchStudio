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

print("")
if failures.isEmpty {
    print("AI DISCLOSURE TESTS: PASS (\(checks) checks)")
    exit(0)
} else {
    print("AI DISCLOSURE TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
