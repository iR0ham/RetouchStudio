import CoreGraphics
import Foundation
import ImageIO
import StudioCore

/// The edit value (`AIEdit`) lives in StudioCore, because a document carries it
/// on every platform. Where its two files live and how they are adopted is this
/// app's job and stays here.

extension AIEdit {
    /// Convenience for the worker reply and the editor, which measure in
    /// CoreGraphics points. The stored value stays portable.
    init(id: UUID = UUID(), preset: String, prompt: String, seed: Int,
         patchFile: String, alphaFile: String, box: CGRect, imagePixels: CGSize,
         patchOrientation: DocumentOrientation? = nil, createdAt: Date = Date(),
         seconds: Double = 0, outsidePixelsIdentical: Bool = true) {
        self.init(id: id, preset: preset, prompt: prompt, seed: seed,
                  patchFile: patchFile, alphaFile: alphaFile,
                  box: StudioRect(box), imagePixels: StudioSize(imagePixels),
                  patchOrientation: patchOrientation, createdAt: createdAt,
                  seconds: seconds, outsidePixelsIdentical: outsidePixelsIdentical)
    }
}

/// Where edit pixels live on disk. One folder per edit id, next to the model
/// cache, so a project file stays a small sidecar and two projects that share
/// an edit share the same bytes.
enum AIEditStore {
    /// Tests point this at a scratch directory so adopting an edit never writes
    /// into the store belonging to the app the owner is working in.
    static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
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
