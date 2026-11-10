import Darwin
import Foundation

/// Starts the protocol-v2 helper with a lease the child owns.
///
/// The parent opens the usage lock, takes a shared lease and duplicates the
/// descriptor. `posix_spawn` maps that descriptor to a fixed number in the
/// child; the parent then closes its own copies. From that moment the kernel
/// holds the lease through the child, so a parent crash releases nothing and
/// the child's exit releases it without any cleanup code.
enum RuntimeBootstrap {
    /// Fixed child descriptor. Passed to the worker as `--usage-fd`.
    static let usageDescriptor: Int32 = 197

    struct Configuration {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let log: URL
        let lease: RuntimeUsageLease
    }

    static func spawn(_ configuration: Configuration) throws -> ChildProcess {
        let manager = FileManager.default
        try manager.createDirectory(at: configuration.log.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        if !manager.fileExists(atPath: configuration.log.path) {
            manager.createFile(atPath: configuration.log.path, contents: nil)
        }
        let log = configuration.log.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard log >= 0 else { throw LockFileError("could not open the helper log") }
        defer { close(log) }

        let inherited = try configuration.lease.duplicateForChild()
        defer { close(inherited) }
        let child = try ChildProcess.spawn(
            executable: configuration.executable,
            arguments: configuration.arguments,
            environment: configuration.environment,
            standardOutput: log, standardError: log,
            descriptors: [(child: usageDescriptor, parent: inherited)])
        // The child's descriptor is what holds the lease now. Closing ours is
        // required: otherwise a parent crash would keep the lock through the
        // orphaned descriptor, pinning the runtime until this process exits.
        configuration.lease.release()
        return child
    }

    static func preparingRecord(parent: ProcessIdentity, socket: URL,
                                previous: HelperRegistry.Record?,
                                now: Date = Date()) -> HelperRegistry.Record {
        HelperRegistry.Record(
            schema: HelperRegistry.schemaVersion,
            protocolVersion: HelperRegistry.protocolVersion,
            generation: UUID().uuidString,
            launchNonce: UUID().uuidString,
            revision: (previous?.revision ?? 0) + 1,
            state: .preparing,
            parent: parent,
            helper: nil,
            socket: socket.path,
            createdAt: now.timeIntervalSince1970,
            updatedAt: now.timeIntervalSince1970,
            shutdown: nil,
            clients: [],
            lastError: nil)
    }

    static func arguments(socket: URL, jobs: URL, models: URL, allowRoots: [URL],
                          generation: String, nonce: String, registry: URL) -> [String] {
        var arguments = ["-m", "retouch_ai_worker", "serve",
                         "--socket", socket.path,
                         "--jobs", jobs.path,
                         "--models", models.path]
        for root in allowRoots {
            arguments += ["--allow-root", root.path]
        }
        arguments += ["--protocol-version", String(HelperRegistry.protocolVersion),
                      "--helper-generation", generation,
                      "--launch-nonce", nonce,
                      "--registry", registry.path,
                      "--usage-fd", String(usageDescriptor)]
        return arguments
    }

    /// Observes the registry until the exact launch becomes ready. Expiry is a
    /// retryable answer; a helper that is still progressing is never killed.
    static func waitForReady(store: HelperRegistryStore,
                             generation: String, nonce: String,
                             timeout: TimeInterval) -> HelperRegistry.Record? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if case .loaded(let record) = store.read(),
               record.state == .ready,
               record.generation == generation,
               record.launchNonce == nonce {
                return record
            }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
