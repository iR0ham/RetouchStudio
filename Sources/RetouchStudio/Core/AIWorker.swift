import AppKit
import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import StudioCore

/// Launches and talks to the local AI helper.
///
/// The helper is a separate process on purpose: it can be killed without
/// touching the document, it never receives more than a copy of the working
/// pixels, and its job path contains no network code. This type only starts it,
/// hands it a temporary copy of the photo, and turns the reply into an `AIEdit`.
enum AIWorker {

    /// Tests point the production-default paths at a scratch tree so they can
    /// exercise the real defaults without reading or writing the owner's data.
    static var supportDirectoryOverride: URL?

    static var supportDirectory: URL {
        if let supportDirectoryOverride { return supportDirectoryOverride.standardizedFileURL }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("RetouchStudio/AI", isDirectory: true)
    }

    /// Control files for the protocol-v2 runtime live under `AI/runtimes`.
    /// The older `AI/runtime` tree is never read, moved or deleted.
    static var runtimeSupportDirectory: URL {
        supportDirectory.appendingPathComponent("runtimes", isDirectory: true)
    }

    private static var v2SocketURL: URL {
        runtimeSupportDirectory.appendingPathComponent("worker.sock")
    }

    private static var v2JobsDirectory: URL {
        runtimeSupportDirectory.appendingPathComponent("jobs", isDirectory: true)
    }

    private static var v2LogURL: URL {
        runtimeSupportDirectory.appendingPathComponent("worker.log")
    }

    private static var v2RegistryURL: URL {
        runtimeSupportDirectory.appendingPathComponent(HelperRegistry.fileName)
    }

    /// Longest edge handed to the helper. The mask policy and the patch size
    /// were measured on an image of this size, so the app does not send more.
    static let workingLongEdge: CGFloat = 1600

    static var jobsDirectory: URL {
        supportDirectory.appendingPathComponent("jobs", isDirectory: true)
    }

    static var modelsDirectory: URL { modelsDirectory(for: supportDirectory) }

    static func modelsDirectory(for support: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_MODELS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return support.appendingPathComponent("models", isDirectory: true)
    }

    /// Model weights stay beside the app state in `AI/models`; the installer
    /// replaces `AI/runtimes`, which must never contain downloaded weights.
    /// A test that passes its own support keeps its isolated model folder.
    private static func modelDirectory(for support: URL) -> URL {
        support.standardizedFileURL == runtimeSupportDirectory.standardizedFileURL
            ? modelsDirectory
            : modelsDirectory(for: support)
    }

    private static var launched: Process?
    private static let launchLock = NSRecursiveLock()

    /// Per-support runtime state. The lock is only ever held for dictionary
    /// work, never across recovery, validation or a process launch, so it can
    /// never invert with the launch or transaction locks.
    private static let runtimeStateLock = NSLock()
    private static var recoveryResults: [String: AIRuntimeRecoveryResult] = [:]
    private static var validatedRoots: Set<String> = []
    private static var runtimeProblems: [String: String] = [:]

    /// Held while the helper this app launched is alive. An installer in any
    /// process needs the exclusive lease, so it cannot swap the tree this
    /// helper is importing from.
    private static var helperLease: RuntimeUsageLease?
    private static var lastLaunchProblem: String?
    /// The registry client this process registered with the v2 helper.
    private static var v2Client: (generation: String, id: String)?

    /// Finishes an interrupted runtime installation before the helper is
    /// looked up. Only a successful recovery is cached: a failed one is retried
    /// on the next use instead of being reported as done for the whole process.
    @discardableResult
    static func recoverRuntimeIfNeeded(force: Bool = false, support: URL? = nil,
                                       hooks: AIRuntime.InstallHooks = AIRuntime.InstallHooks())
        -> AIRuntimeRecoveryResult {
        let support = (support ?? runtimeSupportDirectory).standardizedFileURL
        let key = support.path
        let installKey = AIRuntime.installDirectory(in: support).standardizedFileURL.path
        runtimeStateLock.lock()
        let cached = recoveryResults[key]
        runtimeStateLock.unlock()
        if !force, let cached, cached.isSuccess { return cached }

        let result = AIRuntime.recoverInterruptedInstall(in: support, hooks: hooks)
        runtimeStateLock.lock()
        if result.isSuccess {
            recoveryResults[key] = result
            if let problem = runtimeProblems[installKey],
               problem.hasPrefix("recovery:") || problem.hasPrefix("busy:") {
                runtimeProblems.removeValue(forKey: installKey)
            }
        } else {
            recoveryResults.removeValue(forKey: key)
            // A busy runtime is retryable and gets its own message; a damaged
            // one keeps the validation wording.
            let prefix = result.failure?.code == .busy ? "busy:" : "recovery:"
            runtimeProblems[installKey] = "\(prefix) \(result.logLine)"
        }
        runtimeStateLock.unlock()
        if !result.isSuccess {
            NSLog("[RetouchStudio] AI runtime recovery %@", result.logLine)
        }
        return result
    }

