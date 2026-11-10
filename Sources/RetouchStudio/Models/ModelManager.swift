import Foundation

/// One catalog entry as the manager shows it.
struct AIModelRow: Identifiable, Equatable {
    let id: String
    let name: String
    let task: String
    let license: String
    let bytes: Int?
    let installed: Bool
    let notes: String
    let source: String
}

struct AIModelPlanFile: Equatable {
    let model: String
    let path: String
    let bytes: Int
}

/// Exactly what a download would fetch. The hash is the one the owner approves;
/// the downloader refuses if the catalog changed in between.
struct AIModelPlan: Equatable {
    let models: [String]
    let totalBytes: Int
    let files: [AIModelPlanFile]
    let hash: String
}

/// Model state for the settings sheet: list, checksum, download, remove.
///
/// Downloads run in the worker's own CLI process, never in the server. The
/// server stays network-free; this object only shows a manifest and, after an
/// explicit approval, starts that process.
@MainActor
final class ModelManager: ObservableObject {
    enum Verdict: Equatable {
        case ok
        case failed(String)
    }

    @Published private(set) var rows: [AIModelRow] = []
    @Published private(set) var loading = false
    @Published private(set) var helperError: String?
    @Published private(set) var activeID: String?
    @Published private(set) var receivedBytes = 0
    @Published private(set) var totalBytes = 0
    @Published private(set) var checkingID: String?
    @Published private(set) var verdicts: [String: Verdict] = [:]
    @Published var notice: String?

    private var modelTool: RuntimeModelTool?
    private var activeName = ""
    private var cancelled = false

    var isDownloading: Bool { activeID != nil }

    var percent: Int {
        guard totalBytes > 0 else { return 0 }
        return max(0, min(100, Int((Double(receivedBytes) / Double(totalBytes) * 100).rounded())))
    }

    // MARK: - Catalog

    func refresh() async {
        loading = true
        helperError = nil
        do {
            rows = try await Task.detached(priority: .userInitiated) {
                try AIWorker.ensureRunning()
                guard let reply = try WorkerClient.shared.call("models.list") as? [String: Any],
                      let list = reply["models"] as? [[String: Any]] else {
                    throw AIWorkerFailure(code: -32000, message: L10n.current.modelsHelperMissing)
                }
                return list.compactMap { item -> AIModelRow? in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String else { return nil }
                    return AIModelRow(
                        id: id,
                        name: name,
                        task: item["task"] as? String ?? "",
                        license: item["license"] as? String ?? "",
                        bytes: item["bytes"] as? Int,
                        installed: item["installed"] as? Bool ?? false,
                        notes: item["notes"] as? String ?? "",
                        source: item["source"] as? String ?? "")
                }
            }.value
        } catch {
            rows = []
            helperError = error.localizedDescription
        }
        loading = false
    }

    func plan(for id: String) async throws -> AIModelPlan {
        try await Task.detached(priority: .userInitiated) {
            try AIWorker.ensureRunning()
            guard let reply = try WorkerClient.shared.call(
                "models.plan", ["models": [id]]) as? [String: Any] else {
                throw AIWorkerFailure(code: -32000, message: L10n.current.modelsHelperMissing)
            }
            let files = (reply["files"] as? [[String: Any]] ?? []).compactMap { item -> AIModelPlanFile? in
                guard let model = item["model"] as? String,
                      let path = item["path"] as? String else { return nil }
                return AIModelPlanFile(model: model, path: path, bytes: item["bytes"] as? Int ?? 0)
            }
            guard let hash = reply["manifest_hash"] as? String else {
                throw AIWorkerFailure(code: -32000, message: L10n.current.aiBadReply)
            }
            return AIModelPlan(models: reply["models"] as? [String] ?? [id],
                               totalBytes: reply["total_bytes"] as? Int ?? 0,
                               files: files, hash: hash)
        }.value
    }

    func verify(_ id: String) async {
        checkingID = id
        verdicts[id] = nil
        do {
            let verdict: Verdict = try await Task.detached(priority: .userInitiated) {
                try AIWorker.ensureRunning()
                let reply = try WorkerClient.shared.call(
                    "models.verify", ["model": id]) as? [String: Any] ?? [:]
                if reply["ok"] as? Bool == true { return .ok }
                let failed = reply["failed"] as? [[String: Any]] ?? []
                let file = failed.first?["file"] as? String ?? ""
                return .failed(file)
            }.value
            verdicts[id] = verdict
        } catch {
            verdicts[id] = .failed(error.localizedDescription)
        }
        checkingID = nil
    }

    // MARK: - Transfer

    func startDownload(_ plan: AIModelPlan, name: String) {
        guard modelTool == nil else { return }
        let arguments = ["models", "download"]
            + plan.models
            + ["--models", AIWorker.modelsDirectory.path,
               "--yes", "--consent-hash", plan.hash]

        let errors = Pipe()
        let splitter = LineSplitter()
        let handle = errors.fileHandleForReading
        // The tool is resolved, leased and started inside one locked sequence;
        // by the time this returns, the process is already running (or the
        // call threw and nothing was started). The CLI owns the lease from here
        // on, so a crash of this app cannot let the runtime be replaced under
        // it, and cancellation is acknowledged only on the real exit.
        let tool: RuntimeModelTool
        do {
            tool = try AIWorker.startModelTool(arguments, standardError: errors,
                onExit: { [weak self] status in
                    handle.readabilityHandler = nil
                    Task { @MainActor in
                        self?.finish(status)
                    }
                })
        } catch {
            notice = error.localizedDescription
            return
        }

        cancelled = false
        activeName = name
        activeID = plan.models.first
        receivedBytes = 0
        totalBytes = plan.totalBytes
        notice = nil
        modelTool = tool

        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in splitter.lines(from: data) {
                self?.consume(line)
            }
        }
    }

    func cancelDownload() {
        guard let tool = modelTool else { return }
        cancelled = true
        tool.terminate()
    }

    func remove(_ id: String) async {
        let root = AIWorker.modelsDirectory.standardizedFileURL
        let target = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return }
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: target)
        }.value
        ModelActivity.shared.forget(id)
        verdicts[id] = nil
        await refresh()
    }

    /// Progress lines are `{"download": {"file", "received", "offset", "total"}}`.
    private nonisolated func consume(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let update = object["download"] as? [String: Any] else { return }
        let received = (update["offset"] as? Int ?? 0) + (update["received"] as? Int ?? 0)
        let total = update["total"] as? Int ?? 0
        Task { @MainActor in
            self.receivedBytes = max(self.receivedBytes, received)
            if total > 0 { self.totalBytes = total }
        }
    }

    /// Turns the pipe's byte stream into whole lines. `readabilityHandler`
    /// fires on its own queue, so the partial line is guarded rather than passed
    /// between events by hand.
    private final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""

        func lines(from data: Data) -> [String] {
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            lock.lock()
            defer { lock.unlock() }
            buffer += text
            var parts = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            buffer = parts.popLast() ?? ""
            return parts.filter { !$0.isEmpty }
        }
    }

    private func finish(_ status: Int32?) {
        modelTool = nil
        activeID = nil
        if cancelled {
            notice = L10n.current.modelsDownloadCancelled
        } else if status == 0 {
            notice = L10n.current.modelsDownloaded(activeName)
            receivedBytes = totalBytes
        } else {
            notice = L10n.current.modelsDownloadFailed
        }
        Task { await refresh() }
    }
}
