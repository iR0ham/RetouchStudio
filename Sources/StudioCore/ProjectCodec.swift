import Foundation

/// One snapshot of an open document, ready to become a project. The shell waives
/// the cases the codec cannot decide (no photo open, blocking work running).
public struct ProjectInput {
    public var imageURL: URL
    public var state: DocumentState
    public var exportFormat: String
    public var exportQuality: Double
    /// Zero means "keep the photo's own size"; the codec writes it as `nil`.
    public var exportLongEdge: Int
    public var autoRetouchStrength: Double
    public var autoColorStrength: Double

    public init(imageURL: URL, state: DocumentState, exportFormat: String,
                exportQuality: Double, exportLongEdge: Int,
                autoRetouchStrength: Double, autoColorStrength: Double) {
        self.imageURL = imageURL
        self.state = state
        self.exportFormat = exportFormat
        self.exportQuality = exportQuality
        self.exportLongEdge = exportLongEdge
        self.autoRetouchStrength = autoRetouchStrength
        self.autoColorStrength = autoColorStrength
    }
}

/// Where the photo a project points at lives now, in order of trust: the
/// bookmark survives a move, the absolute path covers an unmoved file, and a
/// file sitting next to the project covers a moved folder. `nil` means the
/// owner has to point at it.
public struct ProjectSourceResolver {
    public var sources: ProjectSourceAccess
    public var bookmarks: ProjectBookmarkStore

    public init(sources: ProjectSourceAccess, bookmarks: ProjectBookmarkStore) {
        self.sources = sources
        self.bookmarks = bookmarks
    }

    public func resolve(_ project: RetouchProject, projectURL: URL?) -> URL? {
        if let data = project.imageBookmark,
           let url = bookmarks.resolveBookmark(data),
           sources.fileExists(at: url) {
            return url
        }
        let absolute = URL(fileURLWithPath: project.imagePath)
        if sources.fileExists(at: absolute) { return absolute }
        if let projectURL {
            let sibling = projectURL.deletingLastPathComponent()
                .appendingPathComponent((project.imagePath as NSString).lastPathComponent)
            if sources.fileExists(at: sibling) { return sibling }
        }
        return nil
    }
}

public enum ProjectCodecError: Error, Equatable {
    case tooNew(Int)
    /// A v4 file requires a capability this build does not implement. Reading
    /// it as if the capability were absent would quietly change the document.
    case unsupportedFeatures([String])
}

/// Reads and writes the project document. Byte compatibility lives here: the
/// encoder settings are fixed, and normalizing empty values to `nil` keeps each
/// file as small as earlier readers expect. The version guard is part of
/// decoding so a caller cannot open a format it does not understand.
///
/// This type only transforms bytes. Reading a file, writing it back and
/// resolving the photo are host responsibilities behind `ProjectByteStore`,
/// `ProjectSourceAccess` and `ProjectBookmarkStore`.
public enum ProjectCodec {
    /// Highest project file version this build reads.
    public static let currentVersion = ProjectV4.currentVersion

    /// The capabilities this build can honor when a file requires them.
    public static let supportedFeatures: Set<String> = ProjectV4.supportedFeatures

    /// Required features this build cannot honor, sorted so the message a host
    /// shows does not depend on the file's key order.
    public static func unsupportedFeatures(_ required: [String]) -> [String] {
        required.filter { !supportedFeatures.contains($0) }.sorted()
    }

    public static func makeProject(_ input: ProjectInput,
                                   bookmarks: ProjectBookmarkStore) -> RetouchProject {
        let state = input.state
        return RetouchProject(imagePath: input.imageURL.path,
                              imageBookmark: bookmarks.bookmark(for: input.imageURL),
                              adjustments: state.adjustments,
                              exportFormat: input.exportFormat,
                              exportQuality: input.exportQuality,
                              exportLongEdge: input.exportLongEdge == 0 ? nil : input.exportLongEdge,
                              autoRetouchStrength: input.autoRetouchStrength,
                              autoColorStrength: input.autoColorStrength,
                              crop: state.crop,
                              healSpots: state.healSpots.isEmpty ? nil : state.healSpots,
                              stickers: state.stickers.isEmpty ? nil : state.stickers,
                              aiEdits: state.aiEdits.isEmpty ? nil : state.aiEdits,
                              analysis: state.analysis == AnalysisSettings() ? nil : state.analysis,
                              selectedFace: state.selectedFaceIndex,
                              orientation: state.orientation.isIdentity ? nil : state.orientation)
    }

