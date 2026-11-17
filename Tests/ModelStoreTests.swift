import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

// W5-2 model store suite. Downloads go to a loopback HTTP server; leases are
// held by real child processes (this same binary re-executed); crashes are real
// `_exit`/SIGKILL events, never a mocked flag.

var failures: [String] = []

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

func runBlocking<T>(_ body: @escaping () async throws -> T) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    // Detached on purpose: top-level code is MainActor-isolated, and blocking
    // that actor would deadlock the very work being awaited.
    Task.detached(priority: .userInitiated) {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return box.result!
}

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

func childExit(_ code: Int32) -> Never {
    fflush(stdout)
    exit(code)
}

// MARK: - Child modes

let arguments = CommandLine.arguments
if arguments.count > 1 {
    switch arguments[1] {
    case "--hold-lock":
        // --hold-lock <path> <sh|ex> <seconds>
        guard arguments.count >= 5 else { childExit(64) }
        do {
            let file = try LockFile.open(URL(fileURLWithPath: arguments[2]))
            try file.acquire(exclusive: arguments[3] == "ex", timeout: 10,
                             busyMessage: "held")
            print("locked")
            fflush(stdout)
            Thread.sleep(forTimeInterval: TimeInterval(arguments[4]) ?? 60)
            childExit(0)
        } catch {
            print("lock-error \(error)")
            childExit(65)
        }
    case "--install-once":
        // --install-once <catalog> <root> <model-id> <base>
        guard arguments.count >= 6 else { childExit(64) }
        do {
            let catalog = try loadFixtureCatalog(path: arguments[2], base: arguments[5])
            guard let entry = catalog.entry(id: arguments[4]) else { childExit(66) }
            let store = ModelStore(root: URL(fileURLWithPath: arguments[3]),
                                   catalog: catalog, allowLocalHTTP: true)
            switch runBlocking({ _ = try await store.install(entry) }) {
            case .success: print("installed"); childExit(0)
            case .failure(let error):
                if let storeError = error as? ModelStoreError {
                    print("code=\(storeError.code)")
                    childExit(storeError.code == "E_MODEL_LEASED" ? 3 : 2)
                }
                print("error=\(error)")
                childExit(2)
            }
        } catch {
            print("error=\(error)")
            childExit(2)
        }
    case "--delete-once":
        // --delete-once <catalog> <root> <model-id> <version> <base>
        guard arguments.count >= 7 else { childExit(64) }
        do {
            let catalog = try loadFixtureCatalog(path: arguments[2], base: arguments[6])
            guard let entry = catalog.entry(id: arguments[4]) else { childExit(66) }
            let store = ModelStore(root: URL(fileURLWithPath: arguments[3]),
                                   catalog: catalog, allowLocalHTTP: true)
            try store.delete(entry, version: arguments[5])
            print("deleted")
            childExit(0)
        } catch {
            print("error=\(error)")
            childExit(2)
        }
    default:
        break
    }
}

// MARK: - Fixtures and helpers

let testsRoot = URL(fileURLWithPath:
    ProcessInfo.processInfo.environment["RETOUCH_TESTS_ROOT"] ?? FileManager.default.currentDirectoryPath)
let fixtureDirectory = testsRoot.appendingPathComponent("Tests/Fixtures/model-store")
let scratchRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-modelstore-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)

struct StorePaths {
    let root: URL
    let store: ModelStore
    let catalog: ModelCatalog
}

func loadFixtureCatalog(path: String, base: String) throws -> ModelCatalog {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let text = String(data: data, encoding: .utf8) else {
        throw ModelCatalog.LoadError.unreadable("fixture is not UTF-8")
    }
    let expanded = text.replacingOccurrences(of: "{base}", with: base)
    return try ModelCatalog.load(data: Data(expanded.utf8), allowLocalHTTP: true)
}

func catalogData(containing ids: Set<String>, base: String) throws -> Data {
    let full = try Data(contentsOf: URL(fileURLWithPath: fixturePath("catalog-fixture.json")))
    var object = try JSONSerialization.jsonObject(with: full) as! [String: Any]
    let entries = object["entries"] as! [[String: Any]]
    object["entries"] = entries.filter { ids.contains($0["id"] as? String ?? "") }
    let filtered = try JSONSerialization.data(withJSONObject: object)
    let text = String(data: filtered, encoding: .utf8)!
    return Data(text.replacingOccurrences(of: "{base}", with: base).utf8)
}

func fixturePath(_ name: String) -> String {
    fixtureDirectory.appendingPathComponent(name).path
}

func workerPython() -> String? {
    [
        ProcessInfo.processInfo.environment["RETOUCH_WORKER_PYTHON"],
        testsRoot.appendingPathComponent("worker/.venv/bin/python3").path,
        "/usr/bin/python3",
    ].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func makeStore(_ server: FixtureServer, _ name: String = "fixture-good",
               fixture: String = "catalog-valid.json",
               allowLocalHTTP: Bool = true) -> StorePaths {
    let catalog = try! loadFixtureCatalog(path: fixturePath(fixture), base: server.base)
    let root = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ModelStore(root: root, catalog: catalog, platform: "macos-arm64",
                           allowLocalHTTP: allowLocalHTTP)
    return StorePaths(root: root, store: store, catalog: catalog)
}

func entry(_ paths: StorePaths, _ id: String) -> ModelCatalogEntry {
    paths.catalog.entry(id: id)!
}

// The worker's load path checks unsigned file sizes, so a fixture that stands
// in for a real model must have the recorded size. Sparse, so it costs no disk.
func writeSizedFixture(at url: URL, bytes: Int) {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: url)
    try! handle.truncate(atOffset: UInt64(bytes))
    try! handle.close()
}

func expectCode(_ result: Result<Void, Error>, _ code: String, _ label: String) {
    switch result {
    case .success:
        check(false, label, "expected \(code), got success")
    case .failure(let error):
        let actual = (error as? ModelStoreError)?.code ?? "\(error)"
        check(actual == code, label, actual)
    }
}

func versionDirectory(_ paths: StorePaths, _ id: String, _ version: String) -> URL {
    paths.store.layout.versionDirectory(model: id, version: version)
}

func stagingChildren(_ paths: StorePaths) -> [String] {
    (try? FileManager.default.contentsOfDirectory(
        atPath: paths.store.layout.staging.path)) ?? []
}

func quarantineChildren(_ paths: StorePaths) -> [String] {
    (try? FileManager.default.contentsOfDirectory(
        atPath: paths.store.layout.quarantine.path)) ?? []
}

