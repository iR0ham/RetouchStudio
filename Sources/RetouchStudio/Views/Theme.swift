import SwiftUI

/// Visual tokens for the whole app. Everything visible should come from here so
/// the UI stays consistent instead of accumulating one-off opacities.
///
/// The palette is warm and low-chroma: espresso graphite for the chrome and a
/// patina green for anything interactive. Warm neutrals keep the app from
/// reading as a generic blue-black panel, and green stays clear of the skin
/// tones that fill the canvas.
enum Theme {

    // MARK: Surfaces

    /// Warm paper white. Hairlines and subtle lifts use this instead of pure
    /// white so highlights stay in the same temperature as the greys.
    static let bone = Color(red: 0.98, green: 0.95, blue: 0.905)

    static let background = Color(red: 0.070, green: 0.066, blue: 0.060)
    static let rail = Color(red: 0.093, green: 0.087, blue: 0.079)
    static let panel = Color(red: 0.117, green: 0.110, blue: 0.099)
    static let card = bone.opacity(0.04)
    static let cardStrong = bone.opacity(0.07)
    static let stroke = bone.opacity(0.105)
    static let hairline = bone.opacity(0.065)

    // MARK: Text

    static let text = Color(red: 0.930, green: 0.912, blue: 0.875)
    static let muted = Color(red: 0.660, green: 0.625, blue: 0.570)
    static let faint = Color(red: 0.445, green: 0.415, blue: 0.370)

    // MARK: Accent — patina green

    static let accent = Color(red: 0.400, green: 0.620, blue: 0.549)
    static let accentBright = Color(red: 0.588, green: 0.800, blue: 0.718)
    static let accentInk = Color(red: 0.035, green: 0.078, blue: 0.063)
    static let accentSoft = Color(red: 0.400, green: 0.620, blue: 0.549).opacity(0.15)

    // MARK: Status

    static let positive = Color(red: 0.545, green: 0.790, blue: 0.660)
    static let warning = Color(red: 0.850, green: 0.680, blue: 0.440)

    // MARK: Detection overlays

    static let overlayEye = Color(red: 0.565, green: 0.745, blue: 0.816)
    static let overlayLip = Color(red: 0.855, green: 0.596, blue: 0.580)

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
