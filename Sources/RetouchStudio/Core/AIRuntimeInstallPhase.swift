import Darwin
import Foundation

/// The runtime installer's observable state. The cycle is explicit so a test
/// can drive every step offline and so the UI never has to infer "what is
/// happening" from a pile of flags:
///
///   notInstalled → awaitingConsent → downloading → verifying → installing → ready
///
/// with `cancelled` and `failed(kind)` reachable from the phases that do work.
/// `ready` and `cancelled` are the terminal answers; `failed` and `cancelled`
/// can be left by a retry, which always asks for consent again.
enum AIRuntimeInstallPhase: Equatable {
    case notInstalled
    case awaitingConsent
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifying
    case installing
    case ready
    case cancelled
    case failed(AIRuntimeInstallFailure)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isTerminal: Bool {
        switch self {
        case .ready, .cancelled, .failed: return true
        default: return false
        }
    }

    /// The phases in which a cancel gesture stops real work.
    var isCancellable: Bool { isBusy }
}

/// Everything that can move the installer. A pure reducer turns (phase, event)
/// into the next phase or `nil` when the pair is illegal.
enum AIRuntimeInstallEvent: Equatable {
    case consentRequested
    case consentGranted(totalBytes: Int64)
    case consentDeclined
    case downloadProgress(receivedBytes: Int64, totalBytes: Int64)
    case downloaded
    case verified
    case installed
    case cancelRequested
    case failed(AIRuntimeInstallFailure)
    case retryRequested
    case recoveryFinished(installed: Bool)
}

enum AIRuntimeInstallReducer {

    /// The whole transition table. Returning `nil` means "reject": the caller
    /// must leave the phase where it was, so an out-of-order URLSession
    /// callback cannot drag a cancelled or ready installer back into work.
    static func reduce(current: AIRuntimeInstallPhase,
                       event: AIRuntimeInstallEvent) -> AIRuntimeInstallPhase? {
        switch (current, event) {
        // Consent, and only consent, starts a download.
        case (.notInstalled, .consentRequested):
            return .awaitingConsent
        case (.awaitingConsent, .consentDeclined):
            return .notInstalled
        case (.awaitingConsent, .consentGranted(let total)):
            return .downloading(receivedBytes: 0, totalBytes: max(0, total))

        // Progress only exists while downloading; a total the server did not
        // send keeps the size the package declared.
        case (.downloading(_, let declared), .downloadProgress(let received, let expected)):
            let total = expected > 0 ? expected : declared
            guard received >= 0, total >= 0, received <= total else { return nil }
            return .downloading(receivedBytes: received, totalBytes: total)
        case (.downloading, .downloaded):
            return .verifying
        case (.verifying, .verified):
            return .installing
        case (.installing, .installed):
            return .ready
        // A commit that finished before the cancel was acknowledged is the
        // truth: the runtime is on disk, so ready wins over a stale cancel.
        case (.cancelled, .installed):
            return .ready

        case (.downloading, .cancelRequested),
             (.verifying, .cancelRequested),
             (.installing, .cancelRequested):
            return .cancelled

        // Any phase that has not reached an answer can fail; startup recovery
        // can fail before consent was ever asked.
        case (_, .failed(let failure)) where !current.isTerminal:
            return .failed(failure)

        // A retry is a new attempt from the start, and it asks again.
        case (.cancelled, .retryRequested), (.failed, .retryRequested):
            return .awaitingConsent

        // Launch-time recovery found a validated runtime.
        case (.notInstalled, .recoveryFinished(let installed)):
            return installed ? .ready : .notInstalled

        default:
            return nil
        }
    }

    /// Reduces in place and reports whether the pair was legal, so the
    /// installer can ignore a stale callback instead of publishing it.
    @discardableResult
    static func reduce(current: AIRuntimeInstallPhase,
                       into phase: inout AIRuntimeInstallPhase,
                       event: AIRuntimeInstallEvent) -> Bool {
        guard let next = reduce(current: current, event: event) else { return false }
        phase = next
        return true
    }
}

/// A failed attempt, with the class the spec names and the sentence the card
/// already showed for that failure. Slice S5 owns new wording; this slice only
/// makes the class explicit.
struct AIRuntimeInstallFailure: Equatable {
    enum Kind: Equatable {
        case network
        case insufficientDisk
        case hashMismatch
        case install
        case incompatibleRuntime
    }

    let kind: Kind
    let message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    static func classify(_ error: Error, l10n: L10n = .current) -> AIRuntimeInstallFailure {
        if let failure = error as? AIRuntimeFailure {
            switch failure.code {
            case .checksum:
                return .init(kind: .hashMismatch,
                             message: l10n.aiRuntimeChecksumFailed)
            case .extract:
                return .init(kind: .incompatibleRuntime,
                             message: l10n.aiRuntimeExtractFailed)
            case .validation:
                return .init(kind: .incompatibleRuntime,
                             message: installMessage(failure, l10n))
            case .install:
                return .init(kind: .install, message: installMessage(failure, l10n))
            case .recovery:
                return .init(kind: .install,
                             message: l10n.aiRuntimeRecoveryFailed)
            case .busy:
                return .init(kind: .install, message: l10n.aiRuntimeBusy)
            }
        }
        if isInsufficientDisk(error) {
            return .init(kind: .insufficientDisk,
                         message: l10n.aiRuntimeDownloadFailed)
        }
        if isTransferFailure(error) {
            return .init(kind: .network, message: l10n.aiRuntimeDownloadFailed)
        }
        return .init(kind: .install, message: l10n.aiRuntimeInstallFailedNothing)
    }

    private static func installMessage(_ failure: AIRuntimeFailure,
                                       _ l10n: L10n) -> String {
        switch failure.previous {
        case .kept: return l10n.aiRuntimeInstallFailed
        case .none: return l10n.aiRuntimeInstallFailedNothing
        case .lost: return l10n.aiRuntimeInstallFailedRollback
        case .preserved: return l10n.aiRuntimeInstallFailedPreserved
        }
    }

    /// A full disk during the download arrives as either a POSIX error or an
    /// `NSError` that wraps one, so both are unwrapped before the class is
    /// decided; the transfer check below must not swallow it.
    private static func isInsufficientDisk(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(ENOSPC) {
            return true
        }
        return false
    }

    private static func isTransferFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            return ns.code != NSURLErrorCancelled
        case NSPOSIXErrorDomain:
            // Connection-level POSIX failures (ENETDOWN, ECONNRESET, …).
            return true
        default:
            return false
        }
    }
}

/// Cooperative cancellation for one install attempt. The installer sets it
/// before the transaction starts; the transaction checks it at every point
/// where a stop either leaves the previous runtime untouched or is handled by
/// the existing rollback.
final class AIRuntimeInstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func cancel() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

/// Thrown by the transaction when the cancellation token was set. It is never
/// wrapped into `AIRuntimeFailure`: the caller maps it to `.cancelled`, not to
/// a failure the owner should retry with a different fix.
struct AIRuntimeInstallCancelled: Error {}
