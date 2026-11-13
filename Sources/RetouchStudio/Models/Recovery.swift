import Foundation
import StudioCore

/// What the owner chose when the launch recovery prompt appeared. Cancel is a
/// first-class answer: it postpones the decision and keeps the recovery copy.
enum RecoveryChoice: Equatable {
    case locate
    case cancel
    case discard
    case restore
}

/// The photo a snapshot was made against, recorded when the snapshot was
/// written. Size and modification date together tell "the same photo" from
/// "something else now lives at that path" without hashing a large file on
/// every autosave.
struct RecoverySourceIdentity: Codable, Equatable {
    var bytes: Int64
    var modified: Date

    static func of(_ url: URL) -> RecoverySourceIdentity? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let bytes = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return RecoverySourceIdentity(bytes: Int64(bytes), modified: modified)
    }
}

/// One recovery candidate. `project` is exactly what an autosave would have
/// written; the date orders candidates and the source identity is what lets the
/// launcher tell a moved photo from a different one.
struct RecoverySnapshot: Codable {
    /// Bumped only if the wrapper's meaning changes. Legacy copies that were
    /// written as a bare project decode with version 0 and no identity.
    static let currentVersion = 1

    var version: Int
    var savedAt: Date
    var project: RetouchProject
    /// Nil for legacy snapshots and for a snapshot whose photo was already
    /// missing when it was written.
    var source: RecoverySourceIdentity?
    /// How the open document's file was written: its version, unknown top-level
    /// keys and required features. Nil for a v3 document and for every legacy
    /// snapshot, so an unchanged v3 snapshot keeps its exact bytes and a bare
    /// project still decodes.
    var fileContext: ProjectWriteContext? = nil

    init(project: RetouchProject, savedAt: Date = Date(),
         source: RecoverySourceIdentity? = nil,
         fileContext: ProjectWriteContext? = nil,
         version: Int = RecoverySnapshot.currentVersion) {
        self.version = version
        self.savedAt = savedAt
        self.project = project
        self.source = source
        self.fileContext = fileContext
    }

    /// Records the identity of the photo the project points at, resolving the
    /// bookmark first so a moved photo keeps its own identity. A context that
    /// carries no file metadata is not stored, so the snapshot stays the same
    /// shape and bytes a v3 build writes.
    static func capture(_ project: RetouchProject, savedAt: Date = Date(),
                        context: ProjectWriteContext = .v3) -> RecoverySnapshot {
        let identity = RecoveryStore.sourceURL(for: project).flatMap(RecoverySourceIdentity.of)
        return RecoverySnapshot(project: project, savedAt: savedAt, source: identity,
                                fileContext: context.carriesFileMetadata ? context : nil)
    }
}

/// Crash recovery with independent candidates.
///
/// `working.retouch` is the only mutable slot: autosave owns it and it always
/// describes the document on screen. Every candidate is a separate, immutable
/// file named `<milliseconds>-<uuid>.retouch`, so no decision about one copy
/// can overwrite or delete another. At launch the working slot and the two
/// legacy slots are lifted into `candidates/` before any new document can
/// autosave, which is what makes Cancel safe for every unresolved copy.
///
/// Restoring is ordered `write working -> verify working -> delete candidate`.
/// A crash before the write leaves the candidate, a crash between the two
/// leaves both complete copies, and a crash after the delete leaves the
/// durable working copy. No step deletes the only recoverable copy.
enum RecoveryStore {

    /// Deterministic failure points used by the data-preservation tests.
    enum Failure: Hashable {
        case workingWrite
        case workingRemove
        case candidateWrite
        case candidateRemove
        case quarantine
        case migrate
    }

    static var injectedFailures: Set<Failure> = []

    /// Invalidates every debounced write that captured an earlier value. Tests
    /// reset it with the scratch store so a task cannot follow them into the
    /// next scenario; EditorModel also bumps it when the active document is
    /// discarded or replaced, so a task that already woke up cannot write the
    /// old document's snapshot afterwards.
    private static var autosaveEpoch = RecoveryPolicy.AutosaveEpoch()

    static var epoch: Int { autosaveEpoch.value }

    static func invalidatePendingAutosaves() {
        autosaveEpoch.invalidate()
    }

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

    static var workingURL: URL {
        directory.appendingPathComponent("working.retouch")
    }

