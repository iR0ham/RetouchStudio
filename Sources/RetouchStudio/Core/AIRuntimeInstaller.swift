import Foundation

/// Downloads the optional AI runtime for the light build. Nothing is fetched
/// until the owner approves the exact archive, its size and its SHA256; the
/// downloaded file is verified before it is extracted.
///
/// The published `phase` is the explicit state machine in
/// `AIRuntimeInstallPhase`: every move goes through its reducer, so a late
/// URLSession callback cannot resurrect a cancelled or finished install.
@MainActor
final class AIRuntimeInstaller: ObservableObject {

    static let shared = AIRuntimeInstaller()

    @Published private(set) var phase: AIRuntimeInstallPhase
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0

    var package: AIRuntime.Package? { AIRuntime.package }

    var isBusy: Bool { phase.isBusy }

    var percent: Int {
        guard total > 0 else { return 0 }
        return max(0, min(100, Int((Double(received) / Double(total) * 100).rounded())))
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloader: DownloadDelegate?
    /// One token per attempt; a cancel during `.installing` reaches the
    /// transaction through this and nothing else.
    private var cancellation: AIRuntimeInstallCancellation?

    private init() {
        // A previous installation may have been interrupted after the old
        // runtime was moved aside. Recovery can run the functional contract, so
        // it stays off the main actor; the card shows the structural state
        // until the result arrives.
        phase = AIRuntime.isStructurallyInstalled ? .ready : .notInstalled
        Task.detached(priority: .utility) {
            let result = AIWorker.recoverRuntimeIfNeeded(force: true)
            let installed = AIRuntime.isStructurallyInstalled
            await MainActor.run {
                guard !self.phase.isBusy else { return }
                if !result.isSuccess {
                    let failure = AIRuntimeInstallFailure(
                        kind: .install,
                        message: result.failure?.code == .busy
                            ? L10n.current.aiRuntimeBusy
                            : L10n.current.aiRuntimeRecoveryFailed)
                    self.apply(.failed(failure))
                } else {
                    self.apply(.recoveryFinished(installed: installed))
                }
            }
        }
    }

    /// The consent alert is on screen. Asking twice is harmless: the reducer
    /// refuses the second request instead of stacking prompts, and the caller
    /// only presents the alert when this returns true.
    @discardableResult
    func requestConsent() -> Bool {
        // `.cancelled` and `.failed` are left by a retry, which always asks
        // for consent again; a first install moves straight to asking.
        if apply(.retryRequested) { return true }
        return apply(.consentRequested)
    }

    /// The consent alert was dismissed without approving a download.
    func declineConsent() {
        guard apply(.consentDeclined) else { return }
        resetTransport()
        received = 0
        total = 0
    }

    func install(_ package: AIRuntime.Package) {
        guard !isBusy else { return }
        // Consent is a transition, not a comment: a download cannot start from
        // any phase the owner has not approved.
        guard apply(.consentGranted(totalBytes: package.bytes)) else { return }
        received = 0
        total = max(0, package.bytes)

        let cancellation = AIRuntimeInstallCancellation()
        self.cancellation = cancellation

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let downloader = DownloadDelegate()
        downloader.onProgress = { [weak self] written, expected in
            Task { @MainActor [weak self] in
                self?.noteProgress(written, expected)
            }
        }
        downloader.onFinish = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finish(result, package: package, cancellation: cancellation)
            }
        }

