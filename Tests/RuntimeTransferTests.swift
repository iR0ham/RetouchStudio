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
    environment.makeHooks = { _, _ in hooks ?? transferHooks() }
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
    // Exactly the required amount passes (the comparison is "at least"). The
    // seeded live tree is part of the reservation, exactly as in the installer.
    let support = transferSupport("exact")
    transferSeedLive(support)
    let engine = ScriptedTransfer()
    engine.outcome = .succeed(goodArchiveBytes)
    let needed = AIRuntimeDiskPreflight.requiredBytes(
        archiveBytes: goodPackage.bytes,
        existingInstallBytes: AIRuntimeDiskPreflight.size(
            of: AIRuntime.installDirectory(in: support)))
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

// MARK: - The reservation counts the live tree

print("\n[RT] the reservation includes a runtime that is already installed")

transferRun {
    let liveSize = AIRuntimeDiskPreflight.size(of: fixtureOld)
    check(liveSize > 0, "an existing tree is measured", "\(liveSize) bytes")
    check(AIRuntimeDiskPreflight.size(
            of: transferRoot.appendingPathComponent("missing-\(UUID().uuidString)")) == 0,
          "a missing tree reserves nothing")
    let base = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: 1_000)
    check(AIRuntimeDiskPreflight.requiredBytes(archiveBytes: 1_000,
                                               existingInstallBytes: 5_000)
            == base + 5_000,
          "the live tree is added to the archive and unpack estimates")
    check(AIRuntimeDiskPreflight.requiredBytes(archiveBytes: 1_000,
                                               existingInstallBytes: -10) == base,
          "a negative measurement cannot shrink the reservation")
}

transferRun {
    // An upgrade under-reserves if the live tree is ignored: exactly enough
    // for the archive alone must still be refused while the old tree exists.
    let support = transferSupport("reserve-live")
    transferSeedLive(support)
    let tree = AIRuntimeDiskPreflight.size(of: AIRuntime.installDirectory(in: support))
    let base = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: goodPackage.bytes)
    let needed = base + tree
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    var capacity = needed - 1
    var environment = transferEnvironment(support: support, engine: engine)
    environment.availableCapacity = { _ in capacity }
    let installer = AIRuntimeInstaller(environment: environment)
    _ = installer.requestConsent()
    installer.install(goodPackage)
    var refusal: AIRuntimeInstallFailure?
    if case .failed(let failure) = installer.phase { refusal = failure }
    check(engine.starts.isEmpty, "the under-reserved upgrade did not start")
    check(refusal?.kind == .insufficientDisk,
          "the old tree is charged against the new install",
          String(describing: installer.phase))
    check(refusal?.message
            == L10n.shared.aiRuntimeInsufficientDisk(neededBytes: needed,
                                                     freeBytes: needed - 1),
          "and the sentence quotes the reservation that includes it")

    capacity = needed
    check(installer.requestConsent(), "the retry asks for consent")
    installer.install(goodPackage)
    check(engine.starts.count == 1, "with the tree counted, the same install proceeds")
    installer.cancel()
}

// MARK: - The later gates do not charge the archive twice

print("\n[RT] the later gates charge only what the transfer has not already spent")

check(AIRuntimeDiskPreflight.remainingAfterDownload(requiredBytes: 1_000,
                                                    archiveBytes: 400) == 600,
      "the archive already on the volume is subtracted from the later need")
check(AIRuntimeDiskPreflight.remainingAfterDownload(requiredBytes: 1_000,
                                                    archiveBytes: 1_400) == 0,
      "an archive larger than the reservation cannot make the need negative")
check(AIRuntimeDiskPreflight.remainingAfterDownload(requiredBytes: 1_000,
                                                    archiveBytes: -5) == 1_000,
      "a negative measurement cannot shrink the later need")

