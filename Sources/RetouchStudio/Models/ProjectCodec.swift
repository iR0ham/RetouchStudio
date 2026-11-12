import CoreGraphics
import Foundation

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

/// Asks whether a path exists. The codec cannot touch the file system itself:
/// the resolver only needs the answer, and tests supply their own.
protocol ProjectSourceAccess {
    func fileExists(at url: URL) -> Bool
}

/// Makes and resolves the bookmark that keeps a photo reachable after a move.
protocol ProjectBookmarkStore {
    func bookmark(for url: URL) -> Data?
    func resolveBookmark(_ data: Data) -> URL?
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
}

/// Reads and writes the v3 sidecar. Byte compatibility lives here: the encoder
/// settings are fixed, and normalizing empty values to `nil` keeps each file as
/// small as earlier readers expect. The version guard is part of decoding so a
/// caller cannot open a format it does not understand.
enum ProjectCodec {
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
                              crop: state.crop,
                              healSpots: state.healSpots.isEmpty ? nil : state.healSpots,
                              stickers: state.stickers.isEmpty ? nil : state.stickers,
                              aiEdits: state.aiEdits.isEmpty ? nil : state.aiEdits,
                              analysis: state.analysis == AnalysisSettings() ? nil : state.analysis,
                              selectedFace: state.selectedFaceIndex,
                              orientation: state.orientation.isIdentity ? nil : state.orientation)
    }

    static func encode(_ project: RetouchProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    static func decode(_ data: Data) throws -> RetouchProject {
        let project = try JSONDecoder().decode(RetouchProject.self, from: data)
        guard project.version <= RetouchProject.currentVersion else {
            throw ProjectCodecError.tooNew(project.version)
        }
        return project
    }
}
