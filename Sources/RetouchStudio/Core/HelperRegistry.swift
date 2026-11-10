import Darwin
import Foundation

/// The single durable record describing the protocol-v2 helper.
///
/// Three identifiers have three different meanings and are never reused:
/// `generation` is immutable for the life of one helper, `launchNonce` is unique
/// per launch attempt and fences a child that lost the race, and `revision`
/// increases on every successful registry mutation and is the only value used
/// for compare-and-swap.
enum HelperRegistry {
    static let schemaVersion = 2
    static let protocolVersion = 2
    static let fileName = "helper-registry.json"
    static let lockName = "helper-registry.lock"

    enum State: String, Codable, CaseIterable {
        case preparing
        case starting
        case ready
        case stopping
        case stopped
        case failed
    }

    struct Shutdown: Codable, Equatable {
        let transactionID: String
        let owner: ProcessIdentity
        let startedAt: Double
        let revisionAtStart: Int
        let generation: String

        enum CodingKeys: String, CodingKey {
            case transactionID = "transaction_id"
            case owner
            case startedAt = "started_at"
            case revisionAtStart = "revision_at_start"
            case generation
        }
    }

    struct Client: Codable, Equatable {
        let id: String
        let identity: ProcessIdentity
        var lastSeen: Double

        enum CodingKeys: String, CodingKey {
            case id
            case identity
            case lastSeen = "last_seen"
        }
    }

    struct Record: Codable, Equatable {
        var schema: Int
        var protocolVersion: Int
        var generation: String
        var launchNonce: String
        var revision: Int
        var state: State
        var parent: ProcessIdentity?
        var helper: ProcessIdentity?
        var socket: String
        var createdAt: Double
        var updatedAt: Double
        var shutdown: Shutdown?
        var clients: [Client]
        var lastError: String?

        enum CodingKeys: String, CodingKey {
            case schema
            case protocolVersion = "protocol_version"
            case generation
            case launchNonce = "launch_nonce"
            case revision
            case state
            case parent
            case helper
            case socket
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case shutdown
            case clients
            case lastError = "last_error"
        }

        func bumped(at now: Date) -> Record {
            var copy = self
            copy.revision += 1
            copy.updatedAt = now.timeIntervalSince1970
            return copy
        }

        func failed(_ detail: String, at now: Date) -> Record {
            var copy = self
            copy.state = .failed
            copy.parent = nil
            copy.helper = nil
            copy.shutdown = nil
            copy.lastError = detail
            copy.updatedAt = now.timeIntervalSince1970
            copy.revision += 1
            return copy
        }

        func validated() throws -> Record {
            try HelperRegistry.validate(self)
            return self
        }
    }

    enum Load {
        case missing
        case loaded(Record)
        case invalid(String)
    }

    // MARK: - Validation

    private static let topKeys: Set<String> = [
        "schema", "protocol_version", "generation", "launch_nonce", "revision",
        "state", "parent", "helper", "socket", "created_at", "updated_at",
        "shutdown", "clients", "last_error",
    ]
    private static let identityKeys: Set<String> =
        ["pid", "start_seconds", "start_microseconds", "executable"]
    private static let shutdownKeys: Set<String> =
        ["transaction_id", "owner", "started_at", "revision_at_start", "generation"]
    private static let clientKeys: Set<String> = ["id", "identity", "last_seen"]

    private static func validate(_ record: Record) throws {
        guard record.schema == schemaVersion else {
            throw LockFileError("the helper registry has an unsupported schema")
        }
        guard record.protocolVersion == protocolVersion else {
            throw LockFileError("the helper registry has an unsupported protocol")
        }
        guard UUID(uuidString: record.generation) != nil,
              UUID(uuidString: record.launchNonce) != nil else {
            throw LockFileError("the helper registry has a malformed identifier")
        }
        guard record.revision >= 0 else {
            throw LockFileError("the helper registry has a negative revision")
        }
        guard !record.socket.isEmpty, !record.socket.contains("\0") else {
            throw LockFileError("the helper registry has an unsafe socket path")
        }
        guard record.updatedAt + 0.001 >= record.createdAt else {
            throw LockFileError("the helper registry has an inconsistent timestamp")
        }

        switch record.state {
        case .preparing:
            guard record.parent != nil, record.helper == nil, record.shutdown == nil else {
                throw LockFileError("a preparing registry entry is inconsistent")
            }
        case .starting, .ready:
            guard record.helper != nil, record.shutdown == nil else {
                throw LockFileError("a running registry entry is inconsistent")
            }
        case .stopping:
            guard record.helper != nil, let shutdown = record.shutdown,
                  shutdown.generation == record.generation else {
                throw LockFileError("a stopping registry entry is inconsistent")
            }
        case .stopped, .failed:
            if let shutdown = record.shutdown, shutdown.generation != record.generation {
                throw LockFileError("a stopped registry entry names another helper")
            }
        }

        var ids = Set<String>()
        for client in record.clients {
            guard !client.id.isEmpty, UUID(uuidString: client.id) != nil,
                  client.identity.pid > 0 else {
                throw LockFileError("the helper registry has a malformed client")
            }
            guard ids.insert(client.id).inserted else {
                throw LockFileError("the helper registry repeats a client")
            }
        }
    }

