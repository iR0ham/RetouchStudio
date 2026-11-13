import CryptoKit
import Foundation
import StudioCore

/// The cryptographic half of the update system. The portable rules live in
/// `StudioCore.UpdatePolicy`; this file only turns base64 into keys and bytes.
enum UpdateSignature {
    /// The release key. Its private half is kept outside the repository (see
    /// Docs/UPDATE_SYSTEM.md) and never ships; losing it only means the owner
    /// has to rotate the public key in a release, not that verification can be
    /// skipped.
    static let releasePublicKey = "jMAfiu36PqtRkYbgwFWjBbKJi59q7ICX7xegXZ1gz2g="

    static func verify(descriptor: String, signatureBase64: String,
                       publicKeyBase64: String = releasePublicKey) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64),
              let rawKey = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        else { return false }
        return key.isValidSignature(signature, for: Data(descriptor.utf8))
    }
}

enum UpdateVerificationError: LocalizedError, Equatable {
    case wrongSize(expected: Int, actual: Int)
    case digestMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .wrongSize(let expected, let actual):
            return "The downloaded update is \(actual) bytes; the signed manifest says \(expected)."
        case .digestMismatch(let expected, let actual):
            return "The downloaded update hashes to \(actual); the signed manifest says \(expected)."
        }
    }
}

enum UpdateFileCheck {
    /// Size and SHA-256 are checked against the signed artifact before anything
    /// is unpacked or moved.
    static func verify(at file: URL, artifact: UpdateArtifact,
                       fileManager: FileManager = .default) throws {
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard size == artifact.size else {
            throw UpdateVerificationError.wrongSize(expected: artifact.size, actual: size)
        }
        let digest = try AIRuntime.sha256(of: file)
        guard digest.lowercased() == artifact.sha256.lowercased() else {
            throw UpdateVerificationError.digestMismatch(expected: artifact.sha256.lowercased(),
                                                         actual: digest.lowercased())
        }
    }
}

/// What a swap leaves behind if the process dies mid-move. The journal is
/// written before the first rename and read on the next launch, so a crash
/// between the two renames is completed or undone instead of leaving half an
/// application on disk.
struct UpdateJournal: Codable, Equatable {
    var current: String
    var staged: String
    var backup: String
}

enum UpdateInstallError: LocalizedError, Equatable {
    case notAnApp(String)
    case missingCurrent(String)
    case parentNotWritable(String)
    case differentVolumes(String, String)
    case swapFailed(String)
    case unreadableJournal(String)
    case unrecoverableJournal(String)
    case unpackFailed(String)
    case wrongBundle(String)

    var errorDescription: String? {
        switch self {
        case .notAnApp(let path): return "\(path) is not an application bundle."
        case .missingCurrent(let path): return "The installed application is missing at \(path)."
        case .parentNotWritable(let path):
            return "\(path) is not writable; move the application somewhere writable or install it manually."
        case .differentVolumes(let a, let b):
            return "\(a) and \(b) are on different volumes; a safe atomic swap is impossible."
        case .swapFailed(let reason): return "The update could not be swapped in: \(reason)"
        case .unreadableJournal(let path): return "The update journal at \(path) is unreadable."
        case .unrecoverableJournal(let path):
            return "The update journal at \(path) refers to missing bundles. Reinstall from the release DMG."
        case .unpackFailed(let reason): return "The update archive could not be unpacked: \(reason)"
        case .wrongBundle(let reason): return "The unpacked application is not the expected release: \(reason)"
        }
    }
}

enum UpdateRecovery: Equatable {
    /// No journal: nothing was interrupted.
    case none
    /// The new bundle is in place; a leftover backup was removed.
    case completed
    /// The old bundle is back in place.
    case rolledBack
    /// Nothing had moved yet; the journal was removed.
    case cleared
}

enum UpdateInstaller {
    static func isApplicationBundle(_ url: URL, fileManager: FileManager = .default) -> Bool {
        url.pathExtension.lowercased() == "app"
            && fileManager.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }

