import CryptoKit
import Foundation

/// The optional local-AI runtime. A light release ships the editor alone and
/// fetches this archive only when the owner asks for AI; a full build carries
/// the same runtime inside the app bundle instead.
enum AIRuntime {

    struct Package: Equatable {
        let version: String
        let fileName: String
        let url: URL
        let bytes: Int64
        let sha256: String

        var hashPrefix: String {
            String(sha256.prefix(16)) + "…"
        }
    }

    private static let RUNTIME_BYTES: Int64 = 388_277_063
    private static let RUNTIME_SHA256 =
        "cb1485beecad1bb947f5e3e2e056b0a2783816522c6e6ba90ed25cf069dddcfd"

    /// The helper is an Apple-silicon runtime, so Intel builds have no package.
    static var package: Package? {
        #if arch(x86_64)
        return nil
        #else
        if let override = overridePackage { return override }
        return Package(
            version: "1.0.0",
            fileName: "RetouchStudio-1.0.0-ai-runtime-arm64.zip",
            url: URL(string: "https://github.com/iR0ham/RetouchStudio/releases/download/v1.0.0/RetouchStudio-1.0.0-ai-runtime-arm64.zip")!,
            bytes: RUNTIME_BYTES,
            sha256: RUNTIME_SHA256)
        #endif
    }

    /// QA hook: a local server can stand in for the release asset, so the
    /// download, checksum and extraction path is testable without the network.
    private static var overridePackage: Package? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["RETOUCH_AI_RUNTIME_URL"],
              let url = URL(string: raw) else { return nil }
        guard let sha = environment["RETOUCH_AI_RUNTIME_SHA256"], !sha.isEmpty else { return nil }
        return Package(
            version: environment["RETOUCH_AI_RUNTIME_VERSION"] ?? "test",
            fileName: url.lastPathComponent,
            url: url,
            bytes: Int64(environment["RETOUCH_AI_RUNTIME_BYTES"] ?? "") ?? 0,
            sha256: sha.lowercased())
    }

    static var installDirectory: URL {
        AIWorker.supportDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    static var isInstalled: Bool {
        package != nil && isValid(root: installDirectory)
    }

    static func isValid(root: URL) -> Bool {
        let manager = FileManager.default
        let python = root.appendingPathComponent("bin/python3")
        let worker = root.appendingPathComponent("retouch_ai_worker", isDirectory: true)
        return manager.isExecutableFile(atPath: python.path)
            && manager.fileExists(atPath: worker.path)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts into Application Support, validates the layout, and only then
    /// replaces the installed copy, so a failed unzip never leaves a broken
    /// runtime behind.
    static func install(archive: URL) throws {
        let manager = FileManager.default
        let support = AIWorker.supportDirectory
        try manager.createDirectory(at: support, withIntermediateDirectories: true)

        let staging = support.appendingPathComponent(
            "runtime-installing-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, isValid(root: staging) else {
            throw AIRuntimeFailure(code: .extract)
        }

        if manager.fileExists(atPath: installDirectory.path) {
            try manager.removeItem(at: installDirectory)
        }
        try manager.moveItem(at: staging, to: installDirectory)
    }
}

struct AIRuntimeFailure: LocalizedError {
    enum Kind {
        case extract
        case checksum
    }

    let code: Kind

    var errorDescription: String? {
        switch code {
        case .checksum: return L10n.current.aiRuntimeChecksumFailed
        case .extract: return L10n.current.aiRuntimeExtractFailed
        }
    }
}
