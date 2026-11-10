import Darwin
import Foundation

/// Durable state for one runtime installation. The marker is the only thing
/// that makes a half-finished swap distinguishable from a committed runtime.
/// It contains no paths: staging and rejected directories are derived from the
/// validated transaction id inside the canonical support directory.
struct RuntimeTransactionRecord: Equatable {
    static let fileName = "runtime-transaction.json"

    enum State: String {
        case preparing
        case swapping
        case rollingBack
        case committed
    }

    let id: String
    let state: State
    let hadPrevious: Bool
}

struct AIRuntimeRecoveryFailure: Equatable {
    enum Code: String {
        case invalidMarker
        case unsafePath
        case liveInvalid
        case backupInvalid
        case validationFailed
        case moveFailed
        case markerWriteFailed
        case lockFailed
        case busy
    }

    let code: Code
    let detail: String
}

struct AIRuntimeRecoveryResult {
    enum Status: String {
        case clean
        case committed
        case restoredBackup
        case adoptedLive
        case rolledBack
    }

    let status: Status
    let failure: AIRuntimeRecoveryFailure?
    let warnings: [String]

    var isSuccess: Bool { failure == nil }

    static func success(_ status: Status,
                        warnings: [String] = []) -> AIRuntimeRecoveryResult {
        AIRuntimeRecoveryResult(status: status, failure: nil, warnings: warnings)
    }

    static func failed(_ code: AIRuntimeRecoveryFailure.Code,
                       _ detail: String) -> AIRuntimeRecoveryResult {
        AIRuntimeRecoveryResult(status: .clean,
                                failure: .init(code: code, detail: detail),
                                warnings: [])
    }

    var logLine: String {
        if let failure {
            return "failed (\(failure.code.rawValue)): \(failure.detail)"
        }
        let suffix = warnings.isEmpty ? "" : " warnings: \(warnings.joined(separator: "; "))"
        return "\(status.rawValue)\(suffix)"
    }
}

/// Serializes installation, recovery, selection and cleanup for one support
/// directory. The recursive in-process lock protects threads; the permanent
/// advisory file lock protects a second process (a QA run or the model CLI).
/// The lock file is never deleted, so its inode remains stable across launches.
final class RuntimeTransactionLock {
    static let shared = RuntimeTransactionLock()

    /// Long enough for a slow functional probe (60 s) plus another process's
    /// validation to finish, short enough that a wedged holder is reported
    /// instead of blocking a launch forever.
    static let defaultTimeout: TimeInterval = 120

    private let recursive = NSRecursiveLock()
    private var depth = 0
    private var lockFile: LockFile?
    private var activeSupport: String?

    func withLock<T>(support: URL,
                     timeout: TimeInterval = RuntimeTransactionLock.defaultTimeout,
                     _ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        guard recursive.lock(before: deadline) else {
            throw AIRuntimeBusyError(
                "another operation in this process is still using the AI runtime")
        }
        defer { recursive.unlock() }

        let key = support.standardizedFileURL.path
        if depth == 0 {
            // The first helper launch can happen before any install created
            // the support folder; the lock file needs its parent.
            try? FileManager.default.createDirectory(at: support,
                                                     withIntermediateDirectories: true)
            let file = try LockFile.open(
                support.appendingPathComponent("runtime.lock"))
            do {
                try file.acquire(
                    exclusive: true,
                    timeout: max(0, deadline.timeIntervalSinceNow),
                    busyMessage:
                        "another Retouch Studio process is using the AI runtime")
            } catch {
                file.close()
                throw error
            }
            lockFile = file
            activeSupport = key
        } else if activeSupport != key {
            throw RuntimeLockError("nested runtime transaction uses a different support directory")
        }

        depth += 1
        defer {
            depth -= 1
            if depth == 0 {
                lockFile?.close()
                lockFile = nil
                activeSupport = nil
            }
        }
        return try body()
    }
}

private struct RuntimeLockError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum AIRuntimeTransaction {

    // MARK: - Public operations

