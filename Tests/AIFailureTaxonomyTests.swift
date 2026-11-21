import Foundation
import StudioCore

// One message used to answer every startup failure. Because
// `missingHelperMessage` asked `AIRuntime.package == nil` first, a helper that
// was on disk and failed to launch was announced as "not available in this
// build" — a different fact, and a wrong one. This suite pins the five states,
// the decision order that keeps them apart, and both languages of their copy.

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

/// True when `text` carries an ASCII letter or digit outside an LRI…PDI run.
/// A Persian sentence may embed a Latin version or product name, but only
/// inside directional isolation; bare Latin is what flips the line.
func hasBareLatin(_ text: String) -> Bool {
    var isolated = false
    for scalar in text.unicodeScalars {
        if scalar == "\u{2066}" { isolated = true; continue }
        if scalar == "\u{2069}" { isolated = false; continue }
        if isolated { continue }
        if scalar.isASCII,
           CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
            return true
        }
    }
    return false
}

// MARK: - The ordering defect: a launch failure is not an absent build

let launch = AIFailureEvidence(runtimePackageAvailable: false,
                               runtimeOnDisk: true,
                               runtimeProblem: nil,
                               launchFailure: "spawn: no such file or directory")
check(AIWorker.failureState(launch) == .workerLaunchFailed,
      "a helper on disk that failed to launch is a launch failure")
check(AIWorker.failureState(launch) != .runtimeUnavailable,
      "the launch failure is not reported as a build without AI",
      "package is nil, as in every light build")

// A launch already recorded stays authoritative even if the layout probe no
// longer finds the interpreter (a deleted venv, a moved checkout).
let vanished = AIFailureEvidence(runtimePackageAvailable: false,
                                 runtimeOnDisk: false,
                                 runtimeProblem: nil,
                                 launchFailure: "helper exited before answering")
check(AIWorker.failureState(vanished) == .workerLaunchFailed,
      "a recorded launch failure outranks a layout probe that now finds nothing")

// An unusable runtime is an installation fact, not a crash, and not absence.
let install = AIFailureEvidence(runtimePackageAvailable: true,
                                runtimeOnDisk: true,
                                runtimeProblem: "validation failed: startup check",
                                launchFailure: nil)
check(AIWorker.failureState(install) == .runtimeInstallFailed,
      "a runtime that failed its startup check is an install failure")
check(AIWorker.failureState(install) != .workerLaunchFailed,
      "an install failure is not called a launch failure")
check(AIWorker.failureState(install) != .runtimeUnavailable,
      "an install failure is not called an absent build")

// A runtime problem outranks a stale launch record: the runtime must be fixed
// first, and "it crashed" would point at the wrong action.
let both = AIFailureEvidence(runtimePackageAvailable: true,
                             runtimeOnDisk: true,
                             runtimeProblem: "busy: another window",
                             launchFailure: "connection refused")
check(AIWorker.failureState(both) == .runtimeInstallFailed,
      "validation or a held runtime outranks an older launch record")

// The only case that may say "this build has no AI" is the one with nothing on
// disk at all.
let absent = AIFailureEvidence(runtimePackageAvailable: false,
                               runtimeOnDisk: false,
                               runtimeProblem: nil,
                               launchFailure: nil)
check(AIWorker.failureState(absent) == .runtimeUnavailable,
      "nothing on disk is the unavailable state")
check(AIWorker.failureState(absent) != .workerLaunchFailed,
      "unavailable is not conflated with a launch failure")

// MARK: - Five states, each constructible

let states = AIFailureState.allCases
check(states.count == 5,
      "the taxonomy holds exactly the five owner-required facts",
      states.map(\.rawValue).joined(separator: ", "))
check(states == [.runtimeUnavailable, .runtimeInstallFailed, .workerLaunchFailed,
                 .inferenceFailed, .exportFailed],
      "the declared order is the order the owner lists them in")
check(Set(states.map(\.rawValue)).count == states.count,
      "no two states share a name")
