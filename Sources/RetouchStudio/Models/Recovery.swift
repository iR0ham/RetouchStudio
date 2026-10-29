import Foundation

/// One recovery copy of the open edit, written while the photo has unsaved
/// work. It is deliberately not the project file: it lives in Application
/// Support, is overwritten every few seconds, and only exists to survive a
/// crash or a forced quit.
enum RecoveryStore {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        // Keyed by bundle, so a test build can never hand its recovery copy to
        // the app the owner is working in.
        let id = Bundle.main.bundleIdentifier ?? "local.retouchstudio.app"
        return base.appendingPathComponent("Retouch Studio/Recovery/\(id)", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("session.retouch")
    }

    static func write(_ project: RetouchProject) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(project).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func read() -> RetouchProject? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RetouchProject.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Only deletes the copy when it belongs to the photo that just became
    /// clean. Opening a different photo at launch must not erase work the
    /// recovery prompt never got the chance to offer.
    static func clear(ifSourcePath path: String?) {
        guard let path else { return }
        if let project = read(), project.imagePath != path { return }
        clear()
    }
}
