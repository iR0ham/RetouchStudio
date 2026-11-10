import Darwin
import Foundation

/// The result of one validation stage. Structural checks only prove that the
/// expected files are present; only the functional stage proves that Python
/// starts, the worker imports, and the helper answers. Capability flags are
/// reported separately because a missing optional backend does not make the
/// core runtime invalid.
struct RuntimeValidationReport: Equatable {
    enum Stage: String {
        case structural
        case functional
    }

    struct Issue: Equatable {
        let code: String
        let detail: String
    }

    let stage: Stage
    let issues: [Issue]
    var capabilities: [String: Bool] = [:]

    var ok: Bool { issues.isEmpty }

    static func success(_ stage: Stage,
                        capabilities: [String: Bool] = [:]) -> RuntimeValidationReport {
        RuntimeValidationReport(stage: stage, issues: [], capabilities: capabilities)
    }

    static func failure(_ stage: Stage, _ code: String, _ detail: String,
                        capabilities: [String: Bool] = [:]) -> RuntimeValidationReport {
        RuntimeValidationReport(stage: stage,
                                issues: [Issue(code: code, detail: detail)],
                                capabilities: capabilities)
    }

    var logLine: String {
        let state = ok ? "ok" : "failed"
        let problems = issues.map { "\($0.code): \($0.detail)" }.joined(separator: "; ")
        var line = "\(stage.rawValue) \(state)"
        if !problems.isEmpty { line += " — \(problems)" }
        if !capabilities.isEmpty {
            let caps = capabilities.keys.sorted().map {
                "\($0)=\(capabilities[$0] == true ? "yes" : "no")"
            }.joined(separator: ",")
            line += " [optional capabilities: \(caps)]"
        }
        return line
    }
}

/// Validates an unpacked AI runtime without touching the owner's projects,
/// Recovery data, or model downloads. Mandatory checks cover the interpreter,
/// the worker entry point, the core imports and a real startup handshake.
/// Feature backends are probed separately and never invalidate the runtime.
enum AIRuntimeValidation {

    static let requiredModules = ["numpy", "PIL"]

    struct OptionalCapability {
        let name: String
        let modules: [String]
    }

    static let optionalCapabilities = [
        OptionalCapability(name: "image-generation", modules: ["torch", "transformers"]),
        OptionalCapability(name: "segmentation", modules: ["sam2"]),
        OptionalCapability(name: "inpainting", modules: ["onnxruntime"]),
        OptionalCapability(name: "generative-fill", modules: ["mlx", "mflux"]),
    ]

    static let expectedPythonMajor = 3
    static let expectedPythonMinor = 13

    #if arch(arm64)
    static let expectedMachine = "arm64"
    #else
    static let expectedMachine = "x86_64"
    #endif

    // MARK: - Structural

    static func structural(root: URL) -> RuntimeValidationReport {
        var issues: [RuntimeValidationReport.Issue] = []
        let manager = FileManager.default
        func check(_ condition: Bool, _ code: String, _ detail: String) {
            if !condition { issues.append(.init(code: code, detail: detail)) }
        }

        if isSymbolicLink(root) {
            issues.append(.init(code: "unsafe-layout",
                                detail: "the runtime root is a symbolic link"))
        }
        var isDir: ObjCBool = false
        check(manager.fileExists(atPath: root.path, isDirectory: &isDir)
              && isDir.boolValue,
              "missing-root", "the runtime root is not a directory")

        let python = root.appendingPathComponent("bin/python3")
        check(manager.isExecutableFile(atPath: python.path),
              "missing-python", "bin/python3 is not executable")

        let worker = root.appendingPathComponent("retouch_ai_worker", isDirectory: true)
        check(isDirectory(worker), "missing-worker", "the worker package is missing")
        for name in ["__main__.py", "server.py", "engine.py"] {
            check(manager.fileExists(atPath: worker.appendingPathComponent(name).path),
                  "missing-worker-file", "retouch_ai_worker/\(name) is missing")
        }

        let sitePackages = root.appendingPathComponent("site-packages", isDirectory: true)
        check(isDirectory(sitePackages), "missing-site-packages",
              "the runtime has no site-packages directory")

        check(frameworkHome(in: root) != nil, "missing-python-home",
              "Python.framework has no installed version")

        let report = RuntimeValidationReport(stage: .structural, issues: issues)
        NSLog("[RetouchStudio] runtime validation %@", report.logLine)
        return report
    }

    // MARK: - Functional

