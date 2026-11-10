import Darwin
import Foundation

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
//    death of the app that launched it and keeps a replacement out.
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
        do {
            var lease: RuntimeUsageLease?
            try RuntimeTransactionLock.shared.withLock(support: support, timeout: 30) {
                try? Data("\(getpid())".utf8).write(
                    to: support.appendingPathComponent("child-startup-locked"))
                Thread.sleep(forTimeInterval: 0.8)
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
    // stopped: copy a real binary so `proc_pidpath` reports the runtime path.
    let runtime = AIRuntime.installDirectory(in: support)
    do {
        try makeFakeRuntime(at: runtime, version: "orphan")
        let interpreter = runtime.appendingPathComponent("bin/python3")
        try FileManager.default.removeItem(at: interpreter)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"),
                                         to: interpreter)
    } catch {
        check(false, "D: orphan fixture written", "\(error)")
        return
    }
    let orphan = Process()
    orphan.executableURL = runtime.appendingPathComponent("bin/python3")
    orphan.arguments = ["20"]
    do { try orphan.run() } catch {
        check(false, "D: orphan helper started", "\(error)")
        return
    }
    let orphanPID = orphan.processIdentifier
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

// MARK: - Run

testCLILaunchCannotRaceSwap()
testLiveHelperLeaseBlocksReplacement()
testCrashedProcessLeavesNoLease()
testUnrelatedProcessIsNeverTerminated()
testStartupAndReplacementSerialize()
testBoundedLockWaitIsRetryable()
testModelCLILeaseIsChildOwned()

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