func runChild(_ arguments: [String], environment: [String: String] = [:]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func launchHolder(_ lockPath: String, exclusive: Bool) -> (Process, Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--hold-lock", lockPath, exclusive ? "ex" : "sh", "60"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    return (process, pipe)
}

func waitForLine(_ pipe: Pipe, containing marker: String) -> Bool {
    var data = Data()
    while !data.contains(0x0A) {
        let chunk = pipe.fileHandleForReading.availableData
        if chunk.isEmpty { return false }
        data.append(chunk)
        if data.count > 4096 { break }
    }
    return String(data: data, encoding: .utf8)?.contains(marker) == true
}

func waitForLocked(_ pipe: Pipe) -> Bool {
    waitForLine(pipe, containing: "locked")
}

/// Reads one newline-terminated line, byte by byte, so a test can follow a
/// worker through several steps without losing the buffered remainder.
func readLine(_ pipe: Pipe) -> String? {
    var bytes: [UInt8] = []
    while true {
        let chunk = pipe.fileHandleForReading.readData(ofLength: 1)
        if chunk.isEmpty {
            return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
        }
        if chunk[0] == 0x0A {
            return String(bytes: bytes, encoding: .utf8)
        }
        bytes.append(contentsOf: chunk)
    }
}

func launchInstall(catalog: String, root: URL, id: String, base: String,
                   crash: String? = nil) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--install-once", catalog, root.path, id, base]
    var env = ProcessInfo.processInfo.environment
    if let crash { env["RETOUCH_MODEL_TEST_CRASH"] = crash }
    process.environment = env
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    return process
}

func waitForPath(_ url: URL, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        usleep(20_000)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

func age(_ url: URL, by seconds: TimeInterval) {
    try? FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
}

func writeManifest(in directory: URL, model: String, version: String) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = ModelManifest(
        schema: ModelManifest.schemaName, modelId: model, version: version,
        catalogVersion: "fixture-1", manifestSha256: "0",
        files: [ModelManifestFile(path: "payload.bin", sizeBytes: 12, sha256: "0")],
        installedAt: Date().timeIntervalSince1970)
    let data = try! JSONEncoder().encode(manifest)
    try! data.write(to: directory.appendingPathComponent("manifest.json"))
}

