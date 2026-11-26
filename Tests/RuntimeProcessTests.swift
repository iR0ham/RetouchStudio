import CoreGraphics
import CoreImage
import Darwin
import Foundation
import UniformTypeIdentifiers

// Cross-process regressions for the runtime hardening:
//
// A. the model CLI is already executing when `startModelTool` returns, so a
//    runtime swap cannot slip between resolution and launch;
// B. a second process holding the shared usage lease keeps an install out until
//    it exits;
// C. killing that process releases the lease (no permanent lock after a crash);
// D. an unrelated process is never signalled, while a verified orphan helper is;
// E. helper startup and replacement serialize on the transaction lock and lease;
// F. a bounded lock wait fails with a retryable busy error and succeeds later;
// G. the model CLI's lease is owned by the CLI process, so it survives the
//    death of the app that launched it and keeps a replacement out;
// H. a cancel request does not free the lease while the CLI is still running;
// I. the production-default model CLI locks and leases the same support tree
//    the runtime installer replaces, while models stay in AI/models;
// J. the working-copy sweep takes folders older than its bound and leaves a
//    copy that is still inside it, so a live job is never cleaned under.
// K. the jobs-root sweep clears what earlier helpers left, while walking past
//    a folder a live job in another process holds, a name that is not a job id
//    and a date it cannot read.
//
// Every child below is a genuine separate process (this same test binary started
// with a `--child-` argument), and every runtime is a temporary fixture.

let rawArguments = CommandLine.arguments
if rawArguments.count > 2, rawArguments[1].hasPrefix("--child-") {
    exit(runChild(Array(rawArguments.dropFirst())))
}

unsetenv("RETOUCH_AI_PYTHON")
unsetenv("RETOUCH_AI_WORKER_ROOT")

var failures: [String] = []

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

let rootDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-runtimeproc-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

// MARK: - Fixtures

func makeFakeRuntime(at root: URL, version: String, python: String? = nil) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root.appendingPathComponent("bin"),
                                withIntermediateDirectories: true)
    let interpreter = root.appendingPathComponent("bin/python3")
    let body = python ?? "#!/bin/sh\nexit 0\n"
    try Data(body.utf8).write(to: interpreter)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
    let worker = root.appendingPathComponent("retouch_ai_worker", isDirectory: true)
    try manager.createDirectory(at: worker, withIntermediateDirectories: true)
    for name in ["__main__.py", "server.py", "engine.py"] {
        try Data("# fake\n".utf8).write(to: worker.appendingPathComponent(name))
    }
    try manager.createDirectory(at: root.appendingPathComponent("site-packages",
                                                                isDirectory: true),
                                withIntermediateDirectories: true)
    try manager.createDirectory(
        at: root.appendingPathComponent("Python.framework/Versions/3.13", isDirectory: true),
        withIntermediateDirectories: true)
    try Data(version.utf8).write(to: root.appendingPathComponent("version.txt"))
}

func copyContents(of source: URL, into destination: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    guard let items = try? manager.contentsOfDirectory(at: source,
                                                       includingPropertiesForKeys: nil) else {
        return
    }
    for item in items {
        let target = destination.appendingPathComponent(item.lastPathComponent)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
            try copyContents(of: item, into: target)
        } else {
            try manager.copyItem(at: item, to: target)
        }
    }
}

func structuralHooks(extract: @escaping (URL, URL) throws -> Void = { _, _ in })
    -> AIRuntime.InstallHooks {
    var hooks = AIRuntime.InstallHooks()
    hooks.extract = extract
    hooks.validateRuntime = { root in
        let layout = AIRuntimeValidation.structural(root: root)
        guard layout.ok else { return layout }
        return RuntimeValidationReport.success(.functional)
    }
    return hooks
}

func fixture(version: String) throws -> URL {
    let url = rootDirectory.appendingPathComponent("fixture-\(version)-\(UUID().uuidString)",
                                                   isDirectory: true)
    try makeFakeRuntime(at: url, version: version)
    return url
}

@discardableResult
func seedRuntime(in support: URL, version: String, python: String? = nil) throws -> URL {
    let source = try fixture(version: version)
    if let python {
        let interpreter = source.appendingPathComponent("bin/python3")
        try Data(python.utf8).write(to: interpreter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: interpreter.path)
    }
    try copyContents(of: source, into: AIRuntime.installDirectory(in: support))
    return source
}

func installFixture(_ source: URL, into support: URL,
                    lockTimeout: TimeInterval = 5,
                    usageTimeout: TimeInterval = 2) throws {
    try AIRuntime.install(
        archive: source, support: support, package: nil,
        hooks: structuralHooks { fixtureURL, staging in
            try copyContents(of: fixtureURL, into: staging)
        },
        lockTimeout: lockTimeout, usageTimeout: usageTimeout)
}

func installedVersion(in support: URL) -> String? {
    let url = AIRuntime.installDirectory(in: support)
        .appendingPathComponent("version.txt")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
}

func freshSupport(_ name: String) -> URL {
    let support = rootDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)",
                                                       isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    return support
}

func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

func pollUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

func spawnSelf(_ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func waitUntilStopped(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning { return false }
    process.waitUntilExit()
    return true
}

// MARK: - Child processes

func runChild(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 2 else { return 64 }
    let mode = arguments[0]
    let support = URL(fileURLWithPath: arguments[1], isDirectory: true)
    func seconds(_ index: Int, _ fallback: Double) -> Double {
        arguments.count > index ? (Double(arguments[index]) ?? fallback) : fallback
    }

    switch mode {
    case "--child-joblock":
        // A helper's claim on one job workdir, held by a process the sweep has no
        // relationship with: the same exclusive `flock` `JobManager._run` takes on
        // `<workdir>/.lock` for the length of a render. `support` is the workdir.
        let path = support.appendingPathComponent(AIWorker.jobLockName).path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return 72 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return 73
        }
        try? Data("\(getpid())".utf8).write(
            to: support.appendingPathComponent("child-joblock-held"))
        Thread.sleep(forTimeInterval: seconds(2, 6))
        close(descriptor)
        return 0

    case "--child-lease":
        do {
            let lease = try RuntimeUsageLease.acquireShared(support: support)
            try? Data("\(getpid())".utf8).write(
                to: support.appendingPathComponent("child-lease-ready"))
            Thread.sleep(forTimeInterval: seconds(2, 4))
            lease.release()
            return 0
        } catch {
            return 70
        }

    case "--child-lock":
        do {
            try RuntimeTransactionLock.shared.withLock(support: support, timeout: 30) {
                try? Data("\(getpid())".utf8).write(
                    to: support.appendingPathComponent("child-lock-held"))
                Thread.sleep(forTimeInterval: seconds(2, 2))
            }
            return 0
        } catch {
            return 71
        }

    case "--child-startup":
        // A helper startup: the transaction lock is taken first, the shared
        // lease is acquired before the lock is released, then the helper runs.
        // The lock is held until the parent releases it, so a slow machine
        // cannot make the window expire before the parent observes it.
        do {
            var lease: RuntimeUsageLease?
            try RuntimeTransactionLock.shared.withLock(support: support, timeout: 30) {
                try? Data("\(getpid())".utf8).write(
                    to: support.appendingPathComponent("child-startup-locked"))
                let release = support.appendingPathComponent("child-startup-release")
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: release.path),
                      Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                lease = try RuntimeUsageLease.acquireShared(support: support)
                try? Data("\(getpid())".utf8).write(
                    to: support.appendingPathComponent("child-startup-started"))
            }
            Thread.sleep(forTimeInterval: 0.5)
            lease?.release()
            return 0
        } catch {
            return 72
        }

    case "--child-sleep":
        // A process that lives inside a runtime path without doing anything,
        // used as a stand-in for a helper left behind by a crashed app.
        Thread.sleep(forTimeInterval: seconds(2, 20))
        return 0

    case "--child-model-cli":
        // Starts the model CLI and stays alive only as its launcher. The CLI
        // itself must keep the runtime leased after this process is killed.
        do {
            let tool = try AIWorker.startModelTool(["models", "download"],
                                                   support: support)
            try? Data("\(tool.pid)".utf8).write(
                to: support.appendingPathComponent("child-model-pid"))
            Thread.sleep(forTimeInterval: seconds(2, 60))
            return 0
        } catch {
            return 73
        }

    default:
        return 64
    }
}

// MARK: - A

func testCLILaunchCannotRaceSwap() {
    print("\n[A] a model CLI launch cannot race a runtime swap")
    let support = freshSupport("cli-race")
    let marker = support.appendingPathComponent("cli-started")
    let script = "#!/bin/sh\nprintf started > '\(marker.path)'\nsleep 1.6\n"
    let source: URL
    do {
        source = try seedRuntime(in: support, version: "v1", python: script)
    } catch {
        check(false, "A: fixture runtime written", "\(error)")
        return
    }

    // The model CLI follows the same developer override as the checkout path:
    // point it at the fixture interpreter and worker package.
    setenv("RETOUCH_AI_PYTHON",
           source.appendingPathComponent("bin/python3").path, 1)
    setenv("RETOUCH_AI_WORKER_ROOT", source.path, 1)
    let tool: RuntimeModelTool
    do {
        tool = try AIWorker.startModelTool(["models", "download"],
                                           support: support,
                                           hooks: structuralHooks())
    } catch {
        unsetenv("RETOUCH_AI_PYTHON")
        unsetenv("RETOUCH_AI_WORKER_ROOT")
        check(false, "A: the CLI starts", "\(error)")
        return
    }
    unsetenv("RETOUCH_AI_PYTHON")
    unsetenv("RETOUCH_AI_WORKER_ROOT")
    check(tool.isRunning, "A: the CLI is already executing when the API returns",
          "pid \(tool.pid)")
    check(waitForFile(marker, timeout: 3), "A: the fake CLI actually ran")

    let next = try? fixture(version: "v2")
    var busy: AIRuntimeFailure?
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 2, usageTimeout: 0.3)
        } catch let failure as AIRuntimeFailure {
            busy = failure
        } catch {
            check(false, "A: the swap fails cleanly", "\(error)")
        }
    }
    check(busy?.code == .busy, "A: a swap while the CLI runs is refused as busy",
          busy.map { "\($0.code)" } ?? "no error")
    check(installedVersion(in: support) == "v1", "A: the live runtime was not touched")

    _ = tool.wait(timeout: 5)
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 5, usageTimeout: 3)
            check(installedVersion(in: support) == "v2",
                  "A: the same swap succeeds once the CLI has exited")
        } catch {
            check(false, "A: the retry succeeds", "\(error)")
        }
    }
}

// MARK: - B

func testLiveHelperLeaseBlocksReplacement() {
    print("\n[B] another process using the helper keeps the runtime in place")
    let support = freshSupport("live-lease")
    do {
        try seedRuntime(in: support, version: "v1")
    } catch {
        check(false, "B: fixture runtime written", "\(error)")
        return
    }

    let ready = support.appendingPathComponent("child-lease-ready")
    let child: Process
    do {
        child = try spawnSelf(["--child-lease", support.path, "3"])
    } catch {
        check(false, "B: second process started", "\(error)")
        return
    }
    check(waitForFile(ready, timeout: 5), "B: the second process holds a usage lease",
          "pid \(child.processIdentifier)")

    let next = try? fixture(version: "v2")
    var busy: AIRuntimeFailure?
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 3, usageTimeout: 0.4)
        } catch let failure as AIRuntimeFailure {
            busy = failure
        } catch {
            check(false, "B: the blocked install reports a typed error", "\(error)")
        }
    }
    check(busy?.code == .busy, "B: replacement is refused while the lease is held",
          busy.map { "\($0.code)" } ?? "no error")
    check(child.isRunning, "B: the using process was not killed")
    check(installedVersion(in: support) == "v1", "B: the runtime was not replaced")

    check(waitUntilStopped(child, timeout: 6), "B: the second process exits on its own")
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 5, usageTimeout: 3)
            check(installedVersion(in: support) == "v2",
                  "B: replacement proceeds after the lease is released")
        } catch {
            check(false, "B: replacement after release", "\(error)")
        }
    }
}

