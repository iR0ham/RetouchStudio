import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Launches and talks to the local AI helper.
///
/// The helper is a separate process on purpose: it can be killed without
/// touching the document, it never receives more than a copy of the working
/// pixels, and its job path contains no network code. This type only starts it,
/// hands it a temporary copy of the photo, and turns the reply into an `AIEdit`.
enum AIWorker {

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("RetouchStudio/AI", isDirectory: true)
    }

    /// Longest edge handed to the helper. The mask policy and the patch size
    /// were measured on an image of this size, so the app does not send more.
    static let workingLongEdge: CGFloat = 1600

    static var jobsDirectory: URL {
        supportDirectory.appendingPathComponent("jobs", isDirectory: true)
    }

    static var modelsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_MODELS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    private static var launched: Process?

    // MARK: - Running the helper

    private static func interpreter() -> URL? {
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_PYTHON"] {
            let url = URL(fileURLWithPath: override)
            return manager.isExecutableFile(atPath: url.path) ? url : nil
        }
        var candidates = [supportDirectory.appendingPathComponent("venv/bin/python3")]
        if let repo = repositoryRoot() {
            candidates.append(repo.appendingPathComponent(".venv/bin/python3"))
            // The source checkout keeps its environment beside `worker/`, not
            // inside it.
            candidates.append(repo.deletingLastPathComponent()
                .appendingPathComponent(".venv/bin/python3"))
        }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    /// The source checkout, when the app is running next to one. A packaged app
    /// carries the helper inside its bundle instead, which Phase 5 adds.
    private static func repositoryRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_WORKER_ROOT"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let local = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("RetouchStudio-Phase0/worker", isDirectory: true)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// True when the helper can be started on this machine at all.
    static var isInstalled: Bool { interpreter() != nil && repositoryRoot() != nil }

    static func ensureRunning() throws {
        if WorkerClient.shared.isAvailable() { return }
        guard let python = interpreter(), let root = repositoryRoot() else {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiHelperMissing)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
        let socket = WorkerClient.socketPath
        try? manager.removeItem(atPath: socket)

        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-m", "retouch_ai_worker", "serve",
            "--socket", socket,
            "--jobs", jobsDirectory.path,
            "--models", modelsDirectory.path,
            // The helper may read the temporary working copy and its own model
            // root, and nothing else.
            "--allow-root", workingDirectory.path,
            "--allow-root", modelsDirectory.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = root.path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let log = supportDirectory.appendingPathComponent("worker.log")
        try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: log.path) {
            manager.createFile(atPath: log.path, contents: nil)
        }
        process.standardOutput = try FileHandle(forWritingTo: log)
        process.standardError = try FileHandle(forWritingTo: log)
        try process.run()
        launched = process

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if WorkerClient.shared.isAvailable() { return }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !WorkerClient.shared.isAvailable() {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiHelperMissing)
        }
    }

    /// Stops a helper this app started. A helper the owner launched by hand is
    /// left alone.
    static func shutdown() {
        guard let process = launched, process.isRunning else { return }
        _ = try? WorkerClient.shared.call("shutdown", timeout: 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        launched = nil
    }

    /// Quit-time stop. A child process outlives the app unless it is signalled,
    /// and the async fallback in `shutdown` never runs once we are terminating.
    static func terminate() {
        guard let process = launched, process.isRunning else { return }
        process.terminate()
        launched = nil
    }

    // MARK: - Working copies

    /// Where the helper may read. One folder per instance, cleared on quit.
    static var workingDirectory: URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetouchStudioAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Writes the photo at working size and returns its URL and pixel size.
    /// This is a copy: the original file is never handed to the helper.
    static func writeWorkingCopy(_ image: CGImage) throws -> (url: URL, size: CGSize) {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, workingLongEdge / max(width, height))
        let target = CGSize(width: max(1, (width * scale).rounded()),
                            height: max(1, (height * scale).rounded()))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(target.width),
                                      height: Int(target.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AIWorkerFailure(code: -32000, message: "could not prepare the photo") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target))
        guard let scaled = context.makeImage() else {
            throw AIWorkerFailure(code: -32000, message: "could not prepare the photo")
        }

        let folder = workingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("photo.png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AIWorkerFailure(code: -32000, message: "could not write the working copy")
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AIWorkerFailure(code: -32000, message: "could not write the working copy")
        }
        return (url, target)
    }

    static func clearWorkingCopies() {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// Writes a rendered export at its own size for the upscaler. Unlike
    /// `writeWorkingCopy` this never resizes: the job exists to add pixels, so
    /// shrinking first would throw away what it is supposed to enlarge.
    static func writeUpscaleSource(_ image: CIImage,
                                   processor: ImageProcessor = .shared) throws -> URL {
        let folder = workingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("source.png")
        guard processor.write(image, to: url, format: .png, quality: 1.0,
                              colorSpace: ExportUpscale.workingColorSpace,
                              metadata: [:]) else {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiBadReply)
        }
        return url
    }
}