/// Loopback HTTP server with per-path body, delay and mid-body disconnect.
final class FixtureServer: @unchecked Sendable {
    private struct Route {
        var body: Data
        var status: Int
        var delayMicroseconds: useconds_t
        var dropAfter: Int?
    }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var requestCount = 0
    private var requestedPaths: [String] = []
    private var running = true
    private let acceptQueue = DispatchQueue(label: "retouch.fixture-http.accept")

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "fixture", code: 1) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(fd); throw NSError(domain: "fixture", code: 2) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        guard listen(fd, 32) == 0 else { Darwin.close(fd); throw NSError(domain: "fixture", code: 3) }
        listenFD = fd
    }

    var base: String { "http://127.0.0.1:\(port)" }

    func serve(_ path: String, _ body: String, status: Int = 200,
               delayMicroseconds: useconds_t = 0, dropAfter: Int? = nil) {
        lock.lock()
        routes[path] = Route(body: Data(body.utf8), status: status,
                             delayMicroseconds: delayMicroseconds, dropAfter: dropAfter)
        lock.unlock()
    }

    func start() {
        acceptQueue.async { [weak self] in
            while let self {
                self.lock.lock()
                let alive = self.running
                self.lock.unlock()
                if !alive { return }
                let client = Darwin.accept(self.listenFD, nil, nil)
                if client < 0 { return }
                DispatchQueue.global().async { self.handle(client) }
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    func paths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requestedPaths
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var request = Data()
        while request.count < 16384 {
            let read = buffer.withUnsafeMutableBytes {
                Darwin.read(client, $0.baseAddress, 4096)
            }
            if read <= 0 { break }
            request.append(buffer, count: read)
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let head = String(data: request, encoding: .utf8),
              let first = head.split(separator: "\r\n").first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? "/"
        lock.lock()
        requestCount += 1
        requestedPaths.append(path)
        let route = routes[path]
        lock.unlock()
        guard let route else {
            send(client, status: 404, body: Data("missing".utf8))
            return
        }
        var header = "HTTP/1.1 \(route.status) \(route.status == 200 ? "OK" : "Error")\r\n"
        header += "Content-Length: \(route.body.count)\r\n"
        header += "Connection: close\r\nContent-Type: application/octet-stream\r\n\r\n"
        writeAll(client, Data(header.utf8))
        if let drop = route.dropAfter {
            if drop > 0 { writeAll(client, route.body.prefix(drop)) }
            return
        }
        for byte in route.body {
            if route.delayMicroseconds > 0 { usleep(route.delayMicroseconds) }
            writeAll(client, Data([byte]))
        }
    }

    private func send(_ client: Int32, status: Int, body: Data) {
        var header = "HTTP/1.1 \(status) Error\r\nContent-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        writeAll(client, Data(header.utf8))
        writeAll(client, body)
    }

    private func writeAll(_ client: Int32, _ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(client, raw.baseAddress!.advanced(by: offset),
                                           raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

func makeServer() -> FixtureServer {
    let server = try! FixtureServer()
    server.serve("/good/payload.bin", "fixture-one\n")
    server.serve("/v2/payload.bin", "fixture-two\n")
    server.start()
    return server
}

// MARK: - [1] Catalog integrity

print("\n[1] catalog: mandatory metadata, DR-5, source and path rules")
do {
    let server = makeServer()
    defer { server.stop() }
    let catalog = try! loadFixtureCatalog(path: fixturePath("catalog-valid.json"),
                                          base: server.base)
    check(catalog.entries.count == 4, "installable fixture catalog decodes",
          "\(catalog.entries.count) entries")
    let good = catalog.entry(id: "fixture-good")!
    check(good.isVerifiable && good.verificationProblem == nil, "complete entry is verifiable")
    let unverifiable = catalog.entry(id: "fixture-unverifiable")!
    check(!unverifiable.isVerifiable && unverifiable.verificationProblem != nil,
          "null size/hash is unverifiable (DR-5)")
    check(unverifiable.sizeBytes == nil && unverifiable.sha256 == nil,
          "unverifiable entry keeps nulls instead of invented values")

    let raw = try! Data(contentsOf: URL(fileURLWithPath: fixturePath("catalog-fixture.json")))
    let rawObject = try! JSONSerialization.jsonObject(with: raw) as! [String: Any]
    check((rawObject["entries"] as! [[String: Any]]).count == 11,
          "full fixture catalog lists the rejected cases")

    var fullRejected = false
    do {
        _ = try ModelCatalog.load(data: catalogData(containing: [
            "fixture-good", "fixture-http", "fixture-offhost", "fixture-traversal",
            "fixture-file-port", "fixture-file-scheme", "fixture-file-userinfo",
            "fixture-file-fragment",
        ], base: server.base), allowLocalHTTP: true)
    } catch {
        fullRejected = true
    }
    check(fullRejected, "a catalog with an insecure entry is rejected as a whole")

    for entryID in ["fixture-http", "fixture-offhost", "fixture-traversal",
                    "fixture-file-port", "fixture-file-scheme",
                    "fixture-file-userinfo", "fixture-file-fragment"] {
        var rejected = false
        do {
            _ = try ModelCatalog.load(data: catalogData(containing: [entryID],
                                                        base: server.base),
                                      allowLocalHTTP: true)
        } catch {
            rejected = true
        }
        check(rejected, "\(entryID) is rejected at catalog load")
    }

    // The port rule is production-specific: the same rejected file is refused
    // with and without the test opt-in, and loopback HTTP is test-only.
    var productionPortRejected = false
    do {
        _ = try ModelCatalog.load(data: catalogData(containing: ["fixture-file-port"],
                                                    base: server.base),
                                  allowLocalHTTP: false)
    } catch {
        productionPortRejected = true
    }
    check(productionPortRejected, "a non-default file port is refused in production")

    var productionHTTPRejected = false
    do {
        _ = try ModelCatalog.load(data: catalogData(containing: ["fixture-good"],
                                                    base: server.base),
                                  allowLocalHTTP: false)
    } catch {
        productionHTTPRejected = true
    }
    check(productionHTTPRejected, "production refuses the loopback HTTP test source")
    check((try? ModelCatalog.load(data: catalogData(containing: ["fixture-good"],
                                                    base: server.base),
                                  allowLocalHTTP: true)) != nil,
          "the explicit test opt-in accepts loopback HTTP")
    let productionHTTPS = try! catalogData(containing: ["fixture-good"],
                                           base: "https://example.com")
    check((try? ModelCatalog.load(data: productionHTTPS, allowLocalHTTP: false)) != nil,
          "a default-port HTTPS source loads in production")

    let production = try! ModelCatalog.load(
        url: testsRoot.appendingPathComponent("Resources/model-catalog.json"))
    check(production.entries.count >= 4, "shipped catalog loads",
          "\(production.entries.count) entries")
    let sam = production.entry(id: "sam2.1-hiera-tiny")
    check(sam?.isVerifiable == false, "shipped SAM 2.1 is listed but unverifiable")
    let swin = production.entry(id: "swin2sr-x4")
    check(swin?.supports(platform: "windows-x64") == false,
          "Swin2SR is not advertised on Windows")
    let migan = production.entry(id: "migan")
    check(migan?.supports(platform: "windows-x64") == true,
          "MI-GAN is advertised on Windows")
    check(production.entries.allSatisfy { $0.licenseEvidenceUrl.lowercased().hasPrefix("https://") },
          "every shipped entry has an HTTPS licence evidence URL")
}

// MARK: - [2] No network outside an approved download

print("\n[2] catalog, snapshot, verify and cleanup never touch the network")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    _ = paths.store.records()
    _ = paths.store.diskUsage()
    _ = paths.store.availableBytes()
    _ = paths.store.cleanup(now: Date().addingTimeInterval(48 * 3600))
    var missingTyped = false
    do {
        _ = try paths.store.verify(entry(paths, "fixture-good"), version: "1.0.0", full: true)
    } catch {
        missingTyped = (error as? ModelStoreError)?.code == "E_MODEL_MISSING"
    }
    check(missingTyped, "verify reports a missing version as E_MODEL_MISSING")
    check(server.count() == 0, "zero HTTP requests for snapshot/verify/cleanup",
          "\(server.count())")
}

// MARK: - [3] Install, atomic layout, idempotence

print("\n[3] staged install, manifest, atomic pointer, idempotent retry")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let good = entry(paths, "fixture-good")
    var progressCount = 0
    let install = runBlocking {
        _ = try await paths.store.install(good) { _ in progressCount += 1 }
    }
    switch install {
    case .success:
        check(true, "install succeeds")
    case .failure(let error):
        check(false, "install succeeds", "\(error)")
    }
    let active = try? paths.store.activePointer("fixture-good")
    check(active?.version == "1.0.0", "active pointer names the installed version")
    check(active?.schema == ModelActivePointer.schemaName, "active pointer schema is exact")
    let manifest = try? JSONDecoder().decode(
        ModelManifest.self,
        from: Data(contentsOf: paths.store.layout.manifestURL(model: "fixture-good",
                                                              version: "1.0.0")))
    check(manifest?.modelId == "fixture-good" && manifest?.files.count == 1,
          "manifest records the model and file list")
    check(stagingChildren(paths).isEmpty, "staging is empty after success")
    check(server.paths() == ["/good/payload.bin"], "exactly the catalog file was fetched",
          "\(server.paths())")
    check(progressCount > 0, "progress was reported", "\(progressCount) updates")

    let report = try! paths.store.verify(good, version: "1.0.0", full: true)
    check(report.ok && report.checked == 1, "full verify passes")
    let record = paths.store.records().first { $0.id == "fixture-good" }!
    check(record.activeVersion == "1.0.0" && record.versions.count == 1,
          "snapshot shows one active version")

    let before = server.count()
    let again = runBlocking { _ = try await paths.store.install(good) }
    if case .failure(let error) = again { check(false, "idempotent reinstall", "\(error)") }
    check(server.count() == before, "reinstall of a verified version downloads nothing",
          "\(server.count() - before) requests")
    check(paths.store.installedVersions(of: good).count == 1, "reinstall does not duplicate a version")

    let manifestURL = paths.store.layout.manifestURL(model: "fixture-good", version: "1.0.0")
    try! Data("{}".utf8).write(to: manifestURL)
    let corrupt = try! paths.store.verify(good, version: "1.0.0", full: true)
    check(!corrupt.ok, "a corrupt manifest fails verification")
}

// MARK: - [4] Refused metadata and mismatched bytes

print("\n[4] SHA mismatch, size mismatch, unverifiable metadata")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    expectCode(runBlocking { _ = try await paths.store.install(entry(paths, "fixture-sha")) },
               "E_MODEL_UNVERIFIED", "SHA mismatch is refused")
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-sha", "1.0.0").path), "no version from a SHA mismatch")
    expectCode(runBlocking { _ = try await paths.store.install(entry(paths, "fixture-size")) },
               "E_MODEL_UNVERIFIED", "size mismatch is refused")
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-size", "1.0.0").path), "no version from a size mismatch")
    let before = server.count()
    expectCode(runBlocking { _ = try await paths.store.install(entry(paths, "fixture-unverifiable")) },
               "E_MODEL_UNVERIFIED", "unverifiable entry is refused before any byte")
    check(server.count() == before, "unverifiable entry made no request")
    check(stagingChildren(paths).isEmpty, "failed downloads left no staging tree")
    check((try? paths.store.activePointer("fixture-sha")) == nil, "no active pointer after failures")
}

// MARK: - [5] Interruption and safe retry

print("\n[5] network interruption leaves nothing active; a retry works")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    server.serve("/good/payload.bin", "fixture-one\n", dropAfter: 4)
    expectCode(runBlocking { _ = try await paths.store.install(entry(paths, "fixture-good")) },
               "E_INVALID_INPUT", "a dropped connection is a typed failure")
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-good", "1.0.0").path), "no version after interruption")
    check(stagingChildren(paths).isEmpty, "staging is cleaned after interruption")
    server.serve("/good/payload.bin", "fixture-one\n")
    switch runBlocking { _ = try await paths.store.install(entry(paths, "fixture-good")) } {
    case .success: check(true, "retry after the network returns succeeds")
    case .failure(let error): check(false, "retry after the network returns succeeds", "\(error)")
    }
}

// MARK: - [6] Cancellation

print("\n[6] cancelled download leaves nothing installed")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    server.serve("/good/payload.bin", "fixture-one\n", delayMicroseconds: 60_000)
    let good = entry(paths, "fixture-good")
    let started = ResultBox<Bool>()
    started.result = .success(false)
    let task = Task.detached {
        try await paths.store.install(good) { _ in started.result = .success(true) }
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, (try? started.result?.get()) != true { usleep(20_000) }
    task.cancel()
    let result = runBlocking { try await task.value }
    expectCode(result.map { _ in () }, "E_CANCELLED", "cancellation is reported as E_CANCELLED")
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-good", "1.0.0").path), "cancellation installed no version")
    check(stagingChildren(paths).isEmpty, "cancellation cleaned staging")
    check((try? paths.store.activePointer("fixture-good")) == nil, "cancellation wrote no pointer")
}

// MARK: - [7] Disk space

print("\n[7] insufficient disk space is refused before any request")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let huge = 9_000_000_000_000_000_000
    let entry = ModelCatalogEntry(
        id: "fixture-huge", name: "huge", capabilities: ["upscale.4x"], version: "1.0.0",
        format: "fixture",
        files: [ModelCatalogFile(path: "payload.bin", sizeBytes: huge,
                                 sha256: String(repeating: "a", count: 64),
                                 sourceUrl: server.base + "/good/payload.bin")],
        sizeBytes: huge, sha256: String(repeating: "b", count: 64),
        sourceUrl: server.base + "/good", codeLicense: "MIT", weightsLicense: "MIT",
        licenseEvidenceUrl: server.base + "/good", platforms: ["macos-arm64"],
        requiredProvider: "cpu", minimumContractVersion: "1",
        preprocess: ModelPreprocess(id: "fixture", version: "1"), deterministic: true,
        notes: "", unverifiableReason: nil)
    let before = server.count()
    expectCode(runBlocking { _ = try await paths.store.install(entry) },
               "E_INVALID_INPUT", "disk check refuses an impossible size")
    check(server.count() == before, "disk refusal made no request")
}