// MARK: - C

func testCrashedProcessLeavesNoLease() {
    print("\n[C] a crashed process leaves no permanent usage lease")
    let support = freshSupport("crashed-lease")
    do {
        try seedRuntime(in: support, version: "v1")
    } catch {
        check(false, "C: fixture runtime written", "\(error)")
        return
    }

    let ready = support.appendingPathComponent("child-lease-ready")
    let child: Process
    do {
        child = try spawnSelf(["--child-lease", support.path, "60"])
    } catch {
        check(false, "C: second process started", "\(error)")
        return
    }
    guard waitForFile(ready, timeout: 5) else {
        check(false, "C: the second process acquired a lease")
        child.terminate()
        _ = waitUntilStopped(child, timeout: 3)
        return
    }
    kill(child.processIdentifier, SIGKILL)
    check(waitUntilStopped(child, timeout: 5), "C: the lease holder is dead",
          "killed pid \(child.processIdentifier)")

    let next = try? fixture(version: "v2")
    let started = Date()
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 3, usageTimeout: 3)
            let elapsed = Date().timeIntervalSince(started)
            check(installedVersion(in: support) == "v2",
                  "C: installation succeeds after the crash")
            check(elapsed < 5, "C: the kernel released the lease", String(format: "%.2fs", elapsed))
        } catch {
            check(false, "C: installation after crash", "\(error)")
        }
    }
}

// MARK: - D

func writeHelperOwner(in support: URL, appPID: Int32, workerPID: Int32,
                      executable: String?) {
    var object: [String: Any] = [
        "appPID": appPID,
        "workerPID": workerPID,
        "models": support.appendingPathComponent("models").path,
    ]
    if let executable { object["workerExecutable"] = executable }
    if let data = try? JSONSerialization.data(withJSONObject: object) {
        try? data.write(to: support.appendingPathComponent("helper-owner.json"))
    }
}

func deadProcessIdentifier() -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    return process.processIdentifier
}

func testUnrelatedProcessIsNeverTerminated() {
    print("\n[D] unrelated processes are never terminated")
    let support = freshSupport("identity")
    guard let deadApp = deadProcessIdentifier() else {
        check(false, "D: a dead PID was captured")
        return
    }

    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["20"]
    do { try unrelated.run() } catch {
        check(false, "D: unrelated process started", "\(error)")
        return
    }
    defer {
        unrelated.terminate()
        _ = waitUntilStopped(unrelated, timeout: 3)
    }
    let unrelatedPID = unrelated.processIdentifier

    // Same executable name, wrong identity: the recorded path does not match.
    writeHelperOwner(in: support, appPID: deadApp, workerPID: unrelatedPID,
                     executable: "/bin/sleep")
    try? AIWorker.prepareForRuntimeReplacement(support: support)
    check(kill(unrelatedPID, 0) == 0,
          "D: a recycled/stale record does not kill the unrelated process",
          "pid \(unrelatedPID) alive")

    // A recorded path inside the runtime still must not match the actual PID.
    writeHelperOwner(in: support, appPID: deadApp, workerPID: unrelatedPID,
                     executable: AIRuntime.installDirectory(in: support)
                        .appendingPathComponent("bin/python3").path)
    try? AIWorker.prepareForRuntimeReplacement(support: support)
    check(kill(unrelatedPID, 0) == 0,
          "D: a mismatched executable path is not enough to signal a PID")

    // A live app with a legacy record (no executable, so no lease) cannot be
    // verified or waited for. That is a retryable busy answer, not a silent
    // swap under a running helper.
    writeHelperOwner(in: support, appPID: unrelatedPID, workerPID: unrelatedPID,
                     executable: nil)
    var legacyBusy = false
    do {
        try AIWorker.prepareForRuntimeReplacement(support: support)
    } catch is AIRuntimeBusyError {
        legacyBusy = true
    } catch {
        check(false, "D: a legacy live owner fails as busy", "\(error)")
    }
    check(legacyBusy, "D: a live older build becomes a retryable busy answer")

    // A verified orphan helper inside this runtime is the one process that is
    // stopped. The fixture is a copy of this suite's own ad-hoc signed binary:
    // newer macOS releases kill a relocated copy of a platform binary before
    // the test can observe it, which made this check pass without the code
    // under test doing anything. The copy runs from the runtime path so
    // `proc_pidpath` reports that path.
    let runtime = AIRuntime.installDirectory(in: support)
    do {
        try makeFakeRuntime(at: runtime, version: "orphan")
        let interpreter = runtime.appendingPathComponent("bin/python3")
        try FileManager.default.removeItem(at: interpreter)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: CommandLine.arguments[0]), to: interpreter)
    } catch {
        check(false, "D: orphan fixture written", "\(error)")
        return
    }
    let orphan = Process()
    orphan.executableURL = runtime.appendingPathComponent("bin/python3")
    orphan.arguments = ["--child-sleep", support.path, "20"]
    do { try orphan.run() } catch {
        check(false, "D: orphan helper started", "\(error)")
        return
    }
    let orphanPID = orphan.processIdentifier
    check(pollUntil(2, { kill(orphanPID, 0) == 0 && orphan.isRunning }),
          "D: the orphan fixture is running", "pid \(orphanPID)")
    writeHelperOwner(in: support, appPID: deadApp, workerPID: orphanPID,
                     executable: runtime.appendingPathComponent("bin/python3").path)
    try? AIWorker.prepareForRuntimeReplacement(support: support)
    let stopped = waitUntilStopped(orphan, timeout: 6)
    check(stopped && kill(orphanPID, 0) != 0,
          "D: a verified orphan helper inside the runtime is stopped",
          "orphan pid \(orphanPID)")
    check(kill(unrelatedPID, 0) == 0,
          "D: the unrelated process is still untouched afterwards")
}

// MARK: - E

func testStartupAndReplacementSerialize() {
    print("\n[E] helper startup and replacement serialize")
    let support = freshSupport("serialize")
    do {
        try seedRuntime(in: support, version: "v1")
    } catch {
        check(false, "E: fixture runtime written", "\(error)")
        return
    }

    let locked = support.appendingPathComponent("child-startup-locked")
    let extractMarker = support.appendingPathComponent("extract-started")
    let child: Process
    do {
        child = try spawnSelf(["--child-startup", support.path])
    } catch {
        check(false, "E: startup process started", "\(error)")
        return
    }
    guard waitForFile(locked, timeout: 5) else {
        check(false, "E: startup took the transaction lock", "pid \(child.processIdentifier)")
        child.terminate()
        _ = waitUntilStopped(child, timeout: 3)
        return
    }

    let next = try? fixture(version: "v2")
    let finished = NSLock()
    var installDone = false
    var installError: String?
    var installThread: Thread?
    if let next {
        let thread = Thread {
            do {
                try AIRuntime.install(
                    archive: next, support: support, package: nil,
                    hooks: structuralHooks { fixtureURL, staging in
                        try? Data("extract".utf8).write(to: extractMarker)
                        try copyContents(of: fixtureURL, into: staging)
                    },
                    lockTimeout: 8, usageTimeout: 8)
            } catch {
                installError = "\(error)"
            }
            finished.lock()
            installDone = true
            finished.unlock()
        }
        thread.start()
        installThread = thread
    }

    Thread.sleep(forTimeInterval: 0.35)
    finished.lock()
    let finishedEarly = installDone
    finished.unlock()
    check(!waitForFile(extractMarker, timeout: 0.01),
          "E: no extraction starts while the startup holds the lock")
    check(!finishedEarly, "E: the install cannot finish during helper startup")

    try? Data().write(to: support.appendingPathComponent("child-startup-release"))
    check(waitUntilStopped(child, timeout: 8), "E: the startup process finishes",
          "pid \(child.processIdentifier)")
    if let installThread {
        let deadline = Date().addingTimeInterval(10)
        while installThread.isExecuting && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    finished.lock()
    let done = installDone
    finished.unlock()
    check(done && installError == nil, "E: the install completes after startup",
          installError ?? "")
    check(installedVersion(in: support) == "v2",
          "E: the replacement won the serialized order")
}

// MARK: - F

func testBoundedLockWaitIsRetryable() {
    print("\n[F] a bounded lock wait fails safely and is retryable")
    let support = freshSupport("lock-timeout")
    let held = support.appendingPathComponent("child-lock-held")
    let child: Process
    do {
        child = try spawnSelf(["--child-lock", support.path, "2"])
    } catch {
        check(false, "F: lock holder started", "\(error)")
        return
    }
    guard waitForFile(held, timeout: 5) else {
        check(false, "F: the lock holder took the transaction lock",
              "pid \(child.processIdentifier)")
        child.terminate()
        _ = waitUntilStopped(child, timeout: 3)
        return
    }

    let next = try? fixture(version: "v2")
    var busy: AIRuntimeFailure?
    let started = Date()
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 0.3, usageTimeout: 1)
        } catch let failure as AIRuntimeFailure {
            busy = failure
        } catch {
            check(false, "F: the bounded wait reports a typed error", "\(error)")
        }
    }
    let waited = Date().timeIntervalSince(started)
    check(busy?.code == .busy, "F: the timeout is reported as busy",
          busy.map { "\($0.code)" } ?? "no error")
    check(waited < 2, "F: the wait is bounded", String(format: "%.2fs", waited))
    check(!FileManager.default.fileExists(
            atPath: AIRuntime.installDirectory(in: support).path),
          "F: nothing was installed by the timed-out attempt")
    check(child.isRunning, "F: the holder was not disturbed")

    check(waitUntilStopped(child, timeout: 6), "F: the holder exits",
          "pid \(child.processIdentifier)")
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 5, usageTimeout: 3)
            check(installedVersion(in: support) == "v2",
                  "F: the retry succeeds without changing the code path")
        } catch {
            check(false, "F: the retry succeeds", "\(error)")
        }
    }
}

// MARK: - G

func testModelCLILeaseIsChildOwned() {
    print("\n[G] the model CLI owns its runtime lease across a launcher crash")
    let support = freshSupport("model-cli-lease")
    let started = support.appendingPathComponent("cli-started")
    // `exec` is deliberate: a shell child would inherit the lease descriptor
    // and keep the runtime pinned after the wrapper exits.
    let script = "#!/bin/sh\nprintf '%s' \"$$\" > '\(started.path)'\nexec sleep 60\n"
    do {
        try seedRuntime(in: support, version: "v1", python: script)
    } catch {
        check(false, "G: fixture runtime written", "\(error)")
        return
    }

    setenv("RETOUCH_AI_PYTHON",
           AIRuntime.installDirectory(in: support).appendingPathComponent("bin/python3").path, 1)
    setenv("RETOUCH_AI_WORKER_ROOT", support.path, 1)
    let child: Process
    do {
        child = try spawnSelf(["--child-model-cli", support.path])
    } catch {
        unsetenv("RETOUCH_AI_PYTHON")
        unsetenv("RETOUCH_AI_WORKER_ROOT")
        check(false, "G: launcher process started", "\(error)")
        return
    }
    unsetenv("RETOUCH_AI_PYTHON")
    unsetenv("RETOUCH_AI_WORKER_ROOT")

    let pidFile = support.appendingPathComponent("child-model-pid")
    guard waitForFile(pidFile, timeout: 5), waitForFile(started, timeout: 5),
          let text = try? String(contentsOf: pidFile, encoding: .utf8),
          let cliPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        check(false, "G: the CLI started and reported its pid")
        child.terminate()
        _ = waitUntilStopped(child, timeout: 3)
        return
    }
    let scriptPID = (try? String(contentsOf: started, encoding: .utf8)) ?? ""
    check(String(cliPID) == scriptPID,
          "G: the reported pid is the process that holds the lease", "pid \(cliPID)")
    check(kill(cliPID, 0) == 0, "G: the CLI is running")

    kill(child.processIdentifier, SIGKILL)
    check(waitUntilStopped(child, timeout: 5), "G: the launching app process is dead")
    check(kill(cliPID, 0) == 0, "G: the CLI outlives the app that started it")

    let next = try? fixture(version: "v2")
    var busy: AIRuntimeFailure?
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 3, usageTimeout: 0.4)
        } catch let failure as AIRuntimeFailure {
            busy = failure
        } catch {
            check(false, "G: the blocked install reports a typed error", "\(error)")
        }
    }
    check(busy?.code == .busy,
          "G: the orphaned CLI still blocks a replacement",
          busy.map { "\($0.code)" } ?? "no error")
    check(installedVersion(in: support) == "v1", "G: the runtime was not replaced")

    kill(cliPID, SIGTERM)
    check(pollUntil(5) { kill(cliPID, 0) != 0 }, "G: the cancelled CLI exits")
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 5, usageTimeout: 3)
            check(installedVersion(in: support) == "v2",
                  "G: the replacement proceeds once the CLI is gone")
        } catch {
            check(false, "G: replacement after the CLI exits", "\(error)")
        }
    }
}

