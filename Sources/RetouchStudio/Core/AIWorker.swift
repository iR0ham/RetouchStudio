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
    private static let launchLock = NSRecursiveLock()

    /// Which app process started the running helper. A helper whose app is gone
    /// is stale: the next launch stops it so its socket and temporary paths are
    /// the ones this process will use.
    private struct HelperOwner: Codable {
        let appPID: Int32
        let workerPID: Int32
        let models: String

        static var url: URL {
            supportDirectory.appendingPathComponent("helper-owner.json")
        }

        static func load() -> HelperOwner? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(HelperOwner.self, from: data)
        }

        static func record(appPID: Int32, workerPID: Int32) {
            let owner = HelperOwner(appPID: appPID, workerPID: workerPID,
                                    models: modelsDirectory.path)
            if let data = try? JSONEncoder().encode(owner) { try? data.write(to: url) }
        }

        static func removeIfOwned(by pid: Int32 = getpid()) {
            guard let owner = load(), owner.appPID == pid else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Running the helper

    /// The interpreter and worker that ship inside the app. A release bundle
    /// has them; a source or QA build falls back to the checkout below.
    static var bundledRoot: URL? {
        #if arch(x86_64)
        // The bundled helper is an Apple-silicon runtime; an Intel Mac cannot
        // execute it. A source checkout with a matching environment still works.
        return nil
        #else
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("Worker", isDirectory: true)
        let python = root.appendingPathComponent("bin/python3")
        return FileManager.default.isExecutableFile(atPath: python.path) ? root : nil
        #endif
    }

    /// The runtime the owner downloaded on demand for a light build. It lives
    /// in Application Support and is only used when the full app did not carry
    /// a helper of its own.
    static var installedRoot: URL? {
        let root = AIRuntime.installDirectory
        return AIRuntime.isInstalled && FileManager.default.isExecutableFile(
            atPath: root.appendingPathComponent("bin/python3").path) ? root : nil
    }

    private static func interpreter() -> URL? {
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_PYTHON"] {
            let url = URL(fileURLWithPath: override)
            return manager.isExecutableFile(atPath: url.path) ? url : nil
        }
        if let bundled = bundledRoot {
            return bundled.appendingPathComponent("bin/python3")
        }
        if let installed = installedRoot {
            return installed.appendingPathComponent("bin/python3")
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

    /// The worker package when the app runs next to a source checkout. A
    /// packaged app carries the helper inside its bundle instead. A checkout is
    /// found by walking up from the executable until `worker/retouch_ai_worker`
    /// appears; `RETOUCH_AI_WORKER_ROOT` overrides the search.
    private static func repositoryRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_WORKER_ROOT"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let bundled = bundledRoot { return bundled }
        if let installed = installedRoot { return installed }
        for start in [Bundle.main.executableURL,
                      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            guard let start else { continue }
            var directory = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
            for _ in 0..<6 {
                let worker = directory.appendingPathComponent("worker", isDirectory: true)
                let package = worker.appendingPathComponent("retouch_ai_worker", isDirectory: true)
                if FileManager.default.fileExists(atPath: package.path) { return worker }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }

    /// Environment for a helper process. A bundled runtime also needs its
    /// site-packages and its framework home; a checkout uses the venv instead.
    private static func workerEnvironment(root: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var paths = [root.path]
        if let bundled = bundledRoot,
           root.standardizedFileURL == bundled.standardizedFileURL {
            paths.append(bundled.appendingPathComponent("site-packages").path)
            environment["PYTHONHOME"] = frameworkHome(in: bundled)?.path
            environment["PYTHONNOUSERSITE"] = "1"
            // The runtime lives inside the sealed app. A .pyc written at launch
            // adds a file the signature never covered, so the whole bundle stops
            // verifying; keep bytecode in memory instead.
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
        } else if let installed = installedRoot,
                  root.standardizedFileURL == installed.standardizedFileURL {
            paths.append(installed.appendingPathComponent("site-packages").path)
            environment["PYTHONHOME"] = frameworkHome(in: installed)?.path
            environment["PYTHONNOUSERSITE"] = "1"
        }
        environment["PYTHONPATH"] = paths.joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private static func frameworkHome(in root: URL) -> URL? {
        let versions = root.appendingPathComponent("Python.framework/Versions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path),
              let newest = names.filter({ !$0.hasPrefix(".") })
                  .max(by: { $0.compare($1, options: .numeric) == .orderedAscending })
        else { return nil }
        return versions.appendingPathComponent(newest, isDirectory: true)
    }

    /// True when the helper can be started on this machine at all.
    static var isInstalled: Bool { interpreter() != nil && repositoryRoot() != nil }

    /// The message an AI tool shows when it cannot start the helper. A light
    /// build points at the runtime download; Intel has no runtime to offer.
    static var missingHelperMessage: String {
        if AIRuntime.package == nil { return L10n.current.aiRuntimeIntelUnavailable }
        if installedRoot == nil && bundledRoot == nil { return L10n.current.aiRuntimeNotInstalled }
        return L10n.current.aiHelperMissing
    }

    static func ensureRunning() throws {
        launchLock.lock()
        defer { launchLock.unlock() }

        if WorkerClient.shared.isAvailable(), adoptRunningHelper() { return }
        if WorkerClient.shared.isReachable() {
            // Alive but did not answer in time: a warm-up or a heavy job. It
            // must not be replaced, or the socket it owns would be pulled out
            // from under the running work.
            if waitForHelper() { return }
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiHelperWriteFailed)
        }
        if let process = launched, !process.isRunning { launched = nil }
        guard let python = interpreter(), let root = repositoryRoot() else {
            throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
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
        process.environment = workerEnvironment(root: root)
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
            if WorkerClient.shared.isAvailable() { break }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !WorkerClient.shared.isAvailable() {
            throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
        }
        HelperOwner.record(appPID: getpid(), workerPID: process.processIdentifier)
        cleanStaleWorkingCopies()
    }

    /// True when the helper answering on the socket should be reused. A helper
    /// whose owning app has exited is stopped first: its exit unlinks the
    /// socket, so the replacement has to wait for it to be gone.
    private static func adoptRunningHelper() -> Bool {
        guard let owner = HelperOwner.load() else { return true }
        if owner.appPID == getpid() { return true }
        if kill(owner.appPID, 0) == 0 { return true }

        // Avoid the transport retry inside this probe: this is the restart path.
        let key = "RetouchStudio.restoringHelper"
        Thread.current.threadDictionary[key] = true
        _ = try? WorkerClient.shared.call("shutdown", timeout: 2)
        Thread.current.threadDictionary.removeObject(forKey: key)

        let deadline = Date().addingTimeInterval(5)
        while kill(owner.workerPID, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if kill(owner.workerPID, 0) == 0 { return true }
        HelperOwner.removeIfOwned(by: owner.appPID)
        return false
    }

    /// The launch self-test: the helper answers, its catalog loads, and every
    /// installed file is the right size. Hashing weights would take minutes on
    /// the 4.6 GB model, so that stays in `models verify`; this is the check
    /// that has to be quick enough to run behind the first paint.
    static func selfTestAtLaunch() {
        guard isInstalled else { return }
        do {
            try ensureRunning()
            let reply = try WorkerClient.shared.call("health", timeout: 15) as? [String: Any] ?? [:]
            let models = reply["models"] as? [[String: Any]] ?? []
            let installed = models.filter { $0["installed"] as? Bool == true }.count
            let ok = reply["ok"] as? Bool ?? false
            NSLog("[RetouchStudio] AI self-test: helper ready, %d installed model(s), health %@",
                  installed, ok ? "ok" : "degraded")
        } catch {
            NSLog("[RetouchStudio] AI self-test: %@", error.localizedDescription)
        }
    }

    /// Called after a transport failure. If the helper this app started has
    /// stopped, a fresh one starts now, so the next attempt does not fail the
    /// same way. A helper the owner launched by hand is not restarted here;
    /// `ensureRunning` finds it by its socket or starts ours.
    @discardableResult
    static func restartIfStopped() -> Bool {
        launchLock.lock()
        defer { launchLock.unlock() }
        if let process = launched {
            if process.isRunning { return true }
            launched = nil
            try? FileManager.default.removeItem(atPath: WorkerClient.socketPath)
        } else if WorkerClient.shared.isReachable() {
            // Started outside this app and still listening: slow, not gone.
            return waitForHelper()
        }
        do {
            try ensureRunning()
            return true
        } catch {
            NSLog("[RetouchStudio] AI helper restart failed: %@", error.localizedDescription)
            return false
        }
    }

    private static func waitForHelper(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if WorkerClient.shared.isAvailable() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    /// Copy folders left by a previous run. Only stale ones go, so a working
    /// copy another window is still using is never touched.
    private static func cleanStaleWorkingCopies(olderThan age: TimeInterval = 86_400) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        guard let items = try? manager.contentsOfDirectory(
            at: workingDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            if modified < cutoff { try? manager.removeItem(at: item) }
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
        HelperOwner.removeIfOwned()
    }

    /// Quit-time stop. A child process outlives the app unless it is signalled,
    /// and the async fallback in `shutdown` never runs once we are terminating.
    static func terminate() {
        guard let process = launched, process.isRunning else { return }
        process.terminate()
        launched = nil
        HelperOwner.removeIfOwned()
    }

    // MARK: - Model tool

    /// Starts the worker's model CLI in a separate process. Downloads live
    /// outside the server on purpose: the server has no network code, and the
    /// owner starts a transfer only by pressing the button that shows the
    /// manifest first.
    static func launchModelTool(_ arguments: [String]) throws -> Process {
        guard let python = interpreter(), let root = repositoryRoot() else {
            throw AIWorkerFailure(code: -32000, message: L10n.current.modelsHelperMissing)
        }
        try FileManager.default.createDirectory(at: modelsDirectory,
                                                withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "retouch_ai_worker"] + arguments
        process.environment = workerEnvironment(root: root)
        return process
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