transferRun {
    // The exact case the real volume caught: a free space equal to the
    // reservation minus the downloaded archive must pass the later gates.
    let support = transferSupport("gate2-exact")
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    let fullNeed = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: goodPackage.bytes)
    let remainder = AIRuntimeDiskPreflight.remainingAfterDownload(
        requiredBytes: fullNeed, archiveBytes: goodPackage.bytes)
    var calls = 0
    var environment = transferEnvironment(support: support, engine: engine)
    environment.availableCapacity = { _ in
        calls += 1
        return calls == 1 ? fullNeed : remainder
    }
    let installer = AIRuntimeInstaller(environment: environment)
    _ = installer.requestConsent()
    installer.install(goodPackage)
    check(engine.starts.count == 1, "the transfer starts with exactly the reservation")
    engine.succeed(goodArchiveBytes)
    let ready = pump { if case .ready = installer.phase { return true }
                       return false }
    check(ready,
          "free space equal to the reservation minus the archive passes both later gates",
          String(describing: installer.phase))
    check(calls >= 3, "both later gates were consulted", "\(calls) checks")
    check(transferMarker(at: AIRuntime.installDirectory(in: support)) == "new",
          "and the install completes")
}

transferRun {
    // One byte below the remaining need is a real refusal, before verifying, so
    // the sentence quotes the remainder rather than the full reservation.
    let support = transferSupport("gate2-short")
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    let fullNeed = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: goodPackage.bytes)
    let remainder = AIRuntimeDiskPreflight.remainingAfterDownload(
        requiredBytes: fullNeed, archiveBytes: goodPackage.bytes)
    var calls = 0
    var environment = transferEnvironment(support: support, engine: engine)
    environment.availableCapacity = { _ in
        calls += 1
        return calls == 1 ? fullNeed : remainder - 1
    }
    let installer = AIRuntimeInstaller(environment: environment)
    _ = installer.requestConsent()
    installer.install(goodPackage)
    engine.succeed(goodArchiveBytes)
    let failed = pump { if case .failed = installer.phase { return true }
                        return false }
    var failure: AIRuntimeInstallFailure?
    if case .failed(let value) = installer.phase { failure = value }
    check(failed && failure?.kind == .insufficientDisk,
          "one byte below the remainder is refused",
          String(describing: installer.phase))
    check(failure?.message
            == L10n.shared.aiRuntimeInsufficientDisk(neededBytes: remainder,
                                                     freeBytes: remainder - 1),
          "the sentence quotes the remaining need, not the reservation")
    check(!transferHasDirectory(in: support, prefix: "protocol-v2-installing-"),
          "no staging tree was written")
}

transferRun {
    // The same remainder applies to the last gate: verification passes, the
    // transaction is still not allowed to start when the volume dropped.
    let support = transferSupport("gate3-short")
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    let fullNeed = AIRuntimeDiskPreflight.requiredBytes(archiveBytes: goodPackage.bytes)
    let remainder = AIRuntimeDiskPreflight.remainingAfterDownload(
        requiredBytes: fullNeed, archiveBytes: goodPackage.bytes)
    var calls = 0
    var environment = transferEnvironment(support: support, engine: engine)
    environment.availableCapacity = { _ in
        calls += 1
        switch calls {
        case 1: return fullNeed
        case 2: return remainder
        default: return remainder - 1
        }
    }
    let installer = AIRuntimeInstaller(environment: environment)
    _ = installer.requestConsent()
    installer.install(goodPackage)
    engine.succeed(goodArchiveBytes)
    let failed = pump { if case .failed = installer.phase { return true }
                        return false }
    var failure: AIRuntimeInstallFailure?
    if case .failed(let value) = installer.phase { failure = value }
    check(failed && failure?.kind == .insufficientDisk,
          "the pre-install gate compares against the same remainder",
          String(describing: installer.phase))
    check(calls == 3, "the third gate is the one that refused", "\(calls) checks")
    check(failure?.message
            == L10n.shared.aiRuntimeInsufficientDisk(neededBytes: remainder,
                                                     freeBytes: remainder - 1),
          "and quotes it")
    check(!transferHasDirectory(in: support, prefix: "protocol-v2-installing-"),
          "nothing was staged")
}

// MARK: - Capacity is rechecked at the later gates

print("\n[RT] capacity is rechecked before verification and before installation")

