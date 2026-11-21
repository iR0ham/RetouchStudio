import Darwin
import Foundation
import StudioCore

// The runtime installer used to answer "what is happening" with six flat cases
// and, on cancel, collapsed straight back to `.missing` — the same answer a
// machine that never had a runtime gives. This suite pins the explicit state
// machine (every legal move, every rejected one), the failure classes the card
// must distinguish, and the transaction behaviour behind a cancel during
// `.installing`: the install stops, and the previously installed runtime is
// still the live one.
//
// Everything here is offline. No test opens a URLSession or fetches a package;
// the archive fixtures are local files and the extract hook is a copy.

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

let reducer = AIRuntimeInstallReducer.self

func reduce(_ phase: AIRuntimeInstallPhase,
            _ event: AIRuntimeInstallEvent) -> AIRuntimeInstallPhase? {
    reducer.reduce(current: phase, event: event)
}

// MARK: - The legal chain

print("\n[RI] the phase cycle is explicit and ordered")

let consent = reduce(.notInstalled, .consentRequested)
check(consent == .awaitingConsent,
      "not installed asks for consent first")
let granted = consent.flatMap { reduce($0, .consentGranted(totalBytes: 1_000)) }
check(granted == .downloading(receivedBytes: 0, totalBytes: 1_000),
      "consent starts a download with the declared size")
let halfway = granted.flatMap {
    reduce($0, .downloadProgress(receivedBytes: 400, totalBytes: 1_000))
}
check(halfway == .downloading(receivedBytes: 400, totalBytes: 1_000),
      "progress keeps received and total")
let verifiedDownload = halfway.flatMap { reduce($0, .downloaded) }
check(verifiedDownload == .verifying,
      "a finished transfer moves to verifying")
let verified = verifiedDownload.flatMap { reduce($0, .verified) }
check(verified == .installing,
      "a matching hash moves to installing")
let installed = verified.flatMap { reduce($0, .installed) }
check(installed == .ready,
      "a committed install is ready")

check(reduce(.notInstalled, .consentRequested) == .awaitingConsent
        && reduce(.awaitingConsent, .consentDeclined) == .notInstalled,
      "declining consent returns to not installed, not to a failure")

// MARK: - Progress arithmetic

print("\n[RI] progress cannot invent a size or run backwards")

check(reduce(.downloading(receivedBytes: 10, totalBytes: 100),
             .downloadProgress(receivedBytes: 10, totalBytes: 0))
        == .downloading(receivedBytes: 10, totalBytes: 100),
      "a server that sends no total keeps the declared size")
check(reduce(.downloading(receivedBytes: 0, totalBytes: 100),
             .downloadProgress(receivedBytes: 10, totalBytes: 0))
        == .downloading(receivedBytes: 10, totalBytes: 100),
      "the same holds after the first callback")
check(reduce(.downloading(receivedBytes: 0, totalBytes: 100),
             .downloadProgress(receivedBytes: 200, totalBytes: 100)) == nil,
      "more bytes than the total is rejected")
check(reduce(.downloading(receivedBytes: 0, totalBytes: 100),
             .downloadProgress(receivedBytes: -1, totalBytes: 100)) == nil,
      "a negative count is rejected")
// URLSession reports -1 when the server declares no length; a negative total
// therefore means "unknown" and must not erase the declared size.
check(reduce(.downloading(receivedBytes: 0, totalBytes: 100),
             .downloadProgress(receivedBytes: 5, totalBytes: -100))
        == .downloading(receivedBytes: 5, totalBytes: 100),
      "an unknown (negative) total keeps the declared size")

// MARK: - Cancellation

print("\n[RI] cancel stops work and lands in cancelled")

for busy in [AIRuntimeInstallPhase.downloading(receivedBytes: 5, totalBytes: 10),
             .verifying, .installing] {
    check(reduce(busy, .cancelRequested) == .cancelled,
          "cancel from \(busy) is cancelled")
    check(!(reduce(busy, .cancelRequested) ?? .ready).isBusy,
          "cancel from \(busy) leaves no work running")
}
check(reduce(.cancelled, .retryRequested) == .awaitingConsent,
      "a retry after a cancel asks for consent again")
