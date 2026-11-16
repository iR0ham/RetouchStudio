import CryptoKit
import Darwin
import Foundation

/// Errors the model store reports with a stable code, so the UI never has to
/// guess from a message.
struct ModelStoreError: LocalizedError, Equatable, CustomStringConvertible {
    let code: String
    let detail: String

    var errorDescription: String? { detail }
    var description: String { "\(code): \(detail)" }

    static func leased(_ model: String, _ version: String) -> ModelStoreError {
        ModelStoreError(code: "E_MODEL_LEASED",
                        detail: "\(model) \(version) is in use by a running job or another window")
    }
    static func unverified(_ detail: String) -> ModelStoreError {
        ModelStoreError(code: "E_MODEL_UNVERIFIED", detail: detail)
    }
    static func missing(_ detail: String) -> ModelStoreError {
        ModelStoreError(code: "E_MODEL_MISSING", detail: detail)
    }
    static func invalid(_ detail: String) -> ModelStoreError {
        ModelStoreError(code: "E_INVALID_INPUT", detail: detail)
    }
    static func cancelled() -> ModelStoreError {
        ModelStoreError(code: "E_CANCELLED", detail: "the download was cancelled; nothing was installed")
    }
}

struct ModelManifestFile: Codable, Equatable {
    let path: String
    let sizeBytes: Int
    let sha256: String
}

struct ModelManifest: Codable, Equatable {
    static let schemaName = "retouchstudio.model-manifest/1"

    let schema: String
    let modelId: String
    let version: String
    let catalogVersion: String
    let manifestSha256: String
    let files: [ModelManifestFile]
    let installedAt: Double
}

struct ModelActivePointer: Codable, Equatable {
    static let schemaName = "retouchstudio.model-active/1"

    let schema: String
    let modelId: String
    let version: String
    let manifestSha256: String
    let activatedAt: Double
}

struct ModelTransferProgress: Equatable {
    let file: String
    let receivedBytes: Int64
    /// `nil` means the total is genuinely unknown and the UI must show an
    /// indeterminate bar instead of a percentage.
    let totalBytes: Int64?
    let fileIndex: Int
    let fileCount: Int
}

struct ModelVerifyReport: Equatable {
    struct Problem: Equatable {
        let file: String
        let reason: String
    }
    let modelId: String
    let version: String
    let checked: Int
    let problems: [Problem]
    var ok: Bool { problems.isEmpty }
}

struct ModelVersionState: Identifiable, Equatable {
    var id: String { version }
    let version: String
    let active: Bool
    let installedBytes: Int64
    let manifestOK: Bool
    let installedAt: Date?
}

enum ModelAvailability: Equatable {
    case ready
    case notInstalled
    case unsupportedPlatform
    case unverifiable(String)
}

struct ModelRecord: Identifiable, Equatable {
    let entry: ModelCatalogEntry
    let versions: [ModelVersionState]
    let activeVersion: String?
    let availability: ModelAvailability
    let installedBytes: Int64

    var id: String { entry.id }
    var isVerifiable: Bool { entry.isVerifiable }
    var active: ModelVersionState? { versions.first { $0.active } }
    var latestInstalled: ModelVersionState? {
        versions.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }
    var catalogVersionInstalled: Bool { versions.contains { $0.version == entry.version } }
}

struct ModelCleanupDecision: Equatable {
    let directory: String
    let action: String
    let reason: String
}

/// One OS-backed lease on a model version. The store never trusts an in-memory
/// set: `LockFile` is the authority, and the kernel drops the lock on exit.
final class ModelLease {
    private let file: LockFile

    private init(file: LockFile) { self.file = file }