// MARK: - [8] Local HTTP only with explicit opt-in; symlink escape

print("\n[8] production refuses loopback HTTP; a symlinked staging root is refused")
do {
    let server = makeServer()
    defer { server.stop() }
    let production = makeStore(server, allowLocalHTTP: false)
    expectCode(runBlocking {
        _ = try await production.store.install(entry(production, "fixture-good"))
    }, "E_INVALID_INPUT", "store without local-HTTP opt-in refuses the test source")

    let paths = makeStore(server)
    try? FileManager.default.removeItem(at: paths.store.layout.staging)
    let outside = scratchRoot.appendingPathComponent("outside-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try! FileManager.default.createSymbolicLink(at: paths.store.layout.staging,
                                                withDestinationURL: outside)
    expectCode(runBlocking { _ = try await paths.store.install(entry(paths, "fixture-good")) },
               "E_INVALID_INPUT", "symlinked .staging is refused")
    let outsideContents = (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []
    check(outsideContents.isEmpty, "nothing was written through the symlink")
}

// MARK: - [9] Real OS leases from child processes

print("\n[9] leases: shared reader, exclusive delete/install, death releases")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let good = entry(paths, "fixture-good")
    _ = runBlocking { _ = try await paths.store.install(good) }
    let lockURL = paths.store.layout.lockURL(model: "fixture-good", version: "1.0.0")

    let (reader, readerPipe) = launchHolder(lockURL.path, exclusive: false)
    check(waitForLocked(readerPipe), "child process holds a real shared flock")
    expectCode(runBlocking { _ = try await paths.store.delete(good, version: "1.0.0") },
               "E_MODEL_LEASED", "delete refuses while a job holds a shared lease")
    expectCode(runBlocking { _ = try await paths.store.install(good) },
               "E_MODEL_LEASED", "install refuses while a reader holds the version")
    let report = try? paths.store.verify(good, version: "1.0.0", full: true)
    check(report?.ok == true, "verify still works under a shared lease")
    reader.terminate()
    reader.waitUntilExit()
    check(reader.isRunning == false, "lease holder exited")
    usleep(100_000)
    switch runBlocking { _ = try await paths.store.delete(good, version: "1.0.0") } {
    case .success: check(true, "death released the OS lease; delete proceeds")
    case .failure(let error): check(false, "death released the OS lease; delete proceeds", "\(error)")
    }

    _ = runBlocking { _ = try await paths.store.install(good) }
    let (writer, writerPipe) = launchHolder(lockURL.path, exclusive: true)
    check(waitForLocked(writerPipe), "child process holds a real exclusive flock")
    expectCode(runBlocking { _ = try paths.store.verify(good, version: "1.0.0", full: true) },
               "E_MODEL_LEASED", "verify needs a shared lease and is refused")
    writer.terminate()
    writer.waitUntilExit()
}

// MARK: - [10] Delete safety

print("\n[10] delete: active pointer removal, quarantine, missing version")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let good = entry(paths, "fixture-good")

    // Delete while a download is in progress: the install holds the version
    // lease, so delete must refuse instead of removing a half-written tree.
    server.serve("/good/payload.bin", "fixture-one\n", delayMicroseconds: 100_000)
    let catalogPath = fixturePath("catalog-valid.json")
    let downloading = launchInstall(catalog: catalogPath, root: paths.root,
                                    id: "fixture-good", base: server.base)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, stagingChildren(paths).isEmpty { usleep(20_000) }
    expectCode(runBlocking { _ = try await paths.store.delete(good, version: "1.0.0") },
               "E_MODEL_LEASED", "delete refuses while a download holds the version")
    kill(downloading.processIdentifier, SIGKILL)
    downloading.waitUntilExit()
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-good", "1.0.0").path), "killed download installed nothing")
    server.serve("/good/payload.bin", "fixture-one\n")

    _ = runBlocking { _ = try await paths.store.install(good) }
    switch runBlocking { _ = try await paths.store.delete(good, version: "1.0.0") } {
    case .success: check(true, "delete of an installed version succeeds")
    case .failure(let error): check(false, "delete of an installed version succeeds", "\(error)")
    }
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-good", "1.0.0").path), "version directory is gone")
    check((try? paths.store.activePointer("fixture-good")) == nil, "active pointer is gone")
    check(quarantineChildren(paths).isEmpty, "quarantine was emptied")
    expectCode(runBlocking { _ = try await paths.store.delete(good, version: "1.0.0") },
               "E_MODEL_MISSING", "deleting a missing version is typed")
}

// MARK: - [11] Update, rollback, and a running job