check(reduce(.cancelled, .installed) == .ready,
      "a commit that beat the cancel is still ready")
check(reduce(.cancelled, .downloadProgress(receivedBytes: 1, totalBytes: 2)) == nil,
      "a late progress callback cannot revive a cancelled download")

// MARK: - Rejected moves

print("\n[RI] illegal moves are refused instead of forced")

let illegal: [(AIRuntimeInstallPhase, AIRuntimeInstallEvent, String)] = [
    (.notInstalled, .downloaded, "not installed cannot skip to verifying"),
    (.notInstalled, .installed, "not installed cannot become ready"),
    (.notInstalled, .verified, "not installed cannot verify"),
    (.notInstalled, .cancelRequested, "there is nothing to cancel yet"),
    (.awaitingConsent, .downloadProgress(receivedBytes: 1, totalBytes: 2),
     "no transfer runs before consent"),
    (.awaitingConsent, .verified, "consent was never granted"),
    (.awaitingConsent, .installed, "consent was never granted to install"),
    (.downloading(receivedBytes: 5, totalBytes: 10), .verified,
     "a download must finish before it can verify"),
    (.downloading(receivedBytes: 5, totalBytes: 10), .installed,
     "a download must be verified and installed"),
    (.verifying, .installed, "verifying must pass first"),
    (.downloading(receivedBytes: 5, totalBytes: 10), .consentGranted(totalBytes: 10),
     "a second consent cannot restart a running download"),
    (.ready, .consentRequested, "ready does not re-open consent"),
    (.ready, .retryRequested, "ready has nothing to retry"),
    (.ready, .cancelRequested, "ready has nothing to cancel"),
    (.awaitingConsent, .retryRequested, "the prompt is already open"),
    (.awaitingConsent, .recoveryFinished(installed: true),
     "startup recovery does not override an open prompt"),
]
for (phase, event, label) in illegal {
    check(reduce(phase, event) == nil, label, "\(phase) + \(event)")
}

// In-place reduction must leave the phase untouched when it refuses.
var guarded = AIRuntimeInstallPhase.downloading(receivedBytes: 5, totalBytes: 10)
let acceptedStale = reducer.reduce(current: guarded, into: &guarded, event: .verified)
check(!acceptedStale && guarded == .downloading(receivedBytes: 5, totalBytes: 10),
      "a refused event does not move the published phase")
var acceptedValid = AIRuntimeInstallPhase.notInstalled
check(reducer.reduce(current: acceptedValid, into: &acceptedValid,
                     event: .consentRequested) && acceptedValid == .awaitingConsent,
      "an accepted event moves the published phase")

// MARK: - Terminal and busy predicates

print("\n[RI] the phase answers the questions the view asks")

check(AIRuntimeInstallPhase.downloading(receivedBytes: 1, totalBytes: 2).isBusy
        && AIRuntimeInstallPhase.verifying.isBusy
        && AIRuntimeInstallPhase.installing.isBusy,
      "the three working phases are busy")
check(!AIRuntimeInstallPhase.notInstalled.isBusy
        && !AIRuntimeInstallPhase.awaitingConsent.isBusy
        && !AIRuntimeInstallPhase.ready.isBusy
        && !AIRuntimeInstallPhase.cancelled.isBusy
        && !AIRuntimeInstallPhase.failed(.init(kind: .network, message: "x")).isBusy,
      "no other phase claims to be busy")
check(AIRuntimeInstallPhase.ready.isTerminal
        && AIRuntimeInstallPhase.cancelled.isTerminal
        && AIRuntimeInstallPhase.failed(.init(kind: .install, message: "x")).isTerminal,
      "ready, cancelled and failed are terminal")
check(AIRuntimeInstallPhase.downloading(receivedBytes: 1, totalBytes: 2).isCancellable
        && AIRuntimeInstallPhase.installing.isCancellable
        && !AIRuntimeInstallPhase.notInstalled.isCancellable
        && !AIRuntimeInstallPhase.ready.isCancellable,
      "only running work is cancellable")

// MARK: - Failure classes

print("\n[RI] failures are classified, not flattened")