transferRun {
    // The volume fills during the transfer: the check before verifying catches
    // it, so the stage never claims to be verifying a file it cannot unpack.
    let support = transferSupport("recheck-verify")
    transferSeedLive(support)
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    var capacity: Int64? = Int64.max
    var calls = 0
    var environment = transferEnvironment(support: support, engine: engine)
    environment.availableCapacity = { _ in
        calls += 1
        return capacity
    }
    let installer = AIRuntimeInstaller(environment: environment)
    _ = installer.requestConsent()
    installer.install(goodPackage)
    check(engine.starts.count == 1, "the transfer started with room to spare")
    let needed = AIRuntimeDiskPreflight.requiredBytes(
        archiveBytes: goodPackage.bytes,
        existingInstallBytes: AIRuntimeDiskPreflight.size(
            of: AIRuntime.installDirectory(in: support)))
    // After the transfer the archive is already on the volume, so the second
    // gate asks only for what is left to unpack.
    let remaining = AIRuntimeDiskPreflight.remainingAfterDownload(
        requiredBytes: needed, archiveBytes: goodPackage.bytes)
    capacity = 0
    engine.succeed(goodArchiveBytes)
    let failed = pump { if case .failed = installer.phase { return true }
                        return false }
    var failure: AIRuntimeInstallFailure?
    if case .failed(let value) = installer.phase { failure = value }
    check(failed && failure?.kind == .insufficientDisk,
          "a volume that filled during the transfer is a disk refusal",
          String(describing: installer.phase))
    check(calls >= 2, "the gate ran again after the transfer", "\(calls) checks")
    check(failure?.message
            == L10n.shared.aiRuntimeInsufficientDisk(neededBytes: remaining, freeBytes: 0),
          "with the shipped sentence and the real numbers")
    check(transferMarker(at: AIRuntime.installDirectory(in: support)) == "old",
          "the previous runtime is still live")
    check(!transferHasDirectory(in: support, prefix: "protocol-v2-installing-"),
          "nothing was staged")
}

transferRun {
    // The volume fills after verification: the claim to install is refused
    // before the transaction may write a staging tree.
    let support = transferSupport("recheck-install")
    transferSeedLive(support)
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    var calls = 0
    var environment = transferEnvironment(support: support, engine: engine)
    environment.availableCapacity = { _ in
        calls += 1
        return calls <= 2 ? Int64.max : 0
    }
    let installer = AIRuntimeInstaller(environment: environment)
    _ = installer.requestConsent()
    installer.install(goodPackage)
    engine.succeed(goodArchiveBytes)
    let failed = pump { if case .failed = installer.phase { return true }
                        return false }
    var failure: AIRuntimeInstallFailure?
    if case .failed(let value) = installer.phase { failure = value }
    check(failed && failure?.kind == .insufficientDisk,
          "a volume that filled before installation is a disk refusal",
          String(describing: installer.phase))
    check(calls == 3, "the third gate is the one that refused", "\(calls) checks")
    check(transferMarker(at: AIRuntime.installDirectory(in: support)) == "old",
          "the previous runtime is still live")
    check(!transferHasDirectory(in: support, prefix: "protocol-v2-installing-"),
          "no staging tree was written")
}

transferRun {
    // An injected POSIX ENOSPC from the extract hook — a shape the production
    // extractor cannot produce (it reports ditto's stderr instead; the real
    // shape is covered below). This pins that a system error of that shape is
    // still classified as the disk when some future hook throws one.
    let support = transferSupport("extract-enospc")
    transferSeedLive(support)
    let engine = ScriptedTransfer()
    engine.outcome = .succeed(goodArchiveBytes)
    var hooks = transferHooks()
    hooks.extract = { _, _ in
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    }
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine,
                                         hooks: hooks))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    let failed = pump { if case .failed = installer.phase { return true }
                        return false }
    var failure: AIRuntimeInstallFailure?
    if case .failed(let value) = installer.phase { failure = value }
    check(failed && failure?.kind == .insufficientDisk,
          "ENOSPC while unpacking is a disk failure, not a bad archive",
          String(describing: installer.phase))
    check(failure?.message == L10n.shared.aiRuntimeDiskFull,
          "the sentence names the disk, not the archive")
    check(transferMarker(at: AIRuntime.installDirectory(in: support)) == "old",
          "the previous runtime is still live")
    check(!transferHasDirectory(in: support, prefix: "protocol-v2-installing-"),
          "the aborted staging tree is removed")
}

print("\n[RT] a wrapped disk error keeps its class through the transaction")