    /// v3 bytes, unchanged. The baseline fixture proves this.
    public static func encode(_ project: RetouchProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    /// Writes the version the document was read as. A v3 file never silently
    /// becomes v4, and a v4 file keeps its keyed geometry and unknown keys.
    public static func encode(_ project: RetouchProject,
                              context: ProjectWriteContext) throws -> Data {
        if context.isV4 {
            return try encodeV4(project,
                                unknownFields: context.unknownFields,
                                requiredFeatures: context.requiredFeatures,
                                nestedUnknowns: context.nestedUnknowns)
        }
        let base = try encode(project)
        guard !context.unknownFields.isEmpty else { return base }
        return try merging(base, unknown: context.unknownFields,
                           known: RetouchProject.knownJSONKeys)
    }

    /// The portable v4 document: named geometry records and a stable key order.
    public static func encodeV4(_ project: RetouchProject,
                                unknownFields: [String: ProjectJSONValue] = [:],
                                requiredFeatures: [String] = [],
                                nestedUnknowns: ProjectUnknownFields? = nil) throws -> Data {
        let record = ProjectV4(project: project, requiredFeatures: requiredFeatures)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var typed = try encoder.encode(record)
        if let nestedUnknowns {
            typed = try applying(nestedUnknowns, to: typed)
        }
        guard !unknownFields.isEmpty else { return typed }
        return try merging(typed, unknown: unknownFields, known: ProjectV4.knownKeys)
    }

    public static func decode(_ data: Data) throws -> RetouchProject {
        try read(data).project
    }

    /// Reads a v3 or v4 file and keeps what a later save needs.
    public static func read(_ data: Data) throws -> ProjectFile {
        let decoder = JSONDecoder()
        let object = try decoder.decode([String: ProjectJSONValue].self, from: data)
        let version = object["version"]?.integerValue ?? RetouchProject.currentVersion
        guard version <= currentVersion else {
            throw ProjectCodecError.tooNew(version)
        }
        if version >= ProjectV4.currentVersion {
            let record = try decoder.decode(ProjectV4.self, from: data)
            let required = record.requiredFeatures ?? []
            let unsupported = unsupportedFeatures(required)
            guard unsupported.isEmpty else {
                throw ProjectCodecError.unsupportedFeatures(unsupported)
            }
            return ProjectFile(
                project: record.project,
                context: ProjectWriteContext(
                    version: version,
                    unknownFields: object.filter { !ProjectV4.knownKeys.contains($0.key) },
                    requiredFeatures: required,
                    nestedUnknowns: try nestedUnknownFields(in: object, of: record)))
        }
        let project = try decoder.decode(RetouchProject.self, from: data)
        return ProjectFile(
            project: project,
            context: ProjectWriteContext(
                version: version,
                unknownFields: object.filter { !RetouchProject.knownJSONKeys.contains($0.key) },
                requiredFeatures: []))
    }

    /// Keeps unknown data without letting it overwrite a field this build owns.
    private static func merging(_ data: Data, unknown: [String: ProjectJSONValue],
                                known: Set<String>) throws -> Data {
        let decoder = JSONDecoder()
        var object = try decoder.decode([String: ProjectJSONValue].self, from: data)
        for (key, value) in unknown where !known.contains(key) {
            object[key] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(object)
    }

    /// The difference between a v4 file and the record this build writes back,
    /// captured per known key so a save can keep it.
    private static func nestedUnknownFields(in raw: [String: ProjectJSONValue],
                                            of record: ProjectV4) throws -> ProjectUnknownFields? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let typedData = try encoder.encode(record)
        guard let typed = try? JSONDecoder().decode(ProjectJSONValue.self, from: typedData),
              case .object(let typedFields) = typed else { return nil }
        var children: [String: ProjectUnknownFields] = [:]
        for key in ProjectV4.knownKeys {
            guard let rawValue = raw[key], let typedValue = typedFields[key] else { continue }
            if let nested = ProjectUnknownFieldCapture.capture(raw: rawValue, typed: typedValue) {
                children[key] = nested
            }
        }
        return children.isEmpty ? nil : .object(children)
    }

    /// Writes the captured nested data back over a freshly encoded record.
    private static func applying(_ nested: ProjectUnknownFields,
                                 to data: Data) throws -> Data {
        var object = try JSONDecoder().decode([String: ProjectJSONValue].self, from: data)
        if case .object(let children) = nested {
            for (key, child) in children {
                if let typed = object[key] {
                    object[key] = ProjectUnknownFieldCapture.applying(child, to: typed)
                } else if case .value(let value) = child {
                    object[key] = value
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(object)
    }
}

// MARK: - File-level facts

/// Any JSON value, kept so an unknown project key can be written back
/// unchanged. Objects and arrays recurse; numbers decode as `Int` when they are
/// integral and `Double` otherwise.
public enum ProjectJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ProjectJSONValue])
    case object([String: ProjectJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ProjectJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ProjectJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var integerValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}

/// JSON a newer writer put inside records this build already models.
///
/// A file is captured against the record this build writes back, so a value is
/// kept only when the typed model did not consume it. Applying the captured
/// data over a later save keeps forward-compatible fields without letting them
/// shadow an edit: a known key always wins, and a record the owner removed
/// takes its unknown data with it.
public indirect enum ProjectUnknownFields: Equatable {
    /// A whole value at a key the record does not know.
    case value(ProjectJSONValue)
    /// Unknown data inside the object at a known key.
    case object([String: ProjectUnknownFields])
    /// Unknown data inside a known array, one entry per element.
    case array([Element])

    /// One array element the overlay was captured from.
    public struct Element: Equatable, Codable {
        /// The element's position when it was read.
        public var index: Int
        /// The element's `id` field, when its record has one.
        public var id: ProjectJSONValue?
        /// The element's known JSON as it was read. It re-matches the element
        /// after the owner edits or removes its neighbours.
        public var known: ProjectJSONValue
        /// Nil for an element that carried no unknown data.
        public var unknown: ProjectUnknownFields?

        public init(index: Int, id: ProjectJSONValue?, known: ProjectJSONValue,
                    unknown: ProjectUnknownFields?) {
            self.index = index
            self.id = id
            self.known = known
            self.unknown = unknown
        }
    }
}

extension ProjectUnknownFields: Codable {
    private enum CodingKeys: String, CodingKey {
        case value, object, array
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try c.decodeIfPresent(ProjectJSONValue.self, forKey: .value) {
            self = .value(value)
        } else if let object = try c.decodeIfPresent([String: ProjectUnknownFields].self,
                                                     forKey: .object) {
            self = .object(object)
        } else if let array = try c.decodeIfPresent([Element].self, forKey: .array) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: c.codingPath,
                                      debugDescription: "unknown-field overlay without a case"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let value): try c.encode(value, forKey: .value)
        case .object(let object): try c.encode(object, forKey: .object)
        case .array(let array): try c.encode(array, forKey: .array)
        }
    }
}

/// Compares the file with the record this build writes back, and merges the
/// difference into a later save.
enum ProjectUnknownFieldCapture {
    static func capture(raw: ProjectJSONValue,
                        typed: ProjectJSONValue) -> ProjectUnknownFields? {
        switch (raw, typed) {
        case (.object(let rawFields), .object(let typedFields)):
            var children: [String: ProjectUnknownFields] = [:]
            for (key, rawValue) in rawFields {
                guard let typedValue = typedFields[key] else {
                    children[key] = .value(rawValue)
                    continue
                }
                if let nested = capture(raw: rawValue, typed: typedValue) {
                    children[key] = nested
                }
            }
            return children.isEmpty ? nil : .object(children)
        case (.array(let rawItems), .array(let typedItems)):
            // A different length means the typed model re-shaped the array, so
            // there is no reliable element to attach unknown data to.
            guard rawItems.count == typedItems.count else { return nil }
            var elements: [ProjectUnknownFields.Element] = []
            var carriesUnknown = false
            for (index, pair) in zip(rawItems, typedItems).enumerated() {
                let unknown = capture(raw: pair.0, typed: pair.1)
                carriesUnknown = carriesUnknown || unknown != nil
                elements.append(.init(index: index, id: identity(of: pair.1),
                                      known: pair.1, unknown: unknown))
            }
            return carriesUnknown ? .array(elements) : nil
        default:
            return nil
        }
    }

