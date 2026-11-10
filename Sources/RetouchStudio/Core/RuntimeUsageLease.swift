import Darwin
import Foundation

/// A shared/exclusive lease over one runtime tree.
///
/// A process that runs something from the runtime (the AI helper or the model
/// CLI) holds a shared lease for as long as the process lives. An installer
/// takes the exclusive lease before it touches the tree. The lock file is
/// permanent, private and never unlinked, so its inode is stable and a
/// substitute file is rejected by `LockFile`.
///
/// For the downloaded runtime the helper does not take the lease itself: the
/// launcher duplicates the locked descriptor into the child before exec. The
/// kernel then keeps the lock for the child's lifetime, including a crash of
/// the launching app. That is what makes orphan recovery safe: taking the
/// exclusive lease proves that no consumer still holds one.
final class RuntimeUsageLease {
    static let fileName = "runtime-usage.lock"

    enum Mode: String {
        case shared
        case exclusive
    }

    private let stateLock = NSLock()
    private var lockFile: LockFile?

    private init(lockFile: LockFile) {
        self.lockFile = lockFile
    }

    /// A non-blocking shared lease. Failing here means an installer already
    /// owns the runtime exclusively; the caller must not start a new user.
    static func acquireShared(support: URL) throws -> RuntimeUsageLease {
        try acquire(support: support, mode: .shared, timeout: 0)
    }

    /// Waits up to `timeout` for every shared holder to go away. A timeout
    /// throws instead of proceeding: the installer must never swap files that
    /// a live consumer is still using.
    static func acquireExclusive(support: URL, timeout: TimeInterval) throws
        -> RuntimeUsageLease {
        try acquire(support: support, mode: .exclusive, timeout: timeout)
    }

    private static func acquire(support: URL, mode: Mode,
                                timeout: TimeInterval) throws -> RuntimeUsageLease {
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        let file = try LockFile.open(support.appendingPathComponent(fileName))
        do {
            try file.acquire(
                exclusive: mode == .exclusive, timeout: timeout,
                busyMessage: mode == .shared
                    ? "the AI runtime is being replaced"
                    : "the AI runtime is in use by another Retouch Studio window")
        } catch {
            file.close()
            throw error
        }
        return RuntimeUsageLease(lockFile: file)
    }

    /// A descriptor that shares this lease and can be handed to a child.
    func duplicateForChild() throws -> Int32 {
        stateLock.lock()
        let file = lockFile
        stateLock.unlock()
        guard let file else {
            throw AIRuntimeBusyError("the runtime usage lease is already released")
        }
        return try file.duplicateDescriptor()
    }

    var isHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockFile != nil
    }

    /// Idempotent: a lease may be released by the code that owns it and again
    /// by a process termination handler.
    func release() {
        stateLock.lock()
        let file = lockFile
        lockFile = nil
        stateLock.unlock()
        file?.close()
    }

    deinit { release() }
}

/// A retryable answer for "something else is using the runtime". It is kept
/// separate from the transaction failure types so the installer can report a
/// busy runtime without pretending anything was replaced or damaged.
struct AIRuntimeBusyError: LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}