    /// Unpacks a verified `zip` and returns its single `.app`. A bundle with
    /// another identifier or version is refused even when its signature and
    /// hash are valid: the manifest names the release, the payload must be it.
    static func unpack(archive: URL, into workspace: URL,
                       expectedVersion: String, bundleIdentifier: String,
                       fileManager: FileManager = .default) throws -> URL {
        try? fileManager.removeItem(at: workspace)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, workspace.path]
        do { try process.run() } catch {
            throw UpdateInstallError.unpackFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.unpackFailed("ditto exited \(process.terminationStatus)")
        }
        let contents = (try? fileManager.contentsOfDirectory(at: workspace,
                                                             includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "app" } ?? []
        guard contents.count == 1, let app = contents.first,
              isApplicationBundle(app, fileManager: fileManager) else {
            throw UpdateInstallError.wrongBundle("the archive does not contain exactly one application")
        }
        let infoPath = app.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: infoPath))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            as? [String: Any]
        guard let info else { throw UpdateInstallError.wrongBundle("unreadable Info.plist") }
        if !bundleIdentifier.isEmpty,
           (info["CFBundleIdentifier"] as? String) != bundleIdentifier {
            throw UpdateInstallError.wrongBundle("bundle identifier \(info["CFBundleIdentifier"] ?? "missing")")
        }
        guard (info["CFBundleShortVersionString"] as? String) == expectedVersion else {
            throw UpdateInstallError.wrongBundle("version \(info["CFBundleShortVersionString"] ?? "missing"), expected \(expectedVersion)")
        }
        return app
    }

    /// Moves `stagedApp` over `currentApp` with a journal and a backup. The
    /// replacement must sit on the same volume; anything else would turn the
    /// final rename into a copy that can be interrupted halfway.
    static func swap(stagedApp: URL, over currentApp: URL, journalURL: URL,
                     fileManager: FileManager = .default) throws {
        guard isApplicationBundle(stagedApp, fileManager: fileManager) else {
            throw UpdateInstallError.notAnApp(stagedApp.path)
        }
        guard isApplicationBundle(currentApp, fileManager: fileManager) else {
            throw UpdateInstallError.missingCurrent(currentApp.path)
        }
        let parent = currentApp.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.parentNotWritable(parent.path)
        }
        guard sameVolume(stagedApp, currentApp) else {
            throw UpdateInstallError.differentVolumes(stagedApp.path, currentApp.path)
        }

        let backup = parent.appendingPathComponent(".\(currentApp.lastPathComponent).backup-\(UUID().uuidString)")
        let journal = UpdateJournal(current: currentApp.path, staged: stagedApp.path,
                                    backup: backup.path)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)

        do {
            try fileManager.moveItem(at: currentApp, to: backup)
        } catch {
            try? fileManager.removeItem(at: journalURL)
            throw UpdateInstallError.swapFailed(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: stagedApp, to: currentApp)
        } catch {
            try? fileManager.moveItem(at: backup, to: currentApp)
            try? fileManager.removeItem(at: journalURL)
            throw UpdateInstallError.swapFailed(error.localizedDescription)
        }
        try? fileManager.removeItem(at: backup)
        try? fileManager.removeItem(at: journalURL)
    }

    /// Called on launch. Decides from what exists on disk, not from a stored
    /// phase, so a journal written by an older build is still interpretable.
    @discardableResult
    static func recover(journalURL: URL, fileManager: FileManager = .default) throws -> UpdateRecovery {
        guard fileManager.fileExists(atPath: journalURL.path) else { return .none }
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(UpdateJournal.self, from: data)
        else { throw UpdateInstallError.unreadableJournal(journalURL.path) }

        let current = URL(fileURLWithPath: journal.current)
        let staged = URL(fileURLWithPath: journal.staged)
        let backup = URL(fileURLWithPath: journal.backup)
        let hasCurrent = fileManager.fileExists(atPath: current.path)
        let hasStaged = fileManager.fileExists(atPath: staged.path)
        let hasBackup = fileManager.fileExists(atPath: backup.path)
        let removeJournal = { try? fileManager.removeItem(at: journalURL) }

        if hasCurrent && hasBackup {
            // The new bundle is in place; the backup is a leftover.
            try? fileManager.removeItem(at: backup)
            removeJournal()
            return .completed
        }
        if !hasCurrent && hasBackup {
            if hasStaged, (try? fileManager.moveItem(at: staged, to: current)) != nil {
                try? fileManager.removeItem(at: backup)
                removeJournal()
                return .completed
            }
            try? fileManager.moveItem(at: backup, to: current)
            removeJournal()
            return .rolledBack
        }
        if hasCurrent && !hasBackup {
            // Either the swap never started or it finished and the backup was
            // already removed. The installed bundle is whole either way.
            removeJournal()
            return .cleared
        }
        throw UpdateInstallError.unrecoverableJournal(journalURL.path)
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func identifier(_ url: URL) -> Any? {
            try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        guard let left = identifier(a), let right = identifier(b) else { return false }
        return String(describing: left) == String(describing: right)
    }
}