    /// A record's stable identity, when it has one.
    static func identity(of value: ProjectJSONValue) -> ProjectJSONValue? {
        guard case .object(let fields) = value,
              case .string? = fields["id"] else { return nil }
        return fields["id"]
    }

    static func applying(_ unknown: ProjectUnknownFields,
                         to typed: ProjectJSONValue) -> ProjectJSONValue {
        switch unknown {
        case .value:
            // A key this build now owns is never replaced by an older payload.
            return typed
        case .object(let children):
            guard case .object(var fields) = typed else { return typed }
            for (key, child) in children {
                if let current = fields[key] {
                    fields[key] = applying(child, to: current)
                } else if case .value(let value) = child {
                    fields[key] = value
                }
                // A nested overlay for a known record that is now absent is
                // dropped: there is nothing left to attach its keys to.
            }
            return .object(fields)
        case .array(let elements):
            guard case .array(var items) = typed else { return typed }
            apply(elements, to: &items)
            return .array(items)
        }
    }

    private static func apply(_ elements: [ProjectUnknownFields.Element],
                              to items: inout [ProjectJSONValue]) {
        let carrying = elements.filter { $0.unknown != nil }
        guard !carrying.isEmpty, !items.isEmpty else { return }
        var used = Array(repeating: false, count: items.count)

        func claim(_ element: ProjectUnknownFields.Element, at index: Int) {
            used[index] = true
            if let unknown = element.unknown {
                items[index] = applying(unknown, to: items[index])
            }
        }

        var pending: [ProjectUnknownFields.Element] = []
        for element in carrying {
            if let id = element.id,
               let index = items.indices.first(where: {
                   !used[$0] && identity(of: items[$0]) == id
               }) {
                claim(element, at: index)
            } else {
                pending.append(element)
            }
        }
        var unmatched: [ProjectUnknownFields.Element] = []
        for element in pending {
            if let index = items.indices.first(where: {
                !used[$0] && items[$0] == element.known
            }) {
                claim(element, at: index)
            } else {
                unmatched.append(element)
            }
        }
        // Position is the last resort, and only when the array kept its length,
        // so a removed element cannot hand its data to a neighbour.
        guard elements.count == items.count else { return }
        for element in unmatched where !used[element.index] {
            claim(element, at: element.index)
        }
    }
}

/// What the open document's file looked like, so a save can keep it that way.
/// A v3 file stays v3; a v4 file stays v4 and keeps its unknown keys.
public struct ProjectWriteContext: Equatable {
    public var version: Int
    public var unknownFields: [String: ProjectJSONValue]
    public var requiredFeatures: [String]
    /// Unknown data inside records this build models, captured while reading.
    public var nestedUnknowns: ProjectUnknownFields?