    static func acquire(store: ModelStore, model: String, version: String,
                        exclusive: Bool, timeout: TimeInterval = 0) throws -> ModelLease {
        try ModelCatalogEntry.requireComponent(model, field: "model id")
        try ModelCatalogEntry.requireComponent(version, field: "model version")
        let url = store.layout.lockURL(model: model, version: version)
        let file = try LockFile.open(url)
        do {
            try file.acquire(exclusive: exclusive, timeout: timeout,
                             busyMessage: "\(model) \(version) is leased")
        } catch {
            file.close()
            throw ModelStoreError.leased(model, version)
        }
        return ModelLease(file: file)
    }

    static func acquireInstallGate(store: ModelStore, timeout: TimeInterval = 0) throws
        -> ModelLease {
        let file = try LockFile.open(store.layout.installGateURL)
        do {
            try file.acquire(exclusive: true, timeout: timeout,
                             busyMessage: "another model install is running")
        } catch {
            file.close()
            throw ModelStoreError(code: "E_MODEL_LEASED",
                                  detail: "another model install is already running")
        }
        return ModelLease(file: file)
    }

    func release() { file.close() }
    deinit { release() }
}

/// Filesystem model store: catalog in, verified immutable versions out.
///
/// Every mutation that can race a reader takes an OS lease first. Downloads
/// write only under `.staging`; a version directory appears by one atomic
/// rename, and `active.json` is replaced by one atomic rename.
final class ModelStore: @unchecked Sendable {
    struct Layout {
        let root: URL

        var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }
        var quarantine: URL { root.appendingPathComponent(".quarantine", isDirectory: true) }
        var locks: URL { root.appendingPathComponent(".locks", isDirectory: true) }
        var installGateURL: URL { locks.appendingPathComponent("install") }

