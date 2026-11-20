import CryptoKit
import Foundation

/// The optional local-AI runtime. A light release ships the editor alone and
/// fetches a protocol-v2 archive only when the owner asks for AI.
///
/// The official protocol-v2 package is not published yet. No URL, size or
/// checksum is invented here, and nothing falls back to the older `AI/runtime`
/// directory: until a real package is released and validated, the download path
/// stays disabled (`package == nil`) and a previously installed legacy runtime
/// is never read.
enum AIRuntime {

    struct Package: Equatable {
        let version: String
        let fileName: String
        let url: URL
        let bytes: Int64
        let sha256: String
        let protocolVersion: Int

        init(version: String, fileName: String, url: URL, bytes: Int64,
             sha256: String, protocolVersion: Int = HelperRegistry.protocolVersion) {
            self.version = version
            self.fileName = fileName
            self.url = url
            self.bytes = bytes
            self.sha256 = sha256
            self.protocolVersion = protocolVersion
        }

        var hashPrefix: String {
            String(sha256.prefix(16)) + "…"
        }
    }

    /// No official protocol-v2 runtime has been published. Fabricating its
    /// metadata would enable a download the app cannot verify, so this stays
    /// nil and the UI reports the runtime as unavailable.
    static var package: Package? { nil }

    static var installDirectory: URL {
        installDirectory(in: AIWorker.runtimeSupportDirectory)
    }

    static func installDirectory(in support: URL) -> URL {
        support.appendingPathComponent("protocol-v2", isDirectory: true)
    }

    static func backupDirectory(in support: URL) -> URL {
        support.appendingPathComponent("protocol-v2-backup", isDirectory: true)
    }

    /// A cheap layout check for display and for deciding whether any runtime
    /// exists. It never grants trust to the downloaded runtime; selection and
    /// transaction recovery use the functional contract.
    static var isStructurallyInstalled: Bool {
        package != nil && isStructurallyValid(root: installDirectory)
    }

    static func isStructurallyValid(root: URL) -> Bool {
        AIRuntimeValidation.structural(root: root).ok
    }

    /// The filesystem steps installation uses. Tests replace one of these to
    /// fail at a specific point; production uses the real file system.
    struct InstallHooks {
        var extract: (URL, URL) throws -> Void = { archive, staging in
            try AIRuntime.extract(archive, into: staging)
        }
        var move: (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
        var remove: (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        }
        var validateStructure: (URL) -> RuntimeValidationReport = { root in
            AIRuntimeValidation.structural(root: root)
        }
        var validateRuntime: (URL) throws -> RuntimeValidationReport = { root in
            AIRuntimeValidation.functional(root: root)
        }
        var checkpoint: (RuntimeInstallCheckpoint) throws -> Void = { _ in }
        /// How the failed-unpack path re-probes the destination volume.
        /// Production reads the same capacity the installer's gates read; a
        /// test replaces it to model a volume that answers 0 or nothing.
        var probeCapacity: (URL) -> Int64? = AIRuntimeDiskPreflight.availableCapacity
        /// Runs under the transaction lock before any file is touched. The app
        /// uses it to stop a running helper that still reads the old runtime.
        var beforeInstall: () throws -> Void = {}
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Installs through the durable transaction: staging is validated first,
    /// the previous runtime stays reachable as a backup until the new one has
    /// passed the full functional contract, and only a committed record allows
    /// the backup to be deleted.
    static func install(archive: URL) throws {
        try install(archive: archive, support: AIWorker.runtimeSupportDirectory,
                    package: package)
    }

    static func install(archive: URL, support: URL, package: Package? = nil,
                        hooks: InstallHooks = InstallHooks(),
                        cancellation: AIRuntimeInstallCancellation? = nil,
                        lockTimeout: TimeInterval = RuntimeTransactionLock.defaultTimeout,
                        usageTimeout: TimeInterval = 10) throws {
        try AIRuntimeTransaction.install(archive: archive, support: support,
                                         package: package, hooks: hooks,
                                         cancellation: cancellation,
                                         lockTimeout: lockTimeout,
                                         usageTimeout: usageTimeout)
    }

    /// Finishes or undoes an interrupted installation. The result is explicit:
    /// a failure is never reported as a completed recovery.
    @discardableResult
    static func recoverInterruptedInstall(in support: URL = AIWorker.runtimeSupportDirectory,
                                          hooks: InstallHooks = InstallHooks(),
                                          lockTimeout: TimeInterval = RuntimeTransactionLock.defaultTimeout,
                                          usageTimeout: TimeInterval = 10)
        -> AIRuntimeRecoveryResult {
        AIRuntimeTransaction.recover(in: support, hooks: hooks,
                                     lockTimeout: lockTimeout,
                                     usageTimeout: usageTimeout)
    }

    private static func extract(_ archive: URL, into staging: URL) throws {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        // ditto says why it stopped on stderr, and a destination that filled
        // up is only visible there. The pipe is drained before waiting so a
        // long message cannot fill the buffer and stall the child.
        let errors = Pipe()
        unzip.standardError = errors
        try unzip.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            let stderr = String(decoding: data, as: UTF8.self)
            throw AIRuntimeFailure(
                code: .extract,
                detail: stderr.isEmpty ? nil : stderr.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                underlying: AIRuntimeUnpackDiagnostics(
                    exitStatus: unzip.terminationStatus, stderr: stderr))
        }
    }
}

enum RuntimeInstallCheckpoint: String {
    case beforeBackupMove
    case afterBackupMove
    case afterLiveMove
    case beforeCommit
    case afterCommit
    case duringRollback
}

/// Tests throw this from a checkpoint to model a process that died before it
/// could run rollback. Production code never throws it.
struct SimulatedRuntimeCrash: Error {}

struct AIRuntimeFailure: LocalizedError {
    enum Kind: Equatable {
        case extract
        case checksum
        case install
        case validation
        case recovery
        case busy
    }