print("\n[11] update installs beside the old version; rollback switches the pointer")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let v1 = entry(paths, "fixture-good")
    let catalog2 = try! loadFixtureCatalog(path: fixturePath("catalog-fixture-v2.json"),
                                           base: server.base)
    let v2 = catalog2.entry(id: "fixture-good")!
    _ = runBlocking { _ = try await paths.store.install(v1) }
    check((try? paths.store.activePointer("fixture-good"))?.version == "1.0.0",
          "first install is active")

    let v1Lock = paths.store.layout.lockURL(model: "fixture-good", version: "1.0.0")
    let (oldJob, oldJobPipe) = launchHolder(v1Lock.path, exclusive: false)
    check(waitForLocked(oldJobPipe), "a job holds the version it is using")
    _ = runBlocking { _ = try await paths.store.install(v2) }
    check(paths.store.installedVersions(of: v1).count == 2, "update kept both versions")
    check((try? paths.store.activePointer("fixture-good"))?.version == "2.0.0",
          "update switched the pointer while the old version was in use")
    check(FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-good", "1.0.0").path),
        "the running job's files were not moved")
    expectCode(runBlocking { _ = try await paths.store.delete(v1, version: "1.0.0") },
               "E_MODEL_LEASED", "delete of a version in use is refused")
    oldJob.terminate()
    oldJob.waitUntilExit()
    usleep(100_000)

    let v2Lock = paths.store.layout.lockURL(model: "fixture-good", version: "2.0.0")
    let (newJob, newJobPipe) = launchHolder(v2Lock.path, exclusive: false)
    check(waitForLocked(newJobPipe), "a job holds the new version")
    let downloads = server.count()
    _ = runBlocking { _ = try await paths.store.activate(v1, version: "1.0.0") }
    check((try? paths.store.activePointer("fixture-good"))?.version == "1.0.0",
          "rollback works while a job holds another version")
    check(server.count() == downloads, "rollback downloaded nothing")
    check(FileManager.default.fileExists(atPath:
        versionDirectory(paths, "fixture-good", "2.0.0").path),
        "rollback left the running job's version intact")
    newJob.terminate()
    newJob.waitUntilExit()
    usleep(100_000)

    // A corrupt target is never activated.
    _ = runBlocking { _ = try await paths.store.activate(v2, version: "2.0.0") }
    try? Data("corrupt".utf8).write(
        to: versionDirectory(paths, "fixture-good", "1.0.0").appendingPathComponent("payload.bin"))
    expectCode(runBlocking { _ = try await paths.store.activate(v1, version: "1.0.0") },
               "E_MODEL_UNVERIFIED", "rollback refuses a corrupt target")
    check((try? paths.store.activePointer("fixture-good"))?.version == "2.0.0",
          "failed rollback left the pointer on the good version")
}

// MARK: - [12] Two processes, two installs

print("\n[12] two processes installing the same version: one wins, one is leased")
do {
    let server = makeServer()
    defer { server.stop() }
    server.serve("/good/payload.bin", "fixture-one\n", delayMicroseconds: 100_000)
    let paths = makeStore(server)
    let catalogPath = fixturePath("catalog-valid.json")
    let first = launchInstall(catalog: catalogPath, root: paths.root,
                              id: "fixture-good", base: server.base)
    usleep(200_000)
    let second = launchInstall(catalog: catalogPath, root: paths.root,
                               id: "fixture-good", base: server.base)
    first.waitUntilExit()
    second.waitUntilExit()
    let statuses = [first.terminationStatus, second.terminationStatus].sorted()
    check(statuses == [0, 3], "one process installed and the other was refused as leased",
          "\(statuses)")
    let report = try? paths.store.verify(entry(paths, "fixture-good"), version: "1.0.0", full: true)
    check(report?.ok == true, "the winning install is complete and verified")
    check(paths.store.installedVersions(of: entry(paths, "fixture-good")).count == 1,
          "exactly one version directory exists")
    check(stagingChildren(paths).isEmpty, "no staging debris from the losing process")
}

// MARK: - [13] Crash boundaries

print("\n[13] crash injection at verification, rename, pointer removal and download")
do {
    let server = makeServer()
    defer { server.stop() }
    let catalogPath = fixturePath("catalog-valid.json")

    // Crash after verification, before the atomic rename.
    let a = makeStore(server)
    let crashA = launchInstall(catalog: catalogPath, root: a.root,
                               id: "fixture-good", base: server.base, crash: "after-verify")
    crashA.waitUntilExit()
    check(crashA.terminationStatus == 86, "child died after verification",
          "status \(crashA.terminationStatus)")
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(a, "fixture-good", "1.0.0").path), "no version before the rename")
    check(stagingChildren(a).count == 1, "the verified staging tree survived the crash")
    switch runBlocking { _ = try await a.store.install(entry(a, "fixture-good")) } {
    case .success: check(true, "restart after the crash installs and activates")
    case .failure(let error): check(false, "restart after the crash installs and activates", "\(error)")
    }
    check((try? a.store.activePointer("fixture-good"))?.version == "1.0.0",
          "restart repaired the missing pointer")
    for child in stagingChildren(a) {
        age(a.store.layout.staging.appendingPathComponent(child), by: 90000)
    }
    _ = a.store.cleanup(now: Date().addingTimeInterval(2 * 3600))
    check(stagingChildren(a).isEmpty, "aged crash staging is reclaimed")
    check(FileManager.default.fileExists(atPath:
        versionDirectory(a, "fixture-good", "1.0.0").path), "cleanup left the installed version")

    // Crash after rename, before the pointer.
    let b = makeStore(server)
    let crashB = launchInstall(catalog: catalogPath, root: b.root,
                               id: "fixture-good", base: server.base, crash: "after-rename")
    crashB.waitUntilExit()
    check(crashB.terminationStatus == 86, "child died after the rename",
          "status \(crashB.terminationStatus)")
    check(FileManager.default.fileExists(atPath:
        versionDirectory(b, "fixture-good", "1.0.0").path), "version directory survived")
    check((try? b.store.activePointer("fixture-good")) == nil, "pointer was not written")
    let recordB = b.store.records().first { $0.id == "fixture-good" }!
    check(recordB.versions.count == 1 && recordB.activeVersion == nil,
          "snapshot shows the inactive version")
    let downloadsB = server.count()
    switch runBlocking { _ = try await b.store.install(entry(b, "fixture-good")) } {
    case .success: check(true, "restart verifies and activates the orphaned version")
    case .failure(let error): check(false, "restart verifies and activates the orphaned version", "\(error)")
    }
    check(server.count() == downloadsB, "restart used the verified files, not the network",
          "\(server.count() - downloadsB) requests")

    // Crash after pointer removal, before quarantine.
    let c = makeStore(server)
    _ = runBlocking { _ = try await c.store.install(entry(c, "fixture-good")) }
    let crashC = runChild(["--delete-once", catalogPath, c.root.path, "fixture-good",
                           "1.0.0", server.base],
                          environment: ["RETOUCH_MODEL_TEST_CRASH": "after-pointer-removal"])
    check(crashC.status == 86, "delete child died after removing the pointer", crashC.output)
    check((try? c.store.activePointer("fixture-good")) == nil, "pointer is gone")
    check(FileManager.default.fileExists(atPath:
        versionDirectory(c, "fixture-good", "1.0.0").path), "files survived the delete crash")
    switch runBlocking { _ = try await c.store.delete(entry(c, "fixture-good"), version: "1.0.0") } {
    case .success: check(true, "a repeated delete completes the interrupted one")
    case .failure(let error): check(false, "a repeated delete completes the interrupted one", "\(error)")
    }

    // Kill during download: partial staging, no manifest.
    let d = makeStore(server)
    server.serve("/good/payload.bin", "fixture-one\n", delayMicroseconds: 200_000)
    let slow = launchInstall(catalog: catalogPath, root: d.root,
                             id: "fixture-good", base: server.base)
    let stagingDeadline = Date().addingTimeInterval(10)
    while Date() < stagingDeadline, stagingChildren(d).isEmpty { usleep(20_000) }
    usleep(300_000)
    kill(slow.processIdentifier, SIGKILL)
    slow.waitUntilExit()
    check(!FileManager.default.fileExists(atPath:
        versionDirectory(d, "fixture-good", "1.0.0").path), "killed download installed nothing")
    let debris = stagingChildren(d)
    check(!debris.isEmpty, "killed download left staging", "\(debris.count)")
    for child in debris {
        age(d.store.layout.staging.appendingPathComponent(child), by: 90000)
    }
    _ = d.store.cleanup(now: Date().addingTimeInterval(2 * 3600))
    check(stagingChildren(d).isEmpty, "cleanup removed identity-less stale staging")
    server.serve("/good/payload.bin", "fixture-one\n")
    switch runBlocking { _ = try await d.store.install(entry(d, "fixture-good")) } {
    case .success: check(true, "a fresh install succeeds after the killed one")
    case .failure(let error): check(false, "a fresh install succeeds after the killed one", "\(error)")
    }
}

