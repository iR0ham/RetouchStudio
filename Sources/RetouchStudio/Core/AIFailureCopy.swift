import Foundation

/// The sentences for the AI failure taxonomy, in both languages.
///
/// `AIWorker.missingHelperMessage` used to collapse every startup failure into
/// "not available in this build", so a helper that was installed and refused to
/// start read as a build without AI. The states live in `AIWorker`; this file
/// keeps their copy together, including the two facts that had no sentence
/// before, so neither language can drift away from the other.
///
/// Sentences that already existed are taken from the string tables instead of
/// being duplicated here. Only the new facts are written out, and the Persian
/// text of those contains no Latin run, so it needs no directional isolation;
/// the test suite keeps it that way.
enum AIFailureCopy {

    /// Whose table to read. Tests pass this explicitly; the app uses `.current`.
    enum Language {
        case english
        case persian

        static var current: Language {
            AppLanguage.current == .persian ? .persian : .english
        }

        var table: L10n { self == .persian ? PersianL10n.table : L10n.shared }
    }

    /// The canonical sentence for a state, in either language. Every state has
    /// both: a fact that exists only in English reads as a different product in
    /// Persian, and the owner needs all five in both.
    static func text(for state: AIFailureState, _ language: Language) -> String {
        switch state {
        case .runtimeUnavailable:
            return runtimeUnavailable(language)
        case .runtimeInstallFailed:
            return runtimeInstallFailed(language)
        case .workerLaunchFailed:
            return language == .persian ? workerLaunchFailedFA : workerLaunchFailedEN
        case .inferenceFailed:
            return language == .persian ? inferenceFailedFA : inferenceFailedEN
        case .exportFailed:
            return language.table.exportFailed
        }
    }

    /// Nothing this build could start: no package, nothing installed.
    static func runtimeUnavailable(_ language: Language) -> String {
        language.table.aiRuntimeUnavailable
    }

    /// A runtime that is here and did not pass its startup check.
    static func runtimeInstallFailed(_ language: Language) -> String {
        language.table.aiRuntimeValidationFailed
    }

    /// A runtime that is on disk but is held by another window. The owner's
    /// five facts have no bucket for "in use", so it keeps its own sentence
    /// under the install-failure state instead of borrowing a wrong one.
    static func runtimeBusy(_ language: Language) -> String {
        language.table.aiRuntimeBusy
    }

    /// Intel has no runtime to offer, which is a different sentence from a
    /// light build on Apple silicon.
    static func runtimeUnavailableIntel(_ language: Language) -> String {
        language.table.aiRuntimeIntelUnavailable
    }

    /// A package exists but nothing is installed. Unreachable while no official
    /// package is published, and kept so the day one is, the sentence stays
    /// the careful one rather than "not available in this build".
    static func runtimeNotInstalled(_ language: Language) -> String {
        language.table.aiRuntimeNotInstalled
    }

    /// The helper is here and did not start. It names no fallback, because
    /// none exists: the edit is simply not attempted.
    static let workerLaunchFailedEN =
        "The local AI helper is on this Mac but did not start. Try the edit again; if it keeps failing, quit and reopen the app."
    static let workerLaunchFailedFA =
        "دستیار محلی هوش مصنوعی روی این مک هست ولی راه‌اندازی نشد. ویرایش را دوباره امتحان کن؛ اگر باز هم نشد، برنامه را ببند و دوباره باز کن."

    /// The helper started and the job failed. Results only enter history whole,
    /// so a failed job leaves the document unchanged.
    static let inferenceFailedEN =
        "The local AI helper started, but the edit failed before it finished. Nothing was changed; try the edit again."
    static let inferenceFailedFA =
        "دستیار محلی هوش مصنوعی شروع شد، ولی ویرایش پیش از پایان ناموفق ماند. چیزی تغییر نکرد؛ ویرایش را دوباره امتحان کن."
}