    public static let v3 = ProjectWriteContext(version: RetouchProject.currentVersion,
                                               unknownFields: [:], requiredFeatures: [])

    public init(version: Int, unknownFields: [String: ProjectJSONValue],
                requiredFeatures: [String],
                nestedUnknowns: ProjectUnknownFields? = nil) {
        self.version = version
        self.unknownFields = unknownFields
        self.requiredFeatures = requiredFeatures
        self.nestedUnknowns = nestedUnknowns
    }

    public var isV4: Bool { version >= ProjectV4.currentVersion }

    /// True when the file carries data a plain v3 rewrite would drop. A context
    /// that carries nothing is not stored in a recovery snapshot at all, which
    /// keeps a v3 snapshot byte-identical to what earlier builds wrote.
    public var carriesFileMetadata: Bool {
        isV4 || !unknownFields.isEmpty || !requiredFeatures.isEmpty
    }
}

/// Recovery snapshots keep the open document's write context next to the v3
/// payload, so a crash-recovered v4 document saves as v4 again. Decoding is
/// tolerant: a context written by an earlier build, or a partial one, falls back
/// to the v3 defaults instead of failing the whole snapshot.
extension ProjectWriteContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, unknownFields, requiredFeatures, nestedUnknowns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? RetouchProject.currentVersion
        unknownFields = try container.decodeIfPresent([String: ProjectJSONValue].self,
                                                      forKey: .unknownFields) ?? [:]
        requiredFeatures = try container.decodeIfPresent([String].self,
                                                         forKey: .requiredFeatures) ?? []
        nestedUnknowns = try container.decodeIfPresent(ProjectUnknownFields.self,
                                                       forKey: .nestedUnknowns)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(unknownFields, forKey: .unknownFields)
        try container.encode(requiredFeatures, forKey: .requiredFeatures)
        try container.encodeIfPresent(nestedUnknowns, forKey: .nestedUnknowns)
    }
}

