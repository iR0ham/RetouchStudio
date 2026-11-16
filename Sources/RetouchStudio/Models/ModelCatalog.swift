import Foundation

/// The bundled model catalog: data, never a remote feed.
///
/// An entry is installable only when every file records an exact size and
/// SHA-256 and the entry carries no `unverifiableReason` (DR-5). The catalog
/// itself is validated before any entry is used, because a malformed path or
/// an unsafe source URL must never reach the downloader.
struct ModelCatalog: Decodable, Equatable {
    let schema: String
    let catalogVersion: String
    let entries: [ModelCatalogEntry]

    static let schemaName = "retouchstudio.model-catalog/1"

    enum LoadError: Error, CustomStringConvertible, Equatable {
        case missing
        case unreadable(String)
        case unsupportedSchema(String)
        case duplicateID(String)
        case unsafe(String)

        var description: String {
            switch self {
            case .missing: return "the bundled model catalog is missing"
            case .unreadable(let detail): return "the model catalog is unreadable: \(detail)"
            case .unsupportedSchema(let schema): return "unsupported model catalog schema \(schema)"
            case .duplicateID(let id): return "the model catalog lists \(id) twice"
            case .unsafe(let detail): return "the model catalog is unsafe: \(detail)"
            }
        }
    }

    static func load(data: Data, allowLocalHTTP: Bool = false) throws -> ModelCatalog {
        let catalog: ModelCatalog
        do {
            catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        guard catalog.schema == schemaName else {
            throw LoadError.unsupportedSchema(catalog.schema)
        }
        var seen = Set<String>()
        for entry in catalog.entries {
            guard seen.insert(entry.id).inserted else {
                throw LoadError.duplicateID(entry.id)
            }
            try entry.validate(allowLocalHTTP: allowLocalHTTP)
        }
        return catalog
    }

    static func load(url: URL, allowLocalHTTP: Bool = false) throws -> ModelCatalog {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missing }
        return try load(data: data, allowLocalHTTP: allowLocalHTTP)
    }

    /// The app bundle copy. Tests and installed builds pass an explicit URL
    /// instead; this is only the shipped lookup.
    static func bundled() throws -> ModelCatalog {
        let candidates = [
            Bundle.main.url(forResource: "model-catalog", withExtension: "json"),
            Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources/model-catalog.json"),
            Bundle.main.resourceURL?.appendingPathComponent("model-catalog.json"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try load(url: url)
        }
        throw LoadError.missing
    }

    func entry(id: String) -> ModelCatalogEntry? {
        entries.first { $0.id == id }
    }
}

struct ModelPreprocess: Codable, Equatable {
    let id: String
    let version: String
}

struct ModelCatalogFile: Codable, Equatable {
    let path: String
    let sizeBytes: Int?
    let sha256: String?
    let sourceUrl: String

    var isVerifiable: Bool {
        guard let sizeBytes, sizeBytes > 0, let sha256 else { return false }
        return sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
    }
}

struct ModelCatalogEntry: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let capabilities: [String]
    let version: String
    let format: String
    let files: [ModelCatalogFile]
    let sizeBytes: Int?
    let sha256: String?
    let sourceUrl: String
    let codeLicense: String
    let weightsLicense: String
    let licenseEvidenceUrl: String
    let platforms: [String]
    let requiredProvider: String
    let minimumContractVersion: String
    let preprocess: ModelPreprocess
    let deterministic: Bool
    let notes: String
    let unverifiableReason: String?

    var isVerifiable: Bool {
        guard unverifiableReason == nil,
              let sizeBytes, sizeBytes > 0,
              let sha256, sha256.count == 64,
              !files.isEmpty else { return false }
        return files.allSatisfy(\.isVerifiable)
    }

    var verificationProblem: String? {
        if let unverifiableReason { return unverifiableReason }
        if files.isEmpty { return "the catalog entry lists no files" }
        if sizeBytes == nil || sha256 == nil {
            return "the catalog entry has no total size or manifest SHA-256"
        }
        if let file = files.first(where: { !$0.isVerifiable }) {
            return "\(file.path) has no exact size or SHA-256"
        }
        return nil
    }

    func supports(platform: String) -> Bool {
        platforms.contains(platform)
    }