        func modelDirectory(_ id: String) -> URL {
            root.appendingPathComponent(id, isDirectory: true)
        }
        func versionDirectory(model: String, version: String) -> URL {
            modelDirectory(model).appendingPathComponent(version, isDirectory: true)
        }
        func manifestURL(model: String, version: String) -> URL {
            versionDirectory(model: model, version: version)
                .appendingPathComponent("manifest.json")
        }
        func activeURL(_ id: String) -> URL {
            modelDirectory(id).appendingPathComponent("active.json")
        }
        func lockURL(model: String, version: String) -> URL {
            locks.appendingPathComponent("\(model)-\(version)")
        }
    }

    static let defaultGrace: TimeInterval = 24 * 60 * 60
    static let requiredReserve: Int64 = 32 * 1024 * 1024

    let layout: Layout
    let catalog: ModelCatalog
    let platform: String
    /// Tests point at a local HTTP listener; production accepts HTTPS only.
    let allowLocalHTTP: Bool
    private let sessionConfiguration: URLSessionConfiguration

    init(root: URL, catalog: ModelCatalog, platform: String = ModelPlatform.current,
         allowLocalHTTP: Bool = false,
         sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.layout = Layout(root: root.standardizedFileURL)
        self.catalog = catalog
        self.platform = platform
        self.allowLocalHTTP = allowLocalHTTP
        self.sessionConfiguration = sessionConfiguration
    }

    static func production(catalog: ModelCatalog? = nil) throws -> ModelStore {
        let catalog = try catalog ?? ModelCatalog.bundled()
        return ModelStore(root: AIWorker.modelsDirectory, catalog: catalog)
    }

    // MARK: - Snapshot

    func records() -> [ModelRecord] {
        catalog.entries.map { entry in
            let availability: ModelAvailability
            if !entry.supports(platform: platform) {
                availability = .unsupportedPlatform
            } else if let problem = entry.verificationProblem {
                availability = .unverifiable(problem)
            } else {
                availability = .ready
            }
            let versions = installedVersions(of: entry)
            let pointerVersion = (try? activePointer(entry.id))?.version
            let active = versions.contains { $0.version == pointerVersion }
                ? pointerVersion : nil
            return ModelRecord(entry: entry, versions: versions,
                               activeVersion: active, availability: availability,
                               installedBytes: versions.reduce(0) { $0 + $1.installedBytes })
        }
    }

    func installedVersions(of entry: ModelCatalogEntry) -> [ModelVersionState] {
        let modelDir = layout.modelDirectory(entry.id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path) else {
            return []
        }
        let active = (try? activePointer(entry.id))?.version
        return names.compactMap { name -> ModelVersionState? in
            guard name != "active.json", !name.hasPrefix(".") else { return nil }
            let directory = modelDir.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let manifest = try? readManifest(in: directory)
            let bytes = directorySize(directory)
            return ModelVersionState(
                version: name,
                active: active == name,
                installedBytes: bytes,
                manifestOK: manifest?.modelId == entry.id && manifest?.version == name,
                installedAt: manifest.map { Date(timeIntervalSince1970: $0.installedAt) })
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func activePointer(_ id: String) throws -> ModelActivePointer? {
        let url = layout.activeURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pointer = try JSONDecoder().decode(ModelActivePointer.self, from: Data(contentsOf: url))
        guard pointer.schema == ModelActivePointer.schemaName, pointer.modelId == id else {
            throw ModelStoreError.unverified("\(id)'s active pointer is invalid")
        }
        return pointer
    }

    func diskUsage() -> Int64 {
        catalog.entries.reduce(0) { total, entry in
            total + installedVersions(of: entry).reduce(0) { $0 + $1.installedBytes }
        }
    }

    func availableBytes() -> Int64? {
        let values = try? layout.root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Install

    /// Installs one immutable catalog version. The install gate serialises
    /// whole installs; the version lease blocks a reader (or delete) from
    /// touching a version that a previous install already published.
    func install(_ entry: ModelCatalogEntry,
                 progress: @escaping (ModelTransferProgress) -> Void = { _ in })
        async throws -> ModelVersionState {
        try validate(entry)
        try prepareLayout()
        guard entry.supports(platform: platform) else {
            throw ModelStoreError.invalid("\(entry.name) is not available on this platform")
        }
        try Task.checkCancellation()

        let gate = try ModelLease.acquireInstallGate(store: self)
        defer { gate.release() }

        let lease = try ModelLease.acquire(store: self, model: entry.id,
                                           version: entry.version, exclusive: true)
        defer { lease.release() }

        let versionDir = layout.versionDirectory(model: entry.id, version: entry.version)
        if FileManager.default.fileExists(atPath: versionDir.path) {
            let report = try verify(entry, version: entry.version, full: true,
                                    lease: lease)
            guard report.ok else {
                throw ModelStoreError.unverified(
                    "\(entry.id) \(entry.version) is installed but \(report.problems.first?.file ?? "its files") failed verification")
            }
            try activate(entry, version: entry.version, lease: lease)
            return versionState(entry: entry, version: entry.version)
        }

        guard let total = entry.sizeBytes else {
            throw ModelStoreError.unverified(entry.verificationProblem ?? "the total size is unknown")
        }
        if let available = availableBytes(),
           available < Int64(total) + Self.requiredReserve {
            throw ModelStoreError.invalid(
                "not enough disk space: \(available) bytes available, \(total) bytes needed plus a reserve")
        }

        let staging = layout.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createPrivateDirectory(staging)
        do {
            var received: Int64 = 0
            for (index, file) in entry.files.enumerated() {
                try Task.checkCancellation()
                guard let size = file.sizeBytes, let hash = file.sha256 else {
                    throw ModelStoreError.unverified("\(file.path) has no exact size or SHA-256")
                }
                let destination = staging.appendingPathComponent(file.path)
                try createPrivateDirectory(destination.deletingLastPathComponent())
                var fileReceived: Int64 = 0
                try await download(file.sourceUrl, to: destination, entry: entry,
                                   expectedBytes: size,
                                   onProgress: { written, expected in
                    fileReceived = written
                    progress(ModelTransferProgress(
                        file: file.path, receivedBytes: received + written,
                        totalBytes: Int64(total), fileIndex: index + 1,
                        fileCount: entry.files.count))
                    _ = expected
                })
                fileReceived = max(fileReceived, Int64(size))
                received += fileReceived
                try verifyFile(destination, path: file.path, size: size, sha256: hash)
            }
            let manifest = ModelManifest(
                schema: ModelManifest.schemaName, modelId: entry.id,
                version: entry.version, catalogVersion: catalog.catalogVersion,
                manifestSha256: entry.sha256 ?? "",
                files: entry.files.compactMap { file in
                    guard let size = file.sizeBytes, let hash = file.sha256 else { return nil }
                    return ModelManifestFile(path: file.path, sizeBytes: size, sha256: hash)
                },
                installedAt: Date().timeIntervalSince1970)
            try writeJSON(manifest,
                          to: staging.appendingPathComponent("manifest.json"), fsync: true)
            testCrashPoint("after-verify")
            try Task.checkCancellation()

            try createPrivateDirectory(layout.modelDirectory(entry.id))
            try FileManager.default.moveItem(at: staging, to: versionDir)
            testCrashPoint("after-rename")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if error is CancellationError { throw ModelStoreError.cancelled() }
            throw error
        }

        try writePointer(entry, version: entry.version)
        return versionState(entry: entry, version: entry.version)
    }

    // MARK: - Verify / activate / delete

    func verify(_ entry: ModelCatalogEntry, version: String, full: Bool,
                lease: ModelLease? = nil) throws -> ModelVerifyReport {
        let held = try lease ?? ModelLease.acquire(
            store: self, model: entry.id, version: version, exclusive: false)
        defer { if lease == nil { held.release() } }

        let directory = layout.versionDirectory(model: entry.id, version: version)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ModelStoreError.missing("\(entry.id) \(version) is not installed")
        }
        var problems: [ModelVerifyReport.Problem] = []
        let manifest: ModelManifest
        do {
            manifest = try readManifest(in: directory)
        } catch {
            return ModelVerifyReport(modelId: entry.id, version: version, checked: 0,
                                     problems: [.init(file: "manifest.json",
                                                      reason: "missing or unreadable")])
        }
        if manifest.modelId != entry.id || manifest.version != version {
            problems.append(.init(file: "manifest.json", reason: "identity mismatch"))
        }
        if manifest.manifestSha256 != (entry.sha256 ?? "") {
            problems.append(.init(file: "manifest.json", reason: "catalog digest mismatch"))
        }
        let recorded = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        let expected = Set(entry.files.map(\.path))
        if Set(recorded.keys) != expected {
            problems.append(.init(file: "manifest.json", reason: "file list mismatch"))
        }

        var checked = 0
        for file in entry.files {
            guard let size = file.sizeBytes, let hash = file.sha256 else {
                problems.append(.init(file: file.path, reason: "catalog metadata incomplete"))
                continue
            }
            if let record = recorded[file.path],
               record.sizeBytes != size || record.sha256 != hash {
                problems.append(.init(file: file.path, reason: "manifest metadata mismatch"))
            }
            let target = directory.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: target.path) else {
                problems.append(.init(file: file.path, reason: "missing"))
                continue
            }
            let actualSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if Int64(actualSize) != Int64(size) {
                problems.append(.init(file: file.path, reason: "size"))
                continue
            }
            if full {
                let digest = (try? sha256File(target)) ?? ""
                if digest != hash {
                    problems.append(.init(file: file.path, reason: "checksum"))
                }
            }
            checked += 1
        }
        return ModelVerifyReport(modelId: entry.id, version: version,
                                 checked: checked, problems: problems)
    }

    /// Rollback and update both end here. The target is fully hashed first, so
    /// a corrupt version is never made active.
    func activate(_ entry: ModelCatalogEntry, version: String,
                  lease: ModelLease? = nil) throws {
        let held = try lease ?? ModelLease.acquire(
            store: self, model: entry.id, version: version, exclusive: false)
        defer { if lease == nil { held.release() } }
        let report = try verify(entry, version: version, full: true, lease: held)
        guard report.ok else {
            throw ModelStoreError.unverified(
                "\(entry.id) \(version) failed verification: \(report.problems.first?.reason ?? "unknown")")
        }
        try writePointer(entry, version: version)
    }

    private func removeActivePointerIfNeeded(_ id: String, version: String) {
        let url = layout.activeURL(id)
        var pointer: ModelActivePointer?
        do { pointer = try activePointer(id) } catch { pointer = nil }
        // A corrupt pointer has no owner; removing it here is the repair, and
        // it cannot name a different valid version.
        if pointer?.version == version || (pointer == nil &&
            FileManager.default.fileExists(atPath: url.path)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writePointer(_ entry: ModelCatalogEntry, version: String) throws {
        let pointer = ModelActivePointer(
            schema: ModelActivePointer.schemaName, modelId: entry.id,
            version: version, manifestSha256: entry.sha256 ?? "",
            activatedAt: Date().timeIntervalSince1970)
        try writeJSON(pointer, to: layout.activeURL(entry.id), fsync: true)
    }

    func delete(_ entry: ModelCatalogEntry, version: String) throws {
        try prepareLayout()
        let lease = try ModelLease.acquire(store: self, model: entry.id,
                                           version: version, exclusive: true)
        defer { lease.release() }

        let directory = layout.versionDirectory(model: entry.id, version: version)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ModelStoreError.missing("\(entry.id) \(version) is not installed")
        }
        removeActivePointerIfNeeded(entry.id, version: version)
        testCrashPoint("after-pointer-removal")
        let quarantine = layout.quarantine.appendingPathComponent(UUID().uuidString,
                                                                  isDirectory: true)
        try createPrivateDirectory(layout.quarantine)
        try FileManager.default.moveItem(at: directory, to: quarantine)
        // Quarantine is a recovery marker: if this delete fails, startup
        // cleanup finds the complete directory and removes it later.
        try? FileManager.default.removeItem(at: quarantine)
    }

    func deleteAll(_ entry: ModelCatalogEntry) throws {
        try prepareLayout()
        var leases: [ModelLease] = []
        defer { leases.forEach { $0.release() } }
        let versions = installedVersions(of: entry)
        for version in versions {
            leases.append(try ModelLease.acquire(
                store: self, model: entry.id, version: version.version, exclusive: true))
        }
        for version in versions {
            let directory = layout.versionDirectory(model: entry.id, version: version.version)
            removeActivePointerIfNeeded(entry.id, version: version.version)
            try createPrivateDirectory(layout.quarantine)
            let quarantine = layout.quarantine.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
            try FileManager.default.moveItem(at: directory, to: quarantine)
            try? FileManager.default.removeItem(at: quarantine)
        }
    }

    // MARK: - Legacy flat installs

    /// Bytes held by the pre-versioning flat layout, when no version exists.
    /// The old CLI wrote `models/<id>/<file>`; the worker still reads it until
    /// a version is active.
    func legacyBytes(_ entry: ModelCatalogEntry) -> Int64? {
        guard installedVersions(of: entry).isEmpty else { return nil }
        let directory = layout.modelDirectory(entry.id)
        var total: Int64 = 0
        for file in entry.files {
            let target = directory.appendingPathComponent(file.path)
            guard let values = try? target.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Adopts a flat install after hashing every file against the catalog.
    /// Files are moved, not copied; a failure puts the moved files back so the
    /// model never ends up half flat and half versioned.
    func migrateLegacy(_ entry: ModelCatalogEntry,
                       progress: @escaping (ModelTransferProgress) -> Void = { _ in })
        async throws -> ModelVersionState {
        try validate(entry)
        try prepareLayout()
        guard legacyBytes(entry) != nil else {
            throw ModelStoreError.missing("\(entry.id) has no flat installation to adopt")
        }
        try Task.checkCancellation()
        let gate = try ModelLease.acquireInstallGate(store: self)
        defer { gate.release() }
        let lease = try ModelLease.acquire(store: self, model: entry.id,
                                           version: entry.version, exclusive: true)
        defer { lease.release() }
        let versionDir = layout.versionDirectory(model: entry.id, version: entry.version)
        guard !FileManager.default.fileExists(atPath: versionDir.path) else {
            throw ModelStoreError.invalid("\(entry.id) \(entry.version) is already versioned")
        }

        let directory = layout.modelDirectory(entry.id)
        var received: Int64 = 0
        for (index, file) in entry.files.enumerated() {
            try Task.checkCancellation()
            guard let size = file.sizeBytes, let hash = file.sha256 else {
                throw ModelStoreError.unverified("\(file.path) has no exact size or SHA-256")
            }
            let source = directory.appendingPathComponent(file.path)
            let actualSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard actualSize == size, (try? sha256File(source)) == hash else {
                throw ModelStoreError.unverified(
                    "\(file.path) does not match the catalog; it is left where it is")
            }
            received += Int64(size)
            progress(ModelTransferProgress(file: file.path, receivedBytes: received,
                                           totalBytes: entry.sizeBytes.map { Int64($0) },
                                           fileIndex: index + 1, fileCount: entry.files.count))
        }

        let staging = layout.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createPrivateDirectory(staging)
        var moved: [(from: URL, to: URL)] = []
        do {
            for file in entry.files {
                let source = directory.appendingPathComponent(file.path)
                let target = staging.appendingPathComponent(file.path)
                try createPrivateDirectory(target.deletingLastPathComponent())
                try FileManager.default.moveItem(at: source, to: target)
                moved.append((source, target))
            }
            let manifest = ModelManifest(
                schema: ModelManifest.schemaName, modelId: entry.id,
                version: entry.version, catalogVersion: catalog.catalogVersion,
                manifestSha256: entry.sha256 ?? "",
                files: entry.files.compactMap { file in
                    guard let size = file.sizeBytes, let hash = file.sha256 else { return nil }
                    return ModelManifestFile(path: file.path, sizeBytes: size, sha256: hash)
                },
                installedAt: Date().timeIntervalSince1970)
            try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"),
                          fsync: true)
            try FileManager.default.moveItem(at: staging, to: versionDir)
        } catch {
            for item in moved.reversed() {
                try? FileManager.default.moveItem(at: item.to, to: item.from)
            }
            try? FileManager.default.removeItem(at: staging)
            if error is CancellationError { throw ModelStoreError.cancelled() }
            throw error
        }
        try writePointer(entry, version: entry.version)
        removeEmptyDirectories(in: directory)
        return versionState(entry: entry, version: entry.version)
    }

    private func removeEmptyDirectories(in root: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true {
                directories.append(url)
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            if contents?.isEmpty == true { try? FileManager.default.removeItem(at: directory) }
        }
    }

    // MARK: - Startup cleanup

    /// Removes staging and quarantine trees older than the grace period. It
    /// skips locked trees and any tree whose identity cannot be read; an
    /// unexplained directory is never deleted.
    func cleanup(now: Date = Date(), grace: TimeInterval = ModelStore.defaultGrace)
        -> [ModelCleanupDecision] {
        var decisions: [ModelCleanupDecision] = []
        guard (try? prepareLayout()) != nil else {
            return [.init(directory: "store", action: "keep",
                          reason: "store layout is not a set of private directories")]
        }
        for (parent, kind) in [(layout.staging, "staging"), (layout.quarantine, "quarantine")] {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                continue
            }
            for child in children {
                let age = now.timeIntervalSince(
                    (try? child.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? now)
                guard age >= grace else {
                    decisions.append(.init(directory: "\(kind)/\(child.lastPathComponent)",
                                           action: "keep", reason: "younger than the grace period"))
                    continue
                }
                // A staging tree without a manifest is still wholly ours. The
                // install gate proves no install is writing it; a quarantine
                // tree without identity is kept, because that state is only
                // reachable if something outside the store put it there.
                guard let manifest = try? readManifest(in: child) else {
                    if kind == "staging" {
                        if let gate = try? ModelLease.acquireInstallGate(store: self) {
                            try? FileManager.default.removeItem(at: child)
                            gate.release()
                            decisions.append(.init(
                                directory: "\(kind)/\(child.lastPathComponent)",
                                action: "removed",
                                reason: "stale staging with no manifest and no install running"))
                        } else {
                            decisions.append(.init(
                                directory: "\(kind)/\(child.lastPathComponent)",
                                action: "keep", reason: "an install holds the install gate"))
                        }
                    } else {
                        decisions.append(.init(
                            directory: "\(kind)/\(child.lastPathComponent)",
                            action: "keep", reason: "identity is not readable"))
                    }
                    continue
                }
                guard let lease = try? ModelLease.acquire(
                    store: self, model: manifest.modelId, version: manifest.version,
                    exclusive: true) else {
                    decisions.append(.init(directory: "\(kind)/\(child.lastPathComponent)",
                                           action: "keep", reason: "a live lease holds it"))
                    continue
                }
                try? FileManager.default.removeItem(at: child)
                lease.release()
                decisions.append(.init(directory: "\(kind)/\(child.lastPathComponent)",
                                       action: "removed", reason: "older than 24 hours and unlocked"))
            }
        }
        for decision in decisions {
            NSLog("[RetouchStudio] model cleanup %@: %@ (%@)", decision.directory,
                  decision.action, decision.reason)
        }
        return decisions
    }

    // MARK: - Helpers

    func validate(_ entry: ModelCatalogEntry) throws {
        do {
            try entry.validate(allowLocalHTTP: allowLocalHTTP)
        } catch {
            throw ModelStoreError.invalid("\(error)")
        }
        if let problem = entry.verificationProblem {
            throw ModelStoreError.unverified(problem)
        }
        for file in entry.files {
            guard Self.isAllowedSource(file.sourceUrl, entry: entry,
                                       allowLocalHTTP: allowLocalHTTP) else {
                throw ModelStoreError.invalid("\(file.sourceUrl) is not the recorded HTTPS source")
            }
        }
    }

    static func isAllowedSource(_ url: String, entry: ModelCatalogEntry,
                                allowLocalHTTP: Bool) -> Bool {
        guard let parsed = URL(string: url), let host = parsed.host,
              let source = URL(string: entry.sourceUrl), let sourceHost = source.host,
              host.caseInsensitiveCompare(sourceHost) == .orderedSame,
              parsed.user == nil, parsed.password == nil, parsed.fragment == nil else {
            return false
        }
        switch parsed.scheme?.lowercased() {
        case "https": return true
        case "http":
            return allowLocalHTTP && (host == "127.0.0.1" || host == "localhost")
        default: return false
        }
    }

    private func download(_ url: String, to destination: URL,
                          entry: ModelCatalogEntry, expectedBytes: Int,
                          onProgress: @escaping (Int64, Int64?) -> Void) async throws {
        guard let parsed = URL(string: url),
              Self.isAllowedSource(url, entry: entry, allowLocalHTTP: allowLocalHTTP) else {
            throw ModelStoreError.invalid("refusing an unrecorded source")
        }
        let transfer = ModelDownloadTransfer(destination: destination,
                                             expectedBytes: expectedBytes,
                                             onProgress: onProgress)
        try await transfer.run(url: parsed, configuration: sessionConfiguration)
    }

    private func verifyFile(_ url: URL, path: String, size: Int, sha256: String) throws {
        let actualSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard actualSize == size else {
            throw ModelStoreError.unverified("\(path) has \(actualSize) bytes, expected \(size)")
        }
        let digest = try sha256File(url)
        guard digest == sha256 else {
            throw ModelStoreError.unverified("\(path) failed its SHA-256 check")
        }
    }

    private func readManifest(in directory: URL) throws -> ModelManifest {
        let url = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
        guard manifest.schema == ModelManifest.schemaName else {
            throw ModelStoreError.unverified("unrecognised version manifest")
        }
        return manifest
    }

    private func versionState(entry: ModelCatalogEntry, version: String) -> ModelVersionState {
        let active = (try? activePointer(entry.id))?.version
        let directory = layout.versionDirectory(model: entry.id, version: version)
        let manifest = try? readManifest(in: directory)
        return ModelVersionState(
            version: version, active: active == version,
            installedBytes: directorySize(directory),
            manifestOK: manifest?.modelId == entry.id && manifest?.version == version,
            installedAt: manifest.map { Date(timeIntervalSince1970: $0.installedAt) })
    }

    private func createPrivateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard isDirectory.boolValue, values?.isSymbolicLink != true else {
                throw ModelStoreError.invalid(
                    "\(url.lastPathComponent) is not a private directory")
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// The three store-managed subdirectories must be real directories. This
    /// is checked before any mutation, so a symlink planted at `.staging`
    /// cannot redirect a download outside the store.
    private func prepareLayout() throws {
        try createPrivateDirectory(layout.root)
        for directory in [layout.staging, layout.quarantine, layout.locks] {
            try createPrivateDirectory(directory)
        }
    }

    /// Test builds let a child process die at a named boundary so crash
    /// recovery is exercised by a real `_exit`, never by a mocked flag.
    private func testCrashPoint(_ name: String) {
        #if RETOUCH_TESTING
        if ProcessInfo.processInfo.environment["RETOUCH_MODEL_TEST_CRASH"] == name {
            _exit(86)
        }
        #endif
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL, fsync: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        if fsync, let handle = try? FileHandle(forWritingTo: temporary) {
            try? handle.synchronize()
            try? handle.close()
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ModelStoreError.invalid("could not publish \(url.lastPathComponent)")
        }
        if fsync, let directory = try? FileHandle(forReadingFrom: url.deletingLastPathComponent()) {
            try? directory.synchronize()
            try? directory.close()
        }
    }

    private func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let block = try? handle.read(upToCount: 1 << 20)
            guard let block, !block.isEmpty else { return false }
            hasher.update(data: block)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

/// Bridges `URLSessionDownloadDelegate` progress into async/await. One
/// transfer owns one session; cancellation closes the session and resumes the
/// continuation exactly once.
private final class ModelDownloadTransfer: NSObject, URLSessionDownloadDelegate,
                                          @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int
    private let onProgress: (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false

    init(destination: URL, expectedBytes: Int,
         onProgress: @escaping (Int64, Int64?) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    func run(url: URL, configuration: URLSessionConfiguration) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let cancelled = finished
                lock.unlock()
                if cancelled {
                    finish(.failure(CancellationError()))
                    return
                }
                let session = URLSession(configuration: configuration, delegate: self,
                                         delegateQueue: nil)
                let task = session.downloadTask(with: url)
                lock.lock()
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func cancel() {
        lock.lock()
        let session = self.session
        let task = self.task
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten,
                   totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    /// A redirect is a different source than the one the owner approved.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse,
           response.statusCode != 200 {
            finish(.failure(ModelStoreError.invalid(
                "the model source answered HTTP \(response.statusCode)")))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled || error is CancellationError {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(ModelStoreError.invalid("the download failed: \(error.localizedDescription)")))
            }
        } else {
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        lock.unlock()
        session?.finishTasksAndInvalidate()
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}