enum UpdateDownloadError: LocalizedError, Equatable {
    case insecureURL(String)
    case badResponse(Int)
    case redirectedToInsecureURL(String)
    case tooLarge(Int)
    case emptyDownload

    var errorDescription: String? {
        switch self {
        case .insecureURL(let url): return "The update URL is not HTTPS: \(url)"
        case .badResponse(let status): return "The update download returned HTTP \(status)."
        case .redirectedToInsecureURL(let url): return "The update download was redirected to \(url)."
        case .tooLarge(let limit):
            return "The update is larger than the signed \(limit)-byte artifact; the download was stopped."
        case .emptyDownload: return "The update download finished without writing a file."
        }
    }
}

/// Streams the artifact to disk and stops the transfer as soon as it passes the
/// signed byte count. The signature is only checked after the download, so an
/// unbounded transfer would let a hostile feed fill the disk before being
/// refused.
private final class BoundedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let artifact: UpdateArtifact
    private let staged: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var finished = false

    init(artifact: UpdateArtifact, staged: URL) {
        self.artifact = artifact
        self.staged = staged
    }

    func run(session: URLSession, url: URL) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let request = URLRequest(url: url, timeoutInterval: 60)
            session.downloadTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<URLResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let response): waiting?.resume(returning: response)
        case .failure(let error): waiting?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            finish(.failure(UpdateDownloadError.redirectedToInsecureURL(request.url?.absoluteString ?? "?")))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten > Int64(artifact.size) else { return }
        downloadTask.cancel()
        finish(.failure(UpdateDownloadError.tooLarge(artifact.size)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(UpdateDownloadError.badResponse(http.statusCode)))
            return
        }
        guard let response = downloadTask.response else {
            finish(.failure(UpdateDownloadError.emptyDownload))
            return
        }
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(response))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(UpdateDownloadError.emptyDownload))
        }
    }
}

enum UpdateDownloader {
    /// Downloads through HTTPS only, refuses a redirect to plain HTTP, stops a
    /// transfer that passes the signed byte count, and does not hand the file
    /// back until size and SHA-256 match the signed manifest.
    static func download(_ artifact: UpdateArtifact, to destination: URL) async throws {
        guard let url = URL(string: artifact.url), url.scheme?.lowercased() == "https" else {
            throw UpdateDownloadError.insecureURL(artifact.url)
        }
        let staged = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: staged)
        let collector = BoundedDownload(artifact: artifact, staged: staged)
        let session = URLSession(configuration: .ephemeral, delegate: collector,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await collector.run(session: session, url: url)
        try UpdateFileCheck.verify(at: staged, artifact: artifact)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
    }
}
