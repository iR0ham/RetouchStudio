import CoreImage
import Foundation

/// Background images live beside the AI edits, not inside the project file:
/// the document stores the stored filename, so a project stays small and can be
/// reopened after the original backdrop was moved or deleted.
enum BackdropStore {
    /// Tests point this at a scratch directory so a copied backdrop never
    /// reaches the store belonging to the app the owner is working in.
    static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("RetouchStudio/backdrops", isDirectory: true)
    }

    /// Copies the chosen file in and returns its stored name. The extension is
    /// kept so Core Image can recognise the format by filename alone.
    static func store(_ url: URL) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        try FileManager.default.copyItem(at: url, to: root.appendingPathComponent(name))
        return name
    }

    static func url(for name: String) -> URL? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent else { return nil }
        let url = root.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Decoded once per nickname; a slider drag must not re-read a 40 MP JPEG
    /// on every preview frame.
    static func image(named name: String) -> CIImage? {
        guard let url = url(for: name) else { return nil }
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = CIImage(contentsOf: url,
                                  options: [CIImageOption.applyOrientationProperty: true])
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static let cache = NSCache<NSString, CIImage>()
}