let english = L10n.shared
let persian = PersianL10n.table
let cases: [(Error, AIRuntimeInstallFailure.Kind, String)] = [
    (AIRuntimeFailure(code: .checksum), .hashMismatch, "a bad hash is a hash mismatch"),
    (AIRuntimeFailure(code: .extract), .incompatibleRuntime, "a failed extract is incompatible"),
    (AIRuntimeFailure(code: .validation), .incompatibleRuntime, "a rejected runtime is incompatible"),
    (AIRuntimeFailure(code: .install, previous: .kept), .install, "an install failure is install"),
    (AIRuntimeFailure(code: .recovery), .install, "a recovery failure is install"),
    (AIRuntimeFailure(code: .busy), .install, "a busy helper is install"),
    (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .insufficientDisk,
     "a full disk is insufficient disk"),
    (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .network,
     "an offline transfer is network"),
    (NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)), .network,
     "a reset connection is network"),
    (NSError(domain: "test", code: 1), .install, "anything else is install"),
]
for (error, kind, label) in cases {
    let failure = AIRuntimeInstallFailure.classify(error)
    check(failure.kind == kind, label, "\(failure.kind)")
    check(!failure.message.isEmpty, "\(label): has a sentence")
}

let wrappedDisk = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile,
                          userInfo: [NSUnderlyingErrorKey:
                                        NSError(domain: NSPOSIXErrorDomain,
                                                code: Int(ENOSPC))])
check(AIRuntimeInstallFailure.classify(wrappedDisk).kind == .insufficientDisk,
      "a disk-full error wrapped inside a URL error is still disk full")

check(AIRuntimeInstallFailure.classify(AIRuntimeFailure(code: .install, previous: .kept),
                                       l10n: english).message
        == english.aiRuntimeInstallFailed,
      "an install failure that kept the old runtime says so")
check(AIRuntimeInstallFailure.classify(AIRuntimeFailure(code: .install, previous: .lost),
                                       l10n: english).message
        == english.aiRuntimeInstallFailedRollback,
      "a failed rollback says the previous runtime was lost")
check(!AIRuntimeInstallFailure.classify(AIRuntimeFailure(code: .checksum),
                                        l10n: persian).message.isEmpty
        && AIRuntimeInstallFailure.classify(AIRuntimeFailure(code: .checksum),
                                            l10n: persian).message
            != english.aiRuntimeChecksumFailed,
      "the Persian table has its own sentence")

let failedPhase = reduce(.downloading(receivedBytes: 5, totalBytes: 10),
                         .failed(.init(kind: .hashMismatch, message: "bad")))
check(failedPhase == .failed(.init(kind: .hashMismatch, message: "bad")),
      "a download failure lands in failed(kind)")
check(reduce(.verifying, .failed(.init(kind: .install, message: "x"))) != nil
        && reduce(.installing, .failed(.init(kind: .install, message: "x"))) != nil,
      "verify and install failures are accepted too")
check(reduce(.notInstalled, .failed(.init(kind: .install, message: "x"))) != nil,
      "startup recovery can fail before any consent")
check(reduce(.failed(.init(kind: .install, message: "x")),
             .failed(.init(kind: .network, message: "y"))) == nil,
      "a failure does not overwrite itself")
check(reduce(.failed(.init(kind: .install, message: "x")), .retryRequested)
        == .awaitingConsent,
      "a retry after a failure asks for consent again")

// MARK: - The cancellation token

print("\n[RI] the token is the one cancellation signal the transaction reads")

let token = AIRuntimeInstallCancellation()
check(!token.isCancelled, "a fresh token is not cancelled")
token.cancel()
check(token.isCancelled, "cancel is visible to the transaction")
token.cancel()
check(token.isCancelled, "cancelling twice is harmless")

// MARK: - The transaction under cancellation (offline fixtures)

print("\n[RI] cancelling an install leaves the previous runtime live")

let installTestRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-installtests-\(UUID().uuidString)",
                            isDirectory: true)
try? FileManager.default.createDirectory(at: installTestRoot,
                                         withIntermediateDirectories: true)