    func validate(allowLocalHTTP: Bool = false) throws {
        try Self.requireComponent(id, field: "id")
        try Self.requireComponent(version, field: "version")
        guard !name.isEmpty else {
            throw ModelCatalog.LoadError.unsafe("\(id) has no display name")
        }
        guard capabilities.allSatisfy(Self.isCapabilityIdentifier) else {
            throw ModelCatalog.LoadError.unsafe("\(id) has an invalid capability id")
        }
        guard Self.isAllowedSource(sourceUrl, allowLocalHTTP: allowLocalHTTP),
              let entryURL = URL(string: sourceUrl), entryURL.host != nil else {
            throw ModelCatalog.LoadError.unsafe("\(id) has a non-HTTPS source")
        }
        for file in files {
            try Self.requireFileComponent(file.path, model: id)
            guard Self.isRecordedFileSource(file.sourceUrl, entrySource: sourceUrl,
                                            allowLocalHTTP: allowLocalHTTP) else {
                throw ModelCatalog.LoadError.unsafe(
                    "\(id)/\(file.path) does not come from the recorded HTTPS source")
            }
        }
        if unverifiableReason == nil,
           let sizeBytes, sizeBytes > 0,
           files.allSatisfy({ $0.sizeBytes != nil }),
           files.reduce(0, { $0 + ($1.sizeBytes ?? 0) }) != sizeBytes {
            throw ModelCatalog.LoadError.unsafe("\(id) total size does not match its files")
        }
    }

    /// Production accepts HTTPS on its default port only. A test may opt into
    /// loopback HTTP; that exception also covers the ephemeral port a local
    /// fixture server listens on. A non-default port is never accepted in
    /// production, even on loopback.
    static func isAllowedSource(_ url: String, allowLocalHTTP: Bool) -> Bool {
        guard let parsed = URL(string: url), let host = parsed.host, !host.isEmpty,
              parsed.user == nil, parsed.password == nil, parsed.fragment == nil else {
            return false
        }
        switch parsed.scheme?.lowercased() {
        case "https": break
        case "http" where allowLocalHTTP && isLoopback(parsed): break
        default: return false
        }
        return isAllowedPort(parsed, allowLocalHTTP: allowLocalHTTP)
    }

    static func isAllowedPort(_ url: URL, allowLocalHTTP: Bool) -> Bool {
        guard let port = url.port else { return true }
        if url.scheme?.lowercased() == "https" && port == 443 { return true }
        return allowLocalHTTP && isLoopback(url)
    }

    /// A file must come from the entry's recorded source: same scheme, same
    /// host, and the same port rules. A redirect cannot change any of these.
    static func isRecordedFileSource(_ url: String, entrySource: String,
                                     allowLocalHTTP: Bool) -> Bool {
        guard isAllowedSource(url, allowLocalHTTP: allowLocalHTTP),
              isAllowedSource(entrySource, allowLocalHTTP: allowLocalHTTP),
              let fileURL = URL(string: url), let recordedURL = URL(string: entrySource),
              let fileHost = fileURL.host, let recordedHost = recordedURL.host,
              fileHost.caseInsensitiveCompare(recordedHost) == .orderedSame,
              fileURL.scheme?.lowercased() == recordedURL.scheme?.lowercased()
        else { return false }
        return true
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    /// Model ids and versions become path components; anything outside a
    /// conservative alphabet is rejected instead of being escaped.
    static func requireComponent(_ value: String, field: String) throws {
        guard !value.isEmpty, value != ".", value != "..",
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber
                                                || $0 == "-" || $0 == "_" || $0 == ".") })
        else {
            throw ModelCatalog.LoadError.unsafe("invalid \(field) \(value.debugDescription)")
        }
    }

    /// A file path may contain subdirectories but never an absolute path, a
    /// backslash, an empty component or a traversal component.
    static func requireFileComponent(_ path: String, model: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw ModelCatalog.LoadError.unsafe("\(model) has an unsafe file path")
        }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part != ".", part != "..",
                  part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber
                                                    || $0 == "-" || $0 == "_" || $0 == ".") })
            else {
                throw ModelCatalog.LoadError.unsafe("\(model) has an unsafe file path")
            }
        }
    }

    static func isCapabilityIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
        }
    }
}

enum ModelPlatform {
    static var current: String {
        #if arch(arm64)
        return "macos-arm64"
        #else
        return "macos-x64"
        #endif
    }
}
