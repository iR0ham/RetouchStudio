import Darwin
import Foundation
import StudioCore

// Download resume and the disk-space preflight, offline.
//
// The installer is driven through its injectable environment: the transfer is a
// scripted engine that writes local bytes (no URLSession, no network), the
// capacity probe is a closure, and the install hooks copy a local runtime
// fixture. Nothing here touches the real support directory or fetches a
// package.
//
// The assertions cover the four promises of the slice: a cancel retains resume
// data *and* its partial, a retry continues the same archive and still verifies
// it by SHA-256, unusable retained state falls back to a clean restart, and a
// preflight refusal never enters `.downloading`.

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

func transferRun(_ body: @MainActor () -> Void) {
    MainActor.assumeIsolated { body() }
}

/// Main-actor tasks (the installer hops to the main actor) are serviced by the
/// main run loop, so the suite pumps it until the phase settles.
@MainActor
func pump(seconds: Double = 20, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

// MARK: - Offline fixtures

let transferRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-transfertests-\(UUID().uuidString)",
                            isDirectory: true)
try? FileManager.default.createDirectory(at: transferRoot,
                                         withIntermediateDirectories: true)

func transferSupport(_ label: String) -> URL {
    let url = transferRoot.appendingPathComponent("\(label)-\(UUID().uuidString)",
                                                  isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func transferFakeRuntime(at root: URL, marker: String) throws {
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

func transferCopy(_ source: URL, into destination: URL) throws {
    let manager = FileManager.default
    for item in try manager.contentsOfDirectory(at: source,
                                                 includingPropertiesForKeys: nil) {
        try manager.copyItem(at: item,
                             to: destination.appendingPathComponent(item.lastPathComponent))
    }
}

func transferMarker(at root: URL) -> String? {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("marker.txt"))
    else { return nil }
    return String(data: data, encoding: .utf8)
}

func transferHasDirectory(in support: URL, prefix: String) -> Bool {
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: support, includingPropertiesForKeys: nil)) ?? []
    return entries.contains { $0.lastPathComponent.hasPrefix(prefix) }
}

func transferSeedLive(_ support: URL, marker: String = "old") {
    let live = AIRuntime.installDirectory(in: support)
    try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    try? transferCopy(fixtureOld, into: live)
}

// The "archive" the scripted engine delivers. Its only role is to have a real
// size and SHA-256; the extract hook copies a fixture and never opens it.
let goodArchiveBytes = Data("local protocol-v2 archive fixture".utf8)
let goodArchiveURL = transferRoot.appendingPathComponent("good-archive.zip")
try? goodArchiveBytes.write(to: goodArchiveURL)
let goodSHA256 = (try? AIRuntime.sha256(of: goodArchiveURL)) ?? ""

let goodPackage = AIRuntime.Package(version: "test",
                                    fileName: "runtime-test.zip",
                                    url: URL(fileURLWithPath: "/nonexistent-runtime.zip"),
                                    bytes: Int64(goodArchiveBytes.count),
                                    sha256: goodSHA256)

let differentPackage = AIRuntime.Package(version: "test-2",
                                         fileName: "runtime-test.zip",
                                         url: URL(fileURLWithPath: "/nonexistent-runtime.zip"),
                                         bytes: Int64(goodArchiveBytes.count),
                                         sha256: String(repeating: "a", count: 64))

let fixtureOld = transferRoot.appendingPathComponent("fixture-old", isDirectory: true)
let fixtureNew = transferRoot.appendingPathComponent("fixture-new", isDirectory: true)
do {
    try transferFakeRuntime(at: fixtureOld, marker: "old")
    try transferFakeRuntime(at: fixtureNew, marker: "new")
} catch {
    check(false, "runtime fixtures written", "\(error)")
}

func transferHooks() -> AIRuntime.InstallHooks {
    var hooks = AIRuntime.InstallHooks()
    hooks.extract = { _, staging in
        try transferCopy(fixtureNew, into: staging)
    }
    hooks.validateRuntime = { root in
        let layout = AIRuntimeValidation.structural(root: root)
        guard layout.ok else { return layout }
        return RuntimeValidationReport.success(.functional)
    }
    return hooks
}

/// A transfer that is scripted by the test. `.hold` waits for the test to
/// report progress, succeed or fail; the other outcomes finish inside `start`.
final class ScriptedTransfer: AIRuntimeTransferEngine {
    enum Outcome {
        case hold
        case succeed(Data)
        case fail(Error)
    }

