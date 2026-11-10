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
                        lockTimeout: TimeInterval = RuntimeTransactionLock.defaultTimeout,
                        usageTimeout: TimeInterval = 10) throws {
        try AIRuntimeTransaction.install(archive: archive, support: support,
                                         package: package, hooks: hooks,
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
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw AIRuntimeFailure(code: .extract)
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

    init(code: Kind, previous: PreviousRuntime = .none, detail: String? = nil) {
        self.code = code
        self.previous = previous
        self.detail = detail
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
