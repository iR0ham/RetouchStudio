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
    /// The closed set of release verdicts a licence dossier can assign.
    ///
    /// A verdict is recorded evidence, never a gate: nothing in this version of
    /// the codebase branches on it. Keeping it an enum rather than a free-text
    /// string is what makes a later reviewed change able to trust the field.
    enum ModelLicenseVerdict: String, Codable, Equatable {
        case usable
        case usableWithConditions = "usable-with-conditions"
        case excluded
    }

    /// Where a licence claim came from, as delivered by the model licence
    /// dossier.
    ///
    /// Every field is optional in the Codable representation for two reasons:
    /// `ModelCatalog.load` decodes with a strict `JSONDecoder`, so a required
    /// key would make every older catalog file unreadable; and a fact that has
    /// not been confirmed must be stored as absent rather than guessed at. A
    /// value that was inferred from a repository-level tag instead of being
    /// stated about the weights keeps `explicit == false`, which is the whole
    /// point of the field.
    struct WeightsLicenseEvidence: Codable, Equatable {
        /// URL of the grant itself, which may differ from the entry's
        /// `licenseEvidenceUrl` when the author ships a dedicated file.
        let licenseUrl: String?
        /// ISO-8601 calendar date the grant was actually read. Never defaulted:
        /// a stamp invented here would defeat rot detection.
        let readOn: String?
        /// Did the author state the grant *about the weights*?
        let explicit: Bool?
        let commercialOk: Bool?
        /// Attribution that would have to be reproduced if a file were ever
        /// mirrored or bundled.
        let noticeText: String?
        let verdict: ModelLicenseVerdict?
        let verdictReason: String?
        /// Dataset provenance statement, or nil when it is not confirmed.
        let datasetNote: String?
        /// The verdict exactly as written in the file, so `validate()` can
        /// reject a word outside the closed set instead of dropping it. Only the
        /// flat spelling can carry a word here that `verdict` refused to parse;
        /// a nested record keeps the two in step by construction.
        let verdictRaw: String?
        /// Set only when the file spells the grant with the flat top-level keys
        /// instead of the nested object. It exists to carry those values into
        /// `init(from:)`; no production catalog writes it, and encoding omits it.
        let flatSpelling: Bool?

        enum CodingKeys: String, CodingKey {
            case licenseUrl
            case readOn
            case explicit
            case commercialOk
            case noticeText
            case verdict
            case verdictReason
            case datasetNote
        }

        init(licenseUrl: String?, readOn: String?, explicit: Bool?, commercialOk: Bool?,
             noticeText: String?, verdict: ModelLicenseVerdict?, verdictRaw: String?,
             verdictReason: String?, datasetNote: String?, flatSpelling: Bool? = nil) {
            self.licenseUrl = licenseUrl
            self.readOn = readOn
            self.explicit = explicit
            self.commercialOk = commercialOk
            self.noticeText = noticeText
            self.verdict = verdict
            self.verdictRaw = verdictRaw
            self.verdictReason = verdictReason
            self.datasetNote = datasetNote
            self.flatSpelling = flatSpelling
        }

        /// Equality is the recorded licence position. `verdictRaw` and
        /// `flatSpelling` say how a file was spelled, not what it claims, so an
        /// unknown verdict word and a flat spelling must not make two otherwise
        /// identical records compare unequal.
        static func == (lhs: WeightsLicenseEvidence, rhs: WeightsLicenseEvidence) -> Bool {
            lhs.licenseUrl == rhs.licenseUrl && lhs.readOn == rhs.readOn
                && lhs.explicit == rhs.explicit && lhs.commercialOk == rhs.commercialOk
                && lhs.noticeText == rhs.noticeText && lhs.verdict == rhs.verdict
                && lhs.verdictReason == rhs.verdictReason
                && lhs.datasetNote == rhs.datasetNote
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            licenseUrl = try container.decodeIfPresent(String.self, forKey: .licenseUrl)
            readOn = try container.decodeIfPresent(String.self, forKey: .readOn)
            explicit = try container.decodeIfPresent(Bool.self, forKey: .explicit)
            commercialOk = try container.decodeIfPresent(Bool.self, forKey: .commercialOk)
            noticeText = try container.decodeIfPresent(String.self, forKey: .noticeText)
            // Read as text rather than as the enum: a word outside the closed
            // set must reach `validate()` and be reported, instead of failing
            // the whole strict decode for a catalog this version cannot know.
            let written = try container.decodeIfPresent(String.self, forKey: .verdict)
            verdictRaw = written
            verdict = written.flatMap(ModelLicenseVerdict.init(rawValue:))
            verdictReason = try container.decodeIfPresent(String.self, forKey: .verdictReason)
            datasetNote = try container.decodeIfPresent(String.self, forKey: .datasetNote)
            flatSpelling = nil
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(licenseUrl, forKey: .licenseUrl)
            try container.encodeIfPresent(readOn, forKey: .readOn)
            try container.encodeIfPresent(explicit, forKey: .explicit)
            try container.encodeIfPresent(commercialOk, forKey: .commercialOk)
            try container.encodeIfPresent(noticeText, forKey: .noticeText)
            // The written word is what came in, so an unknown verdict round
            // trips instead of being silently normalised away.
            try container.encodeIfPresent(verdictRaw, forKey: .verdict)
            try container.encodeIfPresent(verdictReason, forKey: .verdictReason)
            try container.encodeIfPresent(datasetNote, forKey: .datasetNote)
        }
    }

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
    /// Recorded weights-licence evidence. Absent for a catalog written before
    /// this field existed, which must keep decoding unchanged. Declared `var`
    /// only so a test can freeze the remaining fields against an older file;
    /// nothing in production writes it, and every accessor above it stays `let`.
    var weightsEvidence: WeightsLicenseEvidence?
    let platforms: [String]
    let requiredProvider: String
    let minimumContractVersion: String
    let preprocess: ModelPreprocess
    let deterministic: Bool
    let notes: String
    let unverifiableReason: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case capabilities
        case version
        case format
        case files
        case sizeBytes
        case sha256
        case sourceUrl
        case codeLicense
        case weightsLicense
        case licenseEvidenceUrl
        case weightsEvidence
        case platforms
        case requiredProvider
        case minimumContractVersion
        case preprocess
        case deterministic
        case notes
        case unverifiableReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        version = try container.decode(String.self, forKey: .version)
        format = try container.decode(String.self, forKey: .format)
        files = try container.decode([ModelCatalogFile].self, forKey: .files)
        sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        sourceUrl = try container.decode(String.self, forKey: .sourceUrl)
        codeLicense = try container.decode(String.self, forKey: .codeLicense)
        weightsLicense = try container.decode(String.self, forKey: .weightsLicense)
        licenseEvidenceUrl = try container.decode(String.self, forKey: .licenseEvidenceUrl)
        // Two spellings decode into one record: the nested `weightsEvidence`
        // object, which is what this repository ships and what encoding writes,
        // and the flat top-level keys named by the release gate. A file may use
        // either; only the nested form round-trips.
        if let nested = try container.decodeIfPresent(WeightsLicenseEvidence.self,
                                                      forKey: .weightsEvidence) {
            weightsEvidence = nested
        } else {
            let flat = try FlatWeightsEvidence(from: decoder)
            weightsEvidence = flat.isEmpty ? nil : flat.asEvidence()
        }
        platforms = try container.decode([String].self, forKey: .platforms)
        requiredProvider = try container.decode(String.self, forKey: .requiredProvider)
        minimumContractVersion = try container.decode(String.self,
                                                      forKey: .minimumContractVersion)
        preprocess = try container.decode(ModelPreprocess.self, forKey: .preprocess)
        deterministic = try container.decode(Bool.self, forKey: .deterministic)
        notes = try container.decode(String.self, forKey: .notes)
        unverifiableReason = try container.decodeIfPresent(String.self,
                                                           forKey: .unverifiableReason)
    }

    /// Mirrors `weightsEvidence` for the flat spelling. `isEmpty` means "no
    /// evidence key at all", which is how an old catalog file is recognised.
    private struct FlatWeightsEvidence: Decodable {
        let weightsLicenseUrl: String?
        let weightsLicenseReadOn: String?
        let commercialOk: Bool?
        let weightsLicenseExplicit: Bool?
        let noticeText: String?
        let verdict: String?
        let verdictReason: String?
        let datasetNote: String?

        var isEmpty: Bool {
            weightsLicenseUrl == nil && weightsLicenseReadOn == nil && commercialOk == nil
                && weightsLicenseExplicit == nil && noticeText == nil && verdict == nil
                && verdictReason == nil && datasetNote == nil
        }

        func asEvidence() -> WeightsLicenseEvidence {
            WeightsLicenseEvidence(
                licenseUrl: weightsLicenseUrl,
                readOn: weightsLicenseReadOn,
                explicit: weightsLicenseExplicit,
                commercialOk: commercialOk,
                noticeText: noticeText,
                // An unrecognised verdict string must not discard the rest of
                // the record; `validate()` is what rejects it.
                verdict: verdict.flatMap(ModelLicenseVerdict.init(rawValue:)),
                verdictRaw: verdict,
                verdictReason: verdictReason,
                datasetNote: datasetNote,
                flatSpelling: true)
        }
    }

    init(id: String, name: String, capabilities: [String], version: String, format: String,
         files: [ModelCatalogFile], sizeBytes: Int?, sha256: String?, sourceUrl: String,
         codeLicense: String, weightsLicense: String, licenseEvidenceUrl: String,
         weightsEvidence: WeightsLicenseEvidence? = nil, platforms: [String],
         requiredProvider: String, minimumContractVersion: String,
         preprocess: ModelPreprocess, deterministic: Bool, notes: String,
         unverifiableReason: String?) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.version = version
        self.format = format
        self.files = files
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.sourceUrl = sourceUrl
        self.codeLicense = codeLicense
        self.weightsLicense = weightsLicense
        self.licenseEvidenceUrl = licenseEvidenceUrl
        self.weightsEvidence = weightsEvidence
        self.platforms = platforms
        self.requiredProvider = requiredProvider
        self.minimumContractVersion = minimumContractVersion
        self.preprocess = preprocess
        self.deterministic = deterministic
        self.notes = notes
        self.unverifiableReason = unverifiableReason
    }

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
        if var evidence = weightsEvidence {
            try Self.requireHttps(evidence.licenseUrl, model: id, field: "weights licence URL")
            try Self.requireReadOnDate(evidence.readOn, model: id)
            if let verdict = evidence.verdictRaw {
                guard ModelLicenseVerdict(rawValue: verdict) != nil else {
                    throw ModelCatalog.LoadError.unsafe(
                        "\(id) has an unknown weights licence verdict \(verdict.debugDescription)")
                }
            }
            // The two are recorded separately on purpose — a verdict never
            // implies commercial permission — but they may not contradict each
            // other, and the only contradiction expressible here is an entry
            // declared usable while its grant forbids commercial use.
            if evidence.commercialOk == false,
               evidence.verdict == .usable || evidence.verdict == .usableWithConditions {
                throw ModelCatalog.LoadError.unsafe(
                    "\(id) records a verdict of \(evidence.verdict!.rawValue) without a "
                    + "commercial grant")
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

    /// An evidence URL must be HTTPS with no credentials or fragment, under the
    /// same port rules as any other recorded source. Absent is allowed: a
    /// missing claim is auditable, a false one is not.
    static func requireHttps(_ url: String?, model: String, field: String) throws {
        guard let url else { return }
        guard isAllowedSource(url, allowLocalHTTP: false), let parsed = URL(string: url),
              parsed.host != nil else {
            throw ModelCatalog.LoadError.unsafe("\(model) has a non-HTTPS \(field)")
        }
    }

    /// The date a licence was read, as an ISO-8601 calendar date. A free-text
    /// timestamp cannot be compared against a later re-read, so the shape is
    /// enforced rather than trusted.
    static func requireReadOnDate(_ value: String?, model: String) throws {
        guard let value else { return }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let isDate = parts.count == 3
            && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
        guard isDate, let day = Int(parts[2]), let month = Int(parts[1]),
              (1...12).contains(month), (1...31).contains(day) else {
            throw ModelCatalog.LoadError.unsafe(
                "\(model) records a weights licence read date that is not an "
                + "ISO-8601 calendar date")
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