    /// What happened to the runtime that was installed before this attempt.
    /// The installation message must not promise a previous copy when there
    /// was none, or when rolling back failed.
    enum PreviousRuntime: Equatable {
        case kept
        case none
        case lost
        case preserved
    }

    let code: Kind
    var previous: PreviousRuntime
    var detail: String?
    /// The system error this failure wrapped, when one exists. Classification
    /// reads it to keep a full disk a disk problem instead of blaming the
    /// archive that could not be unpacked.
    var underlying: Error?

    init(code: Kind, previous: PreviousRuntime = .none, detail: String? = nil,
         underlying: Error? = nil) {
        self.code = code
        self.previous = previous
        self.detail = detail
        self.underlying = underlying
    }

    var errorDescription: String? {
        switch code {
        case .checksum: return L10n.current.aiRuntimeChecksumFailed
        case .extract: return L10n.current.aiRuntimeExtractFailed
        case .recovery: return L10n.current.aiRuntimeRecoveryFailed
        case .busy: return L10n.current.aiRuntimeBusy
        case .install, .validation:
            switch previous {
            case .kept: return L10n.current.aiRuntimeInstallFailed
            case .none: return L10n.current.aiRuntimeInstallFailedNothing
            case .lost: return L10n.current.aiRuntimeInstallFailedRollback
            case .preserved: return L10n.current.aiRuntimeInstallFailedPreserved
            }
        }
    }
}

/// What `/usr/bin/ditto` said about an unpack that failed.
///
/// The text is kept verbatim because the lines disagree with each other: a
/// destination that fills up mid-expansion produces
/// `ditto: <path>: No space left on device` followed by
/// `ditto: Couldn't read pkzip signature.` (measured on a real bounded HFS+
/// volume). The second line alone reads as a corrupt archive, which is the
/// wrong answer and an invitation to retry the same file forever.
struct AIRuntimeUnpackDiagnostics: Error, Equatable, CustomStringConvertible {
    let exitStatus: Int32
    let stderr: String

    /// The phrase ditto writes for ENOSPC (the `strerror` text). Matched
    /// case-insensitively so a localised system message cannot hide it.
    static let outOfSpacePhrase = "No space left on device"

    var isOutOfSpace: Bool {
        stderr.range(of: Self.outOfSpacePhrase, options: .caseInsensitive) != nil
    }

    var description: String {
        "ditto exited \(exitStatus): "
            + stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The destination volume was at or under the unpack safety margin when an
/// unpack failed. Attached after the failure from a fresh capacity probe, so a
/// volume that lost its last space while ditto was writing still ends in the
/// disk answer even when ditto's own message names something else. A probe
/// that cannot answer produces no such error: judgement is withheld instead.
struct AIRuntimeLowDiskSpace: Error, Equatable {
    let freeBytes: Int64
    let marginBytes: Int64
}
