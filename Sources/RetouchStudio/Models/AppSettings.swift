import Foundation

/// Preferences that outlive one photo. Everything here is a *default* or a
/// view preference; per-photo work still lives in the project file.
///
/// Stored in `UserDefaults`, written on every change, read once at launch. The
/// editor mirrors the values it needs so the sliders keep working exactly as
/// before; this type only decides what a fresh start looks like.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    enum Defaults {
        static let autoRetouchStrength = 70.0
        static let autoColorStrength = 100.0
        static let comparePosition = 0.45
        static let exportFormat = "jpeg"
        static let exportQuality = 0.92
        static let exportLongEdge = 0
        static let healBrushPercent = 1.6
        static let showFaceOverlay = false
        static let stripLocationMetadata = true
    }

    private enum Key {
        static let autoRetouchStrength = "settings.autoRetouchStrength"
        static let autoColorStrength = "settings.autoColorStrength"
        static let comparePosition = "settings.comparePosition"
        static let exportFormat = "settings.exportFormat"
        static let exportQuality = "settings.exportQuality"
        static let exportLongEdge = "settings.exportLongEdge"
        static let healBrushPercent = "settings.healBrushPercent"
        static let showFaceOverlay = "settings.showFaceOverlay"
        static let recovery = "settings.recoveryEnabled"
        static let stripLocationMetadata = "settings.stripLocationMetadata"
    }

    private let store: UserDefaults

    @Published var autoRetouchStrength: Double {
        didSet { store.set(autoRetouchStrength, forKey: Key.autoRetouchStrength) }
    }
    @Published var autoColorStrength: Double {
        didSet { store.set(autoColorStrength, forKey: Key.autoColorStrength) }
    }
    /// Where the before/after split sits when a photo is opened.
    @Published var comparePosition: Double {
        didSet { store.set(comparePosition, forKey: Key.comparePosition) }
    }
    @Published var exportFormat: String {
        didSet { store.set(exportFormat, forKey: Key.exportFormat) }
    }
    @Published var exportQuality: Double {
        didSet { store.set(exportQuality, forKey: Key.exportQuality) }
    }
    /// Longest exported edge in pixels; 0 keeps the original size.
    @Published var exportLongEdge: Int {
        didSet { store.set(exportLongEdge, forKey: Key.exportLongEdge) }
    }
    @Published var healBrushPercent: Double {
        didSet { store.set(healBrushPercent, forKey: Key.healBrushPercent) }
    }
    @Published var showFaceOverlay: Bool {
        didSet { store.set(showFaceOverlay, forKey: Key.showFaceOverlay) }
    }
    /// Autosave a recovery copy while a photo has unsaved work.
    @Published var recoveryEnabled: Bool {
        didSet { store.set(recoveryEnabled, forKey: Key.recovery) }
    }
    /// Leave GPS and camera identity out of exports. On by default: a
    /// retouched portrait should not publish where it was taken or which body
    /// and lens produced it.
    @Published var stripLocationMetadata: Bool {
        didSet { store.set(stripLocationMetadata, forKey: Key.stripLocationMetadata) }
    }
    /// The interface language. The global `AppLanguage.current` follows it, so
    /// the font tokens and the About/Help windows read the same answer.
    @Published var language: AppLanguage = AppLanguage.current {
        didSet { AppLanguage.current = language }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        func anyDouble(_ key: String, _ fallback: Double) -> Double {
            store.object(forKey: key) == nil ? fallback : store.double(forKey: key)
        }
        autoRetouchStrength = anyDouble(Key.autoRetouchStrength, Defaults.autoRetouchStrength)
        autoColorStrength = anyDouble(Key.autoColorStrength, Defaults.autoColorStrength)
        comparePosition = min(1, max(0, anyDouble(Key.comparePosition, Defaults.comparePosition)))
        exportFormat = store.string(forKey: Key.exportFormat) ?? Defaults.exportFormat
        exportQuality = min(1, max(0.4, anyDouble(Key.exportQuality, Defaults.exportQuality)))
        exportLongEdge = max(0, store.integer(forKey: Key.exportLongEdge))
        healBrushPercent = max(0.4, anyDouble(Key.healBrushPercent, Defaults.healBrushPercent))
        showFaceOverlay = store.object(forKey: Key.showFaceOverlay) == nil
            ? Defaults.showFaceOverlay
            : store.bool(forKey: Key.showFaceOverlay)
        recoveryEnabled = store.object(forKey: Key.recovery) == nil
            ? true
            : store.bool(forKey: Key.recovery)
        // A preference written before this key existed decodes to the privacy-
        // preserving default, not to "keep everything".
        stripLocationMetadata = store.object(forKey: Key.stripLocationMetadata) == nil
            ? Defaults.stripLocationMetadata
            : store.bool(forKey: Key.stripLocationMetadata)
    }

    func resetToDefaults() {
        autoRetouchStrength = Defaults.autoRetouchStrength
        autoColorStrength = Defaults.autoColorStrength
        comparePosition = Defaults.comparePosition
        exportFormat = Defaults.exportFormat
        exportQuality = Defaults.exportQuality
        exportLongEdge = Defaults.exportLongEdge
        healBrushPercent = Defaults.healBrushPercent
        showFaceOverlay = Defaults.showFaceOverlay
        recoveryEnabled = true
        stripLocationMetadata = Defaults.stripLocationMetadata
        language = .english
    }
}

// MARK: - Recent files

struct RecentEntry: Codable, Identifiable, Equatable {
    var path: String
    var isProject: Bool
    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Last few files the owner opened, newest first. Kept as plain paths: the app
/// is not sandboxed, so a path is enough to reopen the file.
@MainActor
final class RecentStore: ObservableObject {

    static let shared = RecentStore()

    @Published private(set) var entries: [RecentEntry] = []

    private let store: UserDefaults
    private let key = "recentFiles"
    private let limit = 8

    init(store: UserDefaults = .standard) {
        self.store = store
        guard let data = store.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentEntry].self, from: data) else { return }
        entries = decoded
        prune()
    }

    func add(_ url: URL, isProject: Bool) {
        let path = url.standardizedFileURL.path
        var next = entries.filter { $0.path != path }
        next.insert(RecentEntry(path: path, isProject: isProject), at: 0)
        if next.count > limit { next.removeLast(next.count - limit) }
        entries = next
        prune()
        save()
    }

    func remove(_ entry: RecentEntry) {
        entries.removeAll { $0.path == entry.path }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Drops files that no longer exist. Called on changes, not while a menu is
    /// being built, so it never mutates state during a view update.
    func prune() {
        let alive = entries.filter(\.exists)
        if alive.count != entries.count {
            entries = alive
            save()
        }
    }

    private func save() {
        let data = try? JSONEncoder().encode(entries)
        store.set(data, forKey: key)
    }
}
