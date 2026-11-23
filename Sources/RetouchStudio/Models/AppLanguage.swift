import Foundation
import SwiftUI

/// The two languages the app speaks. English is the default; Persian is the
/// one the owner reads, and it brings its own typeface (Vazir) with it.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case persian = "fa"

    /// The interface direction that goes with the language. The app swaps its
    /// own string table, so the layout has to follow the table rather than the
    /// system locale: a Persian app on an English Mac must still read right to
    /// left.
    var layoutDirection: LayoutDirection {
        self == .persian ? .rightToLeft : .leftToRight
    }

    /// Each option is written in its own script, so the picker reads the way a
    /// speaker of that language expects.
    var title: String {
        switch self {
        case .english: return "English"
        case .persian: return "فارسی"
        }
    }

    /// The language in force right now. The app has one editor window and one
    /// settings sheet, so a single global is enough — and it lets the font
    /// tokens and the About/Help windows read it without an actor hop.
    ///
    /// A string built from the tables reads this, so under the default English
    /// interface a formatter cannot be shown producing its Persian shape. Tests
    /// hold that shape with `languageOverride`, which is never written to
    /// defaults: the suites run as one process, and persisting a flip would leak
    /// into whatever suite the runner executes next.
    static var current: AppLanguage {
        get { languageOverride ?? stored }
        set {
            guard newValue != stored else { return }
            stored = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    /// Test-only seam for the interface language. Production leaves this nil.
    #if RETOUCH_TESTING
    nonisolated(unsafe) static var languageOverride: AppLanguage?
    #else
    static var languageOverride: AppLanguage? { nil }
    #endif

    private static let storageKey = "app.language"

    private static var stored: AppLanguage = {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AppLanguage(rawValue: raw) ?? .english
    }()
}