    /// The full contract a downloaded runtime must pass before this process
    /// starts a helper from it. Recovery runs first, then the structural check,
    /// then the functional probe (interpreter, core imports, startup handshake).
    /// A passing result is cached for the life of the process; a failure is not,
    /// so a retry after fixing something can succeed. Optional feature backends
    /// are reported by the probe but never make the runtime unusable.
    static func downloadedRuntimeUsable(support: URL? = nil,
                                        hooks: AIRuntime.InstallHooks = AIRuntime.InstallHooks())
        -> Bool {
        let support = (support ?? runtimeSupportDirectory).standardizedFileURL
        let root = AIRuntime.installDirectory(in: support)
        let key = root.path

        runtimeStateLock.lock()
        let validated = validatedRoots.contains(key)
        runtimeStateLock.unlock()
        if validated { return true }

        let recovery = recoverRuntimeIfNeeded(support: support, hooks: hooks)
        guard recovery.isSuccess else { return false }
        let layout = AIRuntimeValidation.structural(root: root)
        guard layout.ok else {
            recordRuntimeProblem(key, layout.logLine)
            return false
        }
        do {
            // Validation and the launch that follows it share the transaction
            // lock, so an installer cannot swap the files in between.
            let report = try RuntimeTransactionLock.shared.withLock(support: support) {
                let current = AIRuntimeValidation.structural(root: root)
                guard current.ok else { return current }
                return try hooks.validateRuntime(root)
            }
            guard report.ok else {
                recordRuntimeProblem(key, report.logLine)
                return false
            }
            runtimeStateLock.lock()
            validatedRoots.insert(key)
            runtimeProblems.removeValue(forKey: key)
            runtimeStateLock.unlock()
            return true
        } catch {
            recordRuntimeProblem(key, "validation failed: \(error)")
            return false
        }
    }

    /// Marks a runtime as validated because the installer just ran the same
    /// functional contract on it.
    static func noteRuntimeValidated(root: URL = AIRuntime.installDirectory) {
        runtimeStateLock.lock()
        validatedRoots.insert(root.standardizedFileURL.path)
        runtimeProblems.removeValue(forKey: root.standardizedFileURL.path)
        runtimeStateLock.unlock()
    }

    /// Forgets everything cached for a support directory after an install.
    static func runtimeDidChange(support: URL? = nil) {
        let support = (support ?? runtimeSupportDirectory).standardizedFileURL
        runtimeStateLock.lock()
        recoveryResults.removeValue(forKey: support.path)
        let install = AIRuntime.installDirectory(in: support).standardizedFileURL.path
        validatedRoots.remove(install)
        runtimeProblems.removeValue(forKey: install)
        runtimeProblems.removeValue(forKey: support.path)
        runtimeStateLock.unlock()
        // A replaced runtime has a new helper; do not keep routing calls to the
        // socket of the one that was stopped.
        WorkerClient.selectSocket(nil)
    }

    /// Why the downloaded runtime cannot be used, or nil when it can.
    static var installedRuntimeProblem: String? { runtimeProblem() }

    static func runtimeProblem(support: URL? = nil) -> String? {
        let support = (support ?? runtimeSupportDirectory).standardizedFileURL
        let key = AIRuntime.installDirectory(in: support).standardizedFileURL.path
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return runtimeProblems[key]
    }

    private static func recordRuntimeProblem(_ key: String, _ detail: String) {
        runtimeStateLock.lock()
        validatedRoots.remove(key)
        runtimeProblems[key] = detail
        runtimeStateLock.unlock()
        NSLog("[RetouchStudio] AI runtime is not usable: %@", detail)
    }

