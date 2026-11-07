import CoreGraphics
import Foundation
import ImageIO

/// One generative edit: the pixels the worker produced, the alpha that says
/// where they may be used, and where that rectangle sits on the original photo.
///
/// The photo itself is never rewritten. An edit is a layer — the preview and
/// the export both re-composite it from these two files, so undo is a list
/// change and a project can be reopened at any size.
struct AIEdit: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Which Quick Edit preset produced it, for the UI and the report.
    var preset: String
    var prompt: String
    var seed: Int
    /// `patch.png`: the worker's edited pixels for `box`, at the job's size.
    var patchFile: String
    /// `alpha.png`: 0…255, zero everywhere outside the authorized region.
    var alphaFile: String
    /// Authorized rectangle in normalized original-photo coordinates, top-left
    /// origin, like `HealSpot` and `Sticker`.
    var box: CGRect
    /// The job image's pixel size. Used to keep the two files' true aspect when
    /// a project is reopened at a different preview size.
    var imagePixels: CGSize
    var createdAt: Date = Date()

    /// How long the worker took, kept for the record and the status line.
    var seconds: Double = 0
    /// The worker's own report that nothing outside the region moved.
    var outsidePixelsIdentical: Bool = true
}

/// Where edit pixels live on disk. One folder per edit id, next to the model
/// cache, so a project file stays a small sidecar and two projects that share
/// an edit share the same bytes.
enum AIEditStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("RetouchStudio/AI/edits", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func url(for edit: AIEdit, file: String) -> URL {
        folder(for: edit.id).appendingPathComponent(file)
    }

    static func patchURL(_ edit: AIEdit) -> URL { url(for: edit, file: edit.patchFile) }
    static func alphaURL(_ edit: AIEdit) -> URL { url(for: edit, file: edit.alphaFile) }

    /// True when both files are on disk and readable. A project can outlive a
    /// cache clean, and the editor has to say so instead of drawing nothing.
    static func isAvailable(_ edit: AIEdit) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: patchURL(edit).path)
            && manager.fileExists(atPath: alphaURL(edit).path)
    }

    /// Copies the job's output into the store atomically: two files are written
    /// under a temporary folder and only then renamed into place, so an edit
    /// that exists in the document always has both halves.
    @discardableResult
    static func adopt(id: UUID, patch: URL, alpha: URL) throws -> (patch: String, alpha: String) {
        let manager = FileManager.default
        let destination = folder(for: id)
        let staging = root.appendingPathComponent(".\(id.uuidString).staging", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try manager.copyItem(at: patch, to: staging.appendingPathComponent("patch.png"))
        try manager.copyItem(at: alpha, to: staging.appendingPathComponent("alpha.png"))
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: staging, to: destination)
        return ("patch.png", "alpha.png")
    }

    static func remove(_ edit: AIEdit) {
        try? FileManager.default.removeItem(at: folder(for: edit.id))
    }
}
