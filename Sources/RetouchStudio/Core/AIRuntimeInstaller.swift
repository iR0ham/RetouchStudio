import Foundation

/// The optional runtime arrives as one approved archive. This type owns the
/// transfer, the retained resume state, the disk preflight and the state
/// machine; extraction and the swap stay in `AIRuntimeTransaction`.
///
/// The published `phase` is the explicit state machine in
/// `AIRuntimeInstallPhase`: every move goes through its reducer, so a late
/// transfer callback cannot resurrect a cancelled or finished install.
@MainActor
final class AIRuntimeInstaller: ObservableObject {

    static let shared = AIRuntimeInstaller()

    /// Everything the installer reaches outside itself, in one injectable
    /// value so the transfer suites run offline against a local directory.
    struct Environment {
        var support: URL = AIWorker.runtimeSupportDirectory
        var makeEngine: () -> AIRuntimeTransferEngine = { URLSessionTransferEngine() }
        var availableCapacity: (URL) -> Int64? = AIRuntimeDiskPreflight.availableCapacity
        /// The support directory is passed in, not read from the app: a test
        /// environment that points support elsewhere must not prepare a helper
        /// against the real one.
        var makeHooks: (URL, AIRuntime.Package) -> AIRuntime.InstallHooks = { support, _ in
            var hooks = AIRuntime.InstallHooks()
            hooks.beforeInstall = {
                try AIWorker.prepareForRuntimeReplacement(support: support)
            }
            return hooks
        }
        var runtimeChanged: () -> Void = { AIWorker.runtimeDidChange() }
        var runtimeValidated: () -> Void = { AIWorker.noteRuntimeValidated() }
        var startsRecovered: Bool = true
    }

    @Published private(set) var phase: AIRuntimeInstallPhase
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0

    var package: AIRuntime.Package? { AIRuntime.package }

    var isBusy: Bool { phase.isBusy }

    var percent: Int {
        guard total > 0 else { return 0 }
        return max(0, min(100, Int((Double(received) / Double(total) * 100).rounded())))
    }

    private let environment: Environment
    private var engine: AIRuntimeTransferEngine?
    /// One token per attempt; a cancel during `.installing` reaches the
    /// transaction through this and nothing else.
    private var cancellation: AIRuntimeInstallCancellation?
    private var attempt: AIRuntime.Package?
    /// The reservation this attempt was allowed to start on. The same number is
    /// re-checked before verification and before installation, so a volume that
    /// filled during the transfer is caught before it can half-install a tree.
    private var attemptRequiredBytes: Int64 = 0
    /// Bytes already on disk when the current attempt started. A resumed
    /// transfer that fails without passing this mark let the stored state
    /// down, so it is discarded instead of being forced through.
    private var attemptBaseline: Int64 = 0

