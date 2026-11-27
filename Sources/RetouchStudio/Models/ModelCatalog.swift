import Foundation

/// The path as it appeared on the wire. `URL.path` percent-decodes, so an
/// encoded slash could make one path class look like another; redirect policy
/// and its redacted audit text must use the encoded form instead.
extension URL {
    var modelRedirectPath: String {
        let path = URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    /// A path prefix is a destination policy, not a traversal defence. Refuse
    /// dot segments and encoded separators before any client or server can
    /// normalize them. Decode repeatedly so double-encoded traversal cannot
    /// hide behind a prefix, but stop at a stable value (a literal `%25` is
    /// valid) and fail closed if escaping keeps changing.
    var hasSafeModelRedirectPath: Bool {
        isSafeModelRedirectPath(modelRedirectPath)
    }
}

/// Validates a wire path before URL resolution can normalize dot segments away.
/// `URLComponents(string:)` preserves the escaped relative or absolute path,
/// unlike `URL(string:relativeTo:)`, which may erase literal `..` components.
extension String {
    var hasSafeRawModelRedirectPath: Bool {
        guard !contains("\\"),
              let path = URLComponents(string: self)?.percentEncodedPath else { return false }
        return isSafeModelRedirectPath(path)
    }
}

func isSafeModelRedirectPath(_ path: String) -> Bool {
    func unsafe(_ value: String) -> Bool {
        value == "." || value == ".." || value.contains("/") || value.contains("\\")
    }
    for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
        var value = String(segment)
        var stable = false
        for _ in 0..<8 {
            if unsafe(value) { return false }
            guard value.contains("%"),
                  let decoded = value.removingPercentEncoding,
                  decoded != value else {
                stable = true
                break
            }
            value = decoded
        }
        guard stable, !unsafe(value) else { return false }
    }
    return true
}

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
    /// Host-and-path-class destinations a download may be redirected to. An
    /// absent key is an empty list, which reproduces the historical
    /// refuse-every-redirect behaviour: the safe default is no redirects.
    let redirectAllowList: [ModelRedirectRule]

    static let schemaName = "retouchstudio.model-catalog/1"

    private enum CodingKeys: String, CodingKey {
        case schema
        case catalogVersion
        case entries
        case redirectAllowList
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        catalogVersion = try container.decode(String.self, forKey: .catalogVersion)
        entries = try container.decode([ModelCatalogEntry].self, forKey: .entries)
        redirectAllowList = try container.decodeIfPresent([ModelRedirectRule].self,
                                                          forKey: .redirectAllowList) ?? []
    }

    init(schema: String, catalogVersion: String, entries: [ModelCatalogEntry],
         redirectAllowList: [ModelRedirectRule] = []) {
        self.schema = schema
        self.catalogVersion = catalogVersion
        self.entries = entries
        self.redirectAllowList = redirectAllowList
    }

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
        for rule in catalog.redirectAllowList {
            try rule.validate()
        }
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

    /// The redirect rule that admits `url`, if any. Hosts compare as full,
    /// case-insensitive strings — never as a suffix, a substring or a wildcard —
    /// and the path must sit inside the rule's prefix. An empty allow-list
    /// therefore admits nothing, which is the behaviour the catalog had before
    /// this key existed.
    func redirectRule(matching url: URL) -> ModelRedirectRule? {
        guard let host = url.host, !host.isEmpty,
              url.hasSafeModelRedirectPath else { return nil }
        let path = url.modelRedirectPath
        return redirectAllowList.first { rule in
            rule.host.caseInsensitiveCompare(host) == .orderedSame
                && path.hasPrefix(rule.pathPrefix)
        }
    }
}

/// One redirect destination the catalog admits: a host plus the path class on
/// that host. Both halves are required, because Hugging Face answers a binary
/// file with `302` to `us.aws.cdn.hf.co/xet-bridge-us/…` and a config file with
/// a *relative* `307` to `huggingface.co/api/resolve-cache/…`. A host-only list
/// would still refuse the second one, and a path-only list would admit any path
/// on an allowed host.
///
/// This is data, not code: adding a destination is a catalog change, and the
/// consent sheet names every entry before a byte is requested.
struct ModelRedirectRule: Codable, Equatable {
    /// Lowercase host, no scheme, no port, no wildcard.
    let host: String
    /// Path prefix beginning with `/`; never carries a query or fragment.
    let pathPrefix: String

