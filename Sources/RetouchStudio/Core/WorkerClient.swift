import Foundation

/// A typed failure from the AI helper. The UI shows `message`; `code` keeps the
/// worker's own JSON-RPC code so a licence refusal is not mistaken for a crash.
struct AIWorkerFailure: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

/// Client for the local AI helper: JSON-RPC 2.0 over a Unix socket, one request
/// per line. Nothing here reaches the network; the helper has no network code
/// in its job path at all.
///
/// A connection is opened per call, which is cheap on a Unix socket and means a
/// crashed helper cannot leave a half-read frame behind in a shared connection.
final class WorkerClient {
    static let shared = WorkerClient()

    private static let pathLock = NSLock()
    private static var selectedPath: String?

    /// Where the helper listens. The legacy checkout/bundled helper uses
    /// `AI/worker.sock`; once a protocol-v2 helper is adopted this points at its
    /// socket instead, so every job call follows the registry.
    static var socketPath: String {
        pathLock.lock()
        let selected = selectedPath
        pathLock.unlock()
        if let selected { return selected }
        if let override = ProcessInfo.processInfo.environment["RETOUCH_AI_SOCKET"] {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("RetouchStudio/AI/worker.sock").path
    }

    /// Routes the shared client after a v2 adoption. `nil` restores the legacy
    /// socket so a stopped v2 helper is never reached by a later call.
    static func selectSocket(_ path: String?) {
        pathLock.lock()
        selectedPath = path
        pathLock.unlock()
    }

    /// A client bound to one socket. Used for the v2 health handshake, which
    /// must be answered by the exact helper the registry names. The shared
    /// client passes no path, so it keeps following `selectSocket`.
    private let fixedPath: String?

    var socketPath: String { fixedPath ?? WorkerClient.socketPath }

    init(socketPath: String? = nil) {
        self.fixedPath = socketPath
    }

    func isAvailable(timeout: TimeInterval = 1.2) -> Bool {
        (try? call("ping", timeout: timeout)) != nil
    }

    func call(_ method: String, _ params: [String: Any] = [:],
              timeout: TimeInterval = 20) throws -> Any {
        do {
            return try callOnce(method, params, timeout: timeout)
        } catch let failure as AIWorkerFailure where failure.code == -32000 {
            // A connection that never opened is the one failure worth retrying:
            // the helper may have crashed since the last call. The thread flag
            // stops the launch probe itself from recursing through here.
            let key = "RetouchStudio.restoringHelper"
            let thread = Thread.current.threadDictionary
            guard thread[key] == nil else { throw failure }
            guard AIWorker.isInstalled else {
                throw AIWorkerFailure(code: -32000, message: AIWorker.missingHelperMessage)
            }
            thread[key] = true
            defer { thread.removeObject(forKey: key) }
            guard AIWorker.restartIfStopped() else {
                if AIWorker.installedRuntimeProblem != nil {
                    throw AIWorkerFailure(code: -32000,
                                          message: AIWorker.missingHelperMessage)
                }
                if let problem = AIWorker.lastLaunchFailure {
                    throw AIWorkerFailure(code: -32000, message: problem)
                }
                throw failure
            }
            return try callOnce(method, params, timeout: timeout)
        }
    }

    private func callOnce(_ method: String, _ params: [String: Any],
                          timeout: TimeInterval) throws -> Any {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1,
                                      "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reply = try exchange(data + Data([0x0A]), timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw AIWorkerFailure(code: -32700, message: "the helper sent an unreadable reply")
        }
        if let error = object["error"] as? [String: Any] {
            throw AIWorkerFailure(code: (error["code"] as? Int) ?? -32603,
                                  message: (error["message"] as? String) ?? "helper error")
        }
        return object["result"] ?? [:]
    }

    // MARK: - Jobs

    func submit(_ kind: String, _ params: [String: Any]) throws -> String {
        let result = try call("job.submit", ["kind": kind, "params": params],
                              timeout: 20) as? [String: Any]
        guard let id = result?["job_id"] as? String else {
            throw AIWorkerFailure(code: -32603, message: "the helper did not return a job id")
        }
        return id
    }

    /// Polls until the job finishes. Polling instead of streaming notifications
    /// keeps one code path for progress, cancel and completion.
    ///
    /// `cancelled` is asked between polls. A long job (a 4x upscale can run for
    /// minutes) is inside the helper, not this thread, so stopping means both
    /// giving up here and telling the helper to drop the work.
    func wait(job id: String, timeout: TimeInterval,
              cancelled: () -> Bool = { false },
              progress: ((Int, String) -> Void)? = nil,
              fields: (([String: Any]) -> Void)? = nil) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancelled() {
                cancel(job: id)
                throw AIWorkerFailure(code: -32014, message: "cancelled")
            }
            let status = try call("job.status", ["job_id": id], timeout: 10) as? [String: Any]
            let state = status?["status"] as? String ?? "unknown"
            if let update = status?["progress"] as? [String: Any] {
                fields?(update)
                if let stage = update["stage"] as? String {
                    progress?(update["step"] as? Int ?? 0, stage)
                }
            }
            if ["succeeded", "failed", "cancelled"].contains(state) {
                let result = try call("job.result", ["job_id": id], timeout: 20) as? [String: Any]
                if state == "failed" {
                    let error = result?["error"] as? [String: Any]
                    throw AIWorkerFailure(code: (error?["code"] as? Int) ?? -32603,
                                          message: (error?["message"] as? String) ?? "the AI job failed")
                }
                if state == "cancelled" {
                    throw AIWorkerFailure(code: -32014, message: "cancelled")
                }
                return result ?? [:]
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try? call("job.cancel", ["job_id": id], timeout: 5)
        throw AIWorkerFailure(code: -32013, message: "the AI job took too long")
    }

