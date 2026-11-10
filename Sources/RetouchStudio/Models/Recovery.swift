import Foundation

/// What the owner chose when the launch recovery prompt appeared. Cancel is a
/// first-class answer: it postpones the decision and keeps the recovery copy.
enum RecoveryChoice: Equatable {
    case locate
    case cancel
    case discard
    case restore
}

/// Two independent crash copies of the open edit.
///
/// Active Recovery (`session.retouch`) is the ordinary autosave slot for the
/// document on screen. Pending Recovery (`pending.retouch`) is the snapshot a
/// cancelled launch prompt left behind: it is never written by autosave, almost
/// never moved, and only Restore or Discard resolves it. Keeping them in
/// separate files is what lets the owner reopen the same photo, edit another
/// one, or turn recovery off without losing the postponed edit.
enum RecoveryStore {

    /// Tests point this at a scratch directory so they can never touch the
    /// copies belonging to the app the owner is working in.
    static var directoryOverride: URL?

    /// The copies belonging to the app installed on this Mac. Tests may read
    /// them to prove they leave them alone, but only `directory` decides where
    /// writes go.
    static var productionDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        // Keyed by bundle, so a test build can never hand its recovery copies to
        // the app the owner is working in.
        let id = Bundle.main.bundleIdentifier ?? "app.retouchstudio.mac"
        return base.appendingPathComponent("Retouch Studio/Recovery/\(id)", isDirectory: true)
    }

    static var directory: URL {
        directoryOverride ?? productionDirectory
    }

    static var activeURL: URL {
        directory.appendingPathComponent("session.retouch")
    }

    static var pendingURL: URL {
        directory.appendingPathComponent("pending.retouch")
    }

    // MARK: - Active Recovery

    static func writeActive(_ project: RetouchProject) -> Bool {
        write(project, to: activeURL)
    }

    static func readActive() -> RetouchProject? {
        read(activeURL)
    }

    static func clearActive() {
        try? FileManager.default.removeItem(at: activeURL)
    }

    /// Only deletes the active copy when it belongs to the photo that just
    /// became clean. Pending Recovery is never touched here.
    static func clearActive(ifSourcePath path: String?) {
        guard let path else { return }
        if let project = readActive(), project.imagePath != path { return }
        clearActive()
    }

    // MARK: - Pending Recovery

    static func readPending() -> RetouchProject? {
        read(pendingURL)
    }

    /// Moves the active copy into the pending slot in one rename, which is the
    /// step that makes a cancelled prompt safe from later autosaves. Refuses to
    /// overwrite an existing pending copy; the caller keeps the active file in
    /// that case rather than silently deleting either candidate.
    @discardableResult
    static func preserveActiveAsPending() -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: activeURL.path),
              !manager.fileExists(atPath: pendingURL.path) else { return false }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.moveItem(at: activeURL, to: pendingURL)
            return true
        } catch {
            return false
        }
    }

    /// Resolves a restored or discarded pending snapshot. Never called by
    /// autosave.
    static func discardPending() {
        try? FileManager.default.removeItem(at: pendingURL)
    }

    /// Test cleanup: removes both slots. No production path uses this.
    static func clearAll() {
        clearActive()
        discardPending()
    }

    // MARK: - Shared

    private static func write(_ project: RetouchProject, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func read(_ url: URL) -> RetouchProject? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RetouchProject.self, from: data)
    }
}
