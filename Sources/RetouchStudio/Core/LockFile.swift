import Darwin
import Foundation

struct LockFileError: Error, CustomStringConvertible, Equatable {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A permanent advisory lock file.
///
/// The file is created once and never unlinked, so its inode is stable across
/// launches. A holder verifies that the path still names the inode it opened;
/// an unlink-and-recreate race therefore fails closed instead of silently
/// locking a different file. The mode and owner are checked so another user
/// cannot substitute a file the app would trust.
final class LockFile {
    let url: URL
    let device: dev_t
    let inode: ino_t

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32, device: dev_t, inode: ino_t) {
        self.url = url
        self.descriptor = descriptor
        self.device = device
        self.inode = inode
    }

    deinit { close() }

    static func open(_ url: URL) throws -> LockFile {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let path = url.path
        // A tiny retry loop covers the only benign mismatch: another process
        // created the file between our open and our lstat.
        for _ in 0..<16 {
            let fd = path.withCString {
                Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard fd >= 0 else {
                throw LockFileError("could not open \(url.lastPathComponent)")
            }
            var opened = stat()
            guard fstat(fd, &opened) == 0,
                  (opened.st_mode & S_IFMT) == S_IFREG,
                  opened.st_uid == geteuid(),
                  (opened.st_mode & 0o077) == 0,
                  opened.st_nlink == 1 else {
                Darwin.close(fd)
                throw LockFileError(
                    "\(url.lastPathComponent) is not a private regular lock file")
            }
            var named = stat()
            let status = path.withCString { lstat($0, &named) }
            guard status == 0,
                  named.st_dev == opened.st_dev,
                  named.st_ino == opened.st_ino else {
                Darwin.close(fd)
                continue
            }
            return LockFile(url: url, descriptor: fd,
                            device: opened.st_dev, inode: opened.st_ino)
        }
        throw LockFileError("\(url.lastPathComponent) changed while it was opened")
    }

    @discardableResult
    func tryAcquire(exclusive: Bool) -> Bool {
        let operation = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        return flock(descriptor, operation) == 0
    }

    /// Waits up to `timeout` for the lock. Expiry is a retryable busy answer,
    /// never permission to continue without the lock.
    func acquire(exclusive: Bool, timeout: TimeInterval, busyMessage: String) throws {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if tryAcquire(exclusive: exclusive) { return }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw LockFileError("could not lock \(url.lastPathComponent)")
            }
            if Date() >= deadline { throw AIRuntimeBusyError(busyMessage) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Releases the lock without closing the file, for a lock that is reused
    /// across a long-lived store. Never call this on a lease whose descriptor
    /// was duplicated into a child: `LOCK_UN` acts on the shared open file
    /// description and would drop the child's lease too.
    func unlock() {
        stateLock.lock()
        let fd = descriptor
        stateLock.unlock()
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
    }

    /// A duplicate descriptor that shares the open file description, and
    /// therefore the lock. Used to hand a child its own lease holder.
    func duplicateDescriptor() throws -> Int32 {
        stateLock.lock()
        let fd = descriptor
        stateLock.unlock()
        guard fd >= 0 else { throw LockFileError("the lock is already closed") }
        let copy = dup(fd)
        guard copy >= 0 else {
            throw LockFileError("could not duplicate \(url.lastPathComponent)")
        }
        return copy
    }

    /// Closing releases the lock only when no duplicate descriptor still
    /// refers to the same open file description. Never call `flock(LOCK_UN)`
    /// here: a helper that inherited a duplicated descriptor shares this open
    /// file description, so an explicit unlock in the parent would drop the
    /// lease the child is supposed to own.
    func close() {
        stateLock.lock()
        let fd = descriptor
        descriptor = -1
        stateLock.unlock()
        guard fd >= 0 else { return }
        Darwin.close(fd)
    }
}