    var outcome: Outcome = .hold
    var onStart: ((AIRuntimeTransferResume?) -> Void)?
    var onCancel: (((Data?, URL?) -> Void) -> Void)?
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var finishHandler: ((Result<URL, Error>) -> Void)?

    private(set) var starts: [AIRuntimeTransferResume?] = []
    private(set) var cancelled = false

    func start(package: AIRuntime.Package,
               resume: AIRuntimeTransferResume?,
               onProgress: @escaping (Int64, Int64) -> Void,
               onFinish: @escaping (Result<URL, Error>) -> Void) {
        starts.append(resume)
        progressHandler = onProgress
        finishHandler = onFinish
        onStart?(resume)
        switch outcome {
        case .hold:
            break
        case .succeed(let data):
            report(Int64(data.count), package.bytes)
            succeed(data)
        case .fail(let error):
            fail(error)
        }
    }

    func report(_ written: Int64, _ total: Int64) {
        progressHandler?(written, total)
    }

    func succeed(_ data: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-\(UUID().uuidString).zip")
        try? data.write(to: url)
        finishHandler?(.success(url))
    }

    func fail(_ error: Error) {
        finishHandler?(.failure(error))
    }

    func cancel(producingResumeData: @escaping (Data?, URL?) -> Void) {
        cancelled = true
        if let onCancel {
            onCancel(producingResumeData)
        } else {
            producingResumeData(nil, nil)
        }
    }
}

@MainActor
func transferEnvironment(support: URL,
                         engine: ScriptedTransfer?,
                         capacity: @escaping (URL) -> Int64? = { _ in Int64.max },
                         hooks: AIRuntime.InstallHooks? = nil)
    -> AIRuntimeInstaller.Environment {
    var environment = AIRuntimeInstaller.Environment()
    environment.support = support
    environment.startsRecovered = false
    environment.availableCapacity = capacity
    environment.makeEngine = { engine ?? ScriptedTransfer() }
    environment.makeHooks = { _ in hooks ?? transferHooks() }
    environment.runtimeChanged = {}
    environment.runtimeValidated = {}
    return environment
}

func transferPartialSource(_ bytes: Data) -> URL {
    let url = transferRoot.appendingPathComponent("partial-\(UUID().uuidString).zip")
    try? bytes.write(to: url)
    return url
}

// MARK: - The preflight formula

print("\n[RT] the preflight charges the download, the unpacked tree and a margin")

let documentedDownload: Int64 = 390_000_000          // Docs/RELEASING.md:186
let documentedUnpacked: Int64 = 1_300_000_000        // "about 1.3 GB unpacked"
let headroom: Int64 = AIRuntimeDiskPreflight.bookkeepingHeadroomBytes

let documentedRequired = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: documentedDownload)
let documentedUnpackedShare = documentedRequired - documentedDownload - headroom
check(documentedUnpackedShare >= documentedUnpacked,
      "a ~390 MB archive reserves at least the documented ~1.3 GB unpacked",
      "\(documentedUnpackedShare) bytes")
check(documentedUnpackedShare <= documentedDownload * 4,
      "and the estimate is not padded beyond the evidence")
check(AIRuntimeDiskPreflight.requiredBytes(archiveBytes: 0) == 0,
      "no archive needs no space")
check(AIRuntimeDiskPreflight.requiredBytes(archiveBytes: 1_000) == 1_000 + 3_500 + headroom,
      "the formula is archive + 3.5× archive + 64 MiB")
check(AIRuntimeDiskPreflight.requiredBytes(archiveBytes: 3) == 3 + 10 + headroom,
      "odd byte counts round inside the estimate instead of overflowing it")
check(headroom >= Int64(64 << 20),
      "the transaction records and staging get an explicit margin",
      "\(headroom) bytes")

// The real probe reads the volume that holds the destination; it must not
// invent a number when the system will not answer.
let probeDirectory = transferSupport("probe")
if let realCapacity = AIRuntimeDiskPreflight.availableCapacity(at: probeDirectory) {
    check(realCapacity > 0, "the destination volume answers with its capacity",
          "\(realCapacity) bytes")
} else {
    check(true, "the destination volume may decline to answer; nil means proceed")
}