func installTestSupport(_ label: String) -> URL {
    let url = installTestRoot.appendingPathComponent("\(label)-\(UUID().uuidString)",
                                                     isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func installTestFakeRuntime(at root: URL, marker: String) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root.appendingPathComponent("bin"),
                                withIntermediateDirectories: true)
    let python = root.appendingPathComponent("bin/python3")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let worker = root.appendingPathComponent("retouch_ai_worker", isDirectory: true)
    try manager.createDirectory(at: worker, withIntermediateDirectories: true)
    for name in ["__main__.py", "server.py", "engine.py"] {
        try Data("# fake\n".utf8).write(to: worker.appendingPathComponent(name))
    }
    try manager.createDirectory(at: root.appendingPathComponent("site-packages",
                                                                isDirectory: true),
                                withIntermediateDirectories: true)
    try manager.createDirectory(
        at: root.appendingPathComponent("Python.framework/Versions/3.13",
                                        isDirectory: true),
        withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: root.appendingPathComponent("marker.txt"))
}

func installTestCopy(_ source: URL, into destination: URL) throws {
    let manager = FileManager.default
    for item in try manager.contentsOfDirectory(at: source,
                                                 includingPropertiesForKeys: nil) {
        try manager.copyItem(at: item,
                             to: destination.appendingPathComponent(item.lastPathComponent))
    }
}

func installTestMarker(at root: URL) -> String? {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("marker.txt"))
    else { return nil }
    return String(data: data, encoding: .utf8)
}

func installTestState(in support: URL) -> String? {
    let url = support.appendingPathComponent("runtime-transaction.json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["state"] as? String
}

func installTestHasDirectory(in support: URL, prefix: String) -> Bool {
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: support, includingPropertiesForKeys: nil)) ?? []
    return entries.contains { $0.lastPathComponent.hasPrefix(prefix) }
}

let fixtureOld = installTestRoot.appendingPathComponent("fixture-old", isDirectory: true)
let fixtureNew = installTestRoot.appendingPathComponent("fixture-new", isDirectory: true)
let archiveNew = installTestRoot.appendingPathComponent("archive-new.zip")
do {
    try installTestFakeRuntime(at: fixtureOld, marker: "old")
    try installTestFakeRuntime(at: fixtureNew, marker: "new")
    try Data("archive".utf8).write(to: archiveNew)
} catch {
    check(false, "runtime fixtures written", "\(error)")
}

func installTestInjectLive(_ support: URL) {
    let install = AIRuntime.installDirectory(in: support)
    try? FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try? installTestCopy(fixtureOld, into: install)
}

func installTestHooks(token: AIRuntimeInstallCancellation? = nil,
                      cancelAtExtract: Bool = false,
                      cancelAtCheckpoint: RuntimeInstallCheckpoint? = nil,
                      failingProbes: [String] = []) -> AIRuntime.InstallHooks {
    var hooks = AIRuntime.InstallHooks()
    hooks.extract = { _, staging in
        try installTestCopy(fixtureNew, into: staging)
        if cancelAtExtract { token?.cancel() }
    }
    hooks.validateRuntime = { root in
        // Only the staging copy is probed here: the seeded runtime must stay
        // valid so startup recovery lets the install begin.
        if failingProbes.contains("functional"),
           root.lastPathComponent.contains("-installing-") {
            return RuntimeValidationReport.failure(.functional, "probe", "the runtime did not start")
        }
        let layout = AIRuntimeValidation.structural(root: root)
        guard layout.ok else { return layout }
        return RuntimeValidationReport.success(.functional)
    }
    if let cancelAtCheckpoint {
        hooks.checkpoint = { point in
            if point == cancelAtCheckpoint { token?.cancel() }
        }
    }
    return hooks
}

// A. A token cancelled before the transaction starts changes nothing.
let beforeSupport = installTestSupport("before")
installTestInjectLive(beforeSupport)
let beforeToken = AIRuntimeInstallCancellation()
beforeToken.cancel()
do {
    try AIRuntime.install(archive: archiveNew, support: beforeSupport,
                          hooks: installTestHooks(), cancellation: beforeToken)
    check(false, "A: a pre-cancelled install does not run")
} catch is AIRuntimeInstallCancelled {
    check(true, "A: a pre-cancelled install reports cancellation")
} catch {
    check(false, "A: a pre-cancelled install reports cancellation", "\(error)")
}
check(installTestMarker(at: AIRuntime.installDirectory(in: beforeSupport)) == "old",
      "A: the old runtime is still the live one")
