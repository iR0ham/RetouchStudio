import Foundation

/// A look the owner saved from their own slider positions.
struct UserPreset: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var adjustments: Adjustments = Adjustments()
}

/// Saved looks live in one small JSON file in Application Support. They belong
/// to the person rather than to a photo, so they have to survive closing a
/// project, and they cannot live inside a document the app does not own.
enum UserPresetStore {

    /// The default location. Tests pass their own path.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Retouch Studio", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    static func load(from url: URL = defaultURL) -> [UserPreset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UserPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [UserPreset], to url: URL = defaultURL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(presets) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