// A support directory that has not been created yet is measured on the volume
// of its nearest existing parent, which is the same volume the transfer writes.
let missingDestination = transferRoot
    .appendingPathComponent("not-yet-\(UUID().uuidString)/deeper", isDirectory: true)
let ancestorCapacity = AIRuntimeDiskPreflight.availableCapacity(at: missingDestination)
check(ancestorCapacity != nil && (ancestorCapacity ?? 0) > 0,
      "a destination that does not exist yet is measured on its parent volume",
      String(describing: ancestorCapacity))

// MARK: - Retained state

print("\n[RT] resume state is keyed to the exact archive and deleted on doubt")

transferRun {
    let support = transferSupport("store")
    let store = AIRuntimeResumeStore(support: support)
    let partial = transferPartialSource(Data(goodArchiveBytes.prefix(5)))

    check(store.directory.lastPathComponent == "protocol-v2-download",
          "the store lives in one fixed directory beside the runtime")
    check(store.directory.deletingLastPathComponent().standardizedFileURL
            == support.standardizedFileURL,
          "which is inside the injected support directory")

    check(store.save(resumeData: Data("resume-token".utf8), partial: partial,
                     package: goodPackage),
          "a complete pair is retained")
    let loaded = store.load(for: goodPackage)
    check(loaded?.data == Data("resume-token".utf8),
          "the same identity gets the resume data back")
    check(loaded?.partial?.standardizedFileURL
            == store.partialURL.standardizedFileURL,
          "and the partial file the data refers to")
    check(AIRuntimeResumeStore.size(of: store.partialURL) == 5,
          "the partial is copied, not referenced from a temporary location")

    check(store.load(for: differentPackage) == nil,
          "a different SHA-256 never resumes the retained transfer")
    check(!FileManager.default.fileExists(atPath: store.directory.path),
          "and the mismatched state is deleted, not left to rot")

    _ = store.save(resumeData: Data("resume-token".utf8), partial: partial,
                   package: goodPackage)
    try? FileManager.default.removeItem(at: store.partialURL)
    check(store.load(for: goodPackage) == nil,
          "resume data without its partial is refused")

    let oversized = transferPartialSource(goodArchiveBytes + Data([0, 1, 2]))
    _ = store.save(resumeData: Data("resume-token".utf8), partial: oversized,
                   package: goodPackage)
    check(store.load(for: goodPackage) == nil,
          "a partial larger than the approved archive is refused")

    _ = store.save(resumeData: Data(), partial: partial, package: goodPackage)
    check(store.load(for: goodPackage) == nil,
          "empty resume data is not resumable")

    _ = store.save(resumeData: Data("resume-token".utf8), partial: partial,
                   package: goodPackage)
    try? Data("{".utf8).write(to: store.directory
        .appendingPathComponent("identity.json"))
    check(store.load(for: goodPackage) == nil,
          "an unreadable identity is treated as no resume state")

    check(!store.save(resumeData: Data("resume-token".utf8), partial: nil,
                      package: goodPackage),
          "a save without a partial reports failure")
    check(!FileManager.default.fileExists(atPath: store.directory.path),
          "and leaves nothing behind")

    store.clear()
    check(!FileManager.default.fileExists(atPath: store.directory.path),
          "clear removes the whole directory")
}

// MARK: - Consent and the preflight

print("\n[RT] the preflight refuses before any transfer starts")

transferRun {
    let support = transferSupport("refuse")
    let engine = ScriptedTransfer()
    let needed = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: goodPackage.bytes)
    var capacity: Int64? = needed / 2
    var probed: URL?
    var environment = transferEnvironment(support: support, engine: engine)
    environment.availableCapacity = { url in
        probed = url
        return capacity
    }
    let installer = AIRuntimeInstaller(environment: environment)
    check(installer.phase == .notInstalled, "a clean support directory starts not installed")

    _ = installer.requestConsent()
    installer.install(goodPackage)

    var refusal: AIRuntimeInstallFailure?
    if case .failed(let failure) = installer.phase { refusal = failure }
    check(refusal?.kind == .insufficientDisk,
          "a nearly full disk reports insufficient disk",
          String(describing: installer.phase))
    check(engine.starts.isEmpty,
          "the transfer never started, so nothing was fetched")
    check(probed?.standardizedFileURL == support.standardizedFileURL,
          "the check measured the destination volume")
    check(refusal?.message
            == L10n.shared.aiRuntimeInsufficientDisk(neededBytes: needed,
                                                     freeBytes: needed / 2),
          "the message is the localized one for this shortfall")
    check(refusal?.message.contains("Nothing was installed") ?? false,
          "it says nothing was installed")

    // The same probe with enough room lets the same install proceed.
    capacity = needed
    check(installer.requestConsent(), "a retry after the refusal asks for consent"
            + " again")
    engine.outcome = .succeed(goodArchiveBytes)
    installer.install(goodPackage)
    check(engine.starts.count == 1, "an allowed install starts the transfer")
    let ready = pump { if case .ready = installer.phase { return true }
                       return false }
    check(ready, "and completes", String(describing: installer.phase))
    check(!FileManager.default.fileExists(
            atPath: AIRuntimeResumeStore(support: support).directory.path),
          "no resume directory is created by a clean install")
}