check(!installTestHasDirectory(in: beforeSupport,
                               prefix: AIRuntime.installDirectory(in: beforeSupport)
                                   .lastPathComponent + "-installing-"),
      "A: no staging directory survives")
check(AIRuntime.isStructurallyValid(root: AIRuntime.installDirectory(in: beforeSupport)),
      "A: the live runtime is still valid")

// B. A cancel that arrives during extraction (before any destructive move)
//    abandons the staging tree and keeps the old runtime untouched.
let extractSupport = installTestSupport("extract")
installTestInjectLive(extractSupport)
let extractToken = AIRuntimeInstallCancellation()
do {
    try AIRuntime.install(archive: archiveNew, support: extractSupport,
                          hooks: installTestHooks(token: extractToken, cancelAtExtract: true),
                          cancellation: extractToken)
    check(false, "B: cancelling during extraction stops the install")
} catch is AIRuntimeInstallCancelled {
    check(true, "B: cancelling during extraction is a cancellation, not a failure")
} catch {
    check(false, "B: cancelling during extraction is a cancellation", "\(error)")
}
check(installTestMarker(at: AIRuntime.installDirectory(in: extractSupport)) == "old",
      "B: the old runtime was never moved")
check(!installTestHasDirectory(in: extractSupport,
                               prefix: AIRuntime.installDirectory(in: extractSupport)
                                   .lastPathComponent + "-installing-"),
      "B: extraction staging is removed")
// The live runtime was seeded without a marker; recovery adopts it and writes
// a committed record before the install starts. Abandoning preparation must
// restore that record, not leave the aborted attempt's `preparing` behind.
check(installTestState(in: extractSupport) == "committed",
      "B: the record says the old runtime is committed",
      installTestState(in: extractSupport) ?? "none")
check(AIRuntime.isStructurallyValid(root: AIRuntime.installDirectory(in: extractSupport)),
      "B: the live runtime is still valid")

// C. The fixed defect: cancel after the new runtime is already live. The
//    backup must become live again before the cancel is reported.
for point in [RuntimeInstallCheckpoint.afterLiveMove, .beforeCommit] {
    let swapSupport = installTestSupport("swap-\(point.rawValue)")
    installTestInjectLive(swapSupport)
    let swapToken = AIRuntimeInstallCancellation()
    do {
        try AIRuntime.install(archive: archiveNew, support: swapSupport,
                              hooks: installTestHooks(token: swapToken,
                                                      cancelAtCheckpoint: point),
                              cancellation: swapToken)
        check(false, "C(\(point.rawValue)): cancel during the swap stops the install")
    } catch is AIRuntimeInstallCancelled {
        check(true, "C(\(point.rawValue)): cancel during the swap is a cancellation")
    } catch {
        check(false, "C(\(point.rawValue)): cancel during the swap is a cancellation",
              "\(error)")
    }
    let live = AIRuntime.installDirectory(in: swapSupport)
    check(installTestMarker(at: live) == "old",
          "C(\(point.rawValue)): the previous runtime is live again")
    check(AIRuntime.isStructurallyValid(root: live),
          "C(\(point.rawValue)): the previous runtime is still valid")
    check(!installTestHasDirectory(in: swapSupport,
                                   prefix: live.lastPathComponent + "-installing-"),
          "C(\(point.rawValue)): no staging remains")
    check(!FileManager.default.fileExists(
            atPath: AIRuntime.backupDirectory(in: swapSupport).path),
          "C(\(point.rawValue)): no backup remains")
    check(installTestState(in: swapSupport) == "committed",
          "C(\(point.rawValue)): the record says the old runtime is committed")
}

// D. A deliberate hash mismatch is refused before extraction and classified.
let mismatchSupport = installTestSupport("mismatch")
installTestInjectLive(mismatchSupport)
let archiveBytes = (try? Data(contentsOf: archiveNew).count) ?? 0
let badPackage = AIRuntime.Package(version: "test", fileName: "runtime.zip",
                                   url: URL(fileURLWithPath: "/nonexistent"),
                                   bytes: Int64(archiveBytes),
                                   sha256: String(repeating: "0", count: 64))