let enospc = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
for code in [AIRuntimeFailure.Kind.extract, .install] {
    let wrapped = AIRuntimeFailure(code: code, previous: .kept, detail: "disk",
                                   underlying: enospc)
    check(AIRuntimeInstallFailure.classify(wrapped).kind == .insufficientDisk,
          "a .\(code) failure with an ENOSPC underneath is disk full")
}
let wrappedURL = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile,
                         userInfo: [NSUnderlyingErrorKey: enospc])
let wrappedFailure = AIRuntimeFailure(code: .extract, detail: "disk",
                                      underlying: wrappedURL)
check(AIRuntimeInstallFailure.classify(wrappedFailure).kind == .insufficientDisk,
      "the ENOSPC signal survives a URL error inside the wrapper")
check(AIRuntimeInstallFailure.classify(wrappedFailure).message
        == L10n.shared.aiRuntimeDiskFull,
      "the wrapper's sentence is the disk sentence")
check(!PersianL10n.table.aiRuntimeDiskFull.isEmpty
        && PersianL10n.table.aiRuntimeDiskFull != L10n.shared.aiRuntimeDiskFull,
      "the Persian table has its own disk sentence")

// MARK: - The real ditto failure, not an injected one

print("\n[RT] the production unpacker's own ENOSPC text names the disk")

// Captured verbatim from `/usr/bin/ditto -x -k` into a 3 MB HFS+ image that
// filled mid-expansion (exit status 1). The second line alone would read as a
// corrupt archive; the first is the fact that decides the class.
let capturedDittoStderr = """
ditto: /private/tmp/rs-bounded-mnt/big.bin: No space left on device
ditto: Couldn't read pkzip signature.
"""
let dittoDiagnosis = AIRuntimeUnpackDiagnostics(exitStatus: 1,
                                                stderr: capturedDittoStderr)
check(dittoDiagnosis.isOutOfSpace,
      "the verbatim line from a real bounded-volume run is recognised")
check(!AIRuntimeUnpackDiagnostics(
        exitStatus: 1, stderr: "ditto: Couldn't read pkzip signature.\n").isOutOfSpace,
      "a corrupt-archive line without the space line stays a bad archive")
check(AIRuntimeUnpackDiagnostics(exitStatus: 1, stderr: "").isOutOfSpace == false,
      "an empty message is not guessed to be a full disk")

let dittoFailure = AIRuntimeFailure(code: .extract, detail: "ditto",
                                    underlying: dittoDiagnosis)
check(AIRuntimeInstallFailure.classify(dittoFailure).kind == .insufficientDisk,
      "a .extract failure carrying ditto's space line is a disk refusal")
check(AIRuntimeInstallFailure.classify(dittoFailure).message
        == L10n.shared.aiRuntimeDiskFull,
      "with the disk sentence, not the unpack sentence")
check(AIRuntimeInstallFailure.classify(dittoFailure).message
        != L10n.shared.aiRuntimeExtractFailed,
      "and never 'the runtime could not be unpacked'")

// A probe below the margin decides the same way when the message does not.
let marginVerdict = AIRuntimeLowDiskSpace(
    freeBytes: AIRuntimeDiskPreflight.unpackSafetyMarginBytes,
    marginBytes: AIRuntimeDiskPreflight.unpackSafetyMarginBytes)
check(AIRuntimeInstallFailure.classify(
        AIRuntimeFailure(code: .extract, underlying: marginVerdict)).kind
        == .insufficientDisk,
      "free space at the margin after a failed unpack is a disk refusal")
// A failure with no disk signal keeps the archive's own class. (The low-disk
// verdict is only ever attached below the margin, so its presence is the fact;
// this pins that an ordinary extract error is still an unpack failure.)
check(AIRuntimeInstallFailure.classify(
        AIRuntimeFailure(code: .extract, detail: "not a zip",
                         underlying: NSError(domain: NSCocoaErrorDomain, code: 1)))
        .kind == .incompatibleRuntime,
      "an extract failure without a disk signal stays a bad archive")