// MARK: - [14] Cleanup rules

print("\n[14] cleanup: grace period, live lock, unidentifiable trees")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let staging = paths.store.layout.staging
    let young = staging.appendingPathComponent("young-\(UUID().uuidString)")
    writeManifest(in: young, model: "fixture-good", version: "0.7.0")
    let stale = staging.appendingPathComponent("stale-\(UUID().uuidString)")
    writeManifest(in: stale, model: "fixture-good", version: "0.9.0")
    age(stale, by: 90000)
    let unreadable = staging.appendingPathComponent("no-manifest-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    age(unreadable, by: 90000)
    let locked = staging.appendingPathComponent("locked-\(UUID().uuidString)")
    writeManifest(in: locked, model: "fixture-good", version: "9.9.0")
    age(locked, by: 90000)
    let staleLock = staging.appendingPathComponent("stale-lock-\(UUID().uuidString)")
    writeManifest(in: staleLock, model: "fixture-good", version: "0.6.0")
    age(staleLock, by: 90000)
    let staleLockFile = try! LockFile.open(
        paths.store.layout.lockURL(model: "fixture-good", version: "0.6.0"))
    staleLockFile.close()
    writeManifest(in: paths.store.layout.quarantine.appendingPathComponent("quarantine-1"),
                  model: "fixture-good", version: "0.8.0")
    age(paths.store.layout.quarantine.appendingPathComponent("quarantine-1"), by: 90000)
    let unknownQuarantine = paths.store.layout.quarantine
        .appendingPathComponent("unknown-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: unknownQuarantine, withIntermediateDirectories: true)
    age(unknownQuarantine, by: 90000)

    let lockURL = paths.store.layout.lockURL(model: "fixture-good", version: "9.9.0")
    let (holder, holderPipe) = launchHolder(lockURL.path, exclusive: true)
    check(waitForLocked(holderPipe), "cleanup test holds a real lease")
    let future = Date().addingTimeInterval(2 * 3600)
    let decisions = paths.store.cleanup(now: future)
    check(FileManager.default.fileExists(atPath: young.path), "young staging is kept")
    check(!FileManager.default.fileExists(atPath: stale.path), "stale identified staging is removed")
    check(!FileManager.default.fileExists(atPath: unreadable.path),
          "stale identity-less staging is removed when no install holds the gate")
    check(FileManager.default.fileExists(atPath: locked.path), "stale staging under a live lease is kept")
    check(!FileManager.default.fileExists(atPath: staleLock.path),
          "stale staging whose lock file is no longer held is removed")
    check(!FileManager.default.fileExists(atPath:
        paths.store.layout.quarantine.appendingPathComponent("quarantine-1").path),
        "older identified quarantine is removed")
    check(FileManager.default.fileExists(atPath: unknownQuarantine.path),
          "quarantine without identity is kept")
    check(decisions.contains { $0.action == "keep" && $0.reason.contains("live lease") },
          "a live-lease decision is recorded")
    holder.terminate()
    holder.waitUntilExit()
}

// MARK: - [15] Pointer atomicity and dangling pointers

print("\n[15] pointer replacement is atomic; dangling pointers are not active")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let v1 = entry(paths, "fixture-good")
    let v2 = try! loadFixtureCatalog(path: fixturePath("catalog-fixture-v2.json"),
                                     base: server.base).entry(id: "fixture-good")!
    _ = runBlocking { _ = try await paths.store.install(v1) }
    _ = runBlocking { _ = try await paths.store.install(v2) }
    DispatchQueue.concurrentPerform(iterations: 40) { index in
        _ = runBlocking {
            if index % 2 == 0 { try paths.store.activate(v1, version: "1.0.0") }
            else { try paths.store.activate(v2, version: "2.0.0") }
        }
    }
    let pointerData = try! Data(contentsOf: paths.store.layout.activeURL("fixture-good"))
    let pointer = try? JSONDecoder().decode(ModelActivePointer.self, from: pointerData)
    check(pointer != nil && ["1.0.0", "2.0.0"].contains(pointer!.version),
          "concurrent pointer writes leave one valid pointer", pointer?.version ?? "invalid")
    let leftovers = (try? FileManager.default.contentsOfDirectory(
        atPath: paths.store.layout.modelDirectory("fixture-good").path))?
        .filter { $0.contains(".active.json.") && $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "atomic pointer writes leave no temporary files", "\(leftovers)")

    let pointerURL = paths.store.layout.activeURL("fixture-good")
    let dangling = ModelActivePointer(schema: ModelActivePointer.schemaName,
                                      modelId: "fixture-good", version: "9.9.9",
                                      manifestSha256: "0", activatedAt: 0)
    try! JSONEncoder().encode(dangling).write(to: pointerURL)
    let record = paths.store.records().first { $0.id == "fixture-good" }!
    check(record.activeVersion == nil, "a dangling pointer is not reported as active")
    switch runBlocking { _ = try await paths.store.install(v1) } {
    case .success: check(true, "installing an existing version repairs the pointer")
    case .failure(let error): check(false, "installing an existing version repairs the pointer", "\(error)")
    }
}

// MARK: - [16] Legacy flat migration