var mismatchError: Error?
do {
    try AIRuntime.install(archive: archiveNew, support: mismatchSupport,
                          package: badPackage, hooks: installTestHooks())
} catch {
    mismatchError = error
}
if let failure = mismatchError as? AIRuntimeFailure {
    check(failure.code == .checksum, "D: a bad hash is refused as a checksum failure")
    check(AIRuntimeInstallFailure.classify(failure).kind == .hashMismatch,
          "D: the checksum failure is the hash-mismatch class")
} else {
    check(false, "D: a bad hash is refused", "\(String(describing: mismatchError))")
}
check(installTestMarker(at: AIRuntime.installDirectory(in: mismatchSupport)) == "old",
      "D: a refused archive leaves the old runtime live")
check(!installTestHasDirectory(in: mismatchSupport,
                               prefix: AIRuntime.installDirectory(in: mismatchSupport)
                                   .lastPathComponent + "-installing-"),
      "D: nothing is staged for a refused archive")

// E. A failing final move rolls back and classifies as an install failure.
let moveSupport = installTestSupport("move")
installTestInjectLive(moveSupport)
var moveHooks = installTestHooks()
moveHooks.move = { source, destination in
    if source.lastPathComponent.contains("-installing-") {
        throw NSError(domain: "test", code: 1)
    }
    try FileManager.default.moveItem(at: source, to: destination)
}
var moveError: Error?
do {
    try AIRuntime.install(archive: archiveNew, support: moveSupport, hooks: moveHooks)
} catch {
    moveError = error
}
if let failure = moveError as? AIRuntimeFailure {
    check(failure.code == .install, "E: a failing staging move is an install failure")
    check(failure.previous == .kept, "E: the old runtime was kept by the rollback")
    check(AIRuntimeInstallFailure.classify(failure).kind == .install,
          "E: it classifies as the install kind")
} else {
    check(false, "E: a failing staging move is an install failure",
          "\(String(describing: moveError))")
}
check(installTestMarker(at: AIRuntime.installDirectory(in: moveSupport)) == "old",
      "E: the old runtime is live again")

// F. A runtime that fails the functional probe is refused as incompatible.
let probeSupport = installTestSupport("probe")
installTestInjectLive(probeSupport)
var probeError: Error?
do {
    try AIRuntime.install(archive: archiveNew, support: probeSupport,
                          hooks: installTestHooks(failingProbes: ["functional"]))
} catch {
    probeError = error
}
if let failure = probeError as? AIRuntimeFailure {
    check(failure.code == .validation, "F: a runtime that does not start is a validation failure")
    check(AIRuntimeInstallFailure.classify(failure).kind == .incompatibleRuntime,
          "F: it classifies as incompatible")
} else {
    check(false, "F: a runtime that does not start is refused",
          "\(String(describing: probeError))")
}
check(installTestMarker(at: AIRuntime.installDirectory(in: probeSupport)) == "old",
      "F: the old runtime is untouched")
check(!installTestHasDirectory(in: probeSupport,
                               prefix: AIRuntime.installDirectory(in: probeSupport)
                                   .lastPathComponent + "-installing-"),
      "F: the rejected staging tree is removed")

// H. An unpack failure re-probes the destination through the install hooks.
//     A 0 answer names the disk; a probe that cannot answer keeps the
//     unpacker's own error, so an unreadable volume is never guessed full.
let lowDiskSupport = installTestSupport("unpack-lowdisk")
installTestInjectLive(lowDiskSupport)
var lowDiskHooks = installTestHooks()
lowDiskHooks.extract = { _, _ in throw NSError(domain: "test", code: 7) }
var lowDiskProbed: [URL] = []
lowDiskHooks.probeCapacity = { url in
    lowDiskProbed.append(url)
    return 0
}
var lowDiskError: Error?
do {
    try AIRuntime.install(archive: archiveNew, support: lowDiskSupport,
                          hooks: lowDiskHooks)
} catch {
    lowDiskError = error
}
if let failure = lowDiskError as? AIRuntimeFailure {
    check(failure.code == .extract, "H: the failed unpack is still an extract failure",
          "\(failure.code)")
    check(AIRuntimeInstallFailure.classify(failure).kind == .insufficientDisk,
          "H: a 0 from the re-probe says the disk filled, not the archive")
    check((failure.underlying as? AIRuntimeLowDiskSpace)?.freeBytes == 0,
          "H: and the low-disk wrapper keeps the probe's numbers")
} else {
    check(false, "H: the failed unpack reports an AIRuntimeFailure",
          "\(String(describing: lowDiskError))")
}
check(lowDiskProbed.contains {
        $0.lastPathComponent.contains("-installing-")
      },
      "H: the re-probe asked about the staging destination")