// MARK: - H

func testCancellationKeepsLeaseUntilExit() {
    print("\n[H] a cancel request cannot free the lease while the CLI still runs")
    let support = freshSupport("model-cli-cancel")
    let started = support.appendingPathComponent("cli-started")
    // The wrapper ignores SIGTERM, so it is still mid-operation after the
    // cancel request. The lease is the kernel's through the CLI's descriptor;
    // nothing in the parent can release it early.
    let script = "#!/bin/sh\ntrap '' TERM\nprintf started > '\(started.path)'\nsleep 1.5\n"
    do {
        try seedRuntime(in: support, version: "v1", python: script)
    } catch {
        check(false, "H: fixture runtime written", "\(error)")
        return
    }

    setenv("RETOUCH_AI_PYTHON",
           AIRuntime.installDirectory(in: support).appendingPathComponent("bin/python3").path, 1)
    setenv("RETOUCH_AI_WORKER_ROOT", support.path, 1)
    let tool: RuntimeModelTool
    do {
        tool = try AIWorker.startModelTool(["models", "download"], support: support)
    } catch {
        unsetenv("RETOUCH_AI_PYTHON")
        unsetenv("RETOUCH_AI_WORKER_ROOT")
        check(false, "H: the CLI starts", "\(error)")
        return
    }
    unsetenv("RETOUCH_AI_PYTHON")
    unsetenv("RETOUCH_AI_WORKER_ROOT")
    check(waitForFile(started, timeout: 3), "H: the CLI is running")

    tool.terminate()
    check(tool.isRunning, "H: the CLI survives the cancel request")

    let next = try? fixture(version: "v2")
    var busy: AIRuntimeFailure?
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 2, usageTimeout: 0.3)
        } catch let failure as AIRuntimeFailure {
            busy = failure
        } catch {
            check(false, "H: the blocked install reports a typed error", "\(error)")
        }
    }
    check(busy?.code == .busy, "H: a cancel request does not free the lease",
          busy.map { "\($0.code)" } ?? "no error")
    check(tool.isRunning, "H: the CLI was still active during the refused install")

    check(tool.wait(timeout: 6), "H: the CLI exits on its own")
    if let next {
        do {
            try installFixture(next, into: support, lockTimeout: 5, usageTimeout: 3)
            check(installedVersion(in: support) == "v2",
                  "H: the lease is released only after the real exit")
        } catch {
            check(false, "H: replacement after the real exit", "\(error)")
        }
    }
}

// MARK: - I

func testProductionDefaultUsesInstallerSupport() {
    print("\n[I] the production-default CLI uses the installer's runtime tree")
    let scratch = freshSupport("default-support")
    let runtimeSupport = scratch.appendingPathComponent("runtimes", isDirectory: true)
    let models = scratch.appendingPathComponent("models", isDirectory: true)
    AIWorker.supportDirectoryOverride = scratch
    defer { AIWorker.supportDirectoryOverride = nil }

    let started = scratch.appendingPathComponent("cli-started")
    let source: URL
    do {
        source = try fixture(version: "default-support")
        let interpreter = source.appendingPathComponent("bin/python3")
        let script = "#!/bin/sh\nprintf started > '\(started.path)'\nsleep 4\n"
        try Data(script.utf8).write(to: interpreter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: interpreter.path)
    } catch {
        check(false, "I: fixture runtime written", "\(error)")
        return
    }

    // No `support:` argument: this is the call ModelManager makes in production.
    setenv("RETOUCH_AI_PYTHON",
           source.appendingPathComponent("bin/python3").path, 1)
    setenv("RETOUCH_AI_WORKER_ROOT", source.path, 1)
    let tool: RuntimeModelTool
    do {
        tool = try AIWorker.startModelTool(["models", "download"])
    } catch {
        unsetenv("RETOUCH_AI_PYTHON")
        unsetenv("RETOUCH_AI_WORKER_ROOT")
        check(false, "I: the default CLI starts", "\(error)")
        return
    }
    unsetenv("RETOUCH_AI_PYTHON")
    unsetenv("RETOUCH_AI_WORKER_ROOT")
    check(tool.isRunning, "I: the CLI is running", "pid \(tool.pid)")
    check(waitForFile(started, timeout: 3), "I: the fake CLI actually ran")

    let leasePath = runtimeSupport.appendingPathComponent(RuntimeUsageLease.fileName)
    let lockPath = runtimeSupport.appendingPathComponent("runtime.lock")
    let oldLeasePath = scratch.appendingPathComponent(RuntimeUsageLease.fileName)
    let oldLockPath = scratch.appendingPathComponent("runtime.lock")
    check(FileManager.default.fileExists(atPath: leasePath.path),
          "I: the shared lease lives under AI/runtimes")
    check(FileManager.default.fileExists(atPath: lockPath.path),
          "I: the transaction lock lives under AI/runtimes")
    check(!FileManager.default.fileExists(atPath: oldLeasePath.path),
          "I: the old support root has no usage lease")
    check(!FileManager.default.fileExists(atPath: oldLockPath.path),
          "I: the old support root has no transaction lock")
    check(FileManager.default.fileExists(atPath: models.path),
          "I: model storage stays in AI/models")
    check(!FileManager.default.fileExists(
        atPath: runtimeSupport.appendingPathComponent("models").path),
        "I: no model folder appears inside the runtime tree")

    // The installer takes this exact lease before swapping the runtime.
    var installBlocked = false
    do {
        let lease = try RuntimeUsageLease.acquireExclusive(support: runtimeSupport,
                                                           timeout: 0.3)
        lease.release()
    } catch {
        installBlocked = true
    }
    check(installBlocked, "I: the installer's exclusive lease is refused while the CLI runs")

    var oldRootFree = false
    do {
        let lease = try RuntimeUsageLease.acquireExclusive(support: scratch, timeout: 0)
        lease.release()
        oldRootFree = true
    } catch {
        // A lease in the old tree would mean the default was still wrong.
    }
    check(oldRootFree, "I: no shared lease is held in the old support root")

    check(tool.wait(timeout: 8), "I: the CLI exits on its own")
}

// MARK: - J. The working-copy sweep

func testStaleWorkingCopiesAreSweptAndLiveOnesAreNot() {
    let manager = FileManager.default
    let root = rootDirectory.appendingPathComponent("working-copies", isDirectory: true)
    try? manager.removeItem(at: root)
    try! manager.createDirectory(at: root, withIntermediateDirectories: true)

    func planted(_ age: TimeInterval, file: String = "photo.png") -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try! Data([0x89, 0x50]).write(to: folder.appendingPathComponent(file))
        if age != 0 {
            try! manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: age)],
                                       ofItemAtPath: folder.path)
        }
        return folder
    }

    let stale = planted(-90_000)
    let justInside = planted(-86_000)
    let live = planted(0)
    // A working copy that became a link into someone's folder: the sweep may
    // take the entry, never the bytes the entry points at.
    let outside = rootDirectory.appendingPathComponent("linked-target", isDirectory: true)
    try? manager.removeItem(at: outside)
    try! manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let kept = outside.appendingPathComponent("photo.png")
    try! Data([0x89, 0x50]).write(to: kept)
    try! manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)],
                               ofItemAtPath: outside.path)
    let link = root.appendingPathComponent("linked-copy", isDirectory: true)
    try! manager.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
    // Age the link itself, not what it points at: `lutimes` does not follow.
    var when = [timeval(tv_sec: Int(time(nil)) - 90_000, tv_usec: 0),
                timeval(tv_sec: Int(time(nil)) - 90_000, tv_usec: 0)]
    lutimes(link.path, &when)

    // First launch: the root does not exist yet, and that is not an error.
    AIWorker.cleanStaleWorkingCopies(
        in: root.appendingPathComponent("absent", isDirectory: true))
    let untouched = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
    check(untouched.count == 4, "J: sweeping a root that was never created takes nothing")
    AIWorker.cleanStaleWorkingCopies(in: root)

    let left = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
    check(!left.contains(stale.lastPathComponent),
          "J: a copy older than the bound is swept with its bytes")
    check(left.contains(justInside.lastPathComponent),
          "J: a copy just inside the bound survives")
    check(manager.fileExists(atPath: live.appendingPathComponent("photo.png").path),
          "J: a copy a job is still using keeps its file")
    check(!left.contains(link.lastPathComponent),
          "J: a stale link entry goes with its own date")
    check(manager.fileExists(atPath: kept.path),
          "J: the sweep never follows a link into bytes it does not own")
    check(manager.fileExists(atPath: root.path),
          "J: the sweep takes entries, never the working root itself")
}

// MARK: - K. The jobs-root sweep