    func cancel(job id: String) {
        _ = try? call("job.cancel", ["job_id": id], timeout: 5)
    }

    // MARK: - Transport

    /// Whether something is listening, without asking it anything. A helper
    /// busy inside a heavy job still accepts a connection, so this is what the
    /// restart path uses to tell "gone" apart from "slow".
    func isReachable() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var address = try? unixAddress() else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size) == 0
            }
        }
    }

    private func unixAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            throw AIWorkerFailure(code: -32000, message: "the helper socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = strcpy(chars, path)
            }
        }
        return address
    }

    private func exchange(_ request: Data, timeout: TimeInterval) throws -> Data {
        try exchangeWithPeer(request, timeout: timeout).reply
    }

    /// The same exchange, plus the kernel's answer for which process is on the
    /// other end. The peer PID is captured after `connect` and is what makes a
    /// health reply attributable to one helper rather than to any socket file.
    private func exchangeWithPeer(_ request: Data, timeout: TimeInterval) throws
        -> (reply: Data, peer: Int32?) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AIWorkerFailure(code: -32000, message: "could not open a socket")
        }
        defer { close(fd) }

        var address = try unixAddress()
        var seconds = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size)
            }
        }
        guard connected == 0 else {
            throw AIWorkerFailure(code: -32000,
                                  message: L10n.current.aiHelperStopped)
        }
        var peer = pid_t()
        var peerSize = socklen_t(MemoryLayout<pid_t>.size)
        let peerPID: Int32? = getsockopt(fd, 0, 0x002, &peer, &peerSize) == 0
            ? Int32(peer) : nil

        try request.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if wrote <= 0 {
                    throw AIWorkerFailure(code: -32000, message: L10n.current.aiHelperWriteFailed)
                }
                sent += wrote
            }
        }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if got <= 0 { break }
            reply.append(contentsOf: buffer[0..<got])
            if reply.contains(0x0A) { break }
            if reply.count > 4 * 1024 * 1024 { break }
        }
        guard let newline = reply.firstIndex(of: 0x0A) else {
            if reply.isEmpty {
                throw AIWorkerFailure(code: -32000, message: "the helper closed the connection")
            }
            return (reply, peerPID)
        }
        return (Data(reply[..<newline]), peerPID)
    }

    // MARK: - Protocol-v2 health handshake

    /// Asks the helper to prove it is the exact launch the registry describes.
    ///
    /// The check is deliberately strict: protocol version, helper generation,
    /// launch nonce and PID must all match the registry record, and the kernel's
    /// peer PID must equal the recorded helper identity, which is re-captured
    /// right now (PID plus start time plus executable). A stale or substituted
    /// helper therefore cannot be adopted even if it answers health.
    @discardableResult
    func verifiedHealth(generation: String, nonce: String,
                        helper: ProcessIdentity) throws -> [String: Any] {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1,
                                      "method": "health", "params": [String: Any]()]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let exchange = try exchangeWithPeer(data + Data([0x0A]), timeout: 10)
        guard let object = try JSONSerialization.jsonObject(with: exchange.reply)
                as? [String: Any] else {
            throw AIWorkerFailure(code: -32700, message: "the helper sent an unreadable reply")
        }
        if let error = object["error"] as? [String: Any] {
            throw AIWorkerFailure(code: (error["code"] as? Int) ?? -32603,
                                  message: (error["message"] as? String) ?? "helper error")
        }
        guard let result = object["result"] as? [String: Any] else {
            throw AIWorkerFailure(code: -32603,
                                  message: "the helper did not prove its identity")
        }
        guard let peer = exchange.peer, peer == helper.pid,
              ProcessIdentity.capture(peer) == helper else {
            throw AIWorkerFailure(code: -32000,
                                  message: "the AI helper is not the recorded process")
        }
        guard result["protocol_version"] as? Int == HelperRegistry.protocolVersion,
              result["helper_generation"] as? String == generation,
              result["launch_nonce"] as? String == nonce,
              result["pid"] as? Int == Int(helper.pid) else {
            throw AIWorkerFailure(code: -32000,
                                  message: "the AI helper did not match its registry record")
        }
        return result
    }
}