    static func functional(root: URL, timeout: TimeInterval = 60) -> RuntimeValidationReport {
        let layout = structural(root: root)
        guard layout.ok else {
            let report = RuntimeValidationReport(stage: .functional, issues: layout.issues)
            NSLog("[RetouchStudio] runtime validation %@", report.logLine)
            return report
        }

        let deadline = Date().addingTimeInterval(max(10, timeout))
        let environment = environment(for: root)

        let environmentResult = runPython(
            python(in: root),
            script: environmentScript,
            environment: environment,
            timeout: min(15, remaining(deadline)))
        guard let info = jsonObject(from: environmentResult.stdout) else {
            return finish(.failure(.functional, "environment",
                                   commandDetail(environmentResult,
                                                 fallback: "python did not report its environment")))
        }
        if let problem = environmentProblem(info: info, root: root) {
            return finish(.failure(.functional, "environment", problem))
        }
        guard !environmentResult.timedOut, environmentResult.status == 0 else {
            return finish(.failure(.functional, "environment",
                                   commandDetail(environmentResult,
                                                 fallback: "python could not start")))
        }

        let core = runPython(python(in: root), script: coreImportScript,
                             environment: environment,
                             timeout: min(20, remaining(deadline)))
        guard let coreResult = jsonObject(from: core.stdout) else {
            return finish(.failure(.functional, "core-dependency",
                                   commandDetail(core,
                                                 fallback: "core imports did not report")))
        }
        var failedCore: [String] = []
        for module in requiredModules {
            if let detail = stringValue(coreResult[module]) {
                failedCore.append("\(module): \(detail)")
            } else if coreResult[module] == nil {
                failedCore.append("\(module): missing result")
            }
        }
        if !failedCore.isEmpty || core.timedOut || core.status != 0 {
            let detail = failedCore.isEmpty
                ? commandDetail(core, fallback: "core imports failed")
                : failedCore.joined(separator: "; ")
            return finish(.failure(.functional, "core-dependency", detail))
        }

        if let issue = startHandshake(root: root, environment: environment,
                                      deadline: deadline) {
            return finish(.failure(.functional, issue.code, issue.detail))
        }

        let capabilities = probeOptionalCapabilities(
            root: root, environment: environment,
            timeout: min(45, remaining(deadline)))

        let report = RuntimeValidationReport.success(.functional, capabilities: capabilities)
        return finish(report)
    }

    private static func finish(_ report: RuntimeValidationReport) -> RuntimeValidationReport {
        NSLog("[RetouchStudio] runtime validation %@", report.logLine)
        return report
    }

    // MARK: - Environment / imports

    private static func environment(for root: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = frameworkHome(in: root)?.path
        environment["PYTHONPATH"] = [
            root.path,
            root.appendingPathComponent("site-packages").path,
        ].joined(separator: ":")
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment.removeValue(forKey: "PYTHONSTARTUP")
        environment.removeValue(forKey: "PYTHONEXECUTABLE")
        environment.removeValue(forKey: "PYTHONINSPECT")
        environment.removeValue(forKey: "RETOUCH_AI_EVAL_MODELS")
        return environment
    }

    private static let environmentScript = """
    import json, platform, sys
    print(json.dumps({
        "implementation": platform.python_implementation(),
        "version": list(sys.version_info[:3]),
        "machine": platform.machine(),
        "prefix": sys.prefix,
        "base_prefix": sys.base_prefix,
        "executable": sys.executable,
    }))
    """

    private static let coreImportScript = """
    import json
    result = {}
    for name in ["numpy", "PIL"]:
        try:
            __import__(name)
            result[name] = None
        except BaseException as exc:
            result[name] = type(exc).__name__ + ": " + str(exc)[:160]
    print(json.dumps(result))
    """

    private static func environmentProblem(info: [String: Any], root: URL) -> String? {
        guard info["implementation"] as? String == "CPython" else {
            return "the interpreter is not CPython"
        }
        guard let version = info["version"] as? [Any],
              version.count >= 2,
              let major = version[0] as? Int,
              let minor = version[1] as? Int else {
            return "the interpreter did not report a version"
        }
        guard major == expectedPythonMajor, minor == expectedPythonMinor else {
            return "unexpected Python \(major).\(minor)"
        }
        guard info["machine"] as? String == expectedMachine else {
            return "unexpected architecture \(info["machine"] as? String ?? "unknown")"
        }
        guard let prefix = info["prefix"] as? String,
              isContained(URL(fileURLWithPath: prefix), in: root) else {
            return "the interpreter does not use the runtime as its Python home"
        }
        if let executable = info["executable"] as? String,
           !isContained(URL(fileURLWithPath: executable), in: root) {
            return "the interpreter refers outside the runtime"
        }
        return nil
    }