    /// Asks every helper that would read this runtime to stop before its files
    /// are replaced. Called while the transaction lock is held, so no new helper
    /// can start from the old runtime during the swap. The launch lock is
    /// deliberately not taken here: the transaction lock is always acquired
    /// first, and taking the launch lock second would invert that order.
    ///
    /// Only this app's helper and a helper left behind by a crashed app are
    /// stopped. A helper owned by a live second app is left untouched; its
    /// shared usage lease turns the replacement into a retryable busy answer.
    static func prepareForRuntimeReplacement(support: URL = supportDirectory) throws {
        // Never let the transport retry start a replacement helper from the
        // runtime that is about to be replaced.
        let key = "RetouchStudio.restoringHelper"
        Thread.current.threadDictionary[key] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: key) }

        // A downloaded runtime has a registry-managed helper; only a helper
        // whose process identity and generation match the registry is stopped.
        // The transaction lock is already held by the installer, so this takes
        // only the launch lock and then the registry lock.
        if selectedRuntimeIsDownloaded {
            try prepareV2ForReplacement(support: support)
            return
        }

        var ownHelperStopped = true
        if let process = launched {
            if process.isRunning {
                _ = try? WorkerClient.shared.call("shutdown", timeout: 2)
                ownHelperStopped = waitForExit(process, timeout: 5)
                if !ownHelperStopped {
                    process.terminate()
                    ownHelperStopped = waitForExit(process, timeout: 2)
                }
                if !ownHelperStopped {
                    kill(process.processIdentifier, SIGKILL)
                    ownHelperStopped = waitForExit(process, timeout: 2)
                }
            }
            if ownHelperStopped { launched = nil }
        }

        if let owner = HelperOwner.load(support: support) {
            if owner.appPID == getpid() {
                if verifiedHelper(owner, support: support) {
                    terminateHelper(pid: owner.workerPID)
                    if kill(owner.workerPID, 0) != 0 {
                        HelperOwner.removeIfOwned(by: owner.appPID, support: support)
                    } else {
                        ownHelperStopped = false
                    }
                } else if launched == nil {
                    // The record is ours but its process cannot be verified.
                    // Never signal an unrelated PID; dropping the record is
                    // safe because this app owns it.
                    HelperOwner.removeIfOwned(by: owner.appPID, support: support)
                }
            } else if kill(owner.appPID, 0) != 0 {
                // The owning app is gone. Only a helper whose executable is
                // verifiably inside this runtime is stopped; a recycled PID
                // pointing at anything else is never touched.
                if verifiedHelper(owner, support: support) {
                    terminateHelper(pid: owner.workerPID)
                }
                HelperOwner.removeIfOwned(by: owner.appPID, support: support)
            } else if owner.workerExecutable == nil {
                // A live older build whose record has no executable and which
                // therefore holds no lease. Its helper might still import from
                // this tree, so the replacement must not proceed silently.
                throw AIRuntimeBusyError(
                    "an older Retouch Studio window is using the AI runtime")
            }
        }

        // Hold the lease until the helper is actually gone. Releasing it early
        // would let an installer swap files the old helper still reads.
        if ownHelperStopped { releaseHelperLease() }
    }

    /// Which app process started the running helper. A helper whose app is gone
    /// is stale: the next launch stops it so its socket and temporary paths are
    /// the ones this process will use.
    private struct HelperOwner: Codable {
        let appPID: Int32
        let workerPID: Int32
        let models: String
        /// The exact executable the app launched. Without it a PID is only a
        /// number that can be recycled, so no signal is sent.
        let workerExecutable: String?

        static func url(in support: URL) -> URL {
            support.appendingPathComponent("helper-owner.json")
        }

        static func load(support: URL = AIWorker.supportDirectory) -> HelperOwner? {
            guard let data = try? Data(contentsOf: url(in: support)) else { return nil }
            return try? JSONDecoder().decode(HelperOwner.self, from: data)
        }

        static func record(appPID: Int32, workerPID: Int32, executable: String,
                           support: URL = AIWorker.supportDirectory) {
            let owner = HelperOwner(appPID: appPID, workerPID: workerPID,
                                    models: modelsDirectory(for: support).path,
                                    workerExecutable: executable)
            if let data = try? JSONEncoder().encode(owner) {
                try? data.write(to: url(in: support))
            }
        }

        static func removeIfOwned(by pid: Int32 = getpid(),
                                  support: URL = AIWorker.supportDirectory) {
            guard let owner = load(support: support), owner.appPID == pid else { return }
            try? FileManager.default.removeItem(at: url(in: support))
        }
    }

    // MARK: - Usage lease and process identity

    private static func setHelperLease(_ lease: RuntimeUsageLease) {
        runtimeStateLock.lock()
        let previous = helperLease
        helperLease = lease
        runtimeStateLock.unlock()
        previous?.release()
    }

    private static func releaseHelperLease() {
        runtimeStateLock.lock()
        let lease = helperLease
        helperLease = nil
        runtimeStateLock.unlock()
        lease?.release()
    }

    private static func releaseHelperLease(_ lease: RuntimeUsageLease) {
        runtimeStateLock.lock()
        if helperLease === lease { helperLease = nil }
        runtimeStateLock.unlock()
        lease.release()
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private static func terminateHelper(pid: Int32) {
        guard pid > 0, pid != getpid(), kill(pid, 0) == 0 else { return }
        kill(pid, SIGTERM)
        let graceful = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < graceful {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        let forced = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < forced {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func processExecutablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A PID is killed only when the executable it is actually running matches
    /// the recorded one and that executable lives inside this runtime. The
    /// second condition is what keeps a recycled PID or an unrelated process
    /// safe even when it happens to be another python.
    private static func verifiedHelper(_ owner: HelperOwner, support: URL) -> Bool {
        guard owner.workerPID > 0, owner.workerPID != getpid(),
              let recorded = owner.workerExecutable, !recorded.isEmpty,
              let actual = processExecutablePath(pid: owner.workerPID)
        else { return false }
        let actualURL = URL(fileURLWithPath: actual)
            .resolvingSymlinksInPath().standardizedFileURL
        let recordedURL = URL(fileURLWithPath: recorded)
            .resolvingSymlinksInPath().standardizedFileURL
        guard actualURL.path == recordedURL.path else { return false }
        return isInsideRuntime(actualURL, support: support)
    }

    private static func isInsideRuntime(_ executable: URL, support: URL) -> Bool {
        let supportPath = support.standardizedFileURL.resolvingSymlinksInPath().path
        let path = executable.standardizedFileURL.resolvingSymlinksInPath().path
        // The tree the installer replaces comes from AIRuntime, so the names are
        // derived from it instead of being repeated here. The `runtime` names
        // are the pre-protocol-v2 layout; a helper an older build left behind
        // there is still this app's to stop.
        let installName = AIRuntime.installDirectory(in: support).lastPathComponent
        let backupName = AIRuntime.backupDirectory(in: support).lastPathComponent
        let owned = [installName + "/", backupName + "/", installName + "-rejected-",
                     "runtime/", "runtime-backup/", "runtime-rejected-"]
        return owned.contains { path.hasPrefix(supportPath + "/" + $0) }
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

    /// The protocol-v2 runtime the owner downloaded on demand. Without official
    /// package metadata the downloaded runtime is disabled, so a stale v2 tree
    /// left by an older experiment is never selected either.
    static var installedRoot: URL? { installedRoot() }

    static func installedRoot(support: URL = AIWorker.runtimeSupportDirectory,
                              hooks: AIRuntime.InstallHooks = AIRuntime.InstallHooks())
        -> URL? {
        guard AIRuntime.package != nil else { return nil }
        let support = support.standardizedFileURL
        recoverRuntimeIfNeeded(support: support, hooks: hooks)
        let root = AIRuntime.installDirectory(in: support)
        return AIRuntime.isStructurallyValid(root: root)
            && FileManager.default.isExecutableFile(
                atPath: root.appendingPathComponent("bin/python3").path) ? root : nil
    }

    /// True when the next launch comes from the downloaded protocol-v2
    /// runtime. A developer override, the bundled runtime or a checkout takes
    /// precedence, so only those sources skip the downloaded-runtime gate.
    static var usesDownloadedRuntime: Bool { selectedRuntimeIsDownloaded }

    private static var selectedRuntimeIsDownloaded: Bool {
        selectedRuntimeIsDownloaded(support: runtimeSupportDirectory)
    }

    private static func selectedRuntimeIsDownloaded(
        support: URL, hooks: AIRuntime.InstallHooks = AIRuntime.InstallHooks()) -> Bool {
        guard AIRuntime.package != nil else { return false }
        let environment = ProcessInfo.processInfo.environment
        if environment["RETOUCH_AI_PYTHON"] != nil
            || environment["RETOUCH_AI_WORKER_ROOT"] != nil { return false }
        if bundledRoot != nil { return false }
        return installedRoot(support: support.standardizedFileURL, hooks: hooks) != nil
    }

    private static func interpreter(
        support: URL = AIWorker.runtimeSupportDirectory,
        hooks: AIRuntime.InstallHooks = AIRuntime.InstallHooks()) -> URL? {
        let support = support.standardizedFileURL
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_PYTHON"] {
            let url = URL(fileURLWithPath: override)
            return manager.isExecutableFile(atPath: url.path) ? url : nil
        }
        if let bundled = bundledRoot {
            return bundled.appendingPathComponent("bin/python3")
        }
        if let installed = installedRoot(support: support, hooks: hooks) {
            return installed.appendingPathComponent("bin/python3")
        }
        var candidates = [support.appendingPathComponent("venv/bin/python3")]
        if let repo = repositoryRoot(support: support, hooks: hooks) {
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
    private static func repositoryRoot(
        support: URL = AIWorker.runtimeSupportDirectory,
        hooks: AIRuntime.InstallHooks = AIRuntime.InstallHooks()) -> URL? {
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_WORKER_ROOT"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let bundled = bundledRoot { return bundled }
        if let installed = installedRoot(support: support, hooks: hooks) { return installed }
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
    private static func workerEnvironment(root: URL,
                                          support: URL = AIWorker.runtimeSupportDirectory)
        -> [String: String] {
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
        } else if let installed = installedRoot(support: support),
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

    /// True when the helper can be started on this machine at all. This is a
    /// layout answer for messages and retries; it never grants trust to a
    /// downloaded runtime. `ensureRunning` runs the functional contract first.
    static var isInstalled: Bool { interpreter() != nil && repositoryRoot() != nil }

    /// The message an AI tool shows when it cannot start the helper. A light
    /// build points at the runtime download; Intel has no runtime to offer.
    /// A runtime that is present but failed its contract says so instead of
    /// pretending it is missing or usable.
    static var missingHelperMessage: String {
        if AIRuntime.package == nil {
            #if arch(x86_64)
            return L10n.current.aiRuntimeIntelUnavailable
            #else
            return L10n.current.aiRuntimeUnavailable
            #endif
        }
        if let problem = installedRuntimeProblem {
            return problem.hasPrefix("busy:")
                ? L10n.current.aiRuntimeBusy
                : L10n.current.aiRuntimeValidationFailed
        }
        if installedRoot == nil && bundledRoot == nil { return L10n.current.aiRuntimeNotInstalled }
        return L10n.current.aiHelperMissing
    }

    static func ensureRunning() throws {
        launchLock.lock()
        defer { launchLock.unlock() }
        do {
            if selectedRuntimeIsDownloaded {
                try ensureRunningV2()
            } else {
                try RuntimeTransactionLock.shared.withLock(support: supportDirectory) {
                    try ensureRunningLocked()
                }
            }
            noteLaunchProblem(nil)
        } catch {
            noteLaunchProblem(error.localizedDescription)
            throw error
        }
    }

    /// A transport retry that cannot restart the helper needs the reason the
    /// launch was refused (a busy runtime reads differently from a crash).
    private static func noteLaunchProblem(_ message: String?) {
        runtimeStateLock.lock()
        lastLaunchProblem = message
        runtimeStateLock.unlock()
    }

    static var lastLaunchFailure: String? {
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return lastLaunchProblem
    }

    private static func ensureRunningLocked() throws {
        // Only a bundled or checkout helper reaches this path; it does not read
        // the downloaded tree, so no v2 recovery or lease is involved. The
        // legacy `AI/runtime` directory is never inspected.
        if WorkerClient.shared.isAvailable(), adoptRunningHelper() { return }
        if WorkerClient.shared.isReachable() {
            // Alive but did not answer in time: a warm-up or a heavy job. It
            // must not be replaced, or the socket it owns would be pulled out
            // from under the running work.
            if waitForHelper() { return }
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiHelperWriteFailed)
        }
        if let process = launched {
            if process.isRunning {
                // It did not answer and cannot be reached: an orphan that would
                // otherwise keep the old runtime open. Stop it before a second
                // helper and a second lease exist.
                process.terminate()
                _ = waitForExit(process, timeout: 2)
            }
            if !process.isRunning {
                launched = nil
                releaseHelperLease()
            }
        }
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

        // The shared lease is taken before the helper exists and is released
        // from its termination handler, so the runtime is protected for exactly
        // the helper's lifetime, including a crash of this app.
        let lease: RuntimeUsageLease
        do {
            lease = try RuntimeUsageLease.acquireShared(support: supportDirectory)
        } catch {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiRuntimeBusy)
        }
        do {
            try process.run()
        } catch {
            lease.release()
            throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
        }
        setHelperLease(lease)
        launched = process
        process.terminationHandler = { _ in releaseHelperLease(lease) }
        HelperOwner.record(appPID: getpid(), workerPID: process.processIdentifier,
                           executable: python.path)

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if WorkerClient.shared.isAvailable() { break }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !WorkerClient.shared.isAvailable() {
            throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
        }
        cleanStaleWorkingCopies()
    }

    // MARK: - Protocol-v2 lifecycle

    private struct V2Endpoint {
        let support: URL
        let root: URL
        let socket: URL
        let jobs: URL
        let log: URL
        let store: HelperRegistryStore
    }

    private static func v2Endpoint() throws -> V2Endpoint {
        let support = runtimeSupportDirectory
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return V2Endpoint(support: support,
                          root: AIRuntime.installDirectory(in: support),
                          socket: v2SocketURL,
                          jobs: v2JobsDirectory,
                          log: v2LogURL,
                          store: try HelperRegistryStore(root: support))
    }

    private static func currentIdentity() throws -> ProcessIdentity {
        guard let identity = ProcessIdentity.capture(getpid()) else {
            throw AIWorkerFailure(code: -32000,
                                  message: "could not identify this process")
        }
        return identity
    }

    private static func snapshot(_ endpoint: V2Endpoint) throws -> HelperRegistry.Record? {
        try endpoint.store.inspect { load in
            switch load {
            case .loaded(let record): return record
            case .missing: return nil
            case .invalid(let detail):
                throw AIWorkerFailure(
                    code: -32000,
                    message: "the AI helper registry is invalid: \(detail)")
            }
        }
    }

    /// Serialized by the launch lock and the transaction lock. It either adopts
    /// an already verified helper or performs one fenced launch; it never
    /// replaces a helper whose identity or progress cannot be disproved.
    private static func ensureRunningV2() throws {
        guard AIRuntime.package != nil else {
            throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
        }
        let endpoint = try v2Endpoint()
        try RuntimeTransactionLock.shared.withLock(support: endpoint.support) {
            guard downloadedRuntimeUsable(support: endpoint.support) else {
                throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
            }
            let launch = try LockFile.open(
                endpoint.support.appendingPathComponent("launch.lock"))
            defer { launch.close() }
            try launch.acquire(
                exclusive: true, timeout: 120,
                busyMessage:
                    "another Retouch Studio process is starting the AI helper")
            if try adoptV2(endpoint) { return }
            try launchV2(endpoint)
        }
    }

    private static func adoptV2(_ endpoint: V2Endpoint) throws -> Bool {
        guard let record = try snapshot(endpoint) else { return false }
        switch record.state {
        case .ready:
            guard let helper = record.helper, helper.isAlive else { return false }
            guard record.protocolVersion == HelperRegistry.protocolVersion else {
                throw AIWorkerFailure(code: -32000,
                                      message: L10n.current.aiRuntimeValidationFailed)
            }
            do {
                _ = try WorkerClient(socketPath: endpoint.socket.path)
                    .verifiedHealth(generation: record.generation,
                                    nonce: record.launchNonce, helper: helper)
            } catch {
                // Alive but unverified is never adopted and never signalled.
                return false
            }
            try registerV2Client(endpoint, record: record)
            return true

        case .starting:
            guard let helper = record.helper, helper.isAlive else { return false }
            guard RuntimeBootstrap.waitForReady(
                store: endpoint.store, generation: record.generation,
                nonce: record.launchNonce, timeout: 10) != nil else {
                throw AIWorkerFailure(code: -32000,
                                      message: L10n.current.aiHelperStarting)
            }
            return try adoptV2(endpoint)

        case .preparing:
            guard let parent = record.parent else { return false }
            guard parent.isAlive else { return false }
            // A record this process wrote can only be a previous attempt: the
            // launch lock serializes attempts, so this one is not progressing.
            // It is replaced by `launchV2` (a late child loses the nonce CAS
            // and exits) instead of blocking the app forever.
            if parent == (try currentIdentity()) { return false }
            // A live second process may still be spawning. Wait for its exact
            // launch to become ready; never replace a progressing launch.
            if RuntimeBootstrap.waitForReady(store: endpoint.store,
                                             generation: record.generation,
                                             nonce: record.launchNonce,
                                             timeout: 10) != nil {
                return try adoptV2(endpoint)
            }
            throw AIWorkerFailure(code: -32000,
                                  message: L10n.current.aiHelperStarting)

        case .stopping:
            if let helper = record.helper, helper.isAlive {
                let deadline = Date().addingTimeInterval(10)
                while helper.isAlive, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if helper.isAlive {
                    throw AIWorkerFailure(code: -32000,
                                          message: L10n.current.aiHelperStarting)
                }
            }
            if let shutdown = record.shutdown {
                try finalizeStoppedV2(endpoint, generation: shutdown.generation,
                                      transactionID: shutdown.transactionID)
            }
            return false

        case .stopped, .failed:
            return false
        }
    }

    @discardableResult
    private static func registerV2Client(_ endpoint: V2Endpoint,
                                         record: HelperRegistry.Record) throws -> String {
        let id = UUID().uuidString
        let identity = try currentIdentity()
        let now = Date()
        try endpoint.store.update(timeout: 5) { load in
            guard case .loaded(var current) = load,
                  current.generation == record.generation,
                  current.state == .ready else {
                throw AIWorkerFailure(
                    code: -32000,
                    message: "the AI helper changed while it was starting")
            }
            current.clients.removeAll { !$0.identity.isAlive }
            current.clients.append(
                .init(id: id, identity: identity,
                      lastSeen: now.timeIntervalSince1970))
            return (current.bumped(at: now), ())
        }
        runtimeStateLock.lock()
        v2Client = (record.generation, id)
        runtimeStateLock.unlock()
        // Conversations now go to the v2 socket instead of the legacy one.
        WorkerClient.selectSocket(endpoint.socket.path)
        return id
    }

    /// Marks exactly this launch attempt failed. A record another process
    /// already replaced is left alone, so a stale performer can never overwrite
    /// a newer generation or nonce.
    private static func failLaunch(_ endpoint: V2Endpoint,
                                   _ preparing: HelperRegistry.Record,
                                   _ reason: String) {
        let now = Date()
        try? endpoint.store.update { load in
            guard case .loaded(let current) = load,
                  current.generation == preparing.generation,
                  current.launchNonce == preparing.launchNonce,
                  current.state == .preparing || current.state == .starting else {
                return (nil, ())
            }
            return (current.failed(reason, at: now), ())
        }
    }

    /// Fenced launch. `U_EX` is acquired before the registry probe and held
    /// through the compare-and-swap that replaces any stale launch record. A
    /// child still holding the inherited shared lease blocks that acquisition,
    /// so the exclusive lease itself proves the record cannot be live.
    private static func launchV2(_ endpoint: V2Endpoint) throws {
        let usage: RuntimeUsageLease
        do {
            usage = try RuntimeUsageLease.acquireExclusive(
                support: endpoint.support, timeout: 10)
        } catch let busy as AIRuntimeBusyError {
            throw AIWorkerFailure(code: -32000, message: busy.description)
        }

        let identity = try currentIdentity()
        let preparing: HelperRegistry.Record
        do {
            preparing = try endpoint.store.update(timeout: 5) { load in
                let previous: HelperRegistry.Record?
                switch load {
                case .invalid(let detail):
                    throw AIWorkerFailure(
                        code: -32000,
                        message: "the AI helper registry is invalid: \(detail)")
                case .missing:
                    previous = nil
                case .loaded(let record):
                    previous = record
                }
                if let previous {
                    // Constraint: verify the previous parent by identity, not
                    // by elapsed time, before declaring its launch stale. A
                    // live second process is still progressing; this process's
                    // own record is a finished attempt (the launch lock
                    // serializes them) and a late child loses its nonce CAS.
                    if previous.state == .preparing,
                       let parent = previous.parent, parent.isAlive,
                       parent != identity {
                        throw AIWorkerFailure(
                            code: -32000, message: L10n.current.aiHelperStarting)
                    }
                    if previous.state == .ready || previous.state == .starting,
                       let helper = previous.helper, helper.isAlive {
                        throw AIWorkerFailure(
                            code: -32000, message: L10n.current.aiRuntimeBusy)
                    }
                }
                let fresh = RuntimeBootstrap.preparingRecord(
                    parent: identity, socket: endpoint.socket, previous: previous)
                return (fresh, fresh)
            }
        } catch {
            usage.release()
            throw error
        }
        usage.release()

        let shared: RuntimeUsageLease
        do {
            shared = try RuntimeUsageLease.acquireShared(support: endpoint.support)
        } catch {
            failLaunch(endpoint, preparing, "the runtime became busy")
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiRuntimeBusy)
        }

        guard let python = interpreter(support: endpoint.support),
              let root = repositoryRoot(support: endpoint.support) else {
            shared.release()
            failLaunch(endpoint, preparing, "the runtime layout is incomplete")
            throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: endpoint.jobs, withIntermediateDirectories: true)
        try? manager.removeItem(atPath: endpoint.socket.path)

        let arguments = RuntimeBootstrap.arguments(
            socket: endpoint.socket, jobs: endpoint.jobs, models: modelsDirectory,
            allowRoots: [workingDirectory, modelsDirectory],
            generation: preparing.generation, nonce: preparing.launchNonce,
            registry: v2RegistryURL)
        let configuration = RuntimeBootstrap.Configuration(
            executable: python, arguments: arguments,
            environment: workerEnvironment(root: root, support: endpoint.support),
            log: endpoint.log, lease: shared)
        do {
            _ = try RuntimeBootstrap.spawn(configuration)
        } catch {
            shared.release()
            failLaunch(endpoint, preparing, "the helper could not start: \(error)")
            throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
        }
        // `RuntimeBootstrap.spawn` released the parent's copy; the child owns
        // the lease now, including across a crash of this app.

        guard let ready = RuntimeBootstrap.waitForReady(
            store: endpoint.store, generation: preparing.generation,
            nonce: preparing.launchNonce, timeout: 30) else {
            // No timeout is calibrated yet, so a helper that is still
            // progressing is left running for the next attempt to adopt.
            throw AIWorkerFailure(code: -32000,
                                  message: L10n.current.aiHelperStarting)
        }
        guard let helper = ready.helper else {
            throw AIWorkerFailure(code: -32000,
                                  message: L10n.current.aiHelperStarting)
        }
        _ = try WorkerClient(socketPath: endpoint.socket.path)
            .verifiedHealth(generation: ready.generation,
                            nonce: ready.launchNonce, helper: helper)
        try registerV2Client(endpoint, record: ready)
    }

    private enum ShutdownDecision {
        case nothing
        case shared
        case stop(helper: ProcessIdentity?, shutdown: HelperRegistry.Shutdown)
    }

    /// Stops the helper only when this process is the last valid client. A
    /// helper shared with another live app stays up; its own client record is
    /// what keeps it alive, not who launched it.
    private static func shutdownV2Locked(_ endpoint: V2Endpoint) throws {
        guard let record = try snapshot(endpoint) else { return }

        if record.state == .stopping {
            guard let existing = record.shutdown else { return }
            let me = try currentIdentity()
            let now = Date()
            let performer: HelperRegistry.Shutdown?
            if existing.owner == me {
                // Re-entering our own unfinished stop: retry the helper, not
                // the registry transaction.
                performer = existing
            } else if existing.owner.isAlive {
                // A live second process owns this stop.
                return
            } else {
                // The performer died. Take over only after verifying its
                // identity, and only if the record still names that stop.
                performer = try endpoint.store.update { load in
                    guard case .loaded(var current) = load,
                          current.state == .stopping,
                          let previous = current.shutdown,
                          previous.transactionID == existing.transactionID,
                          !previous.owner.isAlive else { return (nil, nil) }
                    let fresh = HelperRegistry.Shutdown(
                        transactionID: UUID().uuidString, owner: me,
                        startedAt: now.timeIntervalSince1970,
                        revisionAtStart: current.revision,
                        generation: current.generation)
                    current.shutdown = fresh
                    return (current.bumped(at: now), fresh)
                }
            }
            guard let performer else { return }
            if let helper = record.helper, helper.isAlive,
               ProcessIdentity.capture(helper.pid) == helper {
                kill(helper.pid, SIGTERM)
                let deadline = Date().addingTimeInterval(10)
                while helper.isAlive, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            // A helper that survived the wait stays tracked; the record is left
            // stopping so the next attempt retries instead of losing it.
            if let helper = record.helper, helper.isAlive { return }
            try finalizeStoppedV2(endpoint, generation: performer.generation,
                                  transactionID: performer.transactionID)
            return
        }

        guard record.state == .ready, let helper = record.helper else { return }
        let me = try currentIdentity()
        let now = Date()
        let clientID: String? = {
            runtimeStateLock.lock()
            defer { runtimeStateLock.unlock() }
            guard let v2Client, v2Client.generation == record.generation else {
                return nil
            }
            return v2Client.id
        }()
        let decision: ShutdownDecision = try endpoint.store.update(timeout: 5) { load in
            guard case .loaded(var current) = load,
                  current.generation == record.generation,
                  current.state == .ready else { return (nil, .nothing) }
            if let clientID {
                current.clients.removeAll { $0.id == clientID }
            }
            current.clients.removeAll { !$0.identity.isAlive }
            guard current.clients.isEmpty else {
                return (current.bumped(at: now), .shared)
            }
            let shutdown = HelperRegistry.Shutdown(
                transactionID: UUID().uuidString, owner: me,
                startedAt: now.timeIntervalSince1970,
                revisionAtStart: current.revision,
                generation: current.generation)
            var next = current.bumped(at: now)
            next.state = .stopping
            next.shutdown = shutdown
            return (next, .stop(helper: current.helper, shutdown: shutdown))
        }
        runtimeStateLock.lock()
        v2Client = nil
        runtimeStateLock.unlock()

        switch decision {
        case .nothing, .shared:
            return
        case .stop(nil, _):
            return
        case .stop(let helper?, let shutdown):
            if helper.isAlive, ProcessIdentity.capture(helper.pid) == helper {
                kill(helper.pid, SIGTERM)
                let deadline = Date().addingTimeInterval(10)
                while helper.isAlive, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            // The record stays stopping when the helper survives: the next
            // shutdown retries it and no second helper can be launched over it.
            if helper.isAlive { return }
            try finalizeStoppedV2(endpoint, generation: shutdown.generation,
                                  transactionID: shutdown.transactionID)
        }
    }

    private static func finalizeStoppedV2(_ endpoint: V2Endpoint,
                                          generation: String,
                                          transactionID: String) throws {
        let now = Date()
        try endpoint.store.update(timeout: 5) { load in
            guard case .loaded(var current) = load,
                  current.generation == generation,
                  current.state == .stopping,
                  current.shutdown?.transactionID == transactionID else {
                // A stale performer must never overwrite a newer shutdown.
                return (nil, ())
            }
            current.state = .stopped
            current.helper = nil
            current.shutdown = nil
            current.clients = []
            return (current.bumped(at: now), ())
        }
    }

    /// Installer-internal stop. The transaction lock is already held, so only
    /// the launch and registry locks are taken, in that order.
    private static func prepareV2ForReplacement(support: URL) throws {
        let endpoint = try v2Endpoint()
        let launch = try LockFile.open(
            endpoint.support.appendingPathComponent("launch.lock"))
        defer { launch.close() }
        try launch.acquire(
            exclusive: true, timeout: 30,
            busyMessage: "another Retouch Studio process is starting the AI helper")
        try shutdownV2Locked(endpoint)
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
        let recovery = recoverRuntimeIfNeeded()
        guard recovery.isSuccess else {
            NSLog("[RetouchStudio] AI self-test: runtime recovery %@", recovery.logLine)
            return
        }
        guard isInstalled else {
            if let problem = installedRuntimeProblem {
                NSLog("[RetouchStudio] AI self-test: runtime unusable — %@", problem)
            }
            return
        }
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
        launchLock.lock()
        defer { launchLock.unlock() }
        if selectedRuntimeIsDownloaded {
            shutdownV2()
            return
        }
        guard let process = launched, process.isRunning else {
            releaseHelperLease()
            return
        }
        let key = "RetouchStudio.restoringHelper"
        Thread.current.threadDictionary[key] = true
        _ = try? WorkerClient.shared.call("shutdown", timeout: 2)
        Thread.current.threadDictionary.removeObject(forKey: key)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        launched = nil
        // The lease stays until the termination handler fires; the helper may
        // still be reading its runtime for a moment after the reply.
        HelperOwner.removeIfOwned()
    }

    /// Quit-time stop. A child process outlives the app unless it is signalled,
    /// and the async fallback in `shutdown` never runs once we are terminating.
    static func terminate() {
        launchLock.lock()
        defer { launchLock.unlock() }
        if selectedRuntimeIsDownloaded {
            shutdownV2()
            return
        }
        guard let process = launched, process.isRunning else {
            releaseHelperLease()
            return
        }
        process.terminate()
        launched = nil
        releaseHelperLease()
        HelperOwner.removeIfOwned()
    }

    /// One synchronous shutdown attempt for the v2 helper. A busy lock is not
    /// escalated: the child owns its lease, so a helper left running is adopted
    /// or recovered on the next launch instead of being guessed at.
    private static func shutdownV2() {
        do {
            let endpoint = try v2Endpoint()
            try RuntimeTransactionLock.shared.withLock(support: endpoint.support) {
                let launch = try LockFile.open(
                    endpoint.support.appendingPathComponent("launch.lock"))
                defer { launch.close() }
                try launch.acquire(
                    exclusive: true, timeout: 10,
                    busyMessage: "another Retouch Studio process is starting the AI helper")
                try shutdownV2Locked(endpoint)
            }
            runtimeStateLock.lock()
            v2Client = nil
            runtimeStateLock.unlock()
        } catch {
            NSLog("[RetouchStudio] AI helper shutdown skipped: %@", "\(error)")
        }
    }

    // MARK: - Model tool

    /// Starts the worker's model CLI with a lease the CLI process owns. Downloads
    /// live outside the server on purpose: the server has no network code, and
    /// the owner starts a transfer only by pressing the button that shows the
    /// manifest first.
    ///
    /// Resolution, the runtime contract, the shared lease and the spawn all
    /// happen inside one transaction-lock section, so a swap cannot slip
    /// between choosing the interpreter and executing it. The lease descriptor
    /// is duplicated into the child on a fixed number and the parent closes its
    /// copies; from then on the kernel holds the lease through the CLI, even if
    /// this app crashes. Stdout is discarded and stderr is the caller's pipe,
    /// exactly as the progress reader expects.
    static func startModelTool(_ arguments: [String],
                               support: URL = AIWorker.runtimeSupportDirectory,
                               hooks: AIRuntime.InstallHooks = AIRuntime.InstallHooks(),
                               standardError: Pipe? = nil,
                               onExit: @escaping (Int32) -> Void = { _ in })
        throws -> RuntimeModelTool {
        let support = support.standardizedFileURL
        return try RuntimeTransactionLock.shared.withLock(support: support) {
            if selectedRuntimeIsDownloaded(support: support, hooks: hooks),
               !downloadedRuntimeUsable(support: support, hooks: hooks) {
                throw AIWorkerFailure(code: -32000, message: missingHelperMessage)
            }
            guard let python = interpreter(support: support, hooks: hooks),
                  let root = repositoryRoot(support: support, hooks: hooks) else {
                throw AIWorkerFailure(code: -32000,
                                      message: L10n.current.modelsHelperMissing)
            }
            try FileManager.default.createDirectory(
                at: modelDirectory(for: support), withIntermediateDirectories: true)

            let lease: RuntimeUsageLease
            do {
                lease = try RuntimeUsageLease.acquireShared(support: support)
            } catch {
                throw AIWorkerFailure(code: -32000,
                                      message: L10n.current.aiRuntimeBusy)
            }
            let inherited: Int32
            do {
                inherited = try lease.duplicateForChild()
            } catch {
                lease.release()
                throw AIWorkerFailure(code: -32000,
                                      message: L10n.current.modelsDownloadFailed)
            }
            defer { Darwin.close(inherited) }
            let sink = "/dev/null".withCString { Darwin.open($0, O_WRONLY | O_CLOEXEC) }
            guard sink >= 0 else {
                lease.release()
                throw AIWorkerFailure(code: -32000,
                                      message: L10n.current.modelsDownloadFailed)
            }
            defer { Darwin.close(sink) }
            // Once the child holds the write end, the parent's must close or
            // the reader never sees EOF when the CLI exits.
            defer { try? standardError?.fileHandleForWriting.close() }

            let child: ChildProcess
            do {
                child = try ChildProcess.spawn(
                    executable: python,
                    arguments: ["-m", "retouch_ai_worker"] + arguments,
                    environment: workerEnvironment(root: root, support: support),
                    standardOutput: sink,
                    standardError: standardError?.fileHandleForWriting.fileDescriptor,
                    descriptors: [(child: RuntimeBootstrap.usageDescriptor,
                                   parent: inherited)])
            } catch {
                lease.release()
                throw AIWorkerFailure(code: -32000,
                                      message: L10n.current.modelsDownloadFailed)
            }
            // Closing this copy does not release the lock while the child's
            // descriptor refers to the same open file description.
            lease.release()
            return RuntimeModelTool(child: child, onExit: onExit)
        }
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

/// A running model CLI whose runtime lease is owned by the CLI process itself:
/// the launcher closed its descriptor copies after the handoff, so no parent
/// state can release the lease and a crash of the app leaves it in force.
final class RuntimeModelTool {
    private let child: ChildProcess

    var pid: pid_t { child.pid }
    var isRunning: Bool { child.isRunning }
    var terminationStatus: Int32? { child.terminationStatus }

    init(child: ChildProcess, onExit: @escaping (Int32) -> Void) {
        self.child = child
        child.onExit { [weak self] in
            onExit(self?.child.terminationStatus ?? -1)
        }
    }

    /// Cancellation is reported only when the reaper observes the real exit
    /// status; there is no parent-held lease to release early.
    func terminate() { child.terminate() }

    @discardableResult
    func wait(timeout: TimeInterval) -> Bool { child.wait(timeout: timeout) }
}
