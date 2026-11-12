import Foundation
import StudioCore

/// How the photo a snapshot was made against relates to what is on disk now.
/// `.available` offers the copy; `.changed` and `.missing` ask the owner before
/// anything is applied.
enum RecoverySourceState: Equatable {
    case available(URL)
    case changed(URL)
    case missing
}

/// The decisions a recovery launch makes, with no file system underneath.
///
/// `RecoveryStore` still owns the directory layout, renames and durability.
/// Everything that can be decided from values alone lives here or in
/// `RecoveryRules`. The rules that read only names and dates live in
/// StudioCore; the ones that need a snapshot or a project stay here.
enum RecoveryPolicy {

    /// Why a candidate cannot be restored by this build. The copy itself is
    /// never touched: a newer build may still understand it.
    enum RecoveryRefusal: Equatable {
        case tooNew(Int)
        case unsupportedFeatures([String])
    }

    /// Invalidates work captured under an earlier generation.
    typealias AutosaveEpoch = RecoveryRules.AutosaveEpoch

    /// The date is what "oldest first" means. A candidate name carries only
    /// milliseconds, so two copies from the same millisecond keep a stable
    /// order by name without letting the name decide between different dates.
    typealias CandidateOrderKey = RecoveryRules.CandidateOrderKey

    static func olderFirst(_ lhs: CandidateOrderKey, _ rhs: CandidateOrderKey) -> Bool {
        RecoveryRules.olderFirst(lhs, rhs)
    }

    /// Candidate copies, never the working slot and never a dotfile the file
    /// system left behind.
    static func isCandidateFileName(_ name: String) -> Bool {
        RecoveryRules.isCandidateFileName(name)
    }

    /// Reads either a snapshot or the bare project older releases wrote.
    /// A bare project decodes as version 0 with no source identity, which is
    /// what makes legacy copies offerable without knowing their photo.
    static func snapshot(from data: Data, modified: Date?) -> RecoverySnapshot? {
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(RecoverySnapshot.self, from: data) {
            return snapshot
        }
        guard let project = try? decoder.decode(RetouchProject.self, from: data) else { return nil }
        return RecoverySnapshot(project: project, savedAt: modified ?? Date(),
                                source: nil, version: 0)
    }

    /// A recovery copy written by a newer build must never be restored as v3
    /// or lose a capability this build cannot honor. Such a candidate stays on
    /// disk for the build that can read it.
    static func refusal(for snapshot: RecoverySnapshot) -> RecoveryRefusal? {
        guard let context = snapshot.fileContext else { return nil }
        guard context.version <= ProjectCodec.currentVersion else {
            return .tooNew(context.version)
        }
        let unsupported = context.requiredFeatures
            .filter { !ProjectV4.supportedFeatures.contains($0) }.sorted()
        return unsupported.isEmpty ? nil : .unsupportedFeatures(unsupported)
    }

    /// A legacy copy never recorded an identity, so it is offered just like the
    /// old autosave slot was. A new copy with no identity was written while its
    /// photo was already gone; something at that path now is not proven to be
    /// the same photo.
    static func sourceState(url: URL?, recorded: RecoverySourceIdentity?,
                            version: Int, current: RecoverySourceIdentity?) -> RecoverySourceState {
        guard let url else { return .missing }
        guard let recorded else {
            return version == 0 ? .available(url) : .changed(url)
        }
        guard let current else { return .available(url) }
        return current == recorded ? .available(url) : .changed(url)
    }

    /// Legacy slots are promoted one at a time with increasing dates, so the
    /// postponed copy keeps being offered first.
    static func monotonic(_ date: Date, after previous: Date?) -> Date {
        RecoveryRules.monotonic(date, after: previous)
    }

    /// A quarantined file keeps its recognizable base name and gains the
    /// destination UUID, so a second damaged copy cannot replace the first.
    static func quarantineFileName(base: String, pathExtension: String, id: UUID) -> String {
        RecoveryRules.quarantineFileName(base: base, pathExtension: pathExtension, id: id)
    }
}
