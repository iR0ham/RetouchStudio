import Foundation
import StudioCore
import UniformTypeIdentifiers

/// The macOS side of the project ports. The document format, the version guard
/// and the save order live in StudioCore; everything here is about the Mac's
/// file system and its bookmarks.

extension RetouchProject {
    /// The app declares this type in Info.plist, so the panel filters to real
    /// project files instead of any JSON.
    static var contentType: UTType {
        UTType(exportedAs: "app.retouchstudio.project", conformingTo: .json)
    }
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

/// Atomic replace: `.atomic` writes a sibling file and renames it, so a failed
/// save leaves the previous project intact.
struct FileProjectByteStore: ProjectByteStore {
    func readProjectData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ProjectIOError.readFailed
        }
    }

    func writeProjectData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectIOError.writeFailed
        }
    }
}