    private static func probeOptionalCapabilities(root: URL,
                                                  environment: [String: String],
                                                  timeout: TimeInterval) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for capability in optionalCapabilities { result[capability.name] = false }
        guard timeout > 1 else {
            NSLog("[RetouchStudio] runtime validation optional probe skipped (timeout)")
            return result
        }

        let groups = optionalCapabilities.map {
            "\"\($0.name)\": [\($0.modules.map { "\"\($0)\"" }.joined(separator: ", "))]"
        }.joined(separator: ", ")
        let script = """
        import json
        groups = {\(groups)}
        result = {}
        for capability, modules in groups.items():
            errors = []
            for name in modules:
                try:
                    __import__(name)
                except BaseException as exc:
                    errors.append(name + ": " + type(exc).__name__)
            result[capability] = "; ".join(errors) if errors else None
        print(json.dumps(result))
        """

        let command = runPython(python(in: root), script: script,
                                environment: environment, timeout: timeout)
        guard !command.timedOut, command.status == 0,
              let parsed = jsonObject(from: command.stdout) else {
            NSLog("[RetouchStudio] runtime validation optional probe failed: %@",
                  commandDetail(command, fallback: "no report"))
            return result
        }
        for capability in optionalCapabilities {
            result[capability.name] = parsed[capability.name] is NSNull
        }
        return result
    }

    // MARK: - Startup handshake

    private struct HandshakeIssue {
        let code: String
        let detail: String
    }

    private static func startHandshake(root: URL, environment: [String: String],
                                       deadline: Date) -> HandshakeIssue? {
        let manager = FileManager.default
        let probe = URL(fileURLWithPath: "/tmp/retouch-runtime-probe-\(UUID().uuidString)",
                        isDirectory: true)
        let socket = probe.appendingPathComponent("worker.sock")
        let jobs = probe.appendingPathComponent("jobs", isDirectory: true)
        let models = probe.appendingPathComponent("models", isDirectory: true)
        let log = probe.appendingPathComponent("worker.log")
        defer { try? manager.removeItem(at: probe) }

        do {
            try manager.createDirectory(at: probe, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
            try manager.createDirectory(at: jobs, withIntermediateDirectories: true)
            try manager.createDirectory(at: models, withIntermediateDirectories: true)
            manager.createFile(atPath: log.path, contents: nil)
        } catch {
            return HandshakeIssue(code: "startup",
                                   detail: "could not prepare the probe directory: \(error)")
        }

        let process = Process()
        process.executableURL = python(in: root)
        process.arguments = [
            "-m", "retouch_ai_worker", "serve",
            "--socket", socket.path,
            "--jobs", jobs.path,
            "--models", models.path,
            "--allow-root", probe.path,
        ]
        process.environment = environment

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: log)
        } catch {
            return HandshakeIssue(code: "startup",
                                   detail: "could not open the probe log: \(error)")
        }
        process.standardOutput = handle
        process.standardError = handle

        do {
            try process.run()
        } catch {
            try? handle.close()
            return HandshakeIssue(code: "startup",
                                   detail: "the interpreter could not start: \(error)")
        }

        var connected = false
        var lastDetail = "the helper did not answer"
        let startupDeadline = min(deadline, Date().addingTimeInterval(30))
        while Date() < startupDeadline {
            if !process.isRunning { break }
            if let reply = try? probeCall(socketPath: socket.path, method: "ping",
                                          timeout: 1),
               reply["pong"] as? Bool == true {
                connected = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        var healthIssue: HandshakeIssue?
        if connected {
            do {
                let health = try probeCall(socketPath: socket.path, method: "health",
                                           timeout: 5)
                if health["protocol"] as? String == nil
                    || health["version"] as? String == nil
                    || health["ok"] as? Bool != true {
                    healthIssue = HandshakeIssue(
                        code: "health",
                        detail: "the helper returned an incomplete or degraded health report")
                }
            } catch {
                healthIssue = HandshakeIssue(code: "health",
                                             detail: "the health request failed: \(error)")
            }
        }

        _ = try? probeCall(socketPath: socket.path, method: "shutdown", timeout: 2)
        stop(process)
        try? handle.close()

        if !connected {
            let status = process.isRunning ? "running" : "exit \(process.terminationStatus)"
            let tail = logTail(at: log)
            lastDetail = "the helper did not start (\(status))"
            if !tail.isEmpty { lastDetail += ": \(tail)" }
            return HandshakeIssue(code: "startup", detail: lastDetail)
        }
        if let healthIssue { return healthIssue }
        return nil
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func logTail(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let text = String(decoding: data.suffix(4096), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func probeCall(socketPath: String, method: String,
                                  timeout: TimeInterval) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeFailure("could not open a socket") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            throw ProbeFailure("the probe socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = strcpy(chars, socketPath)
            }
        }

        var seconds = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &seconds,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &seconds,
                   socklen_t(MemoryLayout<timeval>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size)
            }
        }
        guard connected == 0 else { throw ProbeFailure("the helper is not listening") }

        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1,
                                      "method": method, "params": [:]]
        let request = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])
        try request.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard wrote > 0 else { throw ProbeFailure("the helper closed the socket") }
                sent += wrote
            }
        }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard got > 0 else { break }
            reply.append(contentsOf: buffer[0..<got])
            if reply.contains(0x0A) { break }
            if reply.count > 4 * 1024 * 1024 { break }
        }
        guard let newline = reply.firstIndex(of: 0x0A) else {
            throw ProbeFailure("the helper closed the connection")
        }
        let data = reply[..<newline]
        guard let object = try JSONSerialization.jsonObject(with: Data(data)) as? [String: Any]
        else { throw ProbeFailure("the helper sent an unreadable reply") }
        if let error = object["error"] as? [String: Any] {
            throw ProbeFailure(error["message"] as? String ?? "the helper returned an error")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Command runner

    private struct CommandResult {
        let status: Int32
        let timedOut: Bool
        let stdout: String
        let stderr: String
    }

    private static func runPython(_ executable: URL, script: String,
                                  environment: [String: String],
                                  timeout: TimeInterval) -> CommandResult {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: "/tmp/retouch-runtime-command-\(UUID().uuidString)",
                       isDirectory: true)
        let out = base.appendingPathComponent("stdout")
        let err = base.appendingPathComponent("stderr")
        defer { try? manager.removeItem(at: base) }

        do {
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            manager.createFile(atPath: out.path, contents: nil)
            manager.createFile(atPath: err.path, contents: nil)
        } catch {
            return CommandResult(status: -1, timedOut: false, stdout: "",
                                 stderr: "could not prepare command files: \(error)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", script]
        process.environment = environment
        do {
            let outHandle = try FileHandle(forWritingTo: out)
            let errHandle = try FileHandle(forWritingTo: err)
            process.standardOutput = outHandle
            process.standardError = errHandle
            try process.run()
            let deadline = Date().addingTimeInterval(max(1, timeout))
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? outHandle.close()
            try? errHandle.close()
            return CommandResult(
                status: process.terminationStatus,
                timedOut: timedOut,
                stdout: String(decoding: (try? Data(contentsOf: out)) ?? Data(), as: UTF8.self),
                stderr: String(decoding: (try? Data(contentsOf: err)) ?? Data(), as: UTF8.self))
        } catch {
            return CommandResult(status: -1, timedOut: false, stdout: "",
                                 stderr: "could not run the interpreter: \(error)")
        }
    }

    private static func commandDetail(_ command: CommandResult,
                                      fallback: String) -> String {
        if command.timedOut { return "timed out" }
        let message = command.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return String(message.suffix(600)) }
        if command.status != 0 { return "exit \(command.status)" }
        return fallback
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        let candidate = text.split(separator: "\n").reversed().first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        }
        guard let candidate,
              let data = String(candidate).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if value == nil || value is NSNull { return nil }
        return value as? String ?? "unknown import error"
    }

    private static func remaining(_ deadline: Date) -> TimeInterval {
        max(1, deadline.timeIntervalSinceNow)
    }

    private static func python(in root: URL) -> URL {
        root.appendingPathComponent("bin/python3")
    }

    static func frameworkHome(in root: URL) -> URL? {
        let versions = root.appendingPathComponent("Python.framework/Versions",
                                                   isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path)
        else { return nil }
        let candidates = names.filter { !$0.hasPrefix(".") && $0 != "Current" }
        guard let newest = candidates.max(by: {
            $0.compare($1, options: .numeric) == .orderedAscending
        }) else { return nil }
        return versions.appendingPathComponent(newest, isDirectory: true)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path,
                                              isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        return result == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isContained(_ candidate: URL, in base: URL) -> Bool {
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let root = base.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    private struct ProbeFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