// Drive the real extractor with no network and no stub. A bounded HFS+ image
// is created and mounted here; when the environment refuses to create one the
// run is reported as not performed rather than as a pass.
struct TransferTool {
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

func transferBoundedVolume() -> (image: URL, mount: URL)? {
    let image = transferRoot.appendingPathComponent("bounded-\(UUID().uuidString).dmg")
    let mount = transferRoot.appendingPathComponent("mount-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    guard TransferTool.run("/usr/bin/hdiutil",
                           ["create", "-quiet", "-size", "3m", "-fs", "HFS+",
                            "-volname", "RSBounded", image.path]).status == 0 else {
        return nil
    }
    guard TransferTool.run("/usr/bin/hdiutil",
                           ["attach", "-quiet", "-nobrowse", "-mountpoint",
                            mount.path, image.path]).status == 0 else {
        try? FileManager.default.removeItem(at: image)
        return nil
    }
    return (image, mount)
}

func transferFillingArchive() -> URL? {
    let source = transferRoot.appendingPathComponent("filling-\(UUID().uuidString)")
    let archive = transferRoot.appendingPathComponent("filling-\(UUID().uuidString).zip")
    try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    var bytes = Data(count: 8 << 20)
    bytes.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
    }
    guard (try? bytes.write(to: source.appendingPathComponent("big.bin"))) != nil,
          TransferTool.run("/usr/bin/ditto", ["-c", "-k", source.path, archive.path])
            .status == 0 else { return nil }
    return archive
}

print("\n[RT] the real extractor reports a full volume as a disk refusal")

if let volume = transferBoundedVolume() {
    let archive = transferFillingArchive()
    if let archive {
        do {
            try AIRuntime.install(archive: archive, support: volume.mount, package: nil)
            check(false, "the bounded volume refuses the real unpack",
                  "install returned")
        } catch let failure as AIRuntimeFailure {
            check(failure.code == .extract,
                  "the real ditto failure stays an extract failure",
                  "\(failure.code)")
            check((failure.underlying as? AIRuntimeUnpackDiagnostics)?.isOutOfSpace == true,
                  "and keeps the ditto text that names the space")
            let classified = AIRuntimeInstallFailure.classify(failure)
            check(classified.kind == .insufficientDisk,
                  "so the real-disk failure classifies as insufficient disk",
                  "\(classified.kind)")
            check(classified.message == L10n.shared.aiRuntimeDiskFull,
                  "with the disk sentence")
            check(classified.message
                    == "The disk filled up while installing the AI runtime. Nothing was installed.",
                  "the English sentence is the shipped one")
        } catch {
            check(false, "the real unpack reports an AIRuntimeFailure", "\(error)")
        }
        check(!transferHasDirectory(in: volume.mount, prefix: "protocol-v2-installing-"),
              "the aborted staging tree is removed from the real volume")
        try? FileManager.default.removeItem(at: archive)
    } else {
        print("  ! the filling archive could not be built; real-volume unpack NOT run")
    }
    _ = TransferTool.run("/usr/bin/hdiutil",
                         ["detach", "-quiet", "-force", volume.mount.path])
    try? FileManager.default.removeItem(at: volume.image)
} else {
    print("  ! a bounded volume could not be created here; real-volume unpack NOT run")
}

check(PersianL10n.table.aiRuntimeDiskFull
        == "دیسک در حین نصب دستیار هوش مصنوعی پر شد. چیزی نصب نشد.",
      "the Persian disk sentence is the shipped one",
      PersianL10n.table.aiRuntimeDiskFull)

// MARK: - The production engine's resume helpers (offline)

print("\n[RT] resume data parsing and restoration are exercised without a network")

func resumePlist(name: String?) -> Data {
    var dictionary: [String: Any] = ["NSURLSessionResumeInfoVersion": 2]
    if let name { dictionary["NSURLSessionResumeInfoTempFileName"] = name }
    return (try? PropertyListSerialization.data(fromPropertyList: dictionary,
                                                format: .xml, options: 0)) ?? Data()
}

let tempDirectory = FileManager.default.temporaryDirectory
let validName = "retouch-resume-\(UUID().uuidString).tmp"
let validPartial = tempDirectory.appendingPathComponent(validName)
try? Data("partial-bytes".utf8).write(to: validPartial)
check(URLSessionTransferEngine.tempName(describedBy: resumePlist(name: validName))
        == validName,
      "a plain temp-file name is read out of the plist")
