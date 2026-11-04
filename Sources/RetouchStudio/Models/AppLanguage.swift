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
    static var current: AppLanguage {
        get { stored }
        set {
            guard newValue != stored else { return }
            stored = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    private static let storageKey = "app.language"

    private static var stored: AppLanguage = {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AppLanguage(rawValue: raw) ?? .english
    }()
}
