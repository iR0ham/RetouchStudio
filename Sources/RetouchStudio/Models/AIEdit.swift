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

    /// The §3.6 record of one stored file: the artifact's own name plus the
    /// suffix, exactly as the helper filed it in its job folder.
    static func sidecar(of artifact: URL) -> URL {
        artifact.deletingLastPathComponent()
            .appendingPathComponent(artifact.lastPathComponent + AIProvenance.sidecarSuffix)
    }

    /// True when both files are on disk and, where a record exists, still match
    /// it. A project can outlive a cache clean, and the editor has to say so
    /// instead of drawing nothing.
    ///
    /// Existence alone used to be the whole test, so a patch truncated by a full
    /// disk or a torn copy read as healthy and got composited. The owner's rule
    /// for an edit that has a record and disagrees with it is the same one §3.6
    /// applies to any artifact: it is missing. An edit stored before records
    /// existed has no sidecar to disagree with, and keeps the answer it always
    /// gave rather than vanishing from a project that opens today.
    static func isAvailable(_ edit: AIEdit) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: patchURL(edit).path),
              manager.fileExists(atPath: alphaURL(edit).path) else { return false }
        return provenanceIntact(edit, file: edit.patchFile)
            && provenanceIntact(edit, file: edit.alphaFile)
    }

    /// Compositing asks this per frame, so a match is remembered against the
    /// file's own size and modification time: the pair is hashed once per edit,
    /// and any write to either file changes the stamp and asks again.
    private static func provenanceIntact(_ edit: AIEdit, file: String) -> Bool {
        let artifact = url(for: edit, file: file)
        let record = sidecar(of: artifact)
        let manager = FileManager.default
        guard manager.fileExists(atPath: record.path) else { return true }
        guard let values = try? artifact.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return false }
        let stamp = "\(size):\(modified.timeIntervalSinceReferenceDate)"
        verifiedLock.lock()
        if let cached = verified[artifact.path], cached.stamp == stamp {
            let intact = cached.intact
            verifiedLock.unlock()
            return intact
        }
        verifiedLock.unlock()
        let intact = (try? AIProvenance.verifiedArtifact(path: artifact.path,
                                                         sidecarPath: record.path)) != nil
        verifiedLock.lock()
        verified[artifact.path] = (stamp: stamp, intact: intact)
        verifiedLock.unlock()
        return intact
    }

    private static var verified: [String: (stamp: String, intact: Bool)] = [:]
    private static let verifiedLock = NSLock()

    /// Copies the job's output into the store atomically: two files are written
    /// under a temporary folder and only then renamed into place, so an edit
    /// that exists in the document always has both halves.
    ///
    /// Each half arrives with the §3.6 record that names its bytes, and adoption
    /// reads that record twice — once against the helper's file before anything
    /// is copied, once against the stored copy before the folder lands. The
    /// second check is the one that matters: the store renames `result.png` to
    /// `patch.png`, so a digest taken from the wrong side of the copy would
    /// license bytes nobody measured. A pair that disagrees throws with nothing
    /// in the store.
    @discardableResult
    static func adopt(id: UUID, patch: URL, alpha: URL,
                      patchProvenance: URL, alphaProvenance: URL) throws
        -> (patch: String, alpha: String) {
        let manager = FileManager.default
        let destination = folder(for: id)
        let staging = root.appendingPathComponent(".\(id.uuidString).staging", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try copyVerified(patch, record: patchProvenance,
                             into: staging, named: "patch.png")
            try copyVerified(alpha, record: alphaProvenance,
                             into: staging, named: "alpha.png")
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: staging, to: destination)
        return ("patch.png", "alpha.png")
    }

    /// Verified source → stored name → verified again.
    private static func copyVerified(_ artifact: URL, record: URL,
                                     into directory: URL, named name: String) throws {
        _ = try AIProvenance.verifiedArtifact(path: artifact.path,
                                              sidecarPath: record.path)
        let stored = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: artifact, to: stored)
        let storedRecord = sidecar(of: stored)
        try FileManager.default.copyItem(at: record, to: storedRecord)
        _ = try AIProvenance.verifiedArtifact(path: stored.path,
                                              sidecarPath: storedRecord.path)
    }

    static func remove(_ edit: AIEdit) {
        try? FileManager.default.removeItem(at: folder(for: edit.id))
    }
}
