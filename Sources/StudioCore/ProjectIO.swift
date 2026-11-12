import Foundation

/// A port for the bytes of one project file.
///
/// The codec decides what the bytes mean; a host decides where they live. That
/// keeps file-system, document-provider and security-scoped rules out of the
/// shared code while every platform still reads and writes the same format.
///
/// `URL` is Foundation's portable file location, not a platform type. Anything
/// a host needs beyond a location — bookmarks, coordinated access, sandbox
/// extensions — stays behind its own port.
public protocol ProjectByteStore {
    /// Returns the complete file or throws. A partial read is never returned.
    func readProjectData(at url: URL) throws -> Data

    /// Replaces the file in one step. Implementations use the strongest atomic
    /// primitive their platform offers; a throwing write leaves any existing
    /// file untouched.
    func writeProjectData(_ data: Data, to url: URL) throws
}

/// The project I/O failures a host reports, without leaking its own error
/// domain into the shared rules.
public enum ProjectIOError: Error, Equatable {
    case readFailed
    case writeFailed
}

/// Reads, writes and resolves project documents through host-supplied ports.
///
/// The store owns the order of operations (read bytes, decode, keep the file
/// context; encode, then replace the file) so every platform saves the same
/// bytes and preserves unknown fields the same way.
public struct ProjectStore {
    public var bytes: ProjectByteStore
    public var sources: ProjectSourceAccess
    public var bookmarks: ProjectBookmarkStore

    public init(bytes: ProjectByteStore, sources: ProjectSourceAccess,
                bookmarks: ProjectBookmarkStore) {
        self.bytes = bytes
        self.sources = sources
        self.bookmarks = bookmarks
    }

    public func makeProject(_ input: ProjectInput) -> RetouchProject {
        ProjectCodec.makeProject(input, bookmarks: bookmarks)
    }

    public func read(at url: URL) throws -> ProjectFile {
        let data: Data
        do {
            data = try bytes.readProjectData(at: url)
        } catch let error as ProjectIOError {
            throw error
        } catch {
            throw ProjectIOError.readFailed
        }
        return try ProjectCodec.read(data)
    }

    public func write(_ project: RetouchProject, context: ProjectWriteContext,
                      to url: URL) throws {
        let data = try ProjectCodec.encode(project, context: context)
        do {
            try bytes.writeProjectData(data, to: url)
        } catch let error as ProjectIOError {
            throw error
        } catch {
            throw ProjectIOError.writeFailed
        }
    }

    public func resolveSource(_ project: RetouchProject, projectURL: URL?) -> URL? {
        ProjectSourceResolver(sources: sources, bookmarks: bookmarks)
            .resolve(project, projectURL: projectURL)
    }
}