print("\n[16] verified flat installs are adopted without network")
do {
    let server = makeServer()
    defer { server.stop() }
    let paths = makeStore(server)
    let good = entry(paths, "fixture-good")
    let flat = paths.store.layout.modelDirectory("fixture-good")
    try! FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
    try! Data("fixture-one\n".utf8).write(to: flat.appendingPathComponent("payload.bin"))
    check(paths.store.legacyBytes(good) == 12, "legacy bytes are detected")
    check(server.count() == 0, "detection made no request")
    switch runBlocking { _ = try await paths.store.migrateLegacy(good) } {
    case .success: check(true, "legacy files are adopted")
    case .failure(let error): check(false, "legacy files are adopted", "\(error)")
    }
    check(server.count() == 0, "adoption used hashes, not the network")
    check(!FileManager.default.fileExists(atPath: flat.appendingPathComponent("payload.bin").path),
          "flat file was moved")
    check((try? paths.store.activePointer("fixture-good"))?.version == "1.0.0",
          "adopted version is active")
    check((try! paths.store.verify(good, version: "1.0.0", full: true)).ok,
          "adopted version verifies")

    let badRoot = makeStore(server)
    let badFlat = badRoot.store.layout.modelDirectory("fixture-good")
    try! FileManager.default.createDirectory(at: badFlat, withIntermediateDirectories: true)
    try! Data("different\n".utf8).write(to: badFlat.appendingPathComponent("payload.bin"))
    expectCode(runBlocking { _ = try await badRoot.store.migrateLegacy(entry(badRoot, "fixture-good")) },
               "E_MODEL_UNVERIFIED", "a mismatching flat file is not adopted")
    check(FileManager.default.fileExists(atPath: badFlat.appendingPathComponent("payload.bin").path),
          "the mismatching file stayed where it was")
}

// MARK: - [17] Worker resolution and shared leases (Python)

print("\n[17] worker resolves active.json and honours the same OS lease")
do {
    let server = makeServer()
    defer { server.stop() }
    let python = [
        ProcessInfo.processInfo.environment["RETOUCH_WORKER_PYTHON"],
        testsRoot.appendingPathComponent("worker/.venv/bin/python3").path,
        "/usr/bin/python3",
    ].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    if let python {
        let paths = makeStore(server)
        let good = entry(paths, "fixture-good")
        _ = runBlocking { _ = try await paths.store.install(good) }

        // migan is in the real worker catalog; give it a version-scoped file.
        let miganRoot = scratchRoot.appendingPathComponent(UUID().uuidString)
        let versionDir = miganRoot.appendingPathComponent("migan/9.9.9")
        try! FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        writeSizedFixture(at: versionDir.appendingPathComponent("migan_pipeline_v2.onnx"),
                          bytes: 28_079_181)
        let pointer = ModelActivePointer(schema: ModelActivePointer.schemaName,
                                         modelId: "migan", version: "9.9.9",
                                         manifestSha256: "0", activatedAt: 0)
        try! JSONEncoder().encode(pointer).write(
            to: miganRoot.appendingPathComponent("migan/active.json"))

        let script = """
        import sys
        sys.path.insert(0, sys.argv[1])
        from retouch_ai_worker.catalog import Catalog
        catalog = Catalog(__import__("pathlib").Path(sys.argv[2]))
        print(catalog.require("migan"))
        """
        let workerPath = testsRoot.appendingPathComponent("worker").path
        func workerRequire(_ root: URL) -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", script, workerPath, root.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try! process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        let versioned = workerRequire(miganRoot)
        check(versioned.0 == 0 && versioned.1.contains("migan/9.9.9"),
              "worker loads the active version directory", versioned.1.trimmingCharacters(in: .whitespacesAndNewlines))

        let legacyRoot = scratchRoot.appendingPathComponent(UUID().uuidString)
        let legacyDir = legacyRoot.appendingPathComponent("migan")
        try! FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        writeSizedFixture(at: legacyDir.appendingPathComponent("migan_pipeline_v2.onnx"),
                         bytes: 28_079_181)
        let legacy = workerRequire(legacyRoot)
        check(legacy.0 == 0, "worker still reads a legacy flat install", legacy.1)

        let lockURL = miganRoot.appendingPathComponent(".locks/migan-9.9.9")
        let (holder, holderPipe) = launchHolder(lockURL.path, exclusive: true)
        check(waitForLocked(holderPipe), "an install holds the exclusive worker lease")
        let leased = workerRequire(miganRoot)
        check(leased.0 != 0 && leased.1.contains("leased"),
              "worker refuses a model while an install holds it", leased.1)
        holder.terminate()
        holder.waitUntilExit()
        usleep(100_000)
        let after = workerRequire(miganRoot)
        check(after.0 == 0, "worker loads after the install releases the lease", after.1)
    } else {
        check(false, "python3 is available for the worker conformance test")
    }
}

// MARK: - [18] Legacy flat lease across worker and adoption