check(URLSessionTransferEngine.partialFile(describedBy: resumePlist(name: validName))?
        .standardizedFileURL == validPartial.standardizedFileURL,
      "and the partial is found inside the temporary directory")
check(URLSessionTransferEngine.partialFile(
        describedBy: resumePlist(name: "retouch-absent-\(UUID().uuidString).tmp")) == nil,
      "a name whose file is gone yields nil, so the clean restart is taken")
check(URLSessionTransferEngine.tempName(describedBy: resumePlist(name: nil)) == nil,
      "a plist without the temp-file key yields nil")
check(URLSessionTransferEngine.tempName(describedBy: Data("not a plist".utf8)) == nil,
      "unreadable resume data yields nil")

let escapingNames = ["..", ".", "sub/partial.tmp", "/tmp/escape.tmp", "a/../b"]
for name in escapingNames {
    check(URLSessionTransferEngine.resumeTempName(name) == nil,
          "the name '\(name)' is not a plain component")
    check(URLSessionTransferEngine.tempName(describedBy: resumePlist(name: name)) == nil,
          "and is rejected inside resume data")
}

// An escaping name must not let restoration delete the temporary directory.
let tempMarker = tempDirectory.appendingPathComponent("retouch-marker-\(UUID().uuidString)")
try? Data("keep".utf8).write(to: tempMarker)
let escapeSource = transferPartialSource(Data("escape".utf8))
check(URLSessionTransferEngine.restorePartial(
        escapeSource, describedBy: resumePlist(name: "..")) == nil,
      "an escaping name restores nothing")
check(FileManager.default.fileExists(atPath: tempMarker.path),
      "and the temporary directory is untouched")
check(URLSessionTransferEngine.restorePartial(
        nil, describedBy: resumePlist(name: validName)) == nil,
      "restoration without a retained partial is a no-op")

let restoreName = "retouch-restore-\(UUID().uuidString).tmp"
let restoreSource = transferPartialSource(Data("restored-bytes".utf8))
let restored = URLSessionTransferEngine.restorePartial(
    restoreSource, describedBy: resumePlist(name: restoreName))
let restoreDestination = tempDirectory.appendingPathComponent(restoreName)
check(restored?.standardizedFileURL == restoreDestination.standardizedFileURL,
      "a valid name restores the partial to the temporary directory")
let restoredText = (try? Data(contentsOf: restoreDestination))
    .flatMap { String(data: $0, encoding: .utf8) }
check(restoredText == "restored-bytes",
      "with the retained bytes")
try? FileManager.default.removeItem(at: restoreDestination)
try? FileManager.default.removeItem(at: validPartial)
try? FileManager.default.removeItem(at: tempMarker)

// N1: an engine given a pair whose partial cannot be restored must start a
// clean download, not a resume the session would answer with a CFNetwork error.
let usableName = "retouch-usable-\(UUID().uuidString).tmp"
let usableSource = transferPartialSource(Data("usable-bytes".utf8))
let usableResume = AIRuntimeTransferResume(
    data: resumePlist(name: usableName), partial: usableSource)
check(URLSessionTransferEngine.usableResume(usableResume) != nil,
      "a restorable pair is offered to the session")
check((try? Data(contentsOf: tempDirectory.appendingPathComponent(usableName)))
        == Data("usable-bytes".utf8),
      "and its partial is put back for the session")
check(URLSessionTransferEngine.usableResume(
        AIRuntimeTransferResume(data: resumePlist(name: usableName), partial: nil)) == nil,
      "a pair without its partial is not offered, so the download starts clean")
check(URLSessionTransferEngine.usableResume(
        AIRuntimeTransferResume(data: resumePlist(name: ".."),
                                partial: usableSource)) == nil,
      "an escaping name is not offered either")
check(URLSessionTransferEngine.usableResume(nil) == nil,
      "no retained pair means a clean download")
try? FileManager.default.removeItem(
    at: tempDirectory.appendingPathComponent(usableName))

// MARK: - A support directory reached through a symlink

print("\n[RT] containment resolves the existing parents on both sides")

let containReal = transferSupport("contain-real")
let containOutside = transferSupport("contain-outside")
let containLink = transferRoot.appendingPathComponent("contain-link-\(UUID().uuidString)")
try? FileManager.default.createSymbolicLink(at: containLink,
                                            withDestinationURL: containReal)

