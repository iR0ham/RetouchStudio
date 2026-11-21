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

// A launch failure stays authoritative even if the layout probe no longer finds
// the interpreter (a deleted venv, a moved checkout). What changed with the
// typed cause is which attempts may write that record at all: only one that had
// a helper to start. The evidence below is built by the production `launchFact`,
// so it is a record an attempt can actually leave; the refusal checks below pin
// the shape the old code fabricated.

struct TaxonomyProbeError: LocalizedError {
    var errorDescription: String? { "helper exited before answering" }
}

let vanished = AIFailureEvidence(
    runtimePackageAvailable: false,
    runtimeOnDisk: false,
    runtimeProblem: nil,
    launchFailure: AIWorker.launchFact(after: .failed(TaxonomyProbeError())))
check(AIWorker.failureState(vanished) == .workerLaunchFailed,
      "a recorded launch failure outranks a layout probe that now finds nothing")

// The record is written by the attempt itself, and its shape decides whether a
// later request may call it a crash.
check(AIWorker.launchFact(after: .started) == nil,
      "a successful start leaves no launch failure to read")
check(AIWorker.launchFact(after: .refused(.noHelperOnDisk)) == nil,
      "a build with nothing to start leaves no launch failure")
check(AIWorker.launchFact(after: .refused(.runtimeUnusable)) == nil,
      "an unusable selected runtime leaves no launch failure")
check(AIWorker.launchFact(after: .failed(TaxonomyProbeError()))
        == "helper exited before answering",
      "an attempt that had a helper to start records why it failed")

// The evidence the old path fabricated — nothing on disk plus a launch record —
// is the one shape a refusal can no longer produce.
let fabricated = AIWorker.launchFact(after: .refused(.noHelperOnDisk))
check(fabricated == nil,
      "a refusal writes no launch record to misread later")
check(AIWorker.failureState(AIFailureEvidence(runtimePackageAvailable: false,
                                              runtimeOnDisk: false,
                                              runtimeProblem: nil,
                                              launchFailure: fabricated))
        == .runtimeUnavailable,
      "so the next request still reads the absent build, not a crash")

AIWorker.noteLaunchFailure(AIWorker.launchFact(after: .failed(TaxonomyProbeError())))
check(AIWorker.lastLaunchFailure == "helper exited before answering",
      "a failed launch is visible to the next request")
AIWorker.noteLaunchFailure(AIWorker.launchFact(after: .started))
check(AIWorker.lastLaunchFailure == nil,
      "a successful launch clears the recorded failure")

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

// MARK: - B1: a helper-less build says the same thing twice

// Two AI actions in a row, in a build that has no helper — through the
// production `ensureRunning`, not a model of it. The sandbox below is a
// temporary support directory, a temporary working directory and a socket path
// nothing listens on, with the developer's interpreter overrides removed, so no
// helper exists to start and nothing outside the temporary directory is read or
// written. The first failure used to be written into the launch record as if a
// helper had crashed, so the second action switched from "not available in this
// build" to "is on this Mac but did not start".

let sandbox = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-helperless-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
let savedSupport = AIWorker.supportDirectoryOverride
let savedWorkingDirectory = FileManager.default.currentDirectoryPath
let savedPython = getenv("RETOUCH_AI_PYTHON").map { String(cString: $0) }
let savedWorkerRoot = getenv("RETOUCH_AI_WORKER_ROOT").map { String(cString: $0) }
unsetenv("RETOUCH_AI_PYTHON")
unsetenv("RETOUCH_AI_WORKER_ROOT")
AIWorker.supportDirectoryOverride = sandbox
WorkerClient.selectSocket(sandbox.appendingPathComponent("no-helper.sock").path)
_ = FileManager.default.changeCurrentDirectoryPath(sandbox.path)

var actionStates: [AIFailureState] = []
var actionSentences: [String] = []
var actionErrors: [String] = []
for _ in 1...2 {
    do {
        try AIWorker.ensureRunning()
        actionStates.append(AIWorker.failureState(AIWorker.helperFailureEvidence))
        actionSentences.append(AIWorker.missingHelperMessage)
        actionErrors.append("started")
    } catch {
        actionStates.append(AIWorker.failureState(AIWorker.helperFailureEvidence))
        actionSentences.append(AIWorker.missingHelperMessage)
        actionErrors.append(error.localizedDescription)
    }
}

