import Foundation

/// Downloads the optional AI runtime for the light build. Nothing is fetched
/// until the owner approves the exact archive, its size and its SHA256; the
/// downloaded file is verified before it is extracted.
@MainActor
final class AIRuntimeInstaller: ObservableObject {

    enum Phase: Equatable {
        case missing
        case downloading
        case verifying
        case installing
        case installed
        case failed(String)
    }

    static let shared = AIRuntimeInstaller()

    @Published private(set) var phase: Phase = AIRuntime.isInstalled ? .installed : .missing
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0

    var package: AIRuntime.Package? { AIRuntime.package }

    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    var percent: Int {
        guard total > 0 else { return 0 }
        return max(0, min(100, Int((Double(received) / Double(total) * 100).rounded())))
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloader: DownloadDelegate?

    private init() {}

    func install(_ package: AIRuntime.Package) {
        guard !isBusy else { return }
        phase = .downloading
        received = 0
        total = package.bytes

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let downloader = DownloadDelegate()
        downloader.onProgress = { [weak self] written, expected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.received = written
                if expected > 0 { self.total = expected }
            }
        }
        downloader.onFinish = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finish(result, package: package)
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
        guard isBusy else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        reset()
        phase = .missing
    }

    private func reset() {
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
        downloader = nil
        received = 0
        total = 0
    }

    private func finish(_ result: Result<URL, Error>, package: AIRuntime.Package) {
        reset()
        switch result {
        case .failure(let error):
            if (error as NSError).code == NSURLErrorCancelled {
                phase = .missing
            } else {
                phase = .failed(L10n.current.aiRuntimeDownloadFailed)
            }
        case .success(let archive):
            verify(archive, package: package)
        }
    }

    private func verify(_ archive: URL, package: AIRuntime.Package) {
        phase = .verifying
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Void, Error>
            do {
                let digest = try AIRuntime.sha256(of: archive)
                guard digest == package.sha256.lowercased() else {
                    throw AIRuntimeFailure(code: .checksum)
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                switch outcome {
                case .failure(let error):
                    try? FileManager.default.removeItem(at: archive)
                    self.phase = .failed(error.localizedDescription)
                case .success:
                    self.extract(archive)
                }
            }
        }
    }

    private func extract(_ archive: URL) {
        phase = .installing
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Void, Error>
            do {
                try AIRuntime.install(archive: archive)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try? FileManager.default.removeItem(at: archive)
            await MainActor.run {
                switch outcome {
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                case .success:
                    self.received = self.total
                    self.phase = .installed
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
