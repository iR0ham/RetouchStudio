import Foundation

/// A typed failure from the AI helper. The UI shows the sentence this type
/// chooses (`EditorModel.localizedAIFailure(_:)`); `code` keeps the worker's own
/// JSON-RPC code so a licence refusal is not mistaken for a crash, and the two
/// capability fields keep what the worker said *about* the refusal — which is
/// the difference between a capability this build never offers and one that is
/// installed here and waiting for a tap. See
/// `Docs/AI_REFUSAL_ROUTING_PROPOSAL.md` §3 and §5.
struct AIWorkerFailure: LocalizedError, Equatable {
    let code: Int
    let message: String
    let capabilityId: String?
    let capabilityState: String?
    /// The Python package a refusal names when the helper cannot import the
    /// runtime an adapter needs. The state is still `blocked` (the weights may
    /// be installed), but no download or Adopt tap can settle this class.
    let missingPackage: String?

    init(code: Int, message: String, data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        capabilityId = data?["capabilityId"] as? String
        capabilityState = data?["state"] as? String
        missingPackage = data?["package"] as? String
    }

    var errorDescription: String? { message }

    /// The W5-0 typed name for the numeric code, matching the Windows host.
    var typedCode: String {
        switch code {
        case -32000: return "E_WORKER_MISSING"
        case -32010: return "E_LICENCE_REFUSED"
        case -32011, -32016: return "E_MODEL_MISSING"
        case -32012: return "E_MODEL_LEASED"
        case -32013: return "E_TIMEOUT"
        case -32014: return "E_CANCELLED"
        case -32015, -32602: return "E_INVALID_INPUT"
        case -32019: return "E_MODEL_UNVERIFIED"
        case -32020: return "E_UNSUPPORTED"
        // The catalog entry's pin is incomplete or malformed, so there is
        // nothing to verify the bytes against. Same honest label as damaged
        // weights, and like them it opens no manager: no download repairs a
        // catalog defect. See `worker/retouch_ai_worker/protocol.py`.
        case -32021: return "E_MODEL_UNVERIFIED"
        default: return "E_INTERNAL"
        }
    }

    /// Whether the model manager holds the step this refusal is waiting for.
    ///
    /// A missing model has always opened it. `-32020` carries both classes the
    /// frozen vocabulary separates, and only `blocked` means the adapter offers
    /// the capability and something on this machine has to be settled — in part
    /// by the Adopt chip the manager renders. `unsupported` is a product answer,
    /// not a queue, so it opens nothing. A refusal that names a runtime package
    /// stays shut too: the manager can only explain it, never settle it.
    var opensModelManager: Bool {
        switch code {
        case -32011: return true
        case -32020: return capabilityState == "blocked" && missingPackage == nil
        default: return false
        }
    }

    /// The capability id of a refusal the model manager can act on, or nil.
    ///
    /// Both halves are needed: `blocked` says something on this machine is
    /// missing, and the id says which task, so the sentence can name it. An
    /// id-less `-32020` — the worker refusing a name that is not this kind's
    /// capability — keeps the generic wording.
    var blockedCapabilityId: String? {
        guard code == -32020, capabilityState == "blocked", missingPackage == nil,
              let capabilityId else { return nil }
        return capabilityId
    }

    /// The capability and runtime package a refusal names when the helper
    /// cannot load the package. It is reported `blocked` like an install
    /// waiting to be adopted, and it needs its own sentence: "installed on this
    /// Mac" is false here, and downloading the model changes nothing. The
    /// host never learns whether the package is absent or merely broken — an
    /// import failure is all the helper can observe — so the sentence says
    /// "cannot load" and names the package rather than blaming the build.
    var runtimeRefusal: (capability: String, package: String)? {
        guard code == -32020, let package = missingPackage, let capabilityId else {
            return nil
        }
        return (capabilityId, package)
    }
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
                                      "contractVersion": "1",
                                      "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reply = try exchange(data + Data([0x0A]), timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw AIWorkerFailure(code: -32700, message: "the helper sent an unreadable reply")
        }
        if let error = object["error"] as? [String: Any] {
            throw AIWorkerFailure(code: (error["code"] as? Int) ?? -32603,
                                  message: (error["message"] as? String) ?? "helper error",
                                  data: error["data"] as? [String: Any])
        }
        return object["result"] ?? [:]
    }

    // MARK: - Jobs

    /// Submits a job. `capability` is the frozen W5-0 id the caller means to
    /// run, and naming it is what lets the helper apply its own verdict before
    /// it loads weights or allocates a tile: a capability this machine cannot
    /// run is refused with `E_UNSUPPORTED` or `E_MODEL_MISSING` instead of
    /// being attempted through the job kind, which only checks the catalog.
    /// A caller that names nothing keeps the unchanged kind-only path.
    ///
    /// `requestedCapability` is a different thing from `capability`: it asks the
    /// helper to write this id into the provenance of the artifacts it hands
    /// back, and nothing more. The helper does not put it through its verdict,
    /// because the Quick Edit tools ship on models whose installs carry no
    /// recorded run — gating the name would refuse edits that work today. A
    /// name the kind cannot carry is refused as bad params.
    func submit(_ kind: String, _ params: [String: Any],
                capability: String? = nil,
                requestedCapability: String? = nil) throws -> String {
        var envelope: [String: Any] = ["kind": kind, "params": params]
        if let capability { envelope["capabilityId"] = capability }
        if let requestedCapability { envelope["requestedCapability"] = requestedCapability }
        let result = try call("job.submit", envelope, timeout: 20) as? [String: Any]
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
                                          message: (error?["message"] as? String) ?? "the AI job failed",
                                          data: error?["data"] as? [String: Any])
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
                                      "contractVersion": "1",
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
        guard result["contractVersion"] as? String == "1",
              result["protocol_version"] as? Int == HelperRegistry.protocolVersion,
              result["helper_generation"] as? String == generation,
              result["launch_nonce"] as? String == nonce,
              result["pid"] as? Int == Int(helper.pid) else {
            throw AIWorkerFailure(code: -32000,
                                  message: "the AI helper did not match its registry record")
        }
        return result
    }
}