AIWorker.supportDirectoryOverride = savedSupport
WorkerClient.selectSocket(nil)
_ = FileManager.default.changeCurrentDirectoryPath(savedWorkingDirectory)
if let savedPython { setenv("RETOUCH_AI_PYTHON", savedPython, 1) }
if let savedWorkerRoot { setenv("RETOUCH_AI_WORKER_ROOT", savedWorkerRoot, 1) }
let sandboxLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) ?? []
try? FileManager.default.removeItem(at: sandbox)

check(actionStates == [.runtimeUnavailable, .runtimeUnavailable],
      "both actions stay in the unavailable state",
      actionStates.map(\.rawValue).joined(separator: " → "))
check(actionSentences[0] == actionSentences[1],
      "the second action says what the first action said",
      actionSentences.map { "«\($0)»" }.joined(separator: " → "))
check(actionSentences[0] == AIFailureCopy.text(for: .runtimeUnavailable,
                                               AIFailureCopy.Language.current),
      "the sentence is the absent-build one, not a launch failure",
      actionSentences[0])
check(actionErrors[0] == actionErrors[1],
      "the thrown error is stable across actions too",
      actionErrors.map { "«\($0)»" }.joined(separator: " → "))
check(AIWorker.lastLaunchFailure == nil,
      "the two attempts left no launch failure behind")
check(AIWorker.supportDirectoryOverride == savedSupport,
      "the sandbox was put back after the sequence")
check(!sandboxLeftovers.contains { $0.hasSuffix(".sock") || $0 == "venv" || $0 == "Worker" },
      "the attempt left no helper behind",
      sandboxLeftovers.joined(separator: ", "))

// MARK: - B2: a leftover tree with no package is not an installation failure

// With `AIRuntime.package == nil` (the shipping state), launch-time recovery can
// still record a problem for a leftover `runtimes/protocol-v2` tree. That is not
// an installation fact in a build that cannot offer the download.
let staleNoTree = AIFailureEvidence(runtimePackageAvailable: false,
                                    runtimeOnDisk: false,
                                    runtimeProblem: "recovery: the transaction record is damaged",
                                    launchFailure: nil)
check(AIWorker.failureState(staleNoTree) == .runtimeUnavailable,
      "with no package a stale runtime problem is not an installation failure")
check(AIWorker.missingHelperMessage(for: staleNoTree, language: .english)
        == AIFailureCopy.runtimeUnavailable(.english),
      "and it does not point at a download this build cannot offer",
      AIWorker.missingHelperMessage(for: staleNoTree, language: .english))

let staleWithTree = AIFailureEvidence(runtimePackageAvailable: false,
                                      runtimeOnDisk: true,
                                      runtimeProblem: "recovery: the transaction record is damaged",
                                      launchFailure: nil)
check(AIWorker.failureState(staleWithTree) == .workerLaunchFailed,
      "a tree that is here and unusable is a start failure, not a download")
check(AIWorker.missingHelperMessage(for: staleWithTree, language: .english)
        != AIFailureCopy.runtimeInstallFailed(.english),
      "its sentence is not the install-failure one that offers Settings")

// The same problem with a package is an installation fact, and its sentence
// names the recovery rather than a startup check.
let recovery = AIFailureEvidence(runtimePackageAvailable: true,
                                 runtimeOnDisk: true,
                                 runtimeProblem: "recovery: the transaction record is damaged",
                                 launchFailure: nil)
check(AIWorker.failureState(recovery) == .runtimeInstallFailed,
      "with a package a runtime problem is still an installation failure")
check(AIWorker.missingHelperMessage(for: recovery, language: .english)
        == AIFailureCopy.runtimeRecoveryFailed(.english),
      "a recovery problem keeps the recovery sentence")
check(AIWorker.missingHelperMessage(for: recovery, language: .persian)
        == AIFailureCopy.runtimeRecoveryFailed(.persian),
      "in Persian too")

// The recovery and busy sentences are shown in the same places, so they keep
// the Persian bidi rule too. (The Intel sentence embeds "Apple silicon", and
// the not-installed sentence embeds "AI"; both live in the string-table file
// this change does not own, so they are reported rather than pinned here.)
for (name, text) in [("recovery", AIFailureCopy.runtimeRecoveryFailed(.persian)),
                     ("busy", AIFailureCopy.runtimeBusy(.persian))] {
    check(!hasBareLatin(text),
          "the \(name) Persian sentence has no bare Latin run",
          hasBareLatin(text) ? text : "")
}

// MARK: - The sentence a start failure is given, per state

