import Foundation

/// The recovery decisions that depend only on values.
///
/// A host store owns the directory layout, renames and durability. Everything
/// that can be decided from a name, a date or a generation number lives here,
/// so every platform applies the same rules and can test them without a file
/// system. Anything that needs a snapshot, a project or a photo identity stays
/// in the host.
public enum RecoveryRules {

    /// Invalidates work captured under an earlier generation.
    public struct AutosaveEpoch: Equatable {
        public private(set) var value = 0

        public init() {}

        public mutating func invalidate() {
            value &+= 1
        }

        public func accepts(_ captured: Int) -> Bool {
            captured == value
        }
    }

    /// The date is what "oldest first" means. A candidate name carries only
    /// milliseconds, so two copies from the same millisecond keep a stable
    /// order by name without letting the name decide between different dates.
    public struct CandidateOrderKey: Equatable {
        public var savedAt: Date
        public var name: String

        public init(savedAt: Date, name: String) {
            self.savedAt = savedAt
            self.name = name
        }
    }

    public static func olderFirst(_ lhs: CandidateOrderKey, _ rhs: CandidateOrderKey) -> Bool {
        if lhs.savedAt != rhs.savedAt { return lhs.savedAt < rhs.savedAt }
        return lhs.name < rhs.name
    }

    /// Candidate copies, never the working slot and never a dotfile the file
    /// system left behind.
    public static func isCandidateFileName(_ name: String) -> Bool {
        (name as NSString).pathExtension == "retouch" && !name.hasPrefix(".")
    }

    /// Legacy slots are promoted one at a time with increasing dates, so the
    /// postponed copy keeps being offered first.
    public static func monotonic(_ date: Date, after previous: Date?) -> Date {
        guard let previous else { return date }
        return date > previous ? date : previous.addingTimeInterval(0.001)
    }

    /// A quarantined file keeps its recognizable base name and gains the
    /// destination UUID, so a second damaged copy cannot replace the first.
    public static func quarantineFileName(base: String, pathExtension: String, id: UUID) -> String {
        pathExtension.isEmpty ? "\(base)-\(id.uuidString)"
                              : "\(base)-\(id.uuidString).\(pathExtension)"
    }
}