/// A project read from disk: the v3 model every call site already uses, plus
/// the file-level facts a save has to preserve.
public struct ProjectFile {
    public var project: RetouchProject
    public var context: ProjectWriteContext

    public init(project: RetouchProject, context: ProjectWriteContext) {
        self.project = project
        self.context = context
    }
}

// MARK: - v4 document

/// The v4 project document. It differs from v3 only where portability and
/// preservation require it: geometry is written as named `{x, y, width,
/// height}` / `{width, height}` records instead of unkeyed arrays, and unknown
/// top-level keys are carried through a save.
struct ProjectV4: Codable, Equatable {
    static let currentVersion = 4

    /// The capabilities this build can honor when a file requires them.
    static let supportedFeatures: Set<String> = ["portable_geometry"]

    static let knownKeys: Set<String> = [
        "version", "imagePath", "imageBookmark", "adjustments", "exportFormat",
        "exportQuality", "exportLongEdge", "autoRetouchStrength",
        "autoColorStrength", "crop", "orientation", "healSpots", "stickers",
        "aiEdits", "analysis", "selectedFace", "requiredFeatures"
    ]

    var version = ProjectV4.currentVersion
    var imagePath: String
    var imageBookmark: Data?
    var adjustments: Adjustments
    var exportFormat: String
    var exportQuality: Double
    var exportLongEdge: Int?
    var autoRetouchStrength: Double
    var autoColorStrength: Double?
    var crop: StudioRect?
    var orientation: DocumentOrientation?
    var healSpots: [HealSpot]?
    var stickers: [Sticker]?
    var aiEdits: [AIEdit]?
    var analysis: AnalysisSettingsV4?
    var selectedFace: Int?
    var requiredFeatures: [String]?

    init(project: RetouchProject, requiredFeatures: [String] = []) {
        imagePath = project.imagePath
        imageBookmark = project.imageBookmark
        adjustments = project.adjustments
        exportFormat = project.exportFormat
        exportQuality = project.exportQuality
        exportLongEdge = project.exportLongEdge
        autoRetouchStrength = project.autoRetouchStrength
        autoColorStrength = project.autoColorStrength
        crop = project.crop
        orientation = project.orientation
        healSpots = project.healSpots
        stickers = project.stickers
        aiEdits = project.aiEdits
        analysis = project.analysis.map(AnalysisSettingsV4.init)
        selectedFace = project.selectedFace
        self.requiredFeatures = requiredFeatures.isEmpty ? nil : requiredFeatures
    }