check(AIWorker.failureState(launch) != AIWorker.failureState(install)
        && AIWorker.failureState(install) != AIWorker.failureState(absent)
        && AIWorker.failureState(launch) != AIWorker.failureState(absent),
      "the three startup states the app can reach are distinguishable")

// MARK: - Copy: both languages, five distinct sentences each

for language in [AIFailureCopy.Language.english, .persian] {
    let texts = states.map { AIFailureCopy.text(for: $0, language) }
    check(Set(texts).count == states.count,
          "all five states have distinct copy in \(language == .persian ? "Persian" : "English")")
    check(texts.allSatisfy { !$0.isEmpty },
          "no state falls back to an empty sentence in \(language == .persian ? "Persian" : "English")")
}

for state in states {
    let en = AIFailureCopy.text(for: state, .english)
    let fa = AIFailureCopy.text(for: state, .persian)
    check(en != fa, "\(state.rawValue) is written in both languages")
    check(!hasBareLatin(fa),
          "\(state.rawValue) Persian copy has no bare Latin run",
          hasBareLatin(fa) ? "add \u{2066}…\u{2069} around the Latin run" : "")
}

// The launch sentence must not borrow the absent-build sentence, in either
// language — that equality is the defect.
check(AIFailureCopy.text(for: .workerLaunchFailed, .english)
        != AIFailureCopy.text(for: .runtimeUnavailable, .english),
      "English launch failure does not read as absence")
check(AIFailureCopy.text(for: .workerLaunchFailed, .persian)
        != AIFailureCopy.text(for: .runtimeUnavailable, .persian),
      "Persian launch failure does not read as absence")

// "In use" and "validation failed" are different sentences under one state.
check(AIFailureCopy.runtimeBusy(.english) != AIFailureCopy.text(for: .runtimeInstallFailed, .english)
        && AIFailureCopy.runtimeBusy(.persian) != AIFailureCopy.text(for: .runtimeInstallFailed, .persian),
      "a held runtime is not described as a failed validation")

// MARK: - The sentences keep the promises the app can actually make

let newEN = AIFailureCopy.workerLaunchFailedEN + " " + AIFailureCopy.inferenceFailedEN
let newFA = AIFailureCopy.workerLaunchFailedFA + " " + AIFailureCopy.inferenceFailedFA
check(!newEN.lowercased().contains("resampl")
        && !newEN.lowercased().contains("fallback")
        && !newEN.lowercased().contains("standard"),
      "no English sentence promises a resampling or standard-processing fallback")
check(!newFA.contains("بازنمونه") && !newFA.contains("استاندارد") && !newFA.contains("جایگزین"),
      "no Persian sentence promises a resampling or standard-processing fallback")
check(!newEN.lowercased().contains("download") && !newFA.contains("دانلود"),
      "no new sentence offers or implies a runtime download")
check(AIFailureCopy.inferenceFailedEN.contains("Nothing was changed")
        && AIFailureCopy.inferenceFailedFA.contains("چیزی تغییر نکرد"),
      "a failed job says the document was left alone, in both languages")

// MARK: - The live path reads the same decision

let live = AIWorker.helperFailureEvidence
if live.runtimeOnDisk {
    check(AIWorker.failureState(live) == .workerLaunchFailed,
          "a checkout with a helper tree does not classify as absent")
    check(AIWorker.missingHelperMessage != L10n.shared.aiRuntimeUnavailable,
          "the live message is not the absent-build sentence",
          "this machine has a helper tree")
} else {
    check(AIWorker.failureState(live) == .runtimeUnavailable,
          "with nothing on disk the live message stays the absent-build sentence")
}
check(!AIWorker.missingHelperMessage.isEmpty,
      "the live message is never empty")

print("")
if failures.isEmpty {
    print("AI FAILURE TAXONOMY TESTS: PASS (\(checks) checks)")
    exit(0)
} else {
    print("AI FAILURE TAXONOMY TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