transferRun {
    // Exactly the required amount passes (the comparison is "at least").
    let support = transferSupport("exact")
    transferSeedLive(support)
    let engine = ScriptedTransfer()
    engine.outcome = .succeed(goodArchiveBytes)
    let needed = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: goodPackage.bytes)
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine,
                                         capacity: { _ in needed }))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    check(engine.starts.count == 1, "exactly the required space is enough")
    _ = pump { if case .ready = installer.phase { return true }; return false }
    check(transferMarker(at: AIRuntime.installDirectory(in: support)) == "new",
          "and the install completes")
}

transferRun {
    // An unreadable capacity must not block an install on a guess.
    let support = transferSupport("unknown-capacity")
    transferSeedLive(support)
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine,
                                         capacity: { _ in nil }))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    check(engine.starts.count == 1,
          "an unreadable capacity lets the transfer report a real failure")
    check(installer.phase.isDownloading, "the install is downloading")
    installer.cancel()
    check(installer.phase == .cancelled, "and can still be cancelled")
}

// MARK: - Cancel retains the pair, retry continues it

print("\n[RT] a cancel keeps both resume data and the partial; a retry continues")

transferRun {
    let support = transferSupport("cancel-resume")
    transferSeedLive(support)
    let engine = ScriptedTransfer()
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine))
    let store = AIRuntimeResumeStore(support: support)
    let live = AIRuntime.installDirectory(in: support)

    _ = installer.requestConsent()
    installer.install(goodPackage)
    check(engine.starts.count == 1 && engine.starts[0] == nil,
          "a first attempt starts with no resume state")

    engine.report(10, goodPackage.bytes)
    _ = pump { installer.received == 10 }
    check(installer.received == 10, "progress is published while downloading")

    engine.onCancel = { deliver in
        let partial = transferPartialSource(Data(goodArchiveBytes.prefix(10)))
        deliver(Data("resume-token".utf8), partial)
    }
    installer.cancel()
    check(installer.phase == .cancelled, "cancel publishes cancelled")
    check(engine.cancelled, "the engine is asked for resume data, not abandoned")
    check(FileManager.default.fileExists(atPath: store.partialURL.path),
          "the partial is retained")
    check(AIRuntimeResumeStore.size(of: store.partialURL) == 10,
          "with the bytes already written")
    check(store.load(for: goodPackage)?.data == Data("resume-token".utf8),
          "and the resume data is keyed to this archive")
    check(transferMarker(at: live) == "old", "the previous runtime is still live")
    check(!AIRuntime.isStructurallyInstalled,
          "an incomplete transfer is never recognised as active")

    // Retry: the retained pair must be offered to the engine, and the finished
    // file must still pass SHA-256 before anything is installed.
    engine.outcome = .hold
    engine.onStart = { resume in
        check(resume != nil, "the retry offers the retained resume data")
        check(resume?.partial?.lastPathComponent == "partial.zip",
              "together with the retained partial")
        engine.report(goodPackage.bytes, goodPackage.bytes)
    }
    check(installer.requestConsent(), "the retry asks for consent")
    installer.install(goodPackage)
    check(engine.starts.count == 2, "a second transfer starts")
    check(engine.starts[1] != nil, "and it is the retained one, not a restart")

    engine.succeed(goodArchiveBytes)
    let ready = pump { if case .ready = installer.phase { return true }
                       return false }
    check(ready, "a resumed transfer that verifies becomes ready",
          String(describing: installer.phase))
    check(installer.total == goodPackage.bytes && installer.received == installer.total,
          "the published total is the approved size")
    check(transferMarker(at: live) == "new", "the resumed archive installed")
    check(!FileManager.default.fileExists(atPath: store.directory.path),
          "a completed install deletes the resume directory")
    check(!transferHasDirectory(in: support,
                                prefix: live.lastPathComponent + "-installing-"),
          "and leaves no staging directory behind")
}