    static func hasArtifacts(in support: URL) -> Bool {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: support, includingPropertiesForKeys: nil) else { return false }
        let installName = AIRuntime.installDirectory(in: support).lastPathComponent
        let backupName = AIRuntime.backupDirectory(in: support).lastPathComponent
        return entries.contains {
            $0.lastPathComponent == RuntimeTransactionRecord.fileName
                || $0.lastPathComponent == backupName
                || $0.lastPathComponent.hasPrefix(installName + "-installing-")
        }
    }

    static func install(archive: URL, support: URL, package: AIRuntime.Package?,
                        hooks: AIRuntime.InstallHooks,
                        lockTimeout: TimeInterval = RuntimeTransactionLock.defaultTimeout,
                        usageTimeout: TimeInterval = 10) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
        } catch {
            throw AIRuntimeFailure(code: .install, previous: .none)
        }

        let liveURL = AIRuntime.installDirectory(in: support)
        func previousRuntime() -> AIRuntimeFailure.PreviousRuntime {
            manager.fileExists(atPath: liveURL.path) ? .kept : .none
        }

        do {
            try RuntimeTransactionLock.shared.withLock(support: support,
                                                       timeout: lockTimeout) {
                // Stops this app's helper before the exclusive lease is taken;
                // a helper owned by a live second app is left alone and shows
                // up as a bounded busy answer instead.
                try hooks.beforeInstall()

                // From here through the commit or rollback the exclusive lease
                // is held continuously: recovery, cleanup, archive verification
                // and the swap all see a tree no consumer can still be reading.
                let usage = try RuntimeUsageLease.acquireExclusive(
                    support: support, timeout: usageTimeout)
                defer { usage.release() }

                let recovery = recoverLocked(in: support, hooks: hooks)
                guard recovery.isSuccess else {
                    throw AIRuntimeFailure(code: .recovery,
                                           previous: previousRuntime(),
                                           detail: recovery.logLine)
                }
                // Recovery deliberately leaves a committed runtime's backup in
                // place while other apps may be using it. Now that the runtime
                // is exclusively ours, the leftover must go: the transaction
                // needs a free backup path and a clean staging namespace.
                try removeLeftovers(in: support, hooks: hooks)
                if let package {
                    try verifyArchive(archive, matches: package)
                }
                try installLocked(archive: archive, support: support, hooks: hooks)
            }
        } catch let failure as AIRuntimeFailure {
            throw failure
        } catch is SimulatedRuntimeCrash {
            throw SimulatedRuntimeCrash()
        } catch let busy as AIRuntimeBusyError {
            throw AIRuntimeFailure(code: .busy, previous: previousRuntime(),
                                   detail: busy.description)
        } catch {
            throw AIRuntimeFailure(code: .install, previous: previousRuntime())
        }
    }

    static func recover(in support: URL,
                        hooks: AIRuntime.InstallHooks,
                        lockTimeout: TimeInterval = RuntimeTransactionLock.defaultTimeout,
                        usageTimeout: TimeInterval = 10) -> AIRuntimeRecoveryResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: support.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .success(.clean)
        }
        do {
            return try RuntimeTransactionLock.shared.withLock(support: support,
                                                              timeout: lockTimeout) {
                // Read-only classification first: a committed runtime with a
                // usable live tree and a leftover backup must remain usable
                // while another app's helper runs. Every mutation below this
                // point happens under the exclusive lease, held continuously.
                let classification = classifyRecovery(in: support, hooks: hooks)
                guard classification.requiresMutation else {
                    return classification.result ?? .success(.clean)
                }
                let usage: RuntimeUsageLease
                do {
                    usage = try RuntimeUsageLease.acquireExclusive(
                        support: support, timeout: usageTimeout)
                } catch let busy as AIRuntimeBusyError {
                    return .failed(.busy, busy.description)
                }
                defer { usage.release() }

                // Reclassify under both locks: the state observed before the
                // exclusive lease may have changed while waiting.
                let current = classifyRecovery(in: support, hooks: hooks)
                guard current.requiresMutation else {
                    return current.result ?? .success(.clean)
                }
                return recoverLocked(in: support, hooks: hooks)
            }
        } catch let busy as AIRuntimeBusyError {
            return .failed(.busy, busy.description)
        } catch {
            return .failed(.lockFailed, "\(error)")
        }
    }

    private struct RecoveryClassification {
        let requiresMutation: Bool
        let result: AIRuntimeRecoveryResult?
    }

    /// Decides from durable state alone whether recovery would move files. A
    /// result without mutation is safe to return while consumers are active.
    private static func classifyRecovery(in support: URL,
                                         hooks: AIRuntime.InstallHooks)
        -> RecoveryClassification {
        switch loadRecord(in: support) {
        case .invalid(let detail):
            // Repair is the owner's decision, never an automatic rewrite.
            return RecoveryClassification(
                requiresMutation: false,
                result: .failed(.invalidMarker, detail))
        case .missing:
            return classifyWithoutMarker(in: support, hooks: hooks)
        case .loaded(let record):
            return classify(record: record, in: support, hooks: hooks)
        }
    }

    private static func classifyWithoutMarker(in support: URL,
                                              hooks: AIRuntime.InstallHooks)
        -> RecoveryClassification {
        let manager = FileManager.default
        let install = AIRuntime.installDirectory(in: support)
        let backup = AIRuntime.backupDirectory(in: support)
        if isSymbolicLink(install) || isSymbolicLink(backup) {
            return RecoveryClassification(
                requiresMutation: false,
                result: .failed(.unsafePath,
                                "a runtime directory is a symbolic link"))
        }
        let liveExists = manager.fileExists(atPath: install.path)
        let backupExists = manager.fileExists(atPath: backup.path)
        let hasStaging = staleStaging(in: support).isEmpty == false
        if !liveExists && !backupExists && !hasStaging {
            return RecoveryClassification(requiresMutation: false,
                                          result: .success(.clean))
        }
        if backupExists { return .init(requiresMutation: true, result: nil) }
        if liveExists {
            guard runtimeIsValid(install, hooks: hooks) else {
                return .init(requiresMutation: false,
                             result: .failed(.liveInvalid,
                                             "the installed runtime is invalid"))
            }
            // A marker is written by adoption; that is a control-file mutation.
            return .init(requiresMutation: true, result: nil)
        }
        return .init(requiresMutation: true, result: nil)
    }

    private static func classify(record: RuntimeTransactionRecord, in support: URL,
                                 hooks: AIRuntime.InstallHooks)
        -> RecoveryClassification {
        let manager = FileManager.default
        let paths: TransactionPaths
        do {
            paths = try transactionPaths(in: support, id: record.id)
        } catch {
            return .init(requiresMutation: false,
                         result: .failed(.unsafePath, "\(error)"))
        }
        if isSymbolicLink(paths.install) || isSymbolicLink(paths.backup) {
            return .init(requiresMutation: false,
                         result: .failed(.unsafePath,
                                         "a runtime directory is a symbolic link"))
        }
        let liveExists = manager.fileExists(atPath: paths.install.path)
        let backupExists = manager.fileExists(atPath: paths.backup.path)

        switch record.state {
        case .committed:
            if liveExists, backupExists {
                // The common startup path stays read-only. Removing the backup
                // would require the exclusive lease, which a helper in another
                // app may still hold.
                if runtimeIsValid(paths.install, hooks: hooks) {
                    return .init(requiresMutation: false,
                                 result: .success(.committed, warnings: [
                                    "the previous runtime backup is kept until the next install",
                                 ]))
                }
                return .init(requiresMutation: true, result: nil)
            }
            if liveExists {
                return .init(requiresMutation: false, result: .success(.committed))
            }
            if backupExists { return .init(requiresMutation: true, result: nil) }
            return .init(requiresMutation: false,
                         result: .failed(.liveInvalid,
                                         "the committed runtime is missing"))
        case .preparing, .swapping, .rollingBack:
            // Finishing these states writes a marker or moves directories.
            return .init(requiresMutation: true, result: nil)
        }
    }

    private static func removeLeftovers(in support: URL,
                                        hooks: AIRuntime.InstallHooks) throws {
        let manager = FileManager.default
        let backup = AIRuntime.backupDirectory(in: support)
        if manager.fileExists(atPath: backup.path) {
            guard !isSymbolicLink(backup) else {
                throw AIRuntimeFailure(code: .install, previous: .kept,
                                       detail: "the old backup is a symbolic link")
            }
            do {
                try hooks.remove(backup)
            } catch {
                throw AIRuntimeFailure(
                    code: .install, previous: .kept,
                    detail: "could not remove the old backup: \(error)")
            }
        }
        for entry in staleStaging(in: support) {
            try? hooks.remove(entry)
        }
    }

    private static func staleStaging(in support: URL) -> [URL] {
        let manager = FileManager.default
        let prefix = AIRuntime.installDirectory(in: support).lastPathComponent
            + "-installing-"
        guard let entries = try? manager.contentsOfDirectory(
            at: support, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter {
            $0.lastPathComponent.hasPrefix(prefix)
                && isContained($0, in: support)
                && !isSymbolicLink($0)
        }
    }

    // MARK: - Install

    private static func installLocked(archive: URL, support: URL,
                                      hooks: AIRuntime.InstallHooks) throws {
        let manager = FileManager.default
        let previousRecord: RuntimeTransactionRecord?
        switch loadRecord(in: support) {
        case .loaded(let record): previousRecord = record
        case .missing: previousRecord = nil
        case .invalid(let detail):
            throw AIRuntimeFailure(code: .recovery, previous: .none, detail: detail)
        }

        let id = UUID().uuidString
        let paths: TransactionPaths
        do {
            paths = try transactionPaths(in: support, id: id)
        } catch {
            throw AIRuntimeFailure(code: .install, previous: .none, detail: "\(error)")
        }

        let hadPrevious = manager.fileExists(atPath: paths.install.path)
        let preparing = RuntimeTransactionRecord(id: id, state: .preparing,
                                                 hadPrevious: hadPrevious)
        do {
            try writeRecord(preparing, in: support)
            try manager.createDirectory(at: paths.staging, withIntermediateDirectories: true)
        } catch {
            throw AIRuntimeFailure(code: .install,
                                   previous: hadPrevious ? .kept : .none,
                                   detail: "\(error)")
        }

        do {
            try hooks.extract(archive, paths.staging)
            let layout = hooks.validateStructure(paths.staging)
            guard layout.ok else {
                throw AIRuntimeFailure(code: .validation,
                                       previous: hadPrevious ? .kept : .none,
                                       detail: layout.logLine)
            }
            let functional = try hooks.validateRuntime(paths.staging)
            guard functional.ok else {
                throw AIRuntimeFailure(code: .validation,
                                       previous: hadPrevious ? .kept : .none,
                                       detail: functional.logLine)
            }
        } catch is SimulatedRuntimeCrash {
            throw SimulatedRuntimeCrash()
        } catch let failure as AIRuntimeFailure {
            abandonPreparation(paths: paths, support: support,
                               record: previousRecord, hooks: hooks)
            throw failure
        } catch {
            abandonPreparation(paths: paths, support: support,
                               record: previousRecord, hooks: hooks)
            throw AIRuntimeFailure(code: .extract,
                                   previous: hadPrevious ? .kept : .none,
                                   detail: "\(error)")
        }

        do {
            try writeRecord(RuntimeTransactionRecord(id: id, state: .swapping,
                                                     hadPrevious: hadPrevious),
                            in: support)
            try hooks.checkpoint(.beforeBackupMove)

            if hadPrevious {
                guard !manager.fileExists(atPath: paths.backup.path) else {
                    throw AIRuntimeFailure(code: .install,
                                           previous: .kept,
                                           detail: "an unexpected backup was present")
                }
                try hooks.move(paths.install, paths.backup)
            }
            try hooks.checkpoint(.afterBackupMove)

            try hooks.move(paths.staging, paths.install)
            try hooks.checkpoint(.afterLiveMove)

            let live = try hooks.validateRuntime(paths.install)
            guard live.ok else {
                throw AIRuntimeFailure(code: .validation,
                                       previous: hadPrevious ? .kept : .none,
                                       detail: live.logLine)
            }

            try hooks.checkpoint(.beforeCommit)
            try writeRecord(RuntimeTransactionRecord(id: id, state: .committed,
                                                     hadPrevious: hadPrevious),
                            in: support)
            try hooks.checkpoint(.afterCommit)

            if manager.fileExists(atPath: paths.backup.path) {
                try? hooks.remove(paths.backup)
            }
            if manager.fileExists(atPath: paths.staging.path) {
                try? hooks.remove(paths.staging)
            }
        } catch is SimulatedRuntimeCrash {
            throw SimulatedRuntimeCrash()
        } catch let failure as AIRuntimeFailure {
            let previous = try rollback(paths: paths, support: support, id: id,
                                        hadPrevious: hadPrevious, hooks: hooks)
            throw AIRuntimeFailure(code: failure.code, previous: previous,
                                   detail: failure.detail)
        } catch {
            do {
                let previous = try rollback(paths: paths, support: support, id: id,
                                            hadPrevious: hadPrevious, hooks: hooks)
                throw AIRuntimeFailure(code: .install, previous: previous,
                                       detail: "\(error)")
            } catch is SimulatedRuntimeCrash {
                throw SimulatedRuntimeCrash()
            } catch let failure as AIRuntimeFailure {
                throw failure
            } catch {
                throw AIRuntimeFailure(code: .install, previous: .preserved,
                                       detail: "\(error)")
            }
        }
    }

    private static func abandonPreparation(paths: TransactionPaths, support: URL,
                                           record: RuntimeTransactionRecord?,
                                           hooks: AIRuntime.InstallHooks) {
        try? hooks.remove(paths.staging)
        if let record {
            try? writeRecord(record, in: support)
        } else {
            removeRecord(in: support)
        }
    }

    private static func rollback(paths: TransactionPaths, support: URL, id: String,
                                 hadPrevious: Bool,
                                 hooks: AIRuntime.InstallHooks)
        throws -> AIRuntimeFailure.PreviousRuntime {
        let manager = FileManager.default
        let backupExists = manager.fileExists(atPath: paths.backup.path)

        // The backup move is the first destructive step. If it never happened,
        // the live directory is still the old, known-good runtime and must not
        // be moved aside.
        if hadPrevious, !backupExists {
            if manager.fileExists(atPath: paths.install.path) {
                try? writeRecord(RuntimeTransactionRecord(id: id, state: .committed,
                                                          hadPrevious: true),
                                 in: support)
                try? hooks.remove(paths.staging)
                return .kept
            }
            return .lost
        }

        do {
            try writeRecord(RuntimeTransactionRecord(id: id, state: .rollingBack,
                                                     hadPrevious: hadPrevious),
                            in: support)
            try hooks.checkpoint(.duringRollback)
        } catch is SimulatedRuntimeCrash {
            throw SimulatedRuntimeCrash()
        } catch {
            return hadPrevious ? .preserved : .none
        }

        var rejected: URL?
        if manager.fileExists(atPath: paths.install.path) {
            do {
                rejected = try setAside(paths.install, support: support, id: id,
                                        hooks: hooks)
            } catch {
                return hadPrevious ? .preserved : .none
            }
        }

        guard hadPrevious else {
            if let rejected { try? hooks.remove(rejected) }
            try? hooks.remove(paths.staging)
            removeRecord(in: support)
            return .none
        }

        guard manager.fileExists(atPath: paths.backup.path) else {
            return .lost
        }
        do {
            try hooks.move(paths.backup, paths.install)
        } catch {
            return .preserved
        }
        let restored = try? hooks.validateRuntime(paths.install)
        guard restored?.ok == true else {
            return .lost
        }
        try? writeRecord(RuntimeTransactionRecord(id: id, state: .committed,
                                                  hadPrevious: hadPrevious),
                         in: support)
        if let rejected { try? hooks.remove(rejected) }
        try? hooks.remove(paths.staging)
        return .kept
    }

    // MARK: - Recovery

    private static func recoverLocked(in support: URL,
                                      hooks: AIRuntime.InstallHooks) -> AIRuntimeRecoveryResult {
        switch loadRecord(in: support) {
        case .invalid(let detail):
            return .failed(.invalidMarker, detail)
        case .loaded(let record):
            return recover(record: record, in: support, hooks: hooks)
        case .missing:
            return recoverWithoutMarker(in: support, hooks: hooks)
        }
    }

    private static func recover(record: RuntimeTransactionRecord, in support: URL,
                                hooks: AIRuntime.InstallHooks) -> AIRuntimeRecoveryResult {
        let paths: TransactionPaths
        do {
            paths = try transactionPaths(in: support, id: record.id)
        } catch {
            return .failed(.unsafePath, "\(error)")
        }
        let manager = FileManager.default
        let liveExists = manager.fileExists(atPath: paths.install.path)
        let backupExists = manager.fileExists(atPath: paths.backup.path)
        if isSymbolicLink(paths.install) || isSymbolicLink(paths.backup) {
            return .failed(.unsafePath, "a runtime directory is a symbolic link")
        }

        switch record.state {
        case .committed:
            guard liveExists || backupExists else {
                return .failed(.liveInvalid, "the committed runtime is missing")
            }
            if backupExists {
                if runtimeIsValid(paths.install, hooks: hooks) {
                    var warnings: [String] = []
                    do {
                        try hooks.remove(paths.backup)
                    } catch {
                        warnings.append("could not remove the old backup: \(error)")
                    }
                    warnings += cleanup(paths: paths, hooks: hooks,
                                        includeBackup: false)
                    return .success(.committed, warnings: warnings)
                }
                return restore(paths: paths, support: support, id: record.id,
                               hadPrevious: record.hadPrevious, hooks: hooks)
            }
            guard liveExists else {
                return .failed(.liveInvalid, "the committed runtime is missing")
            }
            // Selection runs the full functional contract before launch; this
            // path only proves that no unfinished transaction remains.
            return .success(.committed,
                            warnings: cleanup(paths: paths, hooks: hooks,
                                              includeBackup: false))

        case .preparing, .swapping, .rollingBack:
            if backupExists {
                if runtimeIsValid(paths.backup, hooks: hooks) {
                    return restore(paths: paths, support: support, id: record.id,
                                   hadPrevious: record.hadPrevious, hooks: hooks)
                }
                if runtimeIsValid(paths.install, hooks: hooks) {
                    return adopt(paths: paths, support: support, id: record.id,
                                 hadPrevious: record.hadPrevious, hooks: hooks,
                                 status: .adoptedLive,
                                 warning: "the backup failed validation and was left in place")
                }
                return .failed(.backupInvalid,
                               "neither the backup nor the live runtime is safe")
            }
            guard liveExists, runtimeIsValid(paths.install, hooks: hooks) else {
                if record.state == .preparing, !record.hadPrevious {
                    // A first install died before a live runtime existed. There
                    // is nothing to restore, so the marker is retired instead
                    // of reporting a permanently broken runtime.
                    try? hooks.remove(paths.staging)
                    removeRecord(in: support)
                    return .success(.clean)
                }
                return .failed(.liveInvalid, "the live runtime is missing or invalid")
            }
            return adopt(paths: paths, support: support, id: record.id,
                         hadPrevious: record.hadPrevious, hooks: hooks,
                         status: record.state == .rollingBack ? .rolledBack : .adoptedLive)
        }
    }

    private static func recoverWithoutMarker(in support: URL,
                                             hooks: AIRuntime.InstallHooks)
        -> AIRuntimeRecoveryResult {
        let id = UUID().uuidString
        let paths: TransactionPaths
        do {
            paths = try transactionPaths(in: support, id: id)
        } catch {
            return .failed(.unsafePath, "\(error)")
        }
        let manager = FileManager.default
        let liveExists = manager.fileExists(atPath: paths.install.path)
        let backupExists = manager.fileExists(atPath: paths.backup.path)
        if isSymbolicLink(paths.install) || isSymbolicLink(paths.backup) {
            return .failed(.unsafePath, "a runtime directory is a symbolic link")
        }

        if backupExists {
            if runtimeIsValid(paths.backup, hooks: hooks) {
                let result = restore(paths: paths, support: support, id: id,
                                     hadPrevious: true, hooks: hooks)
                if result.isSuccess {
                    return merge(result, warnings: cleanupLegacyStaging(in: support,
                                                                       hooks: hooks))
                }
                return result
            }
            if liveExists, runtimeIsValid(paths.install, hooks: hooks) {
                var result = adopt(paths: paths, support: support, id: id,
                                   hadPrevious: true, hooks: hooks,
                                   status: .adoptedLive,
                                   warning: "an unreadable backup was left in place")
                result = merge(result, warnings: cleanupLegacyStaging(in: support,
                                                                     hooks: hooks))
                return result
            }
            return .failed(.backupInvalid,
                           "neither the backup nor the live runtime is safe")
        }

        if liveExists {
            guard runtimeIsValid(paths.install, hooks: hooks) else {
                return .failed(.liveInvalid, "the installed runtime is invalid")
            }
            let result = adopt(paths: paths, support: support, id: id,
                               hadPrevious: true, hooks: hooks,
                               status: .adoptedLive)
            return merge(result, warnings: cleanupLegacyStaging(in: support,
                                                                hooks: hooks))
        }

        return .success(.clean, warnings: cleanupLegacyStaging(in: support,
                                                               hooks: hooks))
    }

    private static func restore(paths: TransactionPaths, support: URL, id: String,
                                hadPrevious: Bool,
                                hooks: AIRuntime.InstallHooks) -> AIRuntimeRecoveryResult {
        guard runtimeIsValid(paths.backup, hooks: hooks) else {
            return .failed(.backupInvalid, "the backup does not pass validation")
        }
        do {
            try writeRecord(RuntimeTransactionRecord(id: id, state: .rollingBack,
                                                     hadPrevious: hadPrevious),
                            in: support)
        } catch {
            return .failed(.markerWriteFailed, "\(error)")
        }

        var rejected: URL?
        if FileManager.default.fileExists(atPath: paths.install.path) {
            do {
                rejected = try setAside(paths.install, support: support, id: id,
                                        hooks: hooks)
            } catch {
                return .failed(.moveFailed, "could not move the live runtime aside: \(error)")
            }
        }

        do {
            try hooks.move(paths.backup, paths.install)
        } catch {
            return .failed(.moveFailed, "could not restore the backup: \(error)")
        }

        guard runtimeIsValid(paths.install, hooks: hooks) else {
            return .failed(.validationFailed, "the restored runtime did not pass validation")
        }
        do {
            try writeRecord(RuntimeTransactionRecord(id: id, state: .committed,
                                                     hadPrevious: hadPrevious),
                            in: support)
        } catch {
            return .failed(.markerWriteFailed, "\(error)")
        }

        var warnings: [String] = []
        if let rejected {
            do {
                try hooks.remove(rejected)
            } catch {
                warnings.append("could not remove the rejected runtime: \(error)")
            }
        }
        warnings += cleanup(paths: paths, hooks: hooks, includeBackup: false)
        return .success(.restoredBackup, warnings: warnings)
    }

    private static func adopt(paths: TransactionPaths, support: URL, id: String,
                              hadPrevious: Bool, hooks: AIRuntime.InstallHooks,
                              status: AIRuntimeRecoveryResult.Status,
                              warning: String? = nil) -> AIRuntimeRecoveryResult {
        guard runtimeIsValid(paths.install, hooks: hooks) else {
            return .failed(.validationFailed, "the live runtime did not pass validation")
        }
        do {
            try writeRecord(RuntimeTransactionRecord(id: id, state: .committed,
                                                     hadPrevious: hadPrevious),
                            in: support)
        } catch {
            return .failed(.markerWriteFailed, "\(error)")
        }
        var warnings: [String] = []
        if let warning { warnings.append(warning) }
        warnings += cleanup(paths: paths, hooks: hooks, includeBackup: false)
        return .success(status, warnings: warnings)
    }

    private static func cleanup(paths: TransactionPaths, hooks: AIRuntime.InstallHooks,
                                includeBackup: Bool) -> [String] {
        let manager = FileManager.default
        var warnings: [String] = []
        if manager.fileExists(atPath: paths.staging.path) {
            do {
                try hooks.remove(paths.staging)
            } catch {
                warnings.append("could not remove staging data: \(error)")
            }
        }
        if includeBackup, manager.fileExists(atPath: paths.backup.path) {
            do {
                try hooks.remove(paths.backup)
            } catch {
                warnings.append("could not remove the backup: \(error)")
            }
        }
        return warnings
    }

    private static func cleanupLegacyStaging(in support: URL,
                                             hooks: AIRuntime.InstallHooks) -> [String] {
        let manager = FileManager.default
        let prefix = AIRuntime.installDirectory(in: support).lastPathComponent
            + "-installing-"
        guard let entries = try? manager.contentsOfDirectory(
            at: support, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var warnings: [String] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let name = entry.lastPathComponent
            guard isContained(entry, in: support), !isSymbolicLink(entry) else {
                warnings.append("ignored unsafe staging entry \(name)")
                continue
            }
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Only sweep directories that cannot belong to an active install.
            if let modified, Date().timeIntervalSince(modified) < 3600 { continue }
            do {
                try hooks.remove(entry)
            } catch {
                warnings.append("could not remove stale staging \(name): \(error)")
            }
        }
        return warnings
    }

    // MARK: - Marker

    private enum MarkerLoad {
        case missing
        case loaded(RuntimeTransactionRecord)
        case invalid(String)
    }

    private static func loadRecord(in support: URL) -> MarkerLoad {
        let marker = support.appendingPathComponent(RuntimeTransactionRecord.fileName)
        var info = stat()
        let status = marker.path.withCString { lstat($0, &info) }
        if status != 0 { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .invalid("the transaction marker is not a regular file")
        }
        // O_NOFOLLOW closes the window between the lstat above and the read: a
        // marker swapped for a symlink is rejected instead of followed.
        let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return .invalid("the transaction marker cannot be opened safely")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = buffer.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            if got < 0 {
                close(descriptor)
                return .invalid("the transaction marker is unreadable")
            }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
            if data.count > 64 * 1024 {
                close(descriptor)
                return .invalid("the transaction marker is unreasonably large")
            }
        }
        close(descriptor)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .invalid("the transaction marker is unreadable")
        }
        let allowed: Set<String> = ["id", "state", "had_previous", "created"]
        guard Set(object.keys).isSubset(of: allowed) else {
            return .invalid("the transaction marker has unexpected fields")
        }
        guard let rawID = object["id"] as? String,
              let uuid = UUID(uuidString: rawID),
              uuid.uuidString == rawID.uppercased(),
              let rawState = object["state"] as? String,
              let state = RuntimeTransactionRecord.State(rawValue: rawState),
              let hadPrevious = object["had_previous"] as? Bool else {
            return .invalid("the transaction marker is malformed")
        }
        return .loaded(RuntimeTransactionRecord(id: uuid.uuidString,
                                                state: state,
                                                hadPrevious: hadPrevious))
    }

    private static func writeRecord(_ record: RuntimeTransactionRecord,
                                    in support: URL) throws {
        let object: [String: Any] = [
            "id": record.id,
            "state": record.state.rawValue,
            "had_previous": record.hadPrevious,
            "created": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        let marker = support.appendingPathComponent(RuntimeTransactionRecord.fileName)
        try data.write(to: marker, options: .atomic)
        try syncFile(marker)
        syncDirectory(support)
    }

    private static func removeRecord(in support: URL) {
        let marker = support.appendingPathComponent(RuntimeTransactionRecord.fileName)
        try? FileManager.default.removeItem(at: marker)
    }

    private static func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AIRuntimeFailure(code: .install, previous: .none,
                                                    detail: "could not open the marker") }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw AIRuntimeFailure(code: .install, previous: .none,
                                   detail: "could not flush the marker")
        }
    }

    private static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    // MARK: - Paths

    private struct TransactionPaths {
        let install: URL
        let backup: URL
        let staging: URL
    }

    private static func transactionPaths(in support: URL, id: String) throws
        -> TransactionPaths {
        let installName = AIRuntime.installDirectory(in: support).lastPathComponent
        let backupName = AIRuntime.backupDirectory(in: support).lastPathComponent
        let install = try safeURL(installName, in: support)
        let backup = try safeURL(backupName, in: support)
        let staging = try safeURL("\(installName)-installing-\(id)", in: support)
        return TransactionPaths(install: install, backup: backup, staging: staging)
    }

    private static func safeURL(_ name: String, in support: URL) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw RuntimePathError("an unsafe transaction directory name was rejected")
        }
        let url = support.appendingPathComponent(name, isDirectory: true)
        guard isContained(url, in: support) else {
            throw RuntimePathError("a transaction path escapes the support directory")
        }
        guard !isSymbolicLink(url) else {
            throw RuntimePathError("a transaction path is a symbolic link")
        }
        return url
    }

    private static func setAside(_ live: URL, support: URL, id: String,
                                 hooks: AIRuntime.InstallHooks) throws -> URL {
        var index = 1
        let prefix = AIRuntime.installDirectory(in: support).lastPathComponent
            + "-rejected-\(id)"
        var destination = try safeURL(prefix, in: support)
        while FileManager.default.fileExists(atPath: destination.path) {
            index += 1
            destination = try safeURL("\(prefix)-\(index)", in: support)
        }
        try hooks.move(live, destination)
        return destination
    }

    // MARK: - Helpers

    private static func verifyArchive(_ archive: URL, matches package: AIRuntime.Package) throws {
        if package.bytes > 0 {
            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard size == Int(package.bytes) else {
                throw AIRuntimeFailure(code: .checksum, previous: .none)
            }
        }
        let digest = try AIRuntime.sha256(of: archive)
        guard digest == package.sha256.lowercased() else {
            throw AIRuntimeFailure(code: .checksum, previous: .none)
        }
    }

    private static func runtimeIsValid(_ root: URL,
                                       hooks: AIRuntime.InstallHooks) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path),
              !isSymbolicLink(root) else { return false }
        do {
            return try hooks.validateRuntime(root).ok
        } catch {
            return false
        }
    }

    private static func merge(_ result: AIRuntimeRecoveryResult,
                              warnings: [String]) -> AIRuntimeRecoveryResult {
        AIRuntimeRecoveryResult(status: result.status,
                                failure: result.failure,
                                warnings: result.warnings + warnings)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        return result == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isContained(_ candidate: URL, in base: URL) -> Bool {
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let root = base.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    private struct RuntimePathError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