check(AIRuntimeTransaction.isContained(containLink, in: containLink),
      "a support directory is contained in itself")
check(AIRuntimeTransaction.isContained(
        containLink.appendingPathComponent("protocol-v2-installing-abc"),
        in: containLink),
      "a missing staging name under a symlinked support is contained")
check(AIRuntimeTransaction.isContained(
        containReal.appendingPathComponent("protocol-v2"),
        in: containLink),
      "the target spelling of the same directory is contained too")
check(!AIRuntimeTransaction.isContained(
        URL(fileURLWithPath: containLink.path + "-sibling"), in: containLink),
      "a sibling whose name shares the prefix is not contained")

try? FileManager.default.createSymbolicLink(
    at: containReal.appendingPathComponent("escape"),
    withDestinationURL: containOutside)
check(!AIRuntimeTransaction.isContained(
        containReal.appendingPathComponent("escape"), in: containReal),
      "a symlink that leaves the support is still refused")
check(!AIRuntimeTransaction.isContained(
        containReal.appendingPathComponent("escape/missing"), in: containReal),
      "and so is a missing child under that link")

transferRun {
    // End to end: the transaction's own paths accept a symlinked support and
    // install into the real directory the link names.
    let real = transferSupport("contain-install-real")
    let link = transferRoot.appendingPathComponent("contain-install-link-\(UUID().uuidString)")
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    do {
        try AIRuntime.install(archive: goodArchiveURL, support: link, package: nil,
                              hooks: transferHooks())
        check(transferMarker(at: AIRuntime.installDirectory(in: real)) == "new",
              "a transaction through a symlinked support installs into the target")
        check(!FileManager.default.fileExists(atPath: real.appendingPathComponent("escape").path),
              "and writes nothing outside it")
    } catch {
        check(false, "a symlinked support is accepted by the transaction paths",
              "\(error)")
    }
}

// MARK: - A system error at the catch-all keeps its cause

print("\n[RT] a hook failure outside the extract step keeps its system error")

transferRun {
    let support = transferSupport("catch-all-underlying")
    var hooks = transferHooks()
    hooks.beforeInstall = {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                      userInfo: [NSLocalizedDescriptionKey: "injected I/O failure"])
    }
    do {
        try AIRuntime.install(archive: goodArchiveURL, support: support, package: nil,
                              hooks: hooks)
        check(false, "the failing hook refuses the install", "install returned")
    } catch let failure as AIRuntimeFailure {
        check(failure.code == .install, "the failure is the install class",
              "\(failure.code)")
        check(failure.underlying != nil, "and the system error is attached")
        check("\(String(describing: failure.underlying))".contains("injected I/O failure"),
              "with its own message")
    } catch {
        check(false, "the catch-all reports an AIRuntimeFailure", "\(error)")
    }
}

// MARK: - The English size formatter is pinned

print("\n[RT] the English size keeps Latin units")

let latinSize = L10n.byteSize(500_000_000)
check(latinSize.range(of: #"^[0-9.,]+ (bytes|KB|MB|GB|TB)$"#,
                      options: .regularExpression) != nil,
      "an English size is digits plus a Latin unit", latinSize)
check(!latinSize.unicodeScalars.contains { $0.value >= 0x06F0 && $0.value <= 0x06F9 },
      "with no Persian-Indic digit")
check(Digits.persian(latinSize).unicodeScalars.contains {
        $0.value >= 0x06F0 && $0.value <= 0x06F9
      },
      "and the Persian table can convert it afterwards")

// MARK: - An engine that stops without our token

print("\n[RT] an engine cancelled outside the token is not a failure")

transferRun {
    let support = transferSupport("engine-cancel")
    let engine = ScriptedTransfer()
    engine.outcome = .hold
    let installer = AIRuntimeInstaller(
        environment: transferEnvironment(support: support, engine: engine))
    _ = installer.requestConsent()
    installer.install(goodPackage)
    engine.fail(URLError(.cancelled))
    let cancelled = pump { installer.phase == .cancelled }
    check(cancelled, "an engine torn down without the token reports cancelled",
          String(describing: installer.phase))
    check(!installer.phase.isBusy, "and leaves no work running")
}

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