    /// Refuses a rule that cannot be honoured rather than dropping it silently,
    /// so an edited resource can never widen the policy by accident. The error
    /// class is the same `unsafe` one every other catalog defect uses.
    func validate() throws {
        guard !host.isEmpty else {
            throw ModelCatalog.LoadError.unsafe("a redirect rule has an empty host")
        }
        guard host == host.lowercased() else {
            throw ModelCatalog.LoadError.unsafe(
                "redirect rule host \(host.debugDescription) is not lowercase")
        }
        guard host.allSatisfy(Self.isHostChar), !host.contains("*") else {
            throw ModelCatalog.LoadError.unsafe(
                "redirect rule host \(host.debugDescription) is not a plain host name")
        }
        guard !pathPrefix.isEmpty else {
            throw ModelCatalog.LoadError.unsafe(
                "redirect rule for \(host) has an empty path prefix")
        }
        guard pathPrefix.hasPrefix("/") else {
            throw ModelCatalog.LoadError.unsafe(
                "redirect rule for \(host) has a path prefix that does not start with /")
        }
        for bad in ["?", "#", "..", "\\"] where pathPrefix.contains(bad) {
            throw ModelCatalog.LoadError.unsafe(
                "redirect rule for \(host) has \(bad.debugDescription) in its path prefix")
        }
        guard pathPrefix.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) })
        else {
            throw ModelCatalog.LoadError.unsafe(
                "redirect rule for \(host) has whitespace in its path prefix")
        }
    }

    static func isHostChar(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "."
                            || char == "_")
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
    struct ModelUseCondition: Codable, Equatable {
        let text: String
        let met: Bool
    }

    /// What the recorded evidence says about one artefact: the model's code, its
    /// weight files, or its training data.
    ///
    /// The worker's `permitted_use` record is the source of this shape
    /// (`worker/retouch_ai_worker/catalog.py`), and the host mirrors it field for
    /// field: these JSON names are exactly what `ArtefactTerms.to_json()` writes,
    /// so the cross-surface check can compare the two without a translation table.
    ///
    /// `verdict` and `statedBy` are decoded as text, not as enums, for the same
    /// reason every other recorded fact here is: a word this build does not know
    /// must reach `validate()` and be reported, instead of failing the strict
    /// decode for the whole catalog.
    struct ModelArtefactTerms: Codable, Equatable {
        /// The owner's four statuses. Nothing outside this set is a verdict.
        enum Verdict: String, Codable, Equatable {
            case approved
            case approvedWithConditions = "approved-with-conditions"
            case unknown
            case excluded
        }

        /// Who made the statement. `notEstablished` records that the search
        /// happened and produced no usable statement; it is how a record that
        /// cannot survive this schema says "not yet established".
        enum StatedBy: String, Codable, Equatable {
            case rightsHolder = "rights-holder"
            case inferred
            case notEstablished = "not-established"
        }

        /// The one use class this product needs (owner mandate, 2026-11-22).
        static let requiredUse = "public-non-commercial-use-and-distribution"

        let use: String
        /// The end user may obtain this file from `evidenceUrl`.
        let canAcquire: Bool?
        /// The project may publish that URL, the recorded size and SHA-256 and
        /// install from it. No bytes are mirrored, so this says nothing about
        /// mirroring.
        let canRedistribute: Bool?
        /// The recorded use class is permitted.
        let canUse: Bool?
        let statedBy: String
        let evidenceUrl: String
        let readOn: String
        let verdict: String
        let conditions: [ModelUseCondition]
        /// Attribution that would have to be reproduced if a file were mirrored or
        /// bundled. Recorded evidence, not a claim that mirroring happens.
        let notice: String?
        /// Why the verdict is what it is, or what the search could not establish.
        let note: String?

        var verdictValue: Verdict? { Verdict(rawValue: verdict) }
        var statedByValue: StatedBy? { StatedBy(rawValue: statedBy) }

        /// True only when every permission axis is granted; nil when any answer is
        /// missing. A single refusal makes it false: "we know one answer and not the
        /// others" is still not a permission.
        var permitted: Bool? {
            let axes = [canAcquire, canRedistribute, canUse]
            if axes.contains(false) { return false }
            if axes.allSatisfy({ $0 == true }) { return true }
            return nil
        }

        /// Whether this artefact alone satisfies the admission rule.
        var isAdmitted: Bool {
            guard let verdictValue,
                  verdictValue == .approved || verdictValue == .approvedWithConditions,
                  permitted == true else { return false }
            return conditions.allSatisfy(\.met)
        }

        /// Writes every field, including the nulls. The worker's `to_json()` emits
        /// `null` for an absent answer rather than omitting the key, and the
        /// cross-surface test compares the two encodings exactly, so "absent" must
        /// have one spelling on the wire.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(use, forKey: .use)
            try container.encode(canAcquire, forKey: .canAcquire)
            try container.encode(canRedistribute, forKey: .canRedistribute)
            try container.encode(canUse, forKey: .canUse)
            try container.encode(statedBy, forKey: .statedBy)
            try container.encode(evidenceUrl, forKey: .evidenceUrl)
            try container.encode(readOn, forKey: .readOn)
            try container.encode(verdict, forKey: .verdict)
            try container.encode(conditions, forKey: .conditions)
            try container.encode(notice, forKey: .notice)
            try container.encode(note, forKey: .note)
        }

        /// Rejects every record the mandate would otherwise have to infer. Called
        /// for each shipped entry at load time, so an edited resource cannot admit
        /// a model by accident — the same rules the worker applies to its table.
        func validate(model: String, artefact: String) throws {
            let subject = "\(model) \(artefact)"
            guard use == Self.requiredUse else {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) records use \(use.debugDescription), not the required "
                    + "\(Self.requiredUse)")
            }
            guard statedByValue != nil else {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) has an unknown statement source \(statedBy.debugDescription)")
            }
            guard verdictValue != nil else {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) has an unknown licence verdict \(verdict.debugDescription)")
            }
            guard !evidenceUrl.isEmpty else {
                throw ModelCatalog.LoadError.unsafe("\(subject) has no evidence URL")
            }
            try ModelCatalogEntry.requireHttps(evidenceUrl, model: model,
                                               field: "\(artefact) evidence")
            guard !readOn.isEmpty else {
                throw ModelCatalog.LoadError.unsafe("\(subject) has no evidence read date")
            }
            try ModelCatalogEntry.requireReadOnDate(readOn, model: model)

            let axes = [canAcquire, canRedistribute, canUse]
            if statedByValue == .inferred, axes.contains(true) {
                // The central rule: an inference is never a grant.
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) records a permitted axis from inferred evidence")
            }
            if statedByValue == .notEstablished,
               verdictValue != .unknown || !axes.allSatisfy({ $0 == nil }) {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) marks the statement not established but records a decision")
            }
            if axes.contains(false), verdictValue != .excluded {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) records a refused permission without the excluded verdict")
            }
            if verdictValue == .excluded, axes.contains(true) {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) is excluded but records a granted permission")
            }
            let approving = verdictValue == .approved || verdictValue == .approvedWithConditions
            if permitted == true, !approving {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) records every permission without an approving verdict")
            }
            if approving, permitted != true {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) approves the artefact without every permission granted")
            }
            if verdictValue == .approved, !conditions.isEmpty {
                throw ModelCatalog.LoadError.unsafe("\(subject) is approved but carries conditions")
            }
            if verdictValue == .approvedWithConditions {
                guard !conditions.isEmpty else {
                    throw ModelCatalog.LoadError.unsafe(
                        "\(subject) is approved with conditions but lists none")
                }
                guard conditions.allSatisfy(\.met) else {
                    throw ModelCatalog.LoadError.unsafe(
                        "\(subject) is approved with conditions but a condition is unmet")
                }
            }
            if verdictValue == .unknown,
               (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ModelCatalog.LoadError.unsafe(
                    "\(subject) records an unknown verdict without saying what is missing")
            }
        }
    }

    /// The three artefact records one catalogue entry carries.
    struct ModelPermittedUse: Codable, Equatable {
        let code: ModelArtefactTerms
        let weights: ModelArtefactTerms
        let trainingData: ModelArtefactTerms
        /// The admission flag the worker writes beside the record. Decoded only so
        /// `validate()` can refuse a file whose flag disagrees with its own facts.
        let claimedAdmitted: Bool?

        enum CodingKeys: String, CodingKey {
            case code
            case weights
            case trainingData
            case claimedAdmitted = "admitted"
        }

        /// Artefacts whose verdict is `excluded`, in record order.
        var excludedArtefacts: [String] {
            var names: [String] = []
            let records = [("code", code), ("weights", weights), ("training data", trainingData)]
            for (name, terms) in records where terms.verdictValue == .excluded {
                names.append(name)
            }
            return names
        }

        /// The load gate, as the worker applies it: the weight file's record, and no
        /// excluded code or dataset.
        var isAdmitted: Bool {
            weights.isAdmitted && excludedArtefacts.isEmpty
        }

        /// Emits the flag under the wire name the worker writes, so a re-encoded
        /// record compares equal to `PermittedUse.to_json()` in both directions.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            try container.encode(weights, forKey: .weights)
            try container.encode(trainingData, forKey: .trainingData)
            try container.encode(claimedAdmitted, forKey: .claimedAdmitted)
        }

        func validate(model: String) throws {
            try code.validate(model: model, artefact: "code")
            try weights.validate(model: model, artefact: "weights")
            try trainingData.validate(model: model, artefact: "training data")
            if let claimedAdmitted, claimedAdmitted != isAdmitted {
                throw ModelCatalog.LoadError.unsafe(
                    "\(model) records admitted: \(claimedAdmitted) while its record "
                    + "\(isAdmitted ? "admits" : "refuses") the model")
            }
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
    /// The recorded licence position for this model's code, weights and training
    /// data. Absent for a catalog written before this field existed, which must
    /// keep decoding unchanged. Declared `var` only so a test can freeze the
    /// remaining fields against an older file; every accessor stays `let`.
    var permittedUse: ModelPermittedUse?
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
        case permittedUse = "permitted_use"
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
        // Optional, so a catalog written before the four-status record existed
        // still loads under the strict decoder; the store then shows the entry
        // without a recorded position rather than inventing one.
        permittedUse = try container.decodeIfPresent(ModelPermittedUse.self,
                                                     forKey: .permittedUse)
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

    init(id: String, name: String, capabilities: [String], version: String, format: String,
         files: [ModelCatalogFile], sizeBytes: Int?, sha256: String?, sourceUrl: String,
         codeLicense: String, weightsLicense: String, licenseEvidenceUrl: String,
         permittedUse: ModelPermittedUse? = nil, platforms: [String],
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
        self.permittedUse = permittedUse
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
        if let permittedUse {
            try permittedUse.validate(model: id)
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
              parsed.user == nil, parsed.password == nil, parsed.fragment == nil,
              !authorityContainsAt(parsed) else {
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
        return url.scheme?.lowercased() == "http" && allowLocalHTTP && isLoopback(url)
    }

    /// A file must come from the entry's recorded source: same scheme, same
    /// host, and the same port rules. A redirect never changes this: the first
    /// URL of every file is still the recorded `sourceUrl`, and a redirect only
    /// continues from it.
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

    /// The shape a redirect destination must have, independent of the allow-list.
    /// It is exactly the rule the request URL already passed — HTTPS (or loopback
    /// HTTP under the test opt-in), no credentials, no fragment, port 443 or the
    /// test port, non-empty host — so a redirect cannot smuggle in a URL the
    /// catalog would never have recorded. A `file:` or `ftp:` Location fails here.
    ///
    /// `URL` does not report an omitted userinfo as nil for every malformed input,
    /// so the raw authority is checked too: an empty `user=` must not read as absent.
    /// At signs in the path or query are ordinary data and do not imply credentials.
    static func isAllowedRedirectTarget(_ url: URL, allowLocalHTTP: Bool) -> Bool {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, !authorityContainsAt(url),
              url.hasSafeModelRedirectPath else { return false }
        switch url.scheme?.lowercased() {
        case "https": break
        case "http" where allowLocalHTTP && isLoopback(url): break
        default: return false
        }
        return isAllowedPort(url, allowLocalHTTP: allowLocalHTTP)
    }

    private static func authorityContainsAt(_ url: URL) -> Bool {
        let absolute = url.absoluteString
        guard let separator = absolute.range(of: "://") else { return true }
        let authority = absolute[separator.upperBound...].prefix { !"/?#".contains($0) }
        return authority.contains("@")
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
        guard isDate, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else {
            throw ModelCatalog.LoadError.unsafe(
                "\(model) records a licence read date that is not an "
                + "ISO-8601 calendar date")
        }
        // A day the month does not have is a typo, not a date: 2026-11-31 must
        // be refused before anyone compares it with a later re-read.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            throw ModelCatalog.LoadError.unsafe(
                "\(model) records an impossible licence read date \(value)")
        }
        let round = calendar.dateComponents([.year, .month, .day], from: date)
        guard round.year == year, round.month == month, round.day == day else {
            throw ModelCatalog.LoadError.unsafe(
                "\(model) records an impossible licence read date \(value)")
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