    static var candidatesDirectory: URL {
        directory.appendingPathComponent("candidates", isDirectory: true)
    }

    static var quarantineDirectory: URL {
        directory.appendingPathComponent("quarantine", isDirectory: true)
    }

    /// The two-slot layout of releases before the candidate store. Only read
    /// once, at launch, and renamed into `candidates/`.
    static var legacyActiveURL: URL {
        directory.appendingPathComponent("session.retouch")
    }

    static var legacyPendingURL: URL {
        directory.appendingPathComponent("pending.retouch")
    }

    /// Set when the launch could not move an unresolved working copy out of the
    /// autosave slot. Autosave must not overwrite it for the rest of the
    /// session; the failure is reported instead.
    private(set) static var workingLocked = false

    // MARK: - Values

    struct Candidate {
        let url: URL
        let snapshot: RecoverySnapshot
    }

    typealias SourceState = RecoverySourceState

    struct CandidateListing {
        var candidates: [Candidate] = []
        var quarantined = 0
        /// True when a file could neither be read nor set aside. It is left in
        /// place and retried on the next launch, never deleted.
        var failed = false
    }

    struct LaunchResult {
        var migrated = 0
        var quarantined = 0
        var failed = false
    }

    // MARK: - Launch

    /// Moves every unresolved copy out of the slots that can be overwritten.
    ///
    /// Legacy files are renamed one at a time (same volume, atomic), pending
    /// before active, with monotonically increasing dates so the postponed
    /// copy keeps being offered first. A file that cannot be read is
    /// quarantined; a file that cannot be moved stays where it is and is
    /// reported, so the next launch retries it.
    static func prepareForLaunch() -> LaunchResult {
        var result = LaunchResult()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: candidatesDirectory, withIntermediateDirectories: true)
        } catch {
            // Without a candidates folder nothing can leave the working slot,
            // so that slot must stay read-only for the session.
            result.failed = true
            if manager.fileExists(atPath: workingURL.path) { workingLocked = true }
            return result
        }

        var previous: Date?
        for url in [legacyPendingURL, legacyActiveURL] where manager.fileExists(atPath: url.path) {
            guard let original = readLoose(url) else {
                if quarantine(url) { result.quarantined += 1 } else { result.failed = true }
                continue
            }
            let savedAt = RecoveryPolicy.monotonic(original.savedAt, after: previous)
            previous = savedAt
            var snapshot = original
            snapshot.savedAt = savedAt
            if move(url, to: candidateURL(for: savedAt)) {
                result.migrated += 1
            } else {
                result.failed = true
            }
        }

        // The working slot is an unresolved document too. Lift it before a new
        // document can autosave over it. A failed attempt leaves the slot
        // locked for the rest of this session, but the next launch retries:
        // the file is still the only copy and may have become movable.
        if manager.fileExists(atPath: workingURL.path) {
            if let snapshot = readLoose(workingURL) {
                if move(workingURL, to: candidateURL(for: snapshot.savedAt)) {
                    workingLocked = false
                } else {
                    workingLocked = true
                    result.failed = true
                }
            } else if quarantine(workingURL) {
                workingLocked = false
                result.quarantined += 1
            } else {
                workingLocked = true
                result.failed = true
            }
        }
        return result
    }

    // MARK: - Working slot

    static func writeWorking(_ snapshot: RecoverySnapshot) -> Bool {
        guard !workingLocked, !injectedFailures.contains(.workingWrite) else { return false }
        return write(snapshot, to: workingURL)
    }

    static func readWorking() -> RecoverySnapshot? {
        readLoose(workingURL)
    }

    /// Removes the autosave copy only when it belongs to the photo the caller
    /// is done with. Candidates are never touched here, and a copy that could
    /// not be promoted out of the slot is an unresolved candidate, so it is
    /// never removed either.
    @discardableResult
    static func removeWorking(ifSourcePath path: String? = nil) -> Bool {
        let manager = FileManager.default
        guard !workingLocked else { return false }
        guard manager.fileExists(atPath: workingURL.path) else { return true }
        if let path {
            guard let snapshot = readLoose(workingURL) else { return false }
            guard snapshot.project.imagePath == path else { return true }
        }
        guard !injectedFailures.contains(.workingRemove) else { return false }
        do {
            try manager.removeItem(at: workingURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Candidates

    @discardableResult
    static func saveCandidate(_ snapshot: RecoverySnapshot) -> URL? {
        guard !injectedFailures.contains(.candidateWrite) else { return nil }
        let url = candidateURL(for: snapshot.savedAt)
        return write(snapshot, to: url) ? url : nil
    }

    /// Candidates oldest first. A file that cannot be decoded is moved to
    /// `quarantine/`, so it neither blocks the valid candidates nor gets
    /// silently deleted.
    static func loadCandidates() -> CandidateListing {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: candidatesDirectory,
                                                          includingPropertiesForKeys: nil) else {
            return CandidateListing()
        }
        var listing = CandidateListing()
        let ordered = urls.filter { RecoveryPolicy.isCandidateFileName($0.lastPathComponent) }
        for url in ordered {
            if let snapshot = readLoose(url) {
                listing.candidates.append(Candidate(url: url, snapshot: snapshot))
            } else if quarantine(url) {
                listing.quarantined += 1
            } else {
                listing.failed = true
            }
        }
        listing.candidates.sort {
            RecoveryPolicy.olderFirst(
                .init(savedAt: $0.snapshot.savedAt, name: $0.url.lastPathComponent),
                .init(savedAt: $1.snapshot.savedAt, name: $1.url.lastPathComponent))
        }
        return listing
    }

    static func removeCandidate(at url: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL
                == candidatesDirectory.standardizedFileURL else { return false }
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return true }
        guard !injectedFailures.contains(.candidateRemove) else { return false }
        do {
            try manager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Source identity

    /// Where the project's photo lives now, bookmark first so a moved file is
    /// still the same photo. `nil` means the owner has to point at it.
    static func sourceURL(for project: RetouchProject) -> URL? {
        let manager = FileManager.default
        if let data = project.imageBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               manager.fileExists(atPath: url.path) {
                return url
            }
        }
        let absolute = URL(fileURLWithPath: project.imagePath)
        return manager.fileExists(atPath: absolute.path) ? absolute : nil
    }

    static func sourceState(for snapshot: RecoverySnapshot) -> SourceState {
        let url = sourceURL(for: snapshot.project)
        return RecoveryPolicy.sourceState(
            url: url,
            recorded: snapshot.source,
            version: snapshot.version,
            current: url.flatMap(RecoverySourceIdentity.of))
    }

    // MARK: - Test cleanup

    /// Removes every scratch copy. No production path calls this.
    static func clearAll() {
        autosaveEpoch.invalidate()
        workingLocked = false
        let manager = FileManager.default
        for url in [workingURL, legacyActiveURL, legacyPendingURL] {
            try? manager.removeItem(at: url)
        }
        try? manager.removeItem(at: candidatesDirectory)
        try? manager.removeItem(at: quarantineDirectory)
    }

    // MARK: - Files

    private static func candidateURL(for savedAt: Date) -> URL {
        let millis = Int64((savedAt.timeIntervalSince1970 * 1000).rounded(.down))
        let name = String(format: "%013lld-%@.retouch", millis, UUID().uuidString)
        return candidatesDirectory.appendingPathComponent(name)
    }

    /// Reads either a snapshot or the bare project older releases wrote.
    private static func readLoose(_ url: URL) -> RecoverySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return RecoveryPolicy.snapshot(from: data, modified: modified)
    }

    private static func write(_ snapshot: RecoverySnapshot, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            // The caller deletes the previous copy only after this write is
            // proven complete, so a successful return from write(2) is not
            // enough: read the file back and compare the bytes.
            return try Data(contentsOf: url) == data
        } catch {
            return false
        }
    }

    private static func move(_ source: URL, to destination: URL) -> Bool {
        guard !injectedFailures.contains(.migrate) else { return false }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    private static func quarantine(_ url: URL) -> Bool {
        guard !injectedFailures.contains(.quarantine) else { return false }
        guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            return false
        }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
            let name = RecoveryPolicy.quarantineFileName(
                base: url.deletingPathExtension().lastPathComponent,
                pathExtension: url.pathExtension,
                id: UUID())
            try manager.moveItem(at: url, to: quarantineDirectory.appendingPathComponent(name))
            return true
        } catch {
            return false
        }
    }

}