// MARK: - Unusable retained state

print("\n[RT] unusable retained state restarts cleanly instead of half-verifying")

transferRun {
    let support = transferSupport("mismatch-identity")
    transferSeedLive(support)
    let store = AIRuntimeResumeStore(support: support)
    _ = store.save(resumeData: Data("resume-token".utf8),
                   partial: transferPartialSource(Data(goodArchiveBytes.prefix(5))),
                   package: differentPackage)

    let engine = ScriptedTransfer()
    engine.outcome = .hold
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    check(engine.starts.count == 1 && engine.starts[0] == nil,
          "a stored identity for another archive is not offered")
    check(!FileManager.default.fileExists(atPath: store.directory.path),
          "and is deleted before the transfer starts")
    installer.cancel()
}

transferRun {
    // A stored transfer the connection refuses (no bytes moved past the
    // partial) is discarded and restarted once, never reported as the attempt.
    let support = transferSupport("unusable-resume")
    transferSeedLive(support)
    let store = AIRuntimeResumeStore(support: support)
    _ = store.save(resumeData: Data("resume-token".utf8),
                   partial: transferPartialSource(Data(goodArchiveBytes.prefix(5))),
                   package: goodPackage)

    let engine = ScriptedTransfer()
    engine.outcome = .hold
    engine.onStart = { resume in
        if resume != nil {
            engine.fail(URLError(.cannotDecodeContentData))
        }
    }
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    let restarted = pump { engine.starts.count == 2 }
    check(restarted, "an unusable resumed transfer restarts once")
    check(engine.starts.count == 2 && engine.starts[1] == nil,
          "and the restart is clean")
    check(installer.phase.isDownloading,
          "the fallback stays in downloading instead of surfacing a failure",
          String(describing: installer.phase))

    engine.outcome = .hold
    engine.succeed(goodArchiveBytes)
    let ready = pump { if case .ready = installer.phase { return true }
                       return false }
    check(ready, "the clean restart completes",
          String(describing: installer.phase))
    check(transferMarker(at: AIRuntime.installDirectory(in: support)) == "new",
          "with the approved archive")
    check(!FileManager.default.fileExists(atPath: store.directory.path),
          "and no resume state survives")
}

transferRun {
    // A resumed transfer that does move bytes and then loses the connection is
    // a network failure; its partial is kept for the owner's next retry.
    let support = transferSupport("progress-then-fail")
    transferSeedLive(support)
    let store = AIRuntimeResumeStore(support: support)
    _ = store.save(resumeData: Data("resume-token".utf8),
                   partial: transferPartialSource(Data(goodArchiveBytes.prefix(5))),
                   package: goodPackage)

    let engine = ScriptedTransfer()
    engine.outcome = .hold
    engine.onStart = { resume in
        if resume != nil {
            engine.report(20, goodPackage.bytes)
            engine.fail(URLError(.timedOut))
        }
    }
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    let failed = pump { if case .failed = installer.phase { return true }
                        return false }
    check(failed, "a connection loss after progress is a failure")

    var failure: AIRuntimeInstallFailure?
    if case .failed(let value) = installer.phase { failure = value }
    check(failure?.kind == .network, "classified as a network problem",
          String(describing: failure?.kind))
    check(engine.starts.count == 1, "it is not silently retried")
    check(FileManager.default.fileExists(atPath: store.partialURL.path),
          "the partial is kept for the next attempt")
    check(transferMarker(at: AIRuntime.installDirectory(in: support)) == "old",
          "the previous runtime is still live")
    check(!transferHasDirectory(in: support, prefix: "protocol-v2-installing-"),
          "nothing was staged")
}

// MARK: - A resumed file that fails the hash

print("\n[RT] a resumed file that fails SHA-256 is refused, not activated")

