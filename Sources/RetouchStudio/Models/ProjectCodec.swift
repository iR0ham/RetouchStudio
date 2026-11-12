import CoreGraphics
import Foundation
import StudioCore

/// One snapshot of an open document, ready to become a project. The shell waives
/// the cases the codec cannot decide (no photo open, blocking work running).
struct ProjectInput {
    var imageURL: URL
    var state: DocumentState
    var exportFormat: String
    var exportQuality: Double
    /// Zero means "keep the photo's own size"; the codec writes it as `nil`.
    var exportLongEdge: Int
    var autoRetouchStrength: Double
    var autoColorStrength: Double
}

struct FileProjectSourceAccess: ProjectSourceAccess {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

struct URLBookmarkStore: ProjectBookmarkStore {
    func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }
}

/// Where the photo a project points at lives now, in order of trust: the
/// bookmark survives a move, the absolute path covers an unmoved file, and a
/// file sitting next to the project covers a moved folder. `nil` means the
/// owner has to point at it.
struct ProjectSourceResolver {
    var sources: ProjectSourceAccess
    var bookmarks: ProjectBookmarkStore

    func resolve(_ project: RetouchProject, projectURL: URL?) -> URL? {
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

enum ProjectCodecError: Error, Equatable {
    case tooNew(Int)
    /// A v4 file requires a capability this build does not implement. Reading
    /// it as if the capability were absent would quietly change the document.
    case unsupportedFeatures([String])
}

/// Reads and writes the v3 sidecar. Byte compatibility lives here: the encoder
/// settings are fixed, and normalizing empty values to `nil` keeps each file as
/// small as earlier readers expect. The version guard is part of decoding so a
/// caller cannot open a format it does not understand.
enum ProjectCodec {
    /// Highest project file version this build reads.
    static let currentVersion = ProjectV4.currentVersion

    static func makeProject(_ input: ProjectInput, bookmarks: ProjectBookmarkStore) -> RetouchProject {
        let state = input.state
        return RetouchProject(imagePath: input.imageURL.path,
                              imageBookmark: bookmarks.bookmark(for: input.imageURL),
                              adjustments: state.adjustments,
                              exportFormat: input.exportFormat,
                              exportQuality: input.exportQuality,
                              exportLongEdge: input.exportLongEdge == 0 ? nil : input.exportLongEdge,
                              autoRetouchStrength: input.autoRetouchStrength,
                              autoColorStrength: input.autoColorStrength,
                              crop: state.crop?.cgRect,
                              healSpots: state.healSpots.isEmpty ? nil : state.healSpots,
                              stickers: state.stickers.isEmpty ? nil : state.stickers,
                              aiEdits: state.aiEdits.isEmpty ? nil : state.aiEdits,
                              analysis: state.analysis == AnalysisSettings() ? nil : state.analysis,
                              selectedFace: state.selectedFaceIndex,
                              orientation: state.orientation.isIdentity ? nil : state.orientation)
    }

    /// v3 bytes, unchanged. The baseline fixture proves this.
    static func encode(_ project: RetouchProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    /// Writes the version the document was read as. A v3 file never silently
    /// becomes v4, and a v4 file keeps its keyed geometry and unknown keys.
    static func encode(_ project: RetouchProject,
                       context: ProjectWriteContext) throws -> Data {
        if context.isV4 {
            return try encodeV4(project,
                                unknownFields: context.unknownFields,
                                requiredFeatures: context.requiredFeatures)
        }
        let base = try encode(project)
        guard !context.unknownFields.isEmpty else { return base }
        return try merging(base, unknown: context.unknownFields,
                           known: RetouchProject.knownJSONKeys)
    }

    /// The portable v4 document: named geometry records and a stable key order.
    static func encodeV4(_ project: RetouchProject,
                         unknownFields: [String: ProjectJSONValue] = [:],
                         requiredFeatures: [String] = []) throws -> Data {
        let record = ProjectV4(project: project, requiredFeatures: requiredFeatures)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let typed = try encoder.encode(record)
        guard !unknownFields.isEmpty else { return typed }
        return try merging(typed, unknown: unknownFields, known: ProjectV4.knownKeys)
    }

    static func decode(_ data: Data) throws -> RetouchProject {
        try read(data).project
    }

    /// Reads a v3 or v4 file and keeps what a later save needs.
    static func read(_ data: Data) throws -> ProjectFile {
        let decoder = JSONDecoder()
        let object = try decoder.decode([String: ProjectJSONValue].self, from: data)
        let version = object["version"]?.integerValue ?? RetouchProject.currentVersion
        guard version <= currentVersion else {
            throw ProjectCodecError.tooNew(version)
        }
        if version >= ProjectV4.currentVersion {
            let record = try decoder.decode(ProjectV4.self, from: data)
            let required = record.requiredFeatures ?? []
            let unsupported = required.filter { !ProjectV4.supportedFeatures.contains($0) }
            guard unsupported.isEmpty else {
                throw ProjectCodecError.unsupportedFeatures(unsupported.sorted())
            }
            return ProjectFile(
                project: record.project,
                context: ProjectWriteContext(
                    version: version,
                    unknownFields: object.filter { !ProjectV4.knownKeys.contains($0.key) },
                    requiredFeatures: required))
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
}