let notInstalled = AIFailureEvidence(runtimePackageAvailable: true,
                                     runtimeOnDisk: false,
                                     runtimeProblem: nil,
                                     launchFailure: nil)
check(AIWorker.failureState(notInstalled) == .runtimeUnavailable,
      "a package with nothing installed is not a launch failure")
check(AIWorker.missingHelperMessage(for: notInstalled, language: .english)
        == AIFailureCopy.runtimeNotInstalled(.english),
      "it offers the download the package makes possible")

let busy = AIFailureEvidence(runtimePackageAvailable: true,
                             runtimeOnDisk: true,
                             runtimeProblem: "busy: another window holds the runtime",
                             launchFailure: nil)
check(AIWorker.missingHelperMessage(for: busy, language: .english)
        == AIFailureCopy.runtimeBusy(.english),
      "the busy text reaches the message a user sees")
check(AIWorker.missingHelperMessage(for: busy, language: .persian)
        == AIFailureCopy.runtimeBusy(.persian),
      "and its Persian text")

// The Intel sentence is a compile-time branch in the app; the message takes the
// architecture explicitly so the branch is exercised on Apple silicon too.
check(AIWorker.missingHelperMessage(for: absent, language: .english,
                                    architecture: .intel)
        == AIFailureCopy.runtimeUnavailableIntel(.english),
      "an Intel build is told the helper is Apple silicon only")
check(AIWorker.missingHelperMessage(for: absent, language: .english,
                                    architecture: .intel)
        != AIFailureCopy.runtimeUnavailable(.english),
      "and not the light-build sentence")
check(AIWorker.missingHelperMessage(for: absent, language: .english,
                                    architecture: .appleSilicon)
        == AIFailureCopy.runtimeUnavailable(.english),
      "Apple silicon keeps the light-build sentence")
let hostArchitecture: AIWorker.BuildArchitecture
#if arch(x86_64)
hostArchitecture = .intel
#else
hostArchitecture = .appleSilicon
#endif
check(AIWorker.BuildArchitecture.host == hostArchitecture,
      "the production default follows the architecture that built this suite")

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

// An independent oracle for a captured evidence value, per language. The old
// check compared against the English table and only proved the message was
// *different* from one wrong sentence: in Persian it passed without looking at
// anything, and any recorded runtime problem made it fail.
func expectedMessage(_ evidence: AIFailureEvidence,
                     _ language: AIFailureCopy.Language) -> String {
    if evidence.runtimePackageAvailable,
       let problem = evidence.runtimeProblem, !problem.isEmpty {
        if problem.hasPrefix("busy:") { return AIFailureCopy.runtimeBusy(language) }
        if problem.hasPrefix("recovery:") { return AIFailureCopy.runtimeRecoveryFailed(language) }
        return AIFailureCopy.runtimeInstallFailed(language)
    }
    if evidence.runtimeOnDisk || evidence.launchFailure != nil {
        return AIFailureCopy.text(for: .workerLaunchFailed, language)
    }
    if evidence.runtimePackageAvailable { return AIFailureCopy.runtimeNotInstalled(language) }
    #if arch(x86_64)
    return AIFailureCopy.runtimeUnavailableIntel(language)
    #else
    return AIFailureCopy.runtimeUnavailable(language)
    #endif
}

let live = AIWorker.helperFailureEvidence
let liveLanguage = AIFailureCopy.Language.current
let liveExpected = expectedMessage(live, liveLanguage)
check(AIFailureState.allCases.map { AIFailureCopy.text(for: $0, liveLanguage) }
            .contains(AIWorker.missingHelperMessage)
        || [AIFailureCopy.runtimeBusy(liveLanguage),
            AIFailureCopy.runtimeRecoveryFailed(liveLanguage),
            AIFailureCopy.runtimeNotInstalled(liveLanguage),
            AIFailureCopy.runtimeUnavailableIntel(liveLanguage)]
            .contains(AIWorker.missingHelperMessage),
      "the live message is one of the taxonomy's own sentences")
check(AIWorker.missingHelperMessage == liveExpected,
      "the live message is the sentence for this machine's evidence",
      "state \(AIWorker.failureState(live).rawValue), language \(liveLanguage)")
check(AIWorker.missingHelperMessage(for: live, language: .english)
        == expectedMessage(live, .english),
      "in English it is the English sentence for the same evidence")
check(AIWorker.missingHelperMessage(for: live, language: .persian)
        == expectedMessage(live, .persian),
      "in Persian it is the Persian sentence for the same evidence")
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
