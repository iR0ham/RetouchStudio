import Foundation

/// The app's identity in one place: the About window, the Settings panel and
/// the copyright line all read from here.
///
/// Optional contact fields stay hidden while empty. The version comes from the
/// bundle, so a release build only has to stamp `Info.plist`.
enum DeveloperProfile {
    static let name = "iRoham"
    /// Localized so the About window and Settings read naturally in either language.
    static var role: String { L10n.current.aboutDeveloperRoleValue }
    /// e.g. "hello@example.com". Hidden while empty.
    static let email = ""
    /// e.g. "github.com/roham". Hidden while empty.
    static let website = ""

    static let copyrightYear = "2026"

    static var version: String { info("CFBundleShortVersionString") ?? "—" }
    static var build: String { info("CFBundleVersion") ?? "—" }
    static var versionLine: String { "\(version) (\(build))" }
    static var copyrightLine: String { "© \(copyrightYear) \(name)" }

    private static func info(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