check(installTestMarker(at: AIRuntime.installDirectory(in: lowDiskSupport)) == "old",
      "H: the old runtime is untouched")

let unknownSupport = installTestSupport("unpack-unknown")
installTestInjectLive(unknownSupport)
var unknownHooks = installTestHooks()
unknownHooks.extract = { _, _ in throw NSError(domain: "test", code: 7) }
unknownHooks.probeCapacity = { _ in nil }
var unknownError: Error?
do {
    try AIRuntime.install(archive: archiveNew, support: unknownSupport,
                          hooks: unknownHooks)
} catch {
    unknownError = error
}
if let failure = unknownError as? AIRuntimeFailure {
    check(failure.code == .extract, "H: with no capacity answer the unpack stays an extract failure")
    check(AIRuntimeInstallFailure.classify(failure).kind == .incompatibleRuntime,
          "H: an unreadable re-probe never invents an insufficient-disk verdict")
    check(!(failure.underlying is AIRuntimeLowDiskSpace),
          "H: and attaches no low-disk wrapper")
} else {
    check(false, "H: an unreadable re-probe still reports the unpack failure",
          "\(String(describing: unknownError))")
}

// G. The whole cancellation cycle as the installer would drive it: a cancel
//    during installing is `.cancelled`, and a retry goes back through consent.
var cycle = AIRuntimeInstallPhase.notInstalled
_ = reducer.reduce(current: cycle, into: &cycle, event: .consentRequested)
_ = reducer.reduce(current: cycle, into: &cycle, event: .consentGranted(totalBytes: 1_000))
_ = reducer.reduce(current: cycle, into: &cycle,
                   event: .downloadProgress(receivedBytes: 1_000, totalBytes: 1_000))
_ = reducer.reduce(current: cycle, into: &cycle, event: .downloaded)
_ = reducer.reduce(current: cycle, into: &cycle, event: .verified)
let duringInstall = cycle
_ = reducer.reduce(current: cycle, into: &cycle, event: .cancelRequested)
check(cycle == .cancelled && duringInstall == .installing,
      "G: a cancel during installing publishes cancelled, not missing")
check(cycle.isTerminal && !cycle.isBusy, "G: cancelled is a settled answer")
_ = reducer.reduce(current: cycle, into: &cycle, event: .retryRequested)
check(cycle == .awaitingConsent, "G: retry asks for consent again")

// I. The runtime archive arrives as a download, so the file carries
//    `com.apple.quarantine`; ditto copies that flag onto every file it writes,
//    and AMFI then kills the ad-hoc-signed interpreter the runtime ships. The
//    production extractor must not carry the flag across. The fixture is a real
//    archive holding a real compiled executable, the unpack goes through
//    InstallHooks' default closure (the production path, `AIRuntime.extract`),
//    and the extracted binary is executed. The control run shows the same
//    archive leaking the flag when ditto is called without `--noqtn`, so the
//    assertion fails if the flag ever leaves the arguments.
print("\n[RI] a downloaded archive's quarantine never reaches the runtime")

let quarantineAttribute = "com.apple.quarantine"

func installTestQuarantine(_ path: String) -> String? {
    var size = getxattr(path, quarantineAttribute, nil, 0, 0, 0)
    guard size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    size = getxattr(path, quarantineAttribute, &buffer, size, 0, 0)
    guard size > 0 else { return nil }
    return String(decoding: buffer.prefix(size), as: UTF8.self)
}

/// Every path under `root` that carries the quarantine flag, relative to it.
func installTestQuarantinedPaths(_ root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil) else { return [] }
    var found: [String] = []
    for case let url as URL in enumerator where installTestQuarantine(url.path) != nil {
        found.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
    }
    return found
}