        let session = URLSession(configuration: configuration,
                                 delegate: downloader, delegateQueue: nil)
        let task = session.downloadTask(with: package.url)
        self.downloader = downloader
        self.session = session
        self.task = task
        task.resume()
    }

    func cancel() {
        guard phase.isCancellable else { return }
        // The token is what a transaction in `.installing` reads; the URLSession
        // ones stop a transfer. Both are set before the phase moves so no
        // callback can win the race and report progress afterwards.
        cancellation?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        resetTransport()
        received = 0
        total = 0
        apply(.cancelRequested)
    }

    private func noteProgress(_ written: Int64, _ expected: Int64) {
        apply(.downloadProgress(receivedBytes: written, totalBytes: expected))
    }

    private func resetTransport() {
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
        downloader = nil
    }

    @discardableResult
    private func apply(_ event: AIRuntimeInstallEvent) -> Bool {
        guard AIRuntimeInstallReducer.reduce(current: phase, into: &phase, event: event) else {
            return false
        }
        switch phase {
        case .downloading(let written, let expected):
            received = written
            total = expected
        case .ready:
            received = total
        default:
            break
        }
        return true
    }

    private func finish(_ result: Result<URL, Error>,
                        package: AIRuntime.Package,
                        cancellation: AIRuntimeInstallCancellation) {
        resetTransport()
        if cancellation.isCancelled {
            if case .success(let archive) = result {
                try? FileManager.default.removeItem(at: archive)
            }
            return
        }
        switch result {
        case .failure(let error):
            if (error as NSError).code == NSURLErrorCancelled {
                // The session was torn down without our token: report the same
                // stop instead of leaving the phase stuck in `.downloading`.
                apply(.cancelRequested)
            } else {
                apply(.failed(AIRuntimeInstallFailure.classify(error)))
            }
        case .success(let archive):
            verify(archive, package: package, cancellation: cancellation)
        }
    }

    private func verify(_ archive: URL, package: AIRuntime.Package,
                        cancellation: AIRuntimeInstallCancellation) {
        guard apply(.downloaded) else {
            try? FileManager.default.removeItem(at: archive)
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let digest = try AIRuntime.sha256(of: archive)
                guard digest == package.sha256.lowercased() else {
                    throw AIRuntimeFailure(code: .checksum)
                }
                await MainActor.run {
                    guard !cancellation.isCancelled else {
                        try? FileManager.default.removeItem(at: archive)
                        return
                    }
                    self.extract(archive, cancellation: cancellation)
                }
            } catch {
                await MainActor.run {
                    try? FileManager.default.removeItem(at: archive)
                    guard !cancellation.isCancelled else { return }
                    self.apply(.failed(AIRuntimeInstallFailure.classify(error)))
                }
            }
        }
    }

    private func extract(_ archive: URL, cancellation: AIRuntimeInstallCancellation) {
        guard apply(.verified) else {
            try? FileManager.default.removeItem(at: archive)
            return
        }
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Void, Error>
            do {
                var hooks = AIRuntime.InstallHooks()
                hooks.beforeInstall = {
                    try AIWorker.prepareForRuntimeReplacement(
                        support: AIWorker.runtimeSupportDirectory)
                }
                // The transaction verifies the archive again, under its own
                // lock, so a file swapped between download and install is
                // rejected rather than extracted. It also reads the token at
                // every point where a stop leaves a consistent tree.
                try AIRuntime.install(archive: archive,
                                      support: AIWorker.runtimeSupportDirectory,
                                      package: AIRuntime.package,
                                      hooks: hooks,
                                      cancellation: cancellation)
                AIWorker.runtimeDidChange()
                AIWorker.noteRuntimeValidated()
                outcome = .success(())
            } catch {
                // A failed attempt may have left a different live directory, so
                // the cached "validated" answer for this process is no longer
                // trustworthy.
                AIWorker.runtimeDidChange()
                outcome = .failure(error)
            }
            try? FileManager.default.removeItem(at: archive)
            await MainActor.run {
                switch outcome {
                case .failure(let error):
                    if error is AIRuntimeInstallCancelled { return }
                    guard !cancellation.isCancelled else { return }
                    self.apply(.failed(AIRuntimeInstallFailure.classify(error)))
                case .success:
                    self.received = self.total
                    // A commit that landed before the cancel was acknowledged
                    // is the truth: the runtime is on disk.
                    self.apply(.installed)
                }
            }
        }
    }
}

/// URLSession hands downloads to its delegate on a private queue. This object
/// keeps the callbacks out of the main actor and forwards them there.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    private let lock = NSLock()
    private var finished = false

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        onFinish?(result)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent("retouch-runtime-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            complete(.success(keep))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)) }
    }
}