print("\n[18] legacy flat installs share one lease with adoption")
if let python = workerPython() {
    let zeroSha = "6accd17d25cf8d01b9f12d06a0c9d40e1f7ef75bf42d49b31690c91f3355a046"
    let manifestSha = String(repeating: "0", count: 64)
    let json = """
    {"schema":"retouchstudio.model-catalog/1","catalogVersion":"fixture-legacy",
     "entries":[{"id":"migan","name":"migan legacy fixture",
     "capabilities":["inpaint"],"version":"1.0.0","format":"fixture",
     "files":[{"path":"migan_pipeline_v2.onnx","sizeBytes":28079181,"sha256":"\(zeroSha)",
     "sourceUrl":"https://example.com/migan_pipeline_v2.onnx"}],
     "sizeBytes":28079181,"sha256":"\(manifestSha)","sourceUrl":"https://example.com/migan",
     "codeLicense":"MIT","weightsLicense":"MIT",
     "licenseEvidenceUrl":"https://example.com/migan",
     "platforms":["macos-arm64"],"requiredProvider":"cpu",
     "minimumContractVersion":"1","preprocess":{"id":"fixture","version":"1"},
     "deterministic":true,"notes":"fixture"}]}
    """
    let legacyCatalog = try! ModelCatalog.load(data: Data(json.utf8))
    let workerPath = testsRoot.appendingPathComponent("worker").path

    func makeLegacyStore() -> (store: ModelStore, root: URL) {
        let root = scratchRoot.appendingPathComponent(UUID().uuidString)
        let flat = root.appendingPathComponent("migan")
        try! FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        writeSizedFixture(at: flat.appendingPathComponent("migan_pipeline_v2.onnx"),
                          bytes: 28_079_181)
        return (ModelStore(root: root, catalog: legacyCatalog, platform: "macos-arm64"), root)
    }

    func launchWorker(_ root: URL, sleepAfterLoad: Bool) -> (Process, Pipe) {
        let script = sleepAfterLoad ? """
        import sys, time
        sys.path.insert(0, sys.argv[1])
        from pathlib import Path
        from retouch_ai_worker.catalog import Catalog
        print(Catalog(Path(sys.argv[2])).require("migan"), flush=True)
        time.sleep(60)
        """ : """
        import sys
        sys.path.insert(0, sys.argv[1])
        from pathlib import Path
        from retouch_ai_worker.catalog import Catalog
        print(Catalog(Path(sys.argv[2])).require("migan"), flush=True)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", script, workerPath, root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        return (process, pipe)
    }

    func workerRequire(_ root: URL) -> (Int32, String) {
        let (process, pipe) = launchWorker(root, sleepAfterLoad: false)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // Resolves the layout first and prints it, so the test can prove the
    // worker saw the flat path and still ended up on the active version.
    func launchRaceWorker(_ root: URL) -> (Process, Pipe) {
        let script = """
        import sys, json
        sys.path.insert(0, sys.argv[1])
        from pathlib import Path
        from retouch_ai_worker.catalog import Catalog, resolve_model_root
        from retouch_ai_worker.protocol import WorkerError
        root = Path(sys.argv[2])
        print("resolved:" + str(resolve_model_root(root, "migan")), flush=True)
        print("waiting", flush=True)
        try:
            print("loaded:" + str(Catalog(root).require("migan")), flush=True)
        except WorkerError as error:
            print("error:" + json.dumps({"code": error.code, "data": error.data}),
                  flush=True)
            raise SystemExit(3)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", script, workerPath, root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        return (process, pipe)
    }

    // Runs require and prints its typed error instead of a traceback, so the
    // test asserts the JSON-RPC code the host would actually receive.
    func workerErrorCode(_ root: URL) -> (Int32, String) {
        let script = """
        import sys, json
        sys.path.insert(0, sys.argv[1])
        from pathlib import Path
        from retouch_ai_worker.catalog import Catalog
        from retouch_ai_worker.protocol import WorkerError
        try:
            Catalog(Path(sys.argv[2])).require("migan")
        except WorkerError as error:
            print("error:" + json.dumps({"code": error.code, "data": error.data}),
                  flush=True)
            raise SystemExit(3)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", script, workerPath, root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // A running worker holds the shared flat lease; adoption must refuse.
    let (store, root) = makeLegacyStore()
    let legacyEntry = legacyCatalog.entry(id: "migan")!
    let (worker, workerPipe) = launchWorker(root, sleepAfterLoad: true)
    check(waitForLine(workerPipe, containing: "migan"),
          "the worker loads a legacy flat model")
    expectCode(runBlocking { _ = try await store.migrateLegacy(legacyEntry) },
               "E_MODEL_LEASED",
               "adoption refuses while the worker holds the flat lease")
    let flatFile = root.appendingPathComponent("migan/migan_pipeline_v2.onnx")
    check(FileManager.default.fileExists(atPath: flatFile.path),
          "a refused adoption leaves the flat file intact")
    check(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("migan/1.0.0").path),
          "a refused adoption publishes no version")

    // Killing the worker releases the kernel lease; adoption then succeeds.
    worker.terminate()
    worker.waitUntilExit()
    usleep(150_000)
    switch runBlocking { _ = try await store.migrateLegacy(legacyEntry) } {
    case .success: check(true, "adoption succeeds after the worker dies")
    case .failure(let error):
        check(false, "adoption succeeds after the worker dies", "\(error)")
    }
    check((try? store.activePointer("migan"))?.version == "1.0.0",
          "the adopted flat install became active")
    check(!FileManager.default.fileExists(atPath: flatFile.path),
          "the adopted file left the flat layout")
    check(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("migan/1.0.0/migan_pipeline_v2.onnx").path),
          "the adopted file is in the version directory")

    // Adoption holds the exclusive flat lease while hashing. A worker that
    // already resolved the flat layout waits on the lease; when adoption
    // finishes, the worker must follow the new pointer, not its stale path.
    let (raceStore, raceRoot) = makeLegacyStore()
    let raceEntry = legacyCatalog.entry(id: "migan")!
    let hashing = DispatchSemaphore(value: 0)
    let allowMove = DispatchSemaphore(value: 0)
    let adoptionDone = DispatchSemaphore(value: 0)
    var raceResult: Result<ModelVersionState, Error>?
    DispatchQueue.global().async {
        raceResult = runBlocking {
            try await raceStore.migrateLegacy(raceEntry) { progress in
                if progress.fileIndex == 1 {
                    hashing.signal()
                    _ = allowMove.wait(timeout: .now() + 10)
                }
            }
        }
        adoptionDone.signal()
    }
    check(hashing.wait(timeout: .now() + 10) == .success,
          "adoption holds the exclusive flat lease before moving files")
    let (raceWorker, racePipe) = launchRaceWorker(raceRoot)
    let resolvedLine = readLine(racePipe) ?? ""
    let waitingLine = readLine(racePipe) ?? ""
    check(resolvedLine.hasSuffix("/migan"),
          "the worker resolved the flat layout before adoption moved it", resolvedLine)
    check(waitingLine == "waiting", "the worker is waiting for the flat lease",
          waitingLine)
    allowMove.signal()
    check(adoptionDone.wait(timeout: .now() + 10) == .success,
          "adoption finished while the worker waited")
    let raceTail = String(data: racePipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
    raceWorker.waitUntilExit()
    switch raceResult {
    case .success: check(true, "the race adoption completed")
    case .failure(let error): check(false, "the race adoption completed", "\(error)")
    case nil: check(false, "the race adoption completed", "no result")
    }
    check(raceWorker.terminationStatus == 0 && raceTail.contains("/migan/1.0.0"),
          "the worker used the active version, not its stale flat path", raceTail)
    check(!raceTail.contains("error:"),
          "the worker did not report a missing model", raceTail)
    check((try? raceStore.activePointer("migan"))?.version == "1.0.0",
          "the race adoption became active")

    // Adoption holds the exclusive flat lease; the worker must refuse with a
    // typed retryable error rather than "model missing".
    let (secondStore, secondRoot) = makeLegacyStore()
    let secondEntry = legacyCatalog.entry(id: "migan")!
    let exclusive = try! ModelLease.acquireLegacy(store: secondStore, model: "migan",
                                                  exclusive: true)
    let refused = workerErrorCode(secondRoot)
    var refusedCode: Int?
    var refusedReason: String?
    if let line = refused.1.split(separator: "\n").first(where: { $0.hasPrefix("error:") }),
       let data = String(line.dropFirst("error:".count)).data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        refusedCode = object["code"] as? Int
        refusedReason = (object["data"] as? [String: Any])?["reason"] as? String
    }
    check(refused.0 == 3 && refusedCode == -32012 && refusedReason == "leased",
          "the worker reports retryable busy, not a missing model", refused.1)
    check(FileManager.default.fileExists(
            atPath: secondRoot.appendingPathComponent("migan/migan_pipeline_v2.onnx").path),
          "the refused worker left the flat file intact")
    exclusive.release()
    let allowed = workerRequire(secondRoot)
    check(allowed.0 == 0, "the worker loads after adoption releases the flat lease",
          allowed.1)
    switch runBlocking { _ = try await secondStore.migrateLegacy(secondEntry) } {
    case .success: check(true, "adoption succeeds after the worker exits")
    case .failure(let error):
        check(false, "adoption succeeds after the worker exits", "\(error)")
    }
} else {
    check(false, "python3 is available for the legacy lease test")
}

print("\n\(failures.isEmpty ? "✓ all model-store checks passed" : "✗ \(failures.count) checks failed")")
if !failures.isEmpty {
    for failure in failures { print("  ✗ \(failure)") }
    print("MODEL STORE TESTS: FAIL (\(failures.count))")
    exit(1)
}
print("MODEL STORE TESTS: PASS")
exit(0)