    /// The v3 model this file describes. The returned project is always
    /// version 3: v4 is a file format, not a second in-memory document model.
    var project: RetouchProject {
        RetouchProject(imagePath: imagePath,
                       imageBookmark: imageBookmark,
                       adjustments: adjustments,
                       exportFormat: exportFormat,
                       exportQuality: exportQuality,
                       exportLongEdge: exportLongEdge,
                       autoRetouchStrength: autoRetouchStrength,
                       autoColorStrength: autoColorStrength,
                       crop: crop,
                       healSpots: healSpots,
                       stickers: stickers,
                       aiEdits: aiEdits,
                       analysis: analysis?.settings,
                       selectedFace: selectedFace,
                       orientation: orientation)
    }
}

struct AnalysisSettingsV4: Codable, Equatable {
    var isEnabled: Bool
    var showsMesh: Bool
    var showsFaceOutline: Bool
    /// Sorted by raw value so the same set writes the same bytes on every
    /// architecture; v3's `Set` encoding has no order guarantee.
    var regions: [AnalysisRegion]
    var endpoints: [String: StudioPoint]
    var anchors: [String: StudioPoint]
    var lineOpacity: Double
    var lineWeight: Double
    var tint: AnalysisTint
    var glow: Bool
    var marginPercent: Double
    var exportMode: AnalysisExportMode

    init(_ settings: AnalysisSettings) {
        isEnabled = settings.isEnabled
        showsMesh = settings.showsMesh
        showsFaceOutline = settings.showsFaceOutline
        regions = settings.regions.sorted { $0.rawValue < $1.rawValue }
        endpoints = settings.endpoints
        anchors = settings.anchors
        lineOpacity = settings.lineOpacity
        lineWeight = settings.lineWeight
        tint = settings.tint
        glow = settings.glow
        marginPercent = settings.marginPercent
        exportMode = settings.exportMode
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, showsMesh, showsFaceOutline, regions, endpoints, anchors,
             lineOpacity, lineWeight, tint, glow, marginPercent, exportMode
    }

    /// Missing keys fall back exactly like `AnalysisSettings`, so a hand-written
    /// or partial v4 document opens with the same defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        showsMesh = try c.decodeIfPresent(Bool.self, forKey: .showsMesh) ?? false
        showsFaceOutline = try c.decodeIfPresent(Bool.self, forKey: .showsFaceOutline) ?? true
        regions = (try c.decodeIfPresent([AnalysisRegion].self, forKey: .regions)
            ?? Array(AnalysisSettings().regions)).sorted { $0.rawValue < $1.rawValue }
        endpoints = try c.decodeIfPresent([String: StudioPoint].self, forKey: .endpoints) ?? [:]
        anchors = try c.decodeIfPresent([String: StudioPoint].self, forKey: .anchors) ?? [:]
        lineOpacity = try c.decodeIfPresent(Double.self, forKey: .lineOpacity) ?? 1
        lineWeight = try c.decodeIfPresent(Double.self, forKey: .lineWeight) ?? 100
        tint = try c.decodeIfPresent(AnalysisTint.self, forKey: .tint) ?? .chalk
        glow = try c.decodeIfPresent(Bool.self, forKey: .glow) ?? true
        marginPercent = try c.decodeIfPresent(Double.self, forKey: .marginPercent) ?? 12
        exportMode = try c.decodeIfPresent(AnalysisExportMode.self, forKey: .exportMode) ?? .onPhoto
    }

    var settings: AnalysisSettings {
        var value = AnalysisSettings()
        value.isEnabled = isEnabled
        value.showsMesh = showsMesh
        value.showsFaceOutline = showsFaceOutline
        value.regions = Set(regions)
        value.endpoints = endpoints
        value.anchors = anchors
        value.lineOpacity = lineOpacity
        value.lineWeight = lineWeight
        value.tint = tint
        value.glow = glow
        value.marginPercent = marginPercent
        value.exportMode = exportMode
        return value
    }
}