transferRun {
    let support = transferSupport("resumed-hash")
    transferSeedLive(support)
    let live = AIRuntime.installDirectory(in: support)
    let store = AIRuntimeResumeStore(support: support)
    _ = store.save(resumeData: Data("resume-token".utf8),
                   partial: transferPartialSource(Data(goodArchiveBytes.prefix(5))),
                   package: goodPackage)

    let tampered = Data(repeating: 0xAB, count: goodArchiveBytes.count)
    let engine = ScriptedTransfer()
    engine.outcome = .succeed(tampered)
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    check(engine.starts.count == 1 && engine.starts[0] != nil,
          "the retained transfer is used")
    let failed = pump { if case .failed = installer.phase { return true }
                        return false }
    check(failed, "the completed file is rejected")

    var failure: AIRuntimeInstallFailure?
    if case .failed(let value) = installer.phase { failure = value }
    check(failure?.kind == .hashMismatch,
          "the hash mismatch keeps its own class",
          String(describing: failure?.kind))
    check(transferMarker(at: live) == "old",
          "the previous runtime is still the live one")
    check(AIRuntime.isStructurallyValid(root: live),
          "and it is still valid")
    check(!transferHasDirectory(in: support, prefix: live.lastPathComponent + "-installing-"),
          "nothing is staged for a refused archive")
    check(!FileManager.default.fileExists(atPath: store.directory.path),
          "a resumed file that fails is not kept as resumable")
}

// MARK: - Copy in both languages

print("\n[RT] the preflight sentence exists in both languages, digits included")

let shortfallNeeded: Int64 = 500_000_000
let shortfallFree: Int64 = 120_000_000
let englishMessage = L10n.shared.aiRuntimeInsufficientDisk(neededBytes: shortfallNeeded,
                                                           freeBytes: shortfallFree)
let persianMessage = PersianL10n.table.aiRuntimeInsufficientDisk(
    neededBytes: shortfallNeeded, freeBytes: shortfallFree)

check(!englishMessage.isEmpty && !persianMessage.isEmpty,
      "both tables answer")
check(persianMessage != englishMessage,
      "the Persian table has its own sentence")
check(englishMessage.contains(L10n.byteSize(shortfallNeeded))
        && englishMessage.contains(L10n.byteSize(shortfallFree)),
      "the English sentence shows both sizes")
check(persianMessage.contains(Digits.persian(L10n.byteSize(shortfallNeeded)))
        && persianMessage.contains(Digits.persian(L10n.byteSize(shortfallFree))),
      "the Persian sentence shows both sizes in Persian digits")
let persianHasAsciiDigits = persianMessage.unicodeScalars.contains {
    $0.value >= 48 && $0.value <= 57
}
check(!persianHasAsciiDigits, "with no ASCII digit left behind")
let persianHasPersianDigits = persianMessage.unicodeScalars.contains {
    $0.value >= 0x06F0 && $0.value <= 0x06F9
}
check(persianHasPersianDigits, "Persian-Indic digits are present")
check(englishMessage.contains("Not enough free disk space"),
      "the English sentence is written, not a placeholder")
check(persianMessage.contains("فضای آزاد دیسک کافی نیست"),
      "the Persian sentence is written, not a translation stub")
check(persianMessage.contains("نصب نشد"),
      "and it says nothing was installed")
check(Digits.persian("12 MB") == "۱۲ MB",
      "the digit converter does not wait for the interface language")

// MARK: - The phase machine's part in this slice

print("\n[RT] a preflight refusal never looks like a download")

let reducer = AIRuntimeInstallReducer.self
let insufficient = AIRuntimeInstallFailure(kind: .insufficientDisk, message: "m")
check(reducer.reduce(current: .awaitingConsent, event: .failed(insufficient))
        == .failed(insufficient),
      "consent can move to a failure without a download")
check(reducer.reduce(current: .awaitingConsent,
                     event: .downloadProgress(receivedBytes: 1, totalBytes: 2)) == nil,
      "progress is still illegal before consent was granted")
check(reducer.reduce(current: .failed(insufficient), event: .retryRequested)
        == .awaitingConsent,
      "a refused preflight can be retried")
var phase = AIRuntimeInstallPhase.awaitingConsent
_ = reducer.reduce(current: phase, into: &phase, event: .failed(insufficient))
check(!phase.isBusy && phase.isTerminal,
      "the refusal is a settled answer, not a hanging spinner")

try? FileManager.default.removeItem(at: transferRoot)

print("")
if failures.isEmpty {
    print("RUNTIME TRANSFER TESTS: PASS (\(checks) checks)")
    exit(0)
} else {
    print("RUNTIME TRANSFER TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