func testStaleJobFoldersAreSweptAndLiveOnesAreNot() {
    let manager = FileManager.default
    let root = rootDirectory.appendingPathComponent("jobs", isDirectory: true)
    try? manager.removeItem(at: root)
    try! manager.createDirectory(at: root, withIntermediateDirectories: true)

    func aged(_ folder: URL, _ age: TimeInterval) {
        try! manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: age)],
                                   ofItemAtPath: folder.path)
    }

    // Workdirs are named by the helper's twelve-hex-digit job id, which is how
    // the sweep tells its own residue from anything else sharing the root.
    func planted(_ name: String, age: TimeInterval, file: String = "out.png") -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try! manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try! Data([0x89, 0x50]).write(to: folder.appendingPathComponent(file))
        if age != 0 { aged(folder, age) }
        return folder
    }

    let stale = planted("a1b2c3d4e5f6", age: -90_000)
    let justInside = planted("b2c3d4e5f6a1", age: -86_000)
    let young = planted("c3d4e5f6a1b2", age: 0)
    let running = planted("d4e5f6a1b2c3", age: -90_000)
    let notAJob = planted("notes-for-me", age: -90_000)
    // The spelling is the point, so the sample cannot share a name with a real
    // id on a case-insensitive volume: this one is never planted in lowercase.
    let upperCase = planted("A9B8C7D6E5F4", age: -90_000)
    // A dangling entry sharing a job id's shape: its date cannot be read, so the
    // sweep keeps it. A workdir this machine cannot date is not evidence that
    // nobody is using it.
    let undateable = root.appendingPathComponent("e5f6a1b2c3d4", isDirectory: true)
    try! manager.createSymbolicLink(atPath: undateable.path,
                                    withDestinationPath: root.path + "/nowhere")
    var when = [timeval(tv_sec: Int(time(nil)) - 90_000, tv_usec: 0),
                timeval(tv_sec: Int(time(nil)) - 90_000, tv_usec: 0)]
    lutimes(undateable.path, &when)

    // The claim is held by a second process, because that is the arrangement that
    // matters: the helper renders, the app sweeps, and the two have no shared
    // state beyond the flock on `<workdir>/.lock`.
    let holder = try! spawnSelf(["--child-joblock", running.path, "20"])
    let marker = running.appendingPathComponent("child-joblock-held")
    var waited = 0.0
    while !manager.fileExists(atPath: marker.path) && holder.isRunning && waited < 5 {
        Thread.sleep(forTimeInterval: 0.05)
        waited += 0.05
    }
    check(manager.fileExists(atPath: marker.path) && holder.isRunning,
          "K: another process holds this workdir's claim")
    // The claim's own files are the newest bytes in the folder, so it is aged
    // again: the keep below has to be about the lock, not the calendar.
    aged(running, -90_000)

    // A root that was never created is not a decision, and not an error.
    let absent = AIWorker.cleanStaleJobFolders(
        in: root.appendingPathComponent("absent", isDirectory: true))
    check(absent.isEmpty, "K: sweeping a root that was never created decides nothing")

    let decisions = AIWorker.cleanStaleJobFolders(in: root)
    let left = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
    func action(_ folder: URL) -> String {
        decisions.first { $0.folder == folder.lastPathComponent }?.action ?? "missing"
    }
    func reason(_ folder: URL) -> String {
        decisions.first { $0.folder == folder.lastPathComponent }?.reason ?? ""
    }

    check(!left.contains(stale.lastPathComponent),
          "K: residue older than the bound is swept with its bytes")
    check(action(stale) == "removed", "K: the sweep reports the folder it took")
    check(left.contains(justInside.lastPathComponent),
          "K: a job just inside the bound survives")
    check(left.contains(young.lastPathComponent),
          "K: a job this session started keeps its bytes")
    check(reason(justInside).contains("grace"),
          "K: a surviving job is kept for its age, not its lock")
    check(left.contains(running.lastPathComponent),
          "K: a folder a running job locks is never swept, however old it is")
    check(reason(running).contains("running job"),
          "K: the lock is the stated reason, not the calendar")
    check(left.contains(notAJob.lastPathComponent),
          "K: a directory that is not a job workdir is left alone")
    check(left.contains(upperCase.lastPathComponent),
          "K: a name outside the helper's job id spelling is not a workdir")
    check(left.contains(undateable.lastPathComponent),
          "K: a folder whose date cannot be read is kept")
    check(manager.fileExists(atPath: root.path),
          "K: the sweep takes entries, never the jobs root itself")

    // Releasing the claim is what ends a job, and the next pass sees ordinary
    // residue. A kill is the honest version of that release: the kernel drops a
    // flock the holder never closed, which is why a crashed helper needs no
    // repair and why a guard can never outlive the job it protected.
    holder.terminate()
    check(waitUntilStopped(holder, timeout: 5), "K: the process holding the claim is gone")
    let after = AIWorker.cleanStaleJobFolders(in: root)
    check(after.contains { $0.folder == running.lastPathComponent && $0.action == "removed" },
          "K: once the job lets go, its folder is the same residue as any other")
    let still = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
    check(still.contains(justInside.lastPathComponent) && still.contains(young.lastPathComponent),
          "K: the second pass keeps what the first pass kept")
}

// MARK: - L. Runtime environment containment