    private static func unexpectedKeys(in object: [String: Any]) -> String? {
        guard Set(object.keys).isSubset(of: topKeys) else {
            return "the helper registry has unexpected fields"
        }
        for key in ["parent", "helper"] {
            if let identity = object[key] as? [String: Any],
               !Set(identity.keys).isSubset(of: identityKeys) {
                return "the helper registry has unexpected identity fields"
            }
        }
        if let shutdown = object["shutdown"] as? [String: Any] {
            guard Set(shutdown.keys).isSubset(of: shutdownKeys) else {
                return "the helper registry has unexpected shutdown fields"
            }
            if let owner = shutdown["owner"] as? [String: Any],
               !Set(owner.keys).isSubset(of: identityKeys) {
                return "the helper registry has unexpected owner fields"
            }
        }
        if let clients = object["clients"] as? [[String: Any]] {
            for client in clients {
                guard Set(client.keys).isSubset(of: clientKeys) else {
                    return "the helper registry has unexpected client fields"
                }
                if let identity = client["identity"] as? [String: Any],
                   !Set(identity.keys).isSubset(of: identityKeys) {
                    return "the helper registry has unexpected client identity fields"
                }
            }
        }
        return nil
    }

    // MARK: - Reading

    static func read(from url: URL) -> Load {
        var info = stat()
        let status = url.path.withCString { lstat($0, &info) }
        if status != 0 { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o077) == 0 else {
            return .invalid("the helper registry is not a private regular file")
        }
        let fd = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            return .invalid("the helper registry cannot be opened safely")
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if got < 0 { return .invalid("the helper registry is unreadable") }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
            if data.count > 1 << 20 {
                return .invalid("the helper registry is unreasonably large")
            }
        }
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .invalid("the helper registry is unreadable")
        }
        if let problem = unexpectedKeys(in: object) { return .invalid(problem) }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            try validate(record)
            return .loaded(record)
        } catch {
            return .invalid("the helper registry is malformed: \(error)")
        }
    }
}

/// Serializes read-modify-write of the registry and persists it atomically.
/// The lock file is permanent; it is never unlinked, so the inode cannot be
/// swapped between two processes that both "create" it.
final class HelperRegistryStore {
    let root: URL
    private let target: URL
    private let lock: LockFile

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.target = root.appendingPathComponent(HelperRegistry.fileName)
        self.lock = try LockFile.open(
            root.appendingPathComponent(HelperRegistry.lockName))
    }

    func read() -> HelperRegistry.Load { HelperRegistry.read(from: target) }

    /// Holds the registry lock for a read-only decision.
    func inspect<T>(timeout: TimeInterval = 5,
                    _ body: (HelperRegistry.Load) throws -> T) throws -> T {
        try update(timeout: timeout) { load in (nil, try body(load)) }
    }

    /// Runs `body` while holding the registry lock. The body returns the record
    /// to persist (nil for a read-only pass) together with its result.
    func update<T>(timeout: TimeInterval = 5,
                   busyMessage: String =
                    "another Retouch Studio process is updating the AI helper registry",
                   _ body: (HelperRegistry.Load) throws
                    -> (HelperRegistry.Record?, T)) throws -> T {
        try lock.acquire(exclusive: true, timeout: timeout, busyMessage: busyMessage)
        defer { lock.unlock() }
        let load = read()
        let (record, result) = try body(load)
        if let record { try write(record) }
        return result
    }

    private func write(_ record: HelperRegistry.Record) throws {
        _ = try record.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let temp = root.appendingPathComponent(
            ".\(HelperRegistry.fileName).\(UUID().uuidString).tmp")
        let fd = temp.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            throw LockFileError("could not create the helper registry")
        }
        var closed = false
        defer { if !closed { close(fd) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fd, raw.baseAddress!.advanced(by: offset),
                                         raw.count - offset)
                if wrote <= 0 {
                    if errno == EINTR { continue }
                    throw LockFileError("could not write the helper registry")
                }
                offset += wrote
            }
        }
        guard fsync(fd) == 0 else {
            throw LockFileError("could not flush the helper registry")
        }
        close(fd)
        closed = true
        guard rename(temp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw LockFileError("could not replace the helper registry")
        }
        let directory = root.path.withCString { Darwin.open($0, O_RDONLY) }
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }
}