func installTestPaths(_ root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil) else { return [] }
    var found: [String] = []
    for case let url as URL in enumerator {
        found.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
    }
    return found
}

/// Runs a real subprocess and answers (exit status, stdout, timed out). stderr
/// is a pipe of its own so a diagnostic cannot block the child on a full
/// buffer, and the child is killed at the deadline: a quarantined binary waits
/// for a Gatekeeper decision that never comes on a headless run, and a suite
/// must report that instead of hanging.
func installTestRun(_ executable: URL, arguments: [String] = [],
                    timeout: TimeInterval = 20) -> (Int32, String, Bool)? {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        usleep(20_000)
    }
    var timedOut = false
    if process.isRunning {
        timedOut = true
        process.terminate()
        usleep(200_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self), timedOut)
}

let quarantineRoot = installTestSupport("quarantine")
do {
    let source = quarantineRoot.appendingPathComponent("payload", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let cSource = source.appendingPathComponent("main.c")
    try Data("#include <stdio.h>\nint main(void) { printf(\"RUNS\\n\"); return 0; }\n".utf8)
        .write(to: cSource)
    let built = source.appendingPathComponent("probe")
    let compile = installTestRun(URL(fileURLWithPath: "/usr/bin/cc"),
                                 arguments: ["-O0", "-o", built.path, cSource.path])
    check(compile?.0 == 0, "the fixture executable compiles",
          compile.map { "cc exited \($0.0)" } ?? "cc did not start")

    let archive = quarantineRoot.appendingPathComponent("runtime.zip")
    let packed = installTestRun(URL(fileURLWithPath: "/usr/bin/ditto"),
                                arguments: ["-c", "-k", source.path, archive.path])
    check(packed?.0 == 0, "the fixture archive is written like a downloaded runtime")
    let marked = installTestRun(URL(fileURLWithPath: "/usr/bin/xattr"),
                                arguments: ["-w", quarantineAttribute,
                                            "0081;00000000;Test;1", archive.path])
    check(marked?.0 == 0 && installTestQuarantine(archive.path) != nil,
          "the archive carries com.apple.quarantine before extraction",
          installTestQuarantine(archive.path) ?? "absent")

    // Control: the unmodified ditto call is what the defect looked like. It
    // must leak the flag, otherwise the check below proves nothing.
    let control = quarantineRoot.appendingPathComponent("control", isDirectory: true)
    try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
    let plain = installTestRun(URL(fileURLWithPath: "/usr/bin/ditto"),
                               arguments: ["-x", "-k", archive.path, control.path])
    let controlAll = installTestPaths(control)
    let leaked = installTestQuarantinedPaths(control)
    check(plain?.0 == 0 && !leaked.isEmpty,
          "control: bare `ditto -x -k` copies the flag onto every extracted file",
          "\(leaked.count) of \(controlAll.count) paths")

    // The production path: the default hook is the closure the transaction and
    // the installer both use.
    let staging = quarantineRoot.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    var extractError: Error?
    do {
        try AIRuntime.InstallHooks().extract(archive, staging)
    } catch {
        extractError = error
    }
    check(extractError == nil, "the production extractor unpacks the quarantined archive",
          extractError.map { "\($0)" } ?? "")
    let extracted = installTestPaths(staging)
    let carried = installTestQuarantinedPaths(staging)
    check(!extracted.isEmpty && carried.isEmpty,
          "no extracted file carries com.apple.quarantine",
          "\(carried.count) of \(extracted.count) paths")

    let probe = staging.appendingPathComponent("probe")
    let launched = installTestRun(probe)
    check(launched.map { $0.0 == 0 && !$0.2 && $0.1 == "RUNS\n" } ?? false,
          "the extracted executable runs",
          launched.map { $0.2 ? "killed after 20 s without finishing"
                              : "exit \($0.0), stdout \($0.1.trimmingCharacters(in: .newlines))" }
              ?? "the process did not start")
} catch {
    check(false, "the quarantine fixture is written", "\(error)")
}

try? FileManager.default.removeItem(at: installTestRoot)

print("")
if failures.isEmpty {
    print("RUNTIME INSTALL TESTS: PASS (\(checks) checks)")
    exit(0)
} else {
    print("RUNTIME INSTALL TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