func testRuntimeEnvironmentRejectsExternalPaths() {
    print("\n[L] functional validation checks paths, not inert path text")
    let runtime: URL
    do {
        runtime = try fixture(version: "environment")
    } catch {
        check(false, "L: fixture runtime written", "\(error)")
        return
    }

    func report(path: [Any], sysconfig: [String: String],
                root: URL? = nil, basePrefix: String? = nil) -> RuntimeValidationReport {
        let reportedRoot = root ?? runtime
        let info: [String: Any] = [
            "implementation": "CPython",
            "version": [3, 13, 15],
            "machine": AIRuntimeValidation.expectedMachine,
            "prefix": reportedRoot.path,
            "base_prefix": basePrefix ?? reportedRoot.path,
            "executable": reportedRoot.appendingPathComponent("bin/python3").path,
            "path": path,
            "sysconfig_paths": sysconfig,
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: info))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let core = #"{"numpy":null,"PIL":null}"#
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "-c" ]; then
          case "${2:-}" in
            *'"implementation"'*) printf '%s\\n' '\(encoded)' ;;
            *'for name in ["numpy", "PIL"]'*) printf '%s\\n' '\(core)' ;;
            *) exit 1 ;;
          esac
        else
          exit 1
        fi
        """
        try? Data(script.utf8).write(to: runtime.appendingPathComponent("bin/python3"))
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtime.appendingPathComponent("bin/python3").path)
        return AIRuntimeValidation.functional(root: root ?? runtime, timeout: 10)
    }

    let contained = [
        runtime.path,
        runtime.appendingPathComponent("site-packages").path,
        runtime.appendingPathComponent("Python.framework/Versions/3.13/lib/python3.13").path,
    ]
    let containedConfig = [
        "stdlib": runtime.appendingPathComponent("Python.framework/Versions/3.13/lib/python3.13").path,
        "platstdlib": runtime.appendingPathComponent("Python.framework/Versions/3.13/lib/python3.13").path,
    ]
    let clean = report(path: contained, sysconfig: containedConfig)
    check(clean.issues.first?.code == "startup",
          "L: contained paths pass the environment stage",
          clean.issues.first?.detail ?? "no environment issue")

    let alias = rootDirectory.appendingPathComponent(
        "environment-alias-\(UUID().uuidString)", isDirectory: true)
    do {
        // The runtime itself is a real directory. Only an ancestor is a link,
        // matching macOS temporary-directory alias canonicalization and
        // preserving the rule that the runtime root must not itself be a link.
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: rootDirectory)
    } catch {
        check(false, "L: symlinked runtime ancestor created", "\(error)")
        return
    }
    let aliasRoot = alias.appendingPathComponent(runtime.lastPathComponent,
                                                  isDirectory: true)
    let absentStdlibZip = aliasRoot.appendingPathComponent(
        "Python.framework/Versions/3.13/lib/python313.zip").path
    let aliased = report(
        path: [aliasRoot.path, absentStdlibZip],
        sysconfig: [
            "stdlib": runtime.appendingPathComponent("site-packages").path,
            "platstdlib": runtime.appendingPathComponent("site-packages").path,
        ],
        root: aliasRoot)
    check(aliased.issues.first?.code == "startup",
          "L: a symlinked runtime ancestor accepts its absent stdlib zip",
          aliased.issues.first?.detail ?? "no environment issue")

    let outside = rootDirectory.appendingPathComponent(
        "environment-outside-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let escape = runtime.appendingPathComponent("external-link", isDirectory: true)
    try? FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
    let linkedPath = report(path: contained + [escape.path], sysconfig: containedConfig)
    check(linkedPath.issues.first?.code == "environment"
          && linkedPath.issues.first?.detail.contains("module search path") == true,
          "L: an existing symlink inside the runtime cannot escape it",
          linkedPath.issues.first?.detail ?? "no issue")
    let linkedMissingPath = report(
        path: contained + [escape.appendingPathComponent("python313.zip").path],
        sysconfig: containedConfig)
    check(linkedMissingPath.issues.first?.code == "environment"
          && linkedMissingPath.issues.first?.detail.contains("module search path") == true,
          "L: an absent child of an escaping symlink is still refused",
          linkedMissingPath.issues.first?.detail ?? "no issue")

    let externalPath = report(
        path: contained + ["/opt/homebrew/lib/python3.13/site-packages"],
        sysconfig: containedConfig)
    check(externalPath.issues.first?.code == "environment"
          && externalPath.issues.first?.detail.contains("module search path") == true,
          "L: an external sys.path entry is refused before imports",
          externalPath.issues.first?.detail ?? "no issue")

    var leakingConfig = containedConfig
    leakingConfig["include"] = "/usr/local/Cellar/python/include"
    let externalConfig = report(path: contained, sysconfig: leakingConfig)
    check(externalConfig.issues.first?.code == "environment"
          && externalConfig.issues.first?.detail.contains("configuration path") == true,
          "L: an external sysconfig path is refused before imports",
          externalConfig.issues.first?.detail ?? "no issue")

    let relativePath = report(path: contained + [""], sysconfig: containedConfig)
    check(relativePath.issues.first?.code == "environment"
          && relativePath.issues.first?.detail.contains("relative") == true,
          "L: the current-directory import entry is refused",
          relativePath.issues.first?.detail ?? "no issue")
}

// MARK: - M. Optional packaged real-upscale diagnostic

func nearestNeighbour4x(_ image: CIImage) -> CIImage? {
    guard let source = CIContext().createCGImage(image, from: image.extent) else { return nil }
    let width = Int(image.extent.width * 4), height = Int(image.extent.height * 4)
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                                      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)).rawValue) else {
        return nil
    }
    context.interpolationQuality = .none
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let output = context.makeImage() else { return nil }
    return CIImage(cgImage: output)
}

func testPackagedUpscaleDiagnosticContract() {
    print("\n[M] packaged real-upscale diagnostic validates its bounded inputs")
    check(try! PackagedUpscaleSelfTest.parse([]) == nil,
          "M: ordinary app launches do not request inference")

    var missingModel = false
    do {
        _ = try PackagedUpscaleSelfTest.parse(["--upscale-selftest", "--out", "/tmp/rs-out"])
    } catch {
        missingModel = true
    }
    check(missingModel, "M: an upscale self-test without a model is refused")

    var duplicateOutput = false
    do {
        _ = try PackagedUpscaleSelfTest.parse([
            "--upscale-selftest", "--model", "/tmp/swin2sr-x4",
            "--out", "/tmp/rs-out", "--out", "/tmp/other",
        ])
    } catch {
        duplicateOutput = true
    }
    check(duplicateOutput, "M: duplicate output arguments cannot redirect the artifact")

    let workerSocketSuffix = "/ai-worker-state/worker.sock"
    let probeSocketSuffix = "/ai-worker-state/probe/worker.sock"
    let socketCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    let workerOutputByteLimit = socketCapacity - 1 - workerSocketSuffix.utf8.count
    let probeOutputByteLimit = socketCapacity - 1 - probeSocketSuffix.utf8.count
    let outputByteLimit = min(workerOutputByteLimit, probeOutputByteLimit)
    // Measure the canonical temporary root, not its shorter symlink spelling.
    let temporaryRoot = ProcessIdentity.canonical("/tmp")
    func socketOutputPath(bytes: Int, multibyte: Bool) -> String {
        let prefix = temporaryRoot + "/m3-\(UUID().uuidString)-"
        // Foundation file URLs normalize this combining sequence exactly as
        // written. A precomposed é would expand from two UTF-8 bytes to three
        // when converted to a file URL, invalidating a raw-string byte count.
        let multibyteCharacter = "e\u{301}"
        var suffix = ""
        var remaining = bytes - prefix.utf8.count
        if multibyte {
            while remaining >= multibyteCharacter.utf8.count {
                suffix += multibyteCharacter
                remaining -= multibyteCharacter.utf8.count
            }
        }
        suffix += String(repeating: "o", count: remaining)
        return prefix + suffix
    }
    let modelPath = temporaryRoot + "/m3-model-\(UUID().uuidString)"
    var boundaryAccepted = false
    do {
        let options = try PackagedUpscaleSelfTest.parse([
            "--upscale-selftest", "--model", modelPath,
            "--out", socketOutputPath(bytes: outputByteLimit, multibyte: false),
        ])
        boundaryAccepted = options != nil
            && (options!.output.path + probeSocketSuffix).utf8.count == socketCapacity - 1
    } catch {
        boundaryAccepted = false
    }
    check(boundaryAccepted, "M: the longest valid UTF-8 worker socket path is accepted")

    var multibyteBoundaryAccepted = false
    do {
        multibyteBoundaryAccepted = try PackagedUpscaleSelfTest.parse([
            "--upscale-selftest", "--model", modelPath,
            "--out", socketOutputPath(bytes: outputByteLimit, multibyte: true),
        ]) != nil
    } catch {
        multibyteBoundaryAccepted = false
    }
    check(multibyteBoundaryAccepted, "M: socket admission measures UTF-8 bytes rather than characters")

    let probeOnlyTooLongPath = socketOutputPath(bytes: workerOutputByteLimit, multibyte: false)
    var probeLongPathRefused = false
    var probeLongPathMessage = ""
    do {
        _ = try PackagedUpscaleSelfTest.parse([
            "--upscale-selftest", "--model", modelPath, "--out", probeOnlyTooLongPath,
        ])
    } catch {
        probeLongPathRefused = true
        probeLongPathMessage = error.localizedDescription
    }
    check(probeLongPathRefused && probeLongPathMessage.contains("runtime probe socket path is too long"),
          "M: a valid final worker socket cannot hide an overlong runtime-probe socket",
          probeLongPathMessage)

    let tooLongPath = socketOutputPath(bytes: outputByteLimit + 1, multibyte: false)
    var longPathRefused = false
    var longPathMessage = ""
    do {
        _ = try PackagedUpscaleSelfTest.parse([
            "--upscale-selftest", "--model", modelPath, "--out", tooLongPath,
        ])
    } catch {
        longPathRefused = true
        longPathMessage = error.localizedDescription
    }
    check(longPathRefused && longPathMessage.contains("socket path is too long"),
          "M: an overlong UTF-8 worker socket path is refused during argument parsing",
          longPathMessage)

    let multibyteTooLongPath = socketOutputPath(bytes: outputByteLimit + 1, multibyte: true)
    var multibyteLongPathRefused = false
    do {
        _ = try PackagedUpscaleSelfTest.parse([
            "--upscale-selftest", "--model", modelPath, "--out", multibyteTooLongPath,
        ])
    } catch {
        multibyteLongPathRefused = true
    }
    check(multibyteLongPathRefused, "M: a multibyte path cannot hide an overlong socket in its character count")

    let tooLongOutput = URL(fileURLWithPath: tooLongPath)
    defer { try? FileManager.default.removeItem(at: tooLongOutput) }
    var runRefused = false
    var runMessage = ""
    do {
        try PackagedUpscaleSelfTest.run(.init(
            model: URL(fileURLWithPath: modelPath), output: tooLongOutput))
    } catch {
        runRefused = true
        runMessage = error.localizedDescription
    }
    check(runRefused && runMessage.contains("socket path is too long")
            && !FileManager.default.fileExists(atPath: tooLongPath),
          "M: socket preflight happens before output, source or model artifacts are created",
          runMessage)

    let probeOnlyTooLongOutput = URL(fileURLWithPath: probeOnlyTooLongPath)
    defer { try? FileManager.default.removeItem(at: probeOnlyTooLongOutput) }
    var probeRunRefused = false
    var probeRunMessage = ""
    do {
        try PackagedUpscaleSelfTest.run(.init(model: URL(fileURLWithPath: modelPath),
                                             output: probeOnlyTooLongOutput))
    } catch {
        probeRunRefused = true
        probeRunMessage = error.localizedDescription
    }
    check(probeRunRefused && probeRunMessage.contains("runtime probe socket path is too long")
            && !FileManager.default.fileExists(atPath: probeOnlyTooLongPath),
          "M: runtime-probe preflight also happens before any persistent artifact",
          probeRunMessage)

    func packagedReferenceBundle(_ name: String, layout: String) -> Bundle {
        let root = rootDirectory.appendingPathComponent(name, isDirectory: true)
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "app.retouchstudio.m3-resolver-test",
            "CFBundleExecutable": "RetouchStudio",
            "CFBundlePackageType": "APPL",
        ]
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let directory: URL
        let fileName: String
        switch layout {
        case "canonical":
            directory = resources.appendingPathComponent("Tests/Fixtures/upscale-m3", isDirectory: true)
            fileName = "manifest.json"
        case "legacy-directory":
            directory = resources.appendingPathComponent("upscale-m3", isDirectory: true)
            fileName = "manifest.json"
        default:
            directory = resources
            fileName = "upscale-m3-manifest.json"
        }
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data("{}".utf8).write(to: directory.appendingPathComponent(fileName))
        return Bundle(path: root.path)!
    }

    let canonicalBundle = packagedReferenceBundle("canonical-reference.app", layout: "canonical")
    let canonicalReference = try! PackagedUpscaleSelfTest.resolvePackagedReferenceDirectory(in: canonicalBundle)
    if let resourceURL = canonicalBundle.resourceURL {
        check(canonicalReference.standardizedFileURL
                == resourceURL.appendingPathComponent("Tests/Fixtures/upscale-m3").standardizedFileURL,
              "M: production resolves only the canonical bundle fixture")
    } else {
        check(false, "M: the canonical bundle fixture has a resource directory")
    }

    for layout in ["legacy-directory", "legacy-manifest"] {
        let bundle = packagedReferenceBundle("\(layout).app", layout: layout)
        var refused = false
        do {
            _ = try PackagedUpscaleSelfTest.resolvePackagedReferenceDirectory(in: bundle)
        } catch {
            refused = true
        }
        check(refused, "M: production refuses the noncanonical \(layout) fixture fallback")
    }

    let realParent = rootDirectory.appendingPathComponent("real-parent", isDirectory: true)
    let realModel = realParent.appendingPathComponent("swin2sr-x4", isDirectory: true)
    try! FileManager.default.createDirectory(at: realModel, withIntermediateDirectories: true)
    let aliasParent = rootDirectory.appendingPathComponent("alias-parent", isDirectory: true)
    try! FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
    var aliasedOverlapRefused = false
    do {
        _ = try PackagedUpscaleSelfTest.parse([
            "--upscale-selftest",
            "--model", aliasParent.appendingPathComponent("swin2sr-x4").path,
            "--out", realModel.appendingPathComponent("output").path,
        ])
    } catch {
        aliasedOverlapRefused = true
    }
    check(aliasedOverlapRefused, "M: a symlink alias cannot bypass model/output separation")

    let testsRoot = ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"]
        ?? FileManager.default.currentDirectoryPath
    let catalog = try! ModelCatalog.load(url: URL(fileURLWithPath: testsRoot)
        .appendingPathComponent("Resources/model-catalog.json"))
    guard let entry = catalog.entry(id: "swin2sr-x4") else {
        check(false, "M: the bundled catalog contains the exact Swin2SR entry")
        return
    }
    check(entry.version == "1.0.0" && entry.format == "pytorch",
          "M: the trusted Swin2SR entry fixes version and format")
    check(entry.sha256 == "e0da6778bbcffbb26d61fda450648998e22f66d5867924706fee6d929aa50cdf",
          "M: the trusted Swin2SR entry fixes the aggregate checkpoint digest")
    let trustedFiles = Dictionary(uniqueKeysWithValues: entry.files.map { ($0.path, $0) })
    check(Set(trustedFiles.keys) == Set([
        "config.json", "preprocessor_config.json", "pytorch_model.bin",
    ]), "M: the trusted Swin2SR entry fixes the exact three-file checkpoint")
    check(trustedFiles["config.json"]?.sizeBytes == 772
          && trustedFiles["config.json"]?.sha256 == "1e986fb6d0b6de32bae01a6ccd756e5d8ae1525dcb52f7ee5b2dc7f6132d6365",
          "M: the trusted config pin is exact")
    check(trustedFiles["preprocessor_config.json"]?.sizeBytes == 152
          && trustedFiles["preprocessor_config.json"]?.sha256 == "cbc36266fcc93d5bc1e9ca69bcc648ae9d268918ad14cd3507216740f129cc4d",
          "M: the trusted preprocessor pin is exact")
    check(trustedFiles["pytorch_model.bin"]?.sizeBytes == 48_460_141
          && trustedFiles["pytorch_model.bin"]?.sha256 == "4a5f52a20932085557ed115f87c0ee8385e12f2719108c0dfd38c64aedea4710",
          "M: the trusted weights pin is exact")

    let modelRoot = rootDirectory.appendingPathComponent("swin2sr-x4", isDirectory: true)
    let version = modelRoot.appendingPathComponent("1.0.0", isDirectory: true)
    try? FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
    let weights = Data(repeating: 0x5a, count: 128)
    try? weights.write(to: version.appendingPathComponent("pytorch_model.bin"))
    try? Data("{}".utf8).write(to: version.appendingPathComponent("config.json"))
    try? Data("{}".utf8).write(to: version.appendingPathComponent("preprocessor_config.json"))
    let catalogDigest = String(repeating: "a", count: 64)
    let manifest: [String: Any] = [
        "schema": "retouchstudio.model-manifest/1",
        "modelId": "swin2sr-x4", "version": "1.0.0",
        "manifestSha256": catalogDigest,
        "files": [
            ["path": "pytorch_model.bin", "sizeBytes": weights.count,
             "sha256": try! AIRuntime.sha256(of: version.appendingPathComponent("pytorch_model.bin"))],
            ["path": "config.json", "sizeBytes": 2,
             "sha256": try! AIRuntime.sha256(of: version.appendingPathComponent("config.json"))],
            ["path": "preprocessor_config.json", "sizeBytes": 2,
             "sha256": try! AIRuntime.sha256(of: version.appendingPathComponent("preprocessor_config.json"))],
        ],
    ]
    let manifestData = try! JSONSerialization.data(withJSONObject: manifest)
    try! manifestData.write(to: version.appendingPathComponent("manifest.json"))
    let active: [String: Any] = [
        "schema": "retouchstudio.model-active/1", "modelId": "swin2sr-x4",
        "version": "1.0.0", "manifestSha256": catalogDigest,
    ]
    let activeData = try! JSONSerialization.data(withJSONObject: active)
    try! activeData.write(to: modelRoot.appendingPathComponent("active.json"))

    func checkpointRefused(_ label: String, manifest: [String: Any],
                           active: [String: Any], destination: String) {
        let manifestBytes = try! JSONSerialization.data(withJSONObject: manifest)
        let activeBytes = try! JSONSerialization.data(withJSONObject: active)
        try! manifestBytes.write(to: version.appendingPathComponent("manifest.json"))
        try! activeBytes.write(to: modelRoot.appendingPathComponent("active.json"))
        var refused = false
        do {
            try PackagedUpscaleSelfTest.copyModel(
                from: modelRoot,
                to: rootDirectory.appendingPathComponent(destination, isDirectory: true),
                entry: entry)
        } catch {
            refused = true
        }
        check(refused, "M: \(label)")
    }

    checkpointRefused(
        "a self-consistent fake checkpoint cannot stand in for the trusted catalog",
        manifest: manifest, active: active, destination: "fake-checkpoint-copy")

    var wrongDigestManifest = manifest
    wrongDigestManifest["manifestSha256"] = entry.sha256 ?? ""
    let wrongDigestActive: [String: Any] = [
        "schema": "retouchstudio.model-active/1", "modelId": "swin2sr-x4",
        "version": "1.0.0", "manifestSha256": entry.sha256 ?? "",
    ]
    var wrongHashFiles = manifest["files"] as! [[String: Any]]
    wrongHashFiles[0]["sha256"] = String(repeating: "f", count: 64)
    var wrongHashManifest = wrongDigestManifest
    wrongHashManifest["files"] = wrongHashFiles
    checkpointRefused(
        "a manifest file hash cannot replace the trusted catalog pin",
        manifest: wrongHashManifest, active: wrongDigestActive,
        destination: "wrong-file-hash-copy")

    var wrongSizeFiles = manifest["files"] as! [[String: Any]]
    wrongSizeFiles[0]["sizeBytes"] = weights.count + 1
    var wrongSizeManifest = wrongDigestManifest
    wrongSizeManifest["files"] = wrongSizeFiles
    checkpointRefused(
        "a manifest file size cannot replace the trusted catalog pin",
        manifest: wrongSizeManifest, active: wrongDigestActive,
        destination: "wrong-file-size-copy")

    var duplicateFiles = manifest["files"] as! [[String: Any]]
    duplicateFiles[2] = duplicateFiles[0]
    var duplicateManifest = wrongDigestManifest
    duplicateManifest["files"] = duplicateFiles
    checkpointRefused(
        "a duplicate file cannot pad the exact three-file checkpoint",
        manifest: duplicateManifest, active: wrongDigestActive,
        destination: "duplicate-file-copy")

    var missingManifest = wrongDigestManifest
    missingManifest["files"] = Array((manifest["files"] as! [[String: Any]]).prefix(2))
    checkpointRefused(
        "a missing file cannot be hidden by a matching aggregate digest",
        manifest: missingManifest, active: wrongDigestActive,
        destination: "missing-file-copy")

    try! manifestData.write(to: version.appendingPathComponent("manifest.json"))
    try! activeData.write(to: modelRoot.appendingPathComponent("active.json"))

    let wrongActive: [String: Any] = [
        "schema": "retouchstudio.model-active/1", "modelId": "migan",
        "version": "1.0.0", "manifestSha256": active["manifestSha256"] ?? "",
    ]
    try! JSONSerialization.data(withJSONObject: wrongActive).write(
        to: modelRoot.appendingPathComponent("active.json"))
    var wrongModelRefused = false
    do {
        try PackagedUpscaleSelfTest.copyModel(
            from: modelRoot,
            to: rootDirectory.appendingPathComponent("wrong-model-copy", isDirectory: true),
            entry: entry)
    } catch {
        wrongModelRefused = true
    }
    check(wrongModelRefused, "M: another active model cannot stand in for Swin2SR")

    let validActiveData = try! JSONSerialization.data(withJSONObject: active)
    try! validActiveData.write(to: modelRoot.appendingPathComponent("active.json"))
    let mismatchedActive: [String: Any] = [
        "schema": "retouchstudio.model-active/1", "modelId": "swin2sr-x4",
        "version": "1.0.0", "manifestSha256": String(repeating: "b", count: 64),
    ]
    try! JSONSerialization.data(withJSONObject: mismatchedActive).write(
        to: modelRoot.appendingPathComponent("active.json"))
    var digestMismatchRefused = false
    do {
        try PackagedUpscaleSelfTest.copyModel(
            from: modelRoot,
            to: rootDirectory.appendingPathComponent("digest-mismatch-copy", isDirectory: true),
            entry: entry)
    } catch {
        digestMismatchRefused = true
    }
    check(digestMismatchRefused, "M: an active pointer must match the manifest catalog digest")

    try! validActiveData.write(to: modelRoot.appendingPathComponent("active.json"))
    let externalActive = rootDirectory.appendingPathComponent("external-active.json")
    try! validActiveData.write(to: externalActive)
    try! FileManager.default.removeItem(at: modelRoot.appendingPathComponent("active.json"))
    try! FileManager.default.createSymbolicLink(
        at: modelRoot.appendingPathComponent("active.json"), withDestinationURL: externalActive)
    var linkedActiveRefused = false
    do {
        try PackagedUpscaleSelfTest.copyModel(
            from: modelRoot,
            to: rootDirectory.appendingPathComponent("linked-active-copy", isDirectory: true),
            entry: entry)
    } catch {
        linkedActiveRefused = true
    }
    check(linkedActiveRefused, "M: a symlinked active pointer is refused")
    try! FileManager.default.removeItem(at: modelRoot.appendingPathComponent("active.json"))
    try! validActiveData.write(to: modelRoot.appendingPathComponent("active.json"))

    let externalManifest = rootDirectory.appendingPathComponent("external-manifest.json")
    try! manifestData.write(to: externalManifest)
    try! FileManager.default.removeItem(at: version.appendingPathComponent("manifest.json"))
    try! FileManager.default.createSymbolicLink(
        at: version.appendingPathComponent("manifest.json"), withDestinationURL: externalManifest)
    var linkedManifestRefused = false
    do {
        try PackagedUpscaleSelfTest.copyModel(
            from: modelRoot,
            to: rootDirectory.appendingPathComponent("linked-manifest-copy", isDirectory: true),
            entry: entry)
    } catch {
        linkedManifestRefused = true
    }
    check(linkedManifestRefused, "M: a symlinked model manifest is refused")
    try! FileManager.default.removeItem(at: version.appendingPathComponent("manifest.json"))
    try! manifestData.write(to: version.appendingPathComponent("manifest.json"))

    // Reach the destination-creation branch with a catalog-shaped manifest,
    // then prove EEXIST cannot turn into deletion of somebody else's tree.
    let existingDestination = rootDirectory.appendingPathComponent("existing-model-copy",
                                                                    isDirectory: true)
    try! FileManager.default.createDirectory(at: existingDestination,
                                             withIntermediateDirectories: false)
    let sentinel = existingDestination.appendingPathComponent("keep")
    try! Data("owner-state".utf8).write(to: sentinel)
    let trustedManifest: [String: Any] = [
        "schema": "retouchstudio.model-manifest/1",
        "modelId": "swin2sr-x4", "version": "1.0.0",
        "manifestSha256": entry.sha256 ?? "",
        "files": entry.files.map { file in
            ["path": file.path, "sizeBytes": file.sizeBytes ?? 0,
             "sha256": file.sha256 ?? ""]
        },
    ]
    try! JSONSerialization.data(withJSONObject: trustedManifest).write(
        to: version.appendingPathComponent("manifest.json"))
    try! JSONSerialization.data(withJSONObject: [
        "schema": "retouchstudio.model-active/1", "modelId": "swin2sr-x4",
        "version": "1.0.0", "manifestSha256": entry.sha256 ?? "",
    ]).write(to: modelRoot.appendingPathComponent("active.json"))
    var existingRefused = false
    do {
        try PackagedUpscaleSelfTest.copyModel(from: modelRoot, to: existingDestination,
                                              entry: entry)
    } catch {
        existingRefused = true
    }
    check(existingRefused, "M: an existing model destination is refused")
    check((try? String(decoding: Data(contentsOf: sentinel), as: UTF8.self)) == "owner-state",
          "M: refused checkpoint admission never deletes a pre-existing destination")

    let source = PackagedUpscaleSelfTest.syntheticImage()
    guard let nearest = nearestNeighbour4x(source) else {
        check(false, "M: the controlled nearest-neighbour fixture can be rendered")
        return
    }
    let output = PackagedUpscaleSelfTest.validateOutput(
        nearest, inputSize: source.extent.size, source: source)
    check(output?.contains("nearest-neighbour") == true,
          "M: a controlled nearest-neighbour 4x output is refused as model proof",
          output ?? "no problem reported")
    let solid = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 192))
    check(PackagedUpscaleSelfTest.validateOutput(solid, inputSize: source.extent.size) != nil,
          "M: a constant output cannot stand in for model inference")
}

func writePackagedDiagnosticPNG(_ image: CIImage, to url: URL) throws {
    guard let cgImage = CIContext().createCGImage(image, from: image.extent),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "PackagedDiagnosticTest", code: 1)
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PackagedDiagnosticTest", code: 2)
    }
}

func testPackagedUpscaleInputDigestIsSubmittedRGB8() throws {
    print("\n[O] packaged upscale input provenance hashes the submitted RGB8 pixels")
    let rgba = Data([10, 20, 30, 255, 40, 50, 60, 255])
    guard let provider = CGDataProvider(data: rgba as CFData),
          let image = CGImage(width: 2, height: 1, bitsPerComponent: 8,
                              bitsPerPixel: 32, bytesPerRow: 8,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: [.byteOrder32Big,
                                           CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                              provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent) else {
        check(false, "O: the literal RGB fixture can be created")
        return
    }
    let url = rootDirectory.appendingPathComponent("literal-rgb.png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        check(false, "O: the literal RGB fixture can be written")
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    check(CGImageDestinationFinalize(destination), "O: the literal RGB fixture can be written")
    let digest = try ExportService.rgb8SHA256(of: url)
    check(digest == "6e6db0c1e9357a0f1543a26d526d8548ae9867a4a64de41c2752e13f77bcfa13",
          "O: the digest is SHA-256 of row-major RGB8, not PNG bytes",
          digest)

    let previousWorkingRoot = AIWorker.workingDirectoryOverride
    AIWorker.workingDirectoryOverride = rootDirectory.appendingPathComponent("o-working",
                                                                             isDirectory: true)
    defer { AIWorker.workingDirectoryOverride = previousWorkingRoot }
    let submitted = try AIWorker.writeUpscaleSource(CIImage(cgImage: image))
    let submittedDigest = try ExportService.rgb8SHA256(of: submitted)
    check(submittedDigest == "6e6db0c1e9357a0f1543a26d526d8548ae9867a4a64de41c2752e13f77bcfa13",
          "O: the real production submission serializer preserves the literal RGB8 identity",
          submittedDigest)

    func writeFixture(_ name: String, bits: Int, bytes: [UInt8],
                      alpha: CGImageAlphaInfo) throws -> URL {
        let url = rootDirectory.appendingPathComponent(name)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 2, height: 1,
                                  bitsPerComponent: bits, bitsPerPixel: bits * 4,
                                  bytesPerRow: 2 * (bits / 8) * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: [bits == 16 ? .byteOrder16Big : .byteOrder32Big,
                                               CGBitmapInfo(rawValue: alpha.rawValue)],
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PackagedDiagnosticTest", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PackagedDiagnosticTest", code: 4)
        }
        return url
    }

    // Pillow's `convert("RGB")` drops alpha; it does not composite it. These
    // literal digests were measured independently from the resulting RGB rows.
    let alphaURL = try writeFixture(
        "literal-alpha8.png", bits: 8,
        bytes: [10, 20, 30, 0, 40, 50, 60, 128], alpha: .last)
    let alphaDigest = try ExportService.rgb8SHA256(of: alphaURL)
    check(alphaDigest == "6e6db0c1e9357a0f1543a26d526d8548ae9867a4a64de41c2752e13f77bcfa13",
          "O: transparent and partial-alpha samples are dropped, never composited",
          alphaDigest)

    let deepURL = try writeFixture(
        "literal-alpha16.png", bits: 16,
        bytes: [0x12, 0xff, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
                0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x12,
                0x12, 0x00, 0x34, 0x00, 0x78, 0x00, 0xbc, 0x00,
                0x23, 0xff, 0x67, 0xff, 0xab, 0xff, 0xef, 0xff],
        alpha: .last)
    let deepDigest = try ExportService.rgb8SHA256(of: deepURL)
    check(deepDigest == "d0e848b9e26d4e49846b3a8e30688d39399419181dfa0aa0bec5c0bb5c4e59cf",
          "O: RGBA16 input keeps Pillow's high-byte RGB8 conversion exactly",
          deepDigest)
}

func testPackagedUpscaleTrustedProvenanceAndFinalArtifact() throws {
    print("\n[N] packaged upscale adoption trusts submission context and final bytes")
    let testsRoot = ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"]
        ?? FileManager.default.currentDirectoryPath
    let catalog = try! ModelCatalog.load(url: URL(fileURLWithPath: testsRoot)
        .appendingPathComponent("Resources/model-catalog.json"))
    let entry = catalog.entry(id: "swin2sr-x4")!
    let source = PackagedUpscaleSelfTest.syntheticImage()
    let sourceSize = source.extent.size
    let blurred = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
        .cropped(to: source.extent)
    guard let artifactImage = nearestNeighbour4x(blurred) else {
        check(false, "N: the controlled non-nearest artifact can be rendered")
        return
    }
    let submittedJob = "submitted-job"
    let submittedInput = String(repeating: "1", count: 64)

    func makePair(_ name: String, image: CIImage,
                  mutate: (inout [String: Any]) -> Void = { _ in }) throws
        -> (image: CIImage, artifact: URL, provenance: URL) {
        let folder = rootDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let artifact = folder.appendingPathComponent("result.png")
        try writePackagedDiagnosticPNG(image, to: artifact)
        var record: [String: Any] = [
            "schema": AIProvenance.schema,
            "capabilityId": AICapabilityReport.upscale4x,
            "jobId": submittedJob,
            "state": "succeeded",
            "model": [
                "id": entry.id, "version": entry.version, "format": entry.format,
                "provider": "mps",
                "files": entry.files.map { file in
                    ["path": file.path, "sha256": file.sha256 ?? ""]
                },
            ],
            "parameters": ["scale": 4],
            "input": [
                "sha256": submittedInput,
                "width": Int(sourceSize.width), "height": Int(sourceSize.height),
                "bitDepth": 8, "channels": 3,
            ],
            "output": [
                "sha256": try AIRuntime.sha256(of: artifact),
                "width": Int(image.extent.width), "height": Int(image.extent.height),
                "bitDepth": 8, "channels": 3,
            ],
        ]
        mutate(&record)
        let provenance = artifact.deletingLastPathComponent()
            .appendingPathComponent(artifact.lastPathComponent + AIProvenance.sidecarSuffix)
        try JSONSerialization.data(withJSONObject: record).write(to: provenance)
        return (image, artifact, provenance)
    }

    func expectRefused(_ label: String,
                       mutate: (inout [String: Any]) -> Void) throws {
        let pair = try makePair("refused-\(UUID().uuidString)", image: artifactImage,
                                mutate: mutate)
        let output = rootDirectory.appendingPathComponent("adopt-\(UUID().uuidString)",
                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let result = ExportService.UpscaleArtifact(
            image: pair.image, artifact: pair.artifact, provenance: pair.provenance,
            jobID: submittedJob, inputSHA256: submittedInput, model: entry)
        var refused = false
        do {
            try PackagedUpscaleSelfTest.adopt(result, sourceSize: sourceSize,
                                              outputDirectory: output)
        } catch {
            refused = true
        }
        check(refused, "N: \(label)")
    }

    do {
        let pair = try makePair("accepted", image: artifactImage)
        let output = rootDirectory.appendingPathComponent("adopt-accepted", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let result = ExportService.UpscaleArtifact(
            image: pair.image, artifact: pair.artifact, provenance: pair.provenance,
            jobID: submittedJob, inputSHA256: submittedInput, model: entry)
        try PackagedUpscaleSelfTest.adopt(result, sourceSize: sourceSize,
                                          outputDirectory: output)
        check(FileManager.default.fileExists(
                atPath: output.appendingPathComponent("upscaled.png").path),
              "N: a bound artifact and sidecar are adopted together")
    } catch {
        check(false, "N: a bound artifact and sidecar are adopted together", "\(error)")
    }

    try expectRefused("a forged job id cannot redirect the submitted result") { record in
        record["jobId"] = "forged-job"
    }
    try expectRefused("a forged input digest cannot redirect the submitted pixels") { record in
        var input = record["input"] as! [String: Any]
        input["sha256"] = String(repeating: "2", count: 64)
        record["input"] = input
    }
    try expectRefused("a forged model file pin cannot stand in for the catalog") { record in
        var model = record["model"] as! [String: Any]
        var files = model["files"] as! [[String: Any]]
        files[0]["sha256"] = String(repeating: "3", count: 64)
        model["files"] = files
        record["model"] = model
    }
    try expectRefused("a missing model file list cannot borrow catalog trust") { record in
        var model = record["model"] as! [String: Any]
        model.removeValue(forKey: "files")
        record["model"] = model
    }
    try expectRefused("a forged scale cannot redirect the 4x capability") { record in
        record["parameters"] = ["scale": 3]
    }

    do {
        let expected = CGRect(x: 0, y: 0, width: sourceSize.width * 4, height: sourceSize.height * 4)
        let bicubic = source.applyingFilter(
            "CIBicubicScaleTransform",
            parameters: [kCIInputScaleKey: 4, kCIInputAspectRatioKey: 1])
            .cropped(to: expected)
        let pair = try makePair("final-bicubic-substitution", image: bicubic)
        let output = rootDirectory.appendingPathComponent("adopt-final-bicubic-substitution",
                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let result = ExportService.UpscaleArtifact(
            image: artifactImage, artifact: pair.artifact, provenance: pair.provenance,
            jobID: submittedJob, inputSHA256: submittedInput, model: entry)
        var refused = false
        do {
            try PackagedUpscaleSelfTest.adopt(result, sourceSize: sourceSize,
                                              outputDirectory: output)
        } catch {
            refused = true
        }
        check(refused, "N: a bicubic final copy with a self-consistent sidecar is still refused")
    } catch {
        check(false, "N: a bicubic final copy with a self-consistent sidecar is still refused", "\(error)")
    }
}

func testPackagedDiagnosticStateStaysUnderOutput() throws {
    print("\n[P] packaged diagnostic working, cleanup and probe state stay under --out")
    let manager = FileManager.default
    let state = rootDirectory.appendingPathComponent("diagnostic/ai-worker-state", isDirectory: true)
    let working = state.appendingPathComponent("working", isDirectory: true)
    let globalRoot = manager.temporaryDirectory
        .appendingPathComponent("RetouchStudioAI", isDirectory: true)
    let globalMarker = globalRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: globalMarker, withIntermediateDirectories: true)
    try Data("owner-state".utf8).write(to: globalMarker.appendingPathComponent("keep"))
    try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200_000)],
                              ofItemAtPath: globalMarker.path)
    let globalBefore = Set((try? manager.contentsOfDirectory(atPath: globalRoot.path)) ?? [])
    defer {
        AIWorker.workingDirectoryOverride = nil
        try? manager.removeItem(at: globalMarker)
        try? manager.removeItem(at: rootDirectory.appendingPathComponent("diagnostic", isDirectory: true))
    }

    AIWorker.workingDirectoryOverride = working
    check(AIWorker.workingDirectory.standardizedFileURL == working.standardizedFileURL,
          "P: the diagnostic worker uses its output-owned working root")
    let source = try AIWorker.writeUpscaleSource(PackagedUpscaleSelfTest.syntheticImage())
    check(source.path.hasPrefix(state.path + "/"),
          "P: the real upscale submission source is written under --out/ai-worker-state")

    let stale = working.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: stale, withIntermediateDirectories: false)
    try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200_000)],
                              ofItemAtPath: stale.path)
    AIWorker.cleanStaleWorkingCopies()
    check(!manager.fileExists(atPath: stale.path),
          "P: cleanup is scoped to the diagnostic working root")
    check(manager.fileExists(atPath: globalMarker.path),
          "P: diagnostic cleanup never sweeps the normal global temporary root")
    let globalAfter = Set((try? manager.contentsOfDirectory(atPath: globalRoot.path)) ?? [])
    check(globalAfter == globalBefore,
          "P: diagnostic execution creates no sibling state in the global root",
          globalAfter.sorted().joined(separator: ","))

    let probe = AIRuntimeValidation.scratchDirectory(stateRoot: state, prefix: "probe")
    check(probe.deletingLastPathComponent().standardizedFileURL == state.standardizedFileURL,
          "P: validation probe and command scratch directories stay under --out/ai-worker-state")
}

func testPackagedAdoptionRefusesLinkedInputs() throws {
    print("\n[Q] packaged adoption refuses linked artifact and sidecar inputs")
    let manager = FileManager.default
    let testsRoot = ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"]
        ?? FileManager.default.currentDirectoryPath
    let catalog = try! ModelCatalog.load(url: URL(fileURLWithPath: testsRoot)
        .appendingPathComponent("Resources/model-catalog.json"))
    let entry = catalog.entry(id: "swin2sr-x4")!
    let source = PackagedUpscaleSelfTest.syntheticImage()
    let image = nearestNeighbour4x(source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: source.extent))!
    let real = rootDirectory.appendingPathComponent("q-real", isDirectory: true)
    try manager.createDirectory(at: real, withIntermediateDirectories: false)
    let artifact = real.appendingPathComponent("result.png")
    try writePackagedDiagnosticPNG(image, to: artifact)
    let record: [String: Any] = [
        "schema": AIProvenance.schema,
        "capabilityId": AICapabilityReport.upscale4x,
        "jobId": "q-job", "state": "succeeded",
        "model": ["id": entry.id, "version": entry.version, "format": entry.format,
                  "files": entry.files.map { ["path": $0.path, "sha256": $0.sha256 ?? ""] }],
        "parameters": ["scale": 4],
        "input": ["sha256": String(repeating: "1", count: 64)],
        "output": ["sha256": try AIRuntime.sha256(of: artifact),
                   "width": Int(image.extent.width), "height": Int(image.extent.height)],
    ]
    let sidecarData = try JSONSerialization.data(withJSONObject: record)
    let sidecar = real.appendingPathComponent("result.png" + AIProvenance.sidecarSuffix)
    try sidecarData.write(to: sidecar)

    func expectRefused(_ label: String, artifact: URL, provenance: URL,
                       outputName: String, prepare: (URL) throws -> Void = { _ in }) throws {
        let output = rootDirectory.appendingPathComponent(outputName, isDirectory: true)
        try manager.createDirectory(at: output, withIntermediateDirectories: false)
        try prepare(output)
        let result = ExportService.UpscaleArtifact(
            image: image, artifact: artifact, provenance: provenance,
            jobID: "q-job", inputSHA256: String(repeating: "1", count: 64), model: entry)
        var refused = false
        do {
            try PackagedUpscaleSelfTest.adopt(result, sourceSize: source.extent.size,
                                              outputDirectory: output)
        } catch {
            refused = true
        }
        check(refused, "Q: \(label)")
    }

    let artifactLinkFolder = rootDirectory.appendingPathComponent("q-artifact-link", isDirectory: true)
    try manager.createDirectory(at: artifactLinkFolder, withIntermediateDirectories: false)
    let artifactLink = artifactLinkFolder.appendingPathComponent("result.png")
    try manager.createSymbolicLink(at: artifactLink, withDestinationURL: artifact)
    let artifactLinkSidecar = artifactLinkFolder.appendingPathComponent("result.png" + AIProvenance.sidecarSuffix)
    try sidecarData.write(to: artifactLinkSidecar)
    try expectRefused("a symlinked source artifact is not adopted", artifact: artifactLink,
                      provenance: artifactLinkSidecar, outputName: "q-out-artifact-link")

    let sidecarLinkFolder = rootDirectory.appendingPathComponent("q-sidecar-link", isDirectory: true)
    try manager.createDirectory(at: sidecarLinkFolder, withIntermediateDirectories: false)
    let sidecarLinkArtifact = sidecarLinkFolder.appendingPathComponent("result.png")
    try manager.copyItem(at: artifact, to: sidecarLinkArtifact)
    let sidecarLink = sidecarLinkFolder.appendingPathComponent("result.png" + AIProvenance.sidecarSuffix)
    try manager.createSymbolicLink(at: sidecarLink, withDestinationURL: sidecar)
    try expectRefused("a symlinked source sidecar is not adopted", artifact: sidecarLinkArtifact,
                      provenance: sidecarLink, outputName: "q-out-sidecar-link")

    let sentinel = rootDirectory.appendingPathComponent("q-sentinel", isDirectory: true)
    try Data("untouched".utf8).write(to: sentinel)
    try expectRefused("an existing output symlink cannot redirect adoption", artifact: artifact,
                      provenance: sidecar, outputName: "q-out-linked-destination") { output in
        try manager.createSymbolicLink(at: output.appendingPathComponent("upscaled.png"),
                                       withDestinationURL: sentinel)
    }
    check(try String(decoding: Data(contentsOf: sentinel), as: UTF8.self) == "untouched",
          "Q: a refused output link leaves its target untouched")
}

// MARK: - R. Independent provider-specific M3 reference

func m3FixtureDirectory() -> URL {
    let testsRoot = ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"]
        ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: testsRoot)
        .appendingPathComponent("Tests/Fixtures/upscale-m3", isDirectory: true)
}

func m3Image(rgb: Data, width: Int = 256, height: Int = 192) throws -> CIImage {
    guard rgb.count == width * height * 3 else {
        throw NSError(domain: "M3ReferenceTest", code: 1)
    }
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    rgb.withUnsafeBytes { raw in
        let bytes = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = bytes[pixel * 3]
            rgba[pixel * 4 + 1] = bytes[pixel * 3 + 1]
            rgba[pixel * 4 + 2] = bytes[pixel * 3 + 2]
        }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                              bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: [.byteOrder32Big,
                                           CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                              provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent) else {
        throw NSError(domain: "M3ReferenceTest", code: 2)
    }
    return CIImage(cgImage: image)
}

func testPackagedUpscaleIndependentReference() throws {
    print("\n[R] packaged upscale adoption matches the independent provider-specific RGB8 reference")
    let testsRoot = ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"]
        ?? FileManager.default.currentDirectoryPath
    let catalog = try! ModelCatalog.load(url: URL(fileURLWithPath: testsRoot)
        .appendingPathComponent("Resources/model-catalog.json"))
    let entry = catalog.entry(id: "swin2sr-x4")!
    let fixtures = m3FixtureDirectory()
    let source = PackagedUpscaleSelfTest.syntheticImage()
    let sourceSize = source.extent.size
    let sourceDigest = "ee2b9d831fe93d75e157f9507861c4b8dc6ec4ec85a75dac300cf0e00cbde75f"
    let submittedJob = "m3-reference-job"
    let mpsBytes = try Data(contentsOf: fixtures.appendingPathComponent("reference.mps.rgb"))
    let cpuBytes = try Data(contentsOf: fixtures.appendingPathComponent("reference.cpu.rgb"))
    let bicubicBytes = try Data(contentsOf: fixtures.appendingPathComponent("bicubic.rgb"))
    let mpsImage = try m3Image(rgb: mpsBytes)
    let cpuImage = try m3Image(rgb: cpuBytes)
    let bicubicImage = try m3Image(rgb: bicubicBytes)

    check(PackagedUpscaleSelfTest.inferenceProvider(from: ["provider": "mps", "device": "mps"]) == "mps",
          "R: the worker result's agreeing MPS provider is observed")
    check(PackagedUpscaleSelfTest.inferenceProvider(from: ["provider": "cpu", "device": "cpu"]) == "cpu",
          "R: the worker result's agreeing CPU provider is observed")
    check(PackagedUpscaleSelfTest.inferenceProvider(from: ["provider": "mps"]) == nil,
          "R: a missing device cannot establish the inference provider")
    check(PackagedUpscaleSelfTest.inferenceProvider(from: ["provider": "mps", "device": "cpu"]) == nil,
          "R: disagreeing provider fields fail closed")
    check(PackagedUpscaleSelfTest.inferenceProvider(from: ["provider": "metal", "device": "metal"]) == nil,
          "R: an unknown provider cannot borrow a reference")

    func makePair(_ name: String, image: CIImage, sidecarProvider: String?,
                  mutate: (inout [String: Any]) -> Void = { _ in }) throws
        -> (image: CIImage, artifact: URL, provenance: URL) {
        let folder = rootDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let artifact = folder.appendingPathComponent("result.png")
        try writePackagedDiagnosticPNG(image, to: artifact)
        var model: [String: Any] = [
            "id": entry.id, "version": entry.version, "format": entry.format,
            "files": entry.files.map { ["path": $0.path, "sha256": $0.sha256 ?? ""] },
        ]
        if let sidecarProvider { model["provider"] = sidecarProvider }
        var record: [String: Any] = [
            "schema": AIProvenance.schema,
            "capabilityId": AICapabilityReport.upscale4x,
            "jobId": submittedJob,
            "state": "succeeded",
            "model": model,
            "parameters": ["scale": 4],
            "input": [
                "sha256": sourceDigest,
                "width": Int(sourceSize.width), "height": Int(sourceSize.height),
                "bitDepth": 8, "channels": 3,
            ],
            "output": [
                "sha256": try AIRuntime.sha256(of: artifact),
                "width": Int(image.extent.width), "height": Int(image.extent.height),
                "bitDepth": 8, "channels": 3,
            ],
        ]
        mutate(&record)
        let provenance = folder.appendingPathComponent("result.png" + AIProvenance.sidecarSuffix)
        try JSONSerialization.data(withJSONObject: record).write(to: provenance)
        return (image, artifact, provenance)
    }

    func adoptPair(_ name: String, image: CIImage, provider: String?,
                   sidecarProvider: String?, referenceDirectory: URL? = nil) throws -> Bool {
        let pair = try makePair(name, image: image, sidecarProvider: sidecarProvider)
        let output = rootDirectory.appendingPathComponent("adopt-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let result = ExportService.UpscaleArtifact(
            image: pair.image, artifact: pair.artifact, provenance: pair.provenance,
            jobID: submittedJob, inputSHA256: sourceDigest, model: entry,
            provider: provider)
        do {
            try PackagedUpscaleSelfTest.adopt(result, sourceSize: sourceSize,
                                              outputDirectory: output,
                                              referenceDirectory: referenceDirectory ?? fixtures)
            return true
        } catch {
            return false
        }
    }

    func copyReferences(_ name: String) throws -> URL {
        let destination = rootDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for item in try FileManager.default.contentsOfDirectory(at: fixtures,
                                                                includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: item,
                                             to: destination.appendingPathComponent(item.lastPathComponent))
        }
        return destination
    }

    func mutateManifest(in directory: URL,
                        _ mutate: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        mutate(&manifest)
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    check(try adoptPair("r-mps", image: mpsImage, provider: "mps", sidecarProvider: "mps"),
          "R: the exact MPS reference is adopted for an MPS result")
    check(try adoptPair("r-cpu", image: cpuImage, provider: "cpu", sidecarProvider: "cpu"),
          "R: the exact CPU reference is adopted for a CPU result")
    check(!(try adoptPair("r-wrong-provider", image: cpuImage, provider: "mps", sidecarProvider: "mps")),
          "R: the CPU reference cannot stand in for an MPS result")
    check(!(try adoptPair("r-bicubic", image: bicubicImage, provider: "mps", sidecarProvider: "mps")),
          "R: the independent bicubic control cannot stand in for model inference")
    check(!(try adoptPair("r-forged-sidecar", image: mpsImage, provider: "mps", sidecarProvider: "cpu")),
          "R: a self-consistent sidecar cannot forge the inference provider")
    check(!(try adoptPair("r-unknown-provider", image: mpsImage, provider: nil, sidecarProvider: "mps")),
          "R: an unobservable inference provider fails closed")

    let blurred = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
        .cropped(to: source.extent)
    let wrongReference = nearestNeighbour4x(blurred)!
    check(!(try adoptPair("r-wrong-reference", image: wrongReference, provider: "mps", sidecarProvider: "mps")),
          "R: an unrelated non-model reference is rejected")

    var modified = mpsBytes
    modified[0] = modified[0] == 0 ? 1 : 0
    let modifiedImage = try m3Image(rgb: modified)
    check(!(try adoptPair("r-modified-final", image: modifiedImage, provider: "mps", sidecarProvider: "mps")),
          "R: a modified final RGB8 output is rejected even with a self-consistent sidecar")

    func adoptsTamperedManifest(_ name: String,
                                _ mutate: (inout [String: Any]) -> Void) throws -> Bool {
        let directory = try copyReferences("fixtures-\(name)")
        try mutateManifest(in: directory, mutate)
        return try adoptPair(name, image: mpsImage, provider: "mps", sidecarProvider: "mps",
                             referenceDirectory: directory)
    }

    check(!(try adoptsTamperedManifest("r-wrong-aggregate") {
        $0["catalog_aggregate_sha256"] = String(repeating: "0", count: 64)
    }), "R: a reference manifest cannot substitute another catalog aggregate")
    check(!(try adoptsTamperedManifest("r-wrong-checkpoint") {
        var checkpoint = $0["checkpoint"] as! [[String: Any]]
        checkpoint[0]["sha256"] = String(repeating: "0", count: 64)
        $0["checkpoint"] = checkpoint
    }), "R: a reference manifest cannot substitute a checkpoint file pin")
    check(!(try adoptsTamperedManifest("r-wrong-source-hash") {
        var fixture = $0["fixture"] as! [String: Any]
        var source = fixture["source_rgb"] as! [String: Any]
        source["sha256"] = String(repeating: "0", count: 64)
        fixture["source_rgb"] = source
        $0["fixture"] = fixture
    }), "R: a reference manifest cannot change the submitted source binding")
    check(!(try adoptsTamperedManifest("r-wrong-input-hash") {
        var fixture = $0["fixture"] as! [String: Any]
        var input = fixture["input_f32"] as! [String: Any]
        input["sha256"] = String(repeating: "0", count: 64)
        fixture["input_f32"] = input
        $0["fixture"] = fixture
    }), "R: a reference manifest cannot change the float input binding")
    check(!(try adoptsTamperedManifest("r-wrong-output-shape") {
        var contract = $0["fixture_contract"] as! [String: Any]
        contract["expected_output_shape"] = [191, 256, 3]
        $0["fixture_contract"] = contract
    }), "R: a reference manifest cannot change the final RGB8 shape")
    check(!(try adoptsTamperedManifest("r-wrong-reference-hash") {
        var outputs = $0["outputs"] as! [String: Any]
        var mps = outputs["mps"] as! [String: Any]
        mps["sha256"] = String(repeating: "0", count: 64)
        outputs["mps"] = mps
        $0["outputs"] = outputs
    }), "R: a reference manifest cannot change the provider output hash")
    check(!(try adoptsTamperedManifest("r-introduced-tolerance") {
        $0["final_tolerance"] = "1 LSB"
    }), "R: an undeclared comparator tolerance is refused")
}

// MARK: - Run

testCLILaunchCannotRaceSwap()
testLiveHelperLeaseBlocksReplacement()
testCrashedProcessLeavesNoLease()
testUnrelatedProcessIsNeverTerminated()
testStartupAndReplacementSerialize()
testBoundedLockWaitIsRetryable()
testModelCLILeaseIsChildOwned()
testCancellationKeepsLeaseUntilExit()
testProductionDefaultUsesInstallerSupport()
testStaleWorkingCopiesAreSweptAndLiveOnesAreNot()
testStaleJobFoldersAreSweptAndLiveOnesAreNot()
testRuntimeEnvironmentRejectsExternalPaths()
testPackagedUpscaleDiagnosticContract()
try testPackagedUpscaleInputDigestIsSubmittedRGB8()
try testPackagedUpscaleTrustedProvenanceAndFinalArtifact()
try testPackagedDiagnosticStateStaysUnderOutput()
try testPackagedAdoptionRefusesLinkedInputs()
try testPackagedUpscaleIndependentReference()

try? FileManager.default.removeItem(at: rootDirectory)

print("\n" + String(repeating: "-", count: 60))
if failures.isEmpty {
    print("RUNTIME PROCESS TESTS: PASS")
    exit(0)
} else {
    print("RUNTIME PROCESS TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
