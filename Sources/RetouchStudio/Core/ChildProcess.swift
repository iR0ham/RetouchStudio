import Darwin
import Foundation

/// A child process started with an explicit file descriptor set.
///
/// Foundation's `Process` cannot hand an arbitrary descriptor to a child, and
/// the runtime lease must outlive the parent as a child-held lock. Spawning
/// with `POSIX_SPAWN_CLOEXEC_DEFAULT` and explicit `dup2` file actions makes the
/// inherited set auditable: stdin is `/dev/null`, stdout/stderr point at the
/// requested log, and only the runtime lease is added deliberately.
final class ChildProcess {
    let pid: pid_t

    private let stateLock = NSLock()
    private var status: Int32?
    private var handlers: [() -> Void] = []

    struct SpawnFailure: Error, CustomStringConvertible {
        let operation: String
        let code: Int32
        var description: String { "\(operation) failed (errno \(code))" }
    }

    private init(pid: pid_t) {
        self.pid = pid
        reapOnExit()
    }

    static func spawn(executable: URL, arguments: [String],
                      environment: [String: String],
                      standardOutput: Int32? = nil,
                      standardError: Int32? = nil,
                      descriptors: [(child: Int32, parent: Int32)] = []) throws
        -> ChildProcess {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions),
                  "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        try check(posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin action")
        if let standardOutput {
            try check(posix_spawn_file_actions_adddup2(
                &actions, standardOutput, STDOUT_FILENO), "stdout action")
        }
        if let standardError {
            try check(posix_spawn_file_actions_adddup2(
                &actions, standardError, STDERR_FILENO), "stderr action")
        }
        for descriptor in descriptors {
            guard descriptor.parent >= 0, descriptor.child > STDERR_FILENO,
                  descriptor.child < 1024 else {
                throw SpawnFailure(operation: "descriptor action", code: EINVAL)
            }
            try check(posix_spawn_file_actions_adddup2(
                &actions, descriptor.parent, descriptor.child), "descriptor action")
        }
        try check(posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)), "spawn flags")

        var argv: [UnsafeMutablePointer<CChar>?] =
            ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                executable.path.withCString { path in
                    posix_spawn(&pid, path, &actions, &attributes,
                                argvBuffer.baseAddress, envpBuffer.baseAddress)
                }
            }
        }
        guard result == 0 else {
            throw SpawnFailure(operation: "posix_spawn", code: result)
        }
        return ChildProcess(pid: pid)
    }

    private static func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else { throw SpawnFailure(operation: operation, code: result) }
    }

    private func reapOnExit() {
        let pid = self.pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 {
                if errno != EINTR { return }
            }
            let code: Int32
            if (raw & 0x7f) == 0 {
                code = (raw >> 8) & 0xff
            } else {
                code = 128 + (raw & 0x7f)
            }
            self?.recordExit(code)
        }
    }

    private func recordExit(_ code: Int32) {
        stateLock.lock()
        guard status == nil else { stateLock.unlock(); return }
        status = code
        let callbacks = handlers
        handlers.removeAll()
        stateLock.unlock()
        for callback in callbacks { callback() }
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status == nil
    }

    var terminationStatus: Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status
    }

    func onExit(_ handler: @escaping () -> Void) {
        stateLock.lock()
        if status != nil {
            stateLock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        stateLock.unlock()
    }

    func send(_ signal: Int32) {
        guard isRunning else { return }
        kill(pid, signal)
    }

    func terminate() { send(SIGTERM) }

    /// Returns true when the process has exited by the deadline.
    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !isRunning
    }

    func waitUntilExit() {
        while isRunning { Thread.sleep(forTimeInterval: 0.02) }
    }
}
