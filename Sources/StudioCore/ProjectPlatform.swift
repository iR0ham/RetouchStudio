import Foundation

/// The platform services a project needs but must not perform itself.
///
/// These are ports, not implementations: a host supplies them, so the rules
/// that use them stay free of file-system and bookmark APIs. Foundation is
/// enough for the macOS adapter, but a different host can satisfy the same
/// contracts with its own primitives.

/// Asks whether a path exists. A resolver only needs the answer, and tests
/// supply their own.
public protocol ProjectSourceAccess {
    func fileExists(at url: URL) -> Bool
}

/// Makes and resolves the bookmark that keeps a photo reachable after a move.
public protocol ProjectBookmarkStore {
    func bookmark(for url: URL) -> Data?
    func resolveBookmark(_ data: Data) -> URL?
}
