import Foundation

/// App-facing model state. All filesystem and download work goes through
/// `ModelStore`; this object only publishes snapshots to the view and owns the
/// one cancellable install task.
@MainActor
final class ModelManager: ObservableObject {
    enum Verdict: Equatable {
        case ok
        case failed(String)
    }

    struct InstallState: Equatable {
        let modelID: String
        let name: String
        let version: String
        let receivedBytes: Int64
        let totalBytes: Int64?

        var indeterminate: Bool { totalBytes == nil || (totalBytes ?? 0) <= 0 }
        var percent: Int {
            guard let totalBytes, totalBytes > 0 else { return 0 }
            return max(0, min(100, Int((Double(receivedBytes) / Double(totalBytes) * 100).rounded())))
        }
    }

    @Published private(set) var records: [ModelRecord] = []
    @Published private(set) var loading = false
    @Published private(set) var storeError: String?
    @Published private(set) var install: InstallState?
    @Published private(set) var verifyingKey: String?
    @Published private(set) var verdicts: [String: Verdict] = [:]
    @Published private(set) var diskUsage: Int64 = 0
    @Published private(set) var availableDisk: Int64?
    @Published private(set) var legacyBytes: [String: Int64] = [:]
    @Published var notice: String?

    private var store: ModelStore?
    private var installTask: Task<Void, Never>?
    private var lastProgressBytes: Int64 = 0

    var isDownloading: Bool { install != nil }

    func key(_ model: String, _ version: String) -> String { "\(model)@\(version)" }

    // MARK: - Snapshot

    func refresh() async {
        loading = true
        storeError = nil
        do {
            let store = try ensureStore()
            let snapshot = await Task.detached(priority: .userInitiated) { [store] in
                let records = store.records()
                var legacy: [String: Int64] = [:]
                for record in records {
                    if let bytes = store.legacyBytes(record.entry) { legacy[record.id] = bytes }
                }
                return (records, store.diskUsage(), store.availableBytes(), legacy)
            }.value
            records = snapshot.0
            diskUsage = snapshot.1
            availableDisk = snapshot.2
            legacyBytes = snapshot.3
        } catch {
            records = []
            legacyBytes = [:]
            storeError = error.localizedDescription
        }
        loading = false
    }

    /// Runs at app launch, before any model is loaded. It has no UI, so every
    /// decision is logged; a locked or unidentifiable tree is never removed.
    static func cleanupAtStartup() {
        DispatchQueue.global(qos: .utility).async {
            do {
                let store = try ModelStore.production()
                _ = store.cleanup()
            } catch {
                NSLog("[RetouchStudio] model cleanup skipped: %@", "\(error)")
            }
        }
    }

    // MARK: - Install

    func install(_ entry: ModelCatalogEntry) {
        guard installTask == nil else { return }
        let store: ModelStore
        do {
            store = try ensureStore()
        } catch {
            notice = error.localizedDescription
            return
        }
        lastProgressBytes = 0
        install = InstallState(modelID: entry.id, name: entry.name, version: entry.version,
                               receivedBytes: 0,
                               totalBytes: entry.sizeBytes.map { Int64($0) })
        notice = nil
        installTask = Task { [weak self] in
            do {
                _ = try await store.install(entry) { update in
                    Task { @MainActor [weak self] in
                        self?.apply(update)
                    }
                }
                self?.notice = L10n.current.modelsDownloaded(entry.name)
            } catch {
                self?.notice = Self.message(for: error)
            }
            self?.install = nil
            self?.installTask = nil
            await self?.refresh()
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    private func apply(_ update: ModelTransferProgress) {
        guard var current = install else { return }
        // URLSession reports small chunks; republish at most once per megabyte
        // so the main thread is not woken thousands of times.
        guard update.receivedBytes - lastProgressBytes >= 1 << 20
                || update.receivedBytes >= (current.totalBytes ?? Int64.max) - 1 << 20 else {
            return
        }
        lastProgressBytes = update.receivedBytes
        current = InstallState(modelID: current.modelID, name: current.name,
                               version: current.version,
                               receivedBytes: update.receivedBytes,
                               totalBytes: update.totalBytes ?? current.totalBytes)
        install = current
    }

    // MARK: - Verification and version control

    func verify(_ record: ModelRecord, version: String) async {
        let key = key(record.id, version)
        verifyingKey = key
        verdicts[key] = nil
        do {
            let store = try ensureStore()
            let report = try await Task.detached(priority: .userInitiated) { [store] in
                try store.verify(record.entry, version: version, full: true)
            }.value
            verdicts[key] = report.ok
                ? .ok
                : .failed(report.problems.first.map { "\($0.file): \($0.reason)" } ?? "unknown")
        } catch {
            verdicts[key] = .failed(Self.message(for: error))
        }
        verifyingKey = nil
    }

    func activate(_ record: ModelRecord, version: String) async {
        do {
            let store = try ensureStore()
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.activate(record.entry, version: version)
            }.value
            notice = L10n.current.modelsActivated(record.entry.name, version)
        } catch {
            notice = Self.message(for: error)
        }
        await refresh()
    }

    func remove(_ record: ModelRecord, version: String) async {
        do {
            let store = try ensureStore()
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.delete(record.entry, version: version)
            }.value
            ModelActivity.shared.forget(record.id)
            verdicts[key(record.id, version)] = nil
            notice = L10n.current.modelsRemoved(record.entry.name)
        } catch {
            notice = Self.message(for: error)
        }
        await refresh()
    }

    func removeAll(_ record: ModelRecord) async {
        do {
            let store = try ensureStore()
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.deleteAll(record.entry)
            }.value
            ModelActivity.shared.forget(record.id)
            notice = L10n.current.modelsRemoved(record.entry.name)
        } catch {
            notice = Self.message(for: error)
        }
        await refresh()
    }

    func migrateLegacy(_ record: ModelRecord) {
        guard installTask == nil else { return }
        let store: ModelStore
        do {
            store = try ensureStore()
        } catch {
            notice = error.localizedDescription
            return
        }
        lastProgressBytes = 0
        install = InstallState(modelID: record.id, name: record.entry.name,
                               version: record.entry.version, receivedBytes: 0,
                               totalBytes: record.entry.sizeBytes.map { Int64($0) })
        notice = nil
        installTask = Task { [weak self] in
            do {
                _ = try await store.migrateLegacy(record.entry) { update in
                    Task { @MainActor [weak self] in self?.apply(update) }
                }
                self?.notice = L10n.current.modelsMigrated(record.entry.name)
            } catch {
                self?.notice = Self.message(for: error)
            }
            self?.install = nil
            self?.installTask = nil
            await self?.refresh()
        }
    }

    // MARK: - Helpers

    private func ensureStore() throws -> ModelStore {
        if let store { return store }
        let created = try ModelStore.production()
        store = created
        return created
    }

    static func message(for error: Error) -> String {
        if error is CancellationError { return L10n.current.modelsDownloadCancelled }
        guard let error = error as? ModelStoreError else {
            return error.localizedDescription
        }
        switch error.code {
        case "E_CANCELLED": return L10n.current.modelsDownloadCancelled
        case "E_MODEL_LEASED": return L10n.current.modelsInUseRetry
        case "E_MODEL_UNVERIFIED": return L10n.current.modelsUnverified(error.detail)
        case "E_MODEL_MISSING": return L10n.current.modelsMissingFile(error.detail)
        default: return error.detail
        }
    }
}
