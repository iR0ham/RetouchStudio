import SwiftUI

/// Visual tokens for the whole app. Everything visible should come from here so
/// the UI stays consistent instead of accumulating one-off opacities.
enum Theme {

    // MARK: Surfaces

    static let background = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let rail = Color(red: 0.055, green: 0.055, blue: 0.067)
    static let panel = Color(red: 0.082, green: 0.082, blue: 0.094)
    static let card = Color.white.opacity(0.035)
    static let cardStrong = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.05)

    // MARK: Text

    static let text = Color(red: 0.93, green: 0.93, blue: 0.94)
    static let muted = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let faint = Color(red: 0.42, green: 0.42, blue: 0.46)

    // MARK: Accent

    static let accent = Color(red: 0.788, green: 0.545, blue: 0.384)
    static let accentBright = Color(red: 0.867, green: 0.627, blue: 0.467)
    static let accentInk = Color(red: 0.11, green: 0.075, blue: 0.05)
    static let accentSoft = Color(red: 0.788, green: 0.545, blue: 0.384).opacity(0.13)

    // MARK: Status

    static let positive = Color(red: 0.42, green: 0.76, blue: 0.52)
    static let warning = Color(red: 0.91, green: 0.68, blue: 0.36)

    enum Metrics {
        static let rail: CGFloat = 54
        static let panel: CGFloat = 304
        static let headerPadding: CGFloat = 16
    }

    enum Font {
        static let panelTitle = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let section = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let label = SwiftUI.Font.system(size: 12, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let value = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
        static let button = SwiftUI.Font.system(size: 12, weight: .medium)
    }
}

/// A one-pixel separator that reads correctly on the dark surfaces.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }
}