    init(environment: Environment = Environment()) {
        self.environment = environment
        // A previous installation may have been interrupted after the old
        // runtime was moved aside. Recovery can run the functional contract, so
        // it stays off the main actor; the card shows the structural state
        // until the result arrives.
        phase = AIRuntime.isStructurallyInstalled ? .ready : .notInstalled
        guard environment.startsRecovered else { return }
        let support = environment.support
        Task.detached(priority: .utility) {
            let result = AIWorker.recoverRuntimeIfNeeded(force: true)
            let installed = AIRuntime.isStructurallyInstalled
            // A completed runtime makes any retained partial useless, and a
            // crash between a finished transfer and its install can leave the
            // store behind: sweep it once the machine is known to be whole.
            if result.isSuccess && installed {
                AIRuntimeResumeStore(support: support).clear()
            }
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

    /// The consent alert was dismissed without approving a download. A
    /// retained partial transfer survives this: the owner may come back.
    func declineConsent() {
        guard apply(.consentDeclined) else { return }
        engine = nil
        received = 0
        total = 0
    }

    func install(_ package: AIRuntime.Package) {
        guard !isBusy, phase == .awaitingConsent else { return }

        // The preflight runs while consent is still the current phase: a
        // refusal lands in `failed(.insufficientDisk)` without ever entering
        // `.downloading`, so nothing is fetched and nothing is staged. The
        // reservation includes an existing live tree, because an upgrade keeps
        // it on the volume while the new tree is unpacked beside it.
        attemptRequiredBytes = AIRuntimeDiskPreflight.requiredBytes(
            archiveBytes: package.bytes,
            existingInstallBytes: AIRuntimeDiskPreflight.size(
                of: AIRuntime.installDirectory(in: environment.support)))
        if let failure = insufficientDiskFailure(required: attemptRequiredBytes) {
            apply(.failed(failure))
            return
        }

        // Consent is a transition, not a comment: a download cannot start from
        // any phase the owner has not approved.
        guard apply(.consentGranted(totalBytes: package.bytes)) else { return }
        cancellation = AIRuntimeInstallCancellation()
        attempt = package

        // A retained transfer is only usable for exactly this archive; a stale
        // or mismatched one is discarded by the store before this returns.
        let resume = AIRuntimeResumeStore(support: environment.support).load(for: package)
        begin(package: package, resume: resume, allowFreshFallback: resume != nil)
    }

    /// The one capacity gate, used before the transfer, before verification and
    /// before installation. The reservation is a floor, not a prediction: free
    /// space can change while the transfer runs, which is why the later gates
    /// exist. An unreadable capacity withholds judgement and lets the failing
    /// operation report what actually happened.
    private func insufficientDiskFailure(required: Int64) -> AIRuntimeInstallFailure? {
        guard let free = environment.availableCapacity(environment.support),
              free < required else { return nil }
        return AIRuntimeInstallFailure(
            kind: .insufficientDisk,
            message: L10n.current.aiRuntimeInsufficientDisk(neededBytes: required,
                                                            freeBytes: free))
    }

    func cancel() {
        guard phase.isCancellable else { return }
        let downloading = phase.isDownloading
        cancellation?.cancel()
        if downloading, let package = attempt {
            let support = environment.support
            engine?.cancel(producingResumeData: { data, partial in
                // The socket stops inside `cancel`, before this closure runs:
                // `.cancelled` is published below while the store may still be
                // copying up to the whole archive on a background queue. If the
                // process exits in that window the pair is lost and the next
                // attempt falls back to a clean download; the copy never
                // delays the phase the owner sees.
                // Without resume data there is nothing a later retry could
                // continue; the store stays as it was (empty at this point).
                guard let data else { return }
                _ = AIRuntimeResumeStore(support: support)
                    .save(resumeData: data, partial: partial, package: package)
                // The store now owns the bytes. The engine's own temporary copy
                // is either redundant (saved) or unusable (not saved), so it is
                // removed rather than left in the process temporary directory.
                if let partial,
                   partial.deletingLastPathComponent().standardizedFileURL
                    == FileManager.default.temporaryDirectory.standardizedFileURL {
                    try? FileManager.default.removeItem(at: partial)
                }
            })
        }
        engine = nil
        received = 0
        total = 0
        apply(.cancelRequested)
    }

    // MARK: - Transfer

    private func begin(package: AIRuntime.Package, resume: AIRuntimeTransferResume?,
                       allowFreshFallback: Bool) {
        let retained = resume.map { AIRuntimeResumeStore.size(of: $0.partial) } ?? 0
        attemptBaseline = min(max(0, retained), max(0, package.bytes))
        received = attemptBaseline
        total = max(0, package.bytes)
        if attemptBaseline > 0 {
            apply(.downloadProgress(receivedBytes: attemptBaseline, totalBytes: total))
        }

        let engine = environment.makeEngine()
        self.engine = engine
        engine.start(
            package: package,
            resume: resume,
            onProgress: { [weak self] written, expected in
                Task { @MainActor [weak self] in
                    self?.noteProgress(written, expected)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.finish(result, package: package,
                                 allowFreshFallback: allowFreshFallback)
                }
            })
    }

    private func noteProgress(_ written: Int64, _ expected: Int64) {
        apply(.downloadProgress(receivedBytes: written, totalBytes: expected))
    }

    private func finish(_ result: Result<URL, Error>, package: AIRuntime.Package,
                        allowFreshFallback: Bool) {
        engine = nil
        guard let cancellation else { return }
        if cancellation.isCancelled {
            if case .success(let archive) = result {
                try? FileManager.default.removeItem(at: archive)
            }
            return
        }
        switch result {
        case .failure(let error):
            if (error as NSError).code == NSURLErrorCancelled {
                // The engine was torn down without our token: report the same
                // stop instead of leaving the phase stuck in `.downloading`.
                apply(.cancelRequested)
                return
            }
            // A stored resume that never moved past its baseline is unusable
            // (the partial was purged, or the server would not continue it).
            // Discard it and restart cleanly once — never continue a transfer
            // that cannot be verified against the approved archive.
            if allowFreshFallback, received <= attemptBaseline {
                AIRuntimeResumeStore(support: environment.support).clear()
                begin(package: package, resume: nil, allowFreshFallback: false)
                return
            }
            apply(.failed(AIRuntimeInstallFailure.classify(error)))
        case .success(let archive):
            // The transfer is done; nothing here is resumable any more, and a
            // failed verification must not leave a partial a retry could trust.
            AIRuntimeResumeStore(support: environment.support).clear()
            verify(archive, package: package)
        }
    }

    // MARK: - Verification and install

    private func verify(_ archive: URL, package: AIRuntime.Package) {
        // The transfer took room of its own; the unpack needs the rest. The
        // check runs before `.verifying`, so a volume that filled during the
        // download never reaches a stage that looks like progress.
        if let failure = insufficientDiskFailure(required: attemptRequiredBytes) {
            try? FileManager.default.removeItem(at: archive)
            apply(.failed(failure))
            return
        }
        guard apply(.downloaded) else {
            try? FileManager.default.removeItem(at: archive)
            return
        }
        guard let cancellation else { return }
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
                    self.extract(archive, package: package, cancellation: cancellation)
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

    private func extract(_ archive: URL, package: AIRuntime.Package,
                         cancellation: AIRuntimeInstallCancellation) {
        // Last gate before the transaction is allowed to write a staging tree:
        // the archive is on disk now, so this is the check that catches a
        // volume that lost space while the download was verified.
        if let failure = insufficientDiskFailure(required: attemptRequiredBytes) {
            try? FileManager.default.removeItem(at: archive)
            apply(.failed(failure))
            return
        }
        guard apply(.verified) else {
            try? FileManager.default.removeItem(at: archive)
            return
        }
        // Values are read on the main actor and captured; the transaction runs
        // off it under its own lock.
        let support = environment.support
        let hooks = environment.makeHooks(support, package)
        let runtimeChanged = environment.runtimeChanged
        let runtimeValidated = environment.runtimeValidated
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Void, Error>
            do {
                // The transaction verifies the archive again, under its own
                // lock, so a file swapped between download and install is
                // rejected rather than extracted. It also reads the token at
                // every point where a stop leaves a consistent tree.
                try AIRuntime.install(archive: archive,
                                      support: support,
                                      package: package,
                                      hooks: hooks,
                                      cancellation: cancellation)
                runtimeChanged()
                runtimeValidated()
                outcome = .success(())
            } catch {
                // A failed attempt may have left a different live directory, so
                // the cached "validated" answer for this process is no longer
                // trustworthy.
                runtimeChanged()
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
}

// MARK: - The transfer seam

/// A resumable transfer of one package. Production uses URLSession; the
/// suites substitute an engine that writes a local file, so no test opens a
/// connection.
protocol AIRuntimeTransferEngine: AnyObject {
    /// Starts, or continues from `resume`. Progress is the bytes written so
    /// far (including already-retained bytes) and the expected total.
    func start(package: AIRuntime.Package,
               resume: AIRuntimeTransferResume?,
               onProgress: @escaping (Int64, Int64) -> Void,
               onFinish: @escaping (Result<URL, Error>) -> Void)
    /// Stops the transfer and produces the data a later `start` can continue
    /// from, plus the partial file the data refers to (when the engine keeps
    /// one) so the caller can retain both.
    func cancel(producingResumeData: @escaping (Data?, URL?) -> Void)
}

/// The two pieces of a retained transfer: the engine's opaque resume data and
/// the partial archive it continues.
struct AIRuntimeTransferResume: Equatable {
    let data: Data
    let partial: URL?
}

// MARK: - Retained resume state

/// Keeps one interrupted transfer on disk, keyed to the exact package identity
/// (file name, SHA256 and byte count) so a resume can only ever finish the
/// archive the owner approved. Anything else is discarded before a download
/// starts, never activated.
struct AIRuntimeResumeStore {

    struct Identity: Codable, Equatable {
        let fileName: String
        let sha256: String
        let bytes: Int64

        init(package: AIRuntime.Package) {
            fileName = package.fileName
            sha256 = package.sha256.lowercased()
            bytes = package.bytes
        }
    }

    /// One fixed directory beside the runtime: it cannot grow per attempt, and
    /// every path below clears it.
    static let directoryName = "protocol-v2-download"

    let support: URL

    var directory: URL {
        support.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var partialURL: URL { directory.appendingPathComponent("partial.zip") }
    private var resumeDataURL: URL { directory.appendingPathComponent("resume.data") }
    private var identityURL: URL { directory.appendingPathComponent("identity.json") }

    static func size(of url: URL?) -> Int64 {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// Persists the pair. Returns false when either piece did not land, in
    /// which case nothing is left behind.
    @discardableResult
    func save(resumeData: Data, partial: URL?, package: AIRuntime.Package) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? manager.removeItem(at: partialURL)
            if let partial, manager.fileExists(atPath: partial.path) {
                try manager.copyItem(at: partial, to: partialURL)
            }
            try resumeData.write(to: resumeDataURL, options: .atomic)
            let identity = try JSONEncoder().encode(Identity(package: package))
            try identity.write(to: identityURL, options: .atomic)
            guard Self.size(of: partialURL) > 0 else {
                clear()
                return false
            }
            return true
        } catch {
            clear()
            return false
        }
    }

    /// The retained transfer, only when every piece is present and belongs to
    /// this package. A mismatch is discarded, not reported: the caller simply
    /// starts a clean download.
    func load(for package: AIRuntime.Package) -> AIRuntimeTransferResume? {
        guard let identityData = try? Data(contentsOf: identityURL),
              let stored = try? JSONDecoder().decode(Identity.self, from: identityData)
        else {
            clear()
            return nil
        }
        let expected = Identity(package: package)
        guard stored == expected,
              let data = try? Data(contentsOf: resumeDataURL), !data.isEmpty,
              Self.size(of: partialURL) > 0,
              Self.size(of: partialURL) <= package.bytes
        else {
            clear()
            return nil
        }
        return AIRuntimeTransferResume(data: data, partial: partialURL)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Disk preflight

/// How much free space an install needs before the first byte is fetched.
///
/// Evidence: `Docs/RELEASING.md:186` records the approved runtime shape as an
/// optional ~390 MB Apple-silicon download that unpacks to about 1.3 GB. The
/// archive and the extracted tree are on the same volume at the same time
/// during the swap, so the estimate charges the archive plus 3.5× its size
/// (3.33× measured, rounded up as headroom) plus 64 MiB for the transaction
/// records and staging directories. An existing live tree is charged as well:
/// it stays on the volume until the new one has passed its probe.
enum AIRuntimeDiskPreflight {

    static let unpackedNumerator: Int64 = 7
    static let unpackedDenominator: Int64 = 2   // 3.5 × archive
    static let bookkeepingHeadroomBytes: Int64 = 64 << 20

    static func requiredBytes(archiveBytes: Int64,
                              existingInstallBytes: Int64 = 0) -> Int64 {
        let existing = max(0, existingInstallBytes)
        guard archiveBytes > 0 else { return existing }
        let unpacked = archiveBytes / unpackedDenominator * unpackedNumerator
            + archiveBytes % unpackedDenominator * unpackedNumerator / unpackedDenominator
        return archiveBytes + unpacked + bookkeepingHeadroomBytes + existing
    }

    /// Bytes an existing directory occupies, or the size of a single file.
    /// A missing path is zero: nothing is reserved for a tree that is not there.
    static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        guard isDirectory.boolValue else {
            return AIRuntimeResumeStore.size(of: url)
        }
        guard let enumerator = manager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Free space the system is willing to give this process, which is the
    /// number the install can actually use. A destination that does not exist
    /// yet is measured on its nearest existing parent, because the volume is
    /// the same one the transfer will write to. `nil` means "could not tell":
    /// the caller proceeds and lets the transfer report a real failure rather
    /// than blocking an install on a failed probe.
    static func availableCapacity(at url: URL) -> Int64? {
        let manager = FileManager.default
        var target = url
        var hops = 0
        while !manager.fileExists(atPath: target.path), hops < 16,
              target.pathComponents.count > 1 {
            target.deleteLastPathComponent()
            hops += 1
        }
        guard manager.fileExists(atPath: target.path),
              let values = try? target.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Production engine

/// URLSession implementation of the seam. Cancellation produces the session's
/// resume data; the partial archive the data refers to is copied out so the
/// store can retain both. Persisting a partial across launches is best effort:
/// if the session cannot continue a stored transfer, the installer discards it
/// and starts a clean download.
final class URLSessionTransferEngine: NSObject, AIRuntimeTransferEngine,
                                      URLSessionDownloadDelegate {

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var onProgress: ((Int64, Int64) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?

    private let lock = NSLock()
    private var finished = false

    func start(package: AIRuntime.Package,
               resume: AIRuntimeTransferResume?,
               onProgress: @escaping (Int64, Int64) -> Void,
               onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: configuration,
                                 delegate: self, delegateQueue: nil)
        self.session = session

        if let resume {
            Self.restorePartial(resume.partial, describedBy: resume.data)
            task = session.downloadTask(withResumeData: resume.data)
        } else {
            task = session.downloadTask(with: package.url)
        }
        task?.resume()
    }

    func cancel(producingResumeData: @escaping (Data?, URL?) -> Void) {
        guard let task else {
            producingResumeData(nil, nil)
            return
        }
        task.cancel { [weak self] data in
            self?.session?.invalidateAndCancel()
            guard let data else {
                producingResumeData(nil, nil)
                return
            }
            producingResumeData(data, Self.partialFile(describedBy: data))
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        onFinish?(result)
        session?.finishTasksAndInvalidate()
    }

    // MARK: URLSessionDownloadDelegate

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

    // MARK: Resume data

    /// The resume data is a property list whose temp-file entry names the
    /// partial inside the session's temporary directory. Reading it is how the
    /// partial can be retained next to the data; if the format ever changes,
    /// the key is missing, the partial is not retained, and the next attempt
    /// starts cleanly.
    static let partialKey = "NSURLSessionResumeInfoTempFileName"

    /// A resume plist belongs to this user's own session, but it is still
    /// untrusted input on the way to `removeItem` and `copyItem`: a name is
    /// accepted only when it is a single path component. `.`, `..` or anything
    /// with a separator would target the temporary directory itself rather
    /// than a partial inside it.
    static func resumeTempName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..",
              name == URL(fileURLWithPath: name).lastPathComponent
        else { return nil }
        return name
    }

    static func tempName(describedBy data: Data) -> String? {
        guard let any = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let plist = any as? [String: Any],
              let name = plist[partialKey] as? String
        else { return nil }
        return resumeTempName(name)
    }

    static func partialFile(describedBy data: Data) -> URL? {
        guard let name = tempName(describedBy: data) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Copies the retained partial back to the name the resume data refers to,
    /// and reports where it wrote it. `nil` means nothing was restored (no
    /// partial, or a name that is not a plain component), which makes the next
    /// attempt fail instead of continuing a half-restored transfer.
    @discardableResult
    static func restorePartial(_ partial: URL?, describedBy data: Data) -> URL? {
        guard let partial, let name = tempName(describedBy: data) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.copyItem(at: partial, to: destination)) != nil else {
            return nil
        }
        return destination
    }
}
