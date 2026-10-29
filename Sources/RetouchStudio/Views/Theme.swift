import SwiftUI

/// Visual tokens for the whole app. Everything visible comes from here so the
/// UI stays consistent instead of accumulating one-off opacities.
///
/// The shell is a neutral graphite — no colour cast that would lie about the
/// photo sitting in the middle of it. Surfaces step up in small even increments
/// (#1D → #24 → #2E), and only the chrome carries colour: chartreuse for the
/// action that commits work, sky for the action that generates one.
enum Theme {

    // MARK: Surfaces

    /// Cool near-white for anything that must read as light on graphite:
    /// hairlines, the active tool pill, slider knobs.
    static let bone = Color(red: 0.965, green: 0.965, blue: 0.965)

    /// Window shell.
    static let background = Color(red: 0.114, green: 0.114, blue: 0.114)
    /// Bar and panel cards, one step up from the shell.
    static let panel = Color(red: 0.141, green: 0.141, blue: 0.141)
    /// Wells inside a card: chips, text fields, segmented pickers.
    static let inset = Color(red: 0.180, green: 0.180, blue: 0.180)
    /// A well that is hovered or selected.
    static let raised = Color(red: 0.220, green: 0.220, blue: 0.220)

    static let card = panel
    static let cardStrong = inset

    static let stroke = bone.opacity(0.085)
    static let hairline = bone.opacity(0.075)

    // MARK: Text

    static let text = Color(red: 0.949, green: 0.949, blue: 0.949)
    static let muted = Color(red: 0.639, green: 0.639, blue: 0.639)
    static let faint = Color(red: 0.431, green: 0.431, blue: 0.431)

    // MARK: Accent — chartreuse

    static let accent = Color(red: 0.875, green: 0.961, blue: 0.478)
    static let accentBright = Color(red: 0.937, green: 0.980, blue: 0.682)
    static let accentDeep = Color(red: 0.659, green: 0.827, blue: 0.235)
    /// Text and glyphs on a filled chartreuse surface.
    static let accentInk = Color(red: 0.106, green: 0.129, blue: 0.020)
    static let accentSoft = Color(red: 0.875, green: 0.961, blue: 0.478).opacity(0.13)

    // MARK: Secondary — sky

    /// The generative action: Auto Retouch and Auto Color, the reference's
    /// "Generate" button. Kept apart from chartreuse so "make it" and "ship it"
    /// never look like the same control.
    static let sky = Color(red: 0.561, green: 0.784, blue: 0.973)
    static let skyDeep = Color(red: 0.290, green: 0.584, blue: 0.886)
    static let skyInk = Color(red: 0.024, green: 0.122, blue: 0.196)
    static let skySoft = Color(red: 0.561, green: 0.784, blue: 0.973).opacity(0.13)

    // MARK: Status

    static let positive = Color(red: 0.545, green: 0.790, blue: 0.660)
    static let warning = Color(red: 0.850, green: 0.680, blue: 0.440)

    // MARK: Detection overlays

    static let overlayEye = Color(red: 0.565, green: 0.745, blue: 0.816)
    static let overlayLip = Color(red: 0.855, green: 0.596, blue: 0.580)

    // MARK: Geometry

    enum Metrics {
        static let bar: CGFloat = 52
        static let gutter: CGFloat = 14
        /// The window buttons keep a band of their own above the bar, so the bar
        /// only needs a whisper of space before it.
        static let topGutter: CGFloat = 8
        static let leftPanel: CGFloat = 292
        static let rightPanel: CGFloat = 318
        static let headerPadding: CGFloat = 16
    }

    enum Radius {
        static let card: CGFloat = 18
        static let control: CGFloat = 12
        static let chip: CGFloat = 10
        static let canvas: CGFloat = 16
        static let pill: CGFloat = 999
    }

    enum Font {
        /// Every face the app draws with. Persian switches to Vazir, the
        /// typeface the owner asked for; English keeps the system face.
        static func face(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            guard AppLanguage.current == .persian else {
                return .system(size: size, weight: weight)
            }
            return .custom(vazirName(for: weight), size: size)
        }

        static var panelTitle: SwiftUI.Font { face(size: 15, weight: .semibold) }
        static var section: SwiftUI.Font { face(size: 10.5, weight: .semibold) }
        static var label: SwiftUI.Font { face(size: 12) }
        static var caption: SwiftUI.Font { face(size: 11) }
        /// Numbers stay monospaced in both languages: they are read as a
        /// column, not as words.
        static var value: SwiftUI.Font { .system(size: 11, weight: .medium, design: .monospaced) }
        static var button: SwiftUI.Font { face(size: 12.5, weight: .semibold) }

        /// The PostScript names of the Vazir faces bundled in Resources/Fonts.
        private static func vazirName(for weight: SwiftUI.Font.Weight) -> String {
            switch weight {
            case .bold: return "Vazirmatn-Bold"
            case .semibold: return "Vazirmatn-SemiBold"
            case .medium: return "Vazirmatn-Medium"
            default: return "Vazirmatn-Regular"
            }
        }
    }
}

/// Motion for the shell. Springs, because every control in the reference moves
/// rather than snaps; the response times are short enough that a drag still
/// tracks the pointer.
enum Motion {
    /// Taps, hovers, knob growth.
    static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.78)
    /// Tool pill sliding along the bar, section rows opening.
    static let smooth = Animation.spring(response: 0.40, dampingFraction: 0.86)
    /// Anything that carries content: panels cross-fading, the photo loading.
    static let swell = Animation.spring(response: 0.52, dampingFraction: 0.92)

    /// The press feedback shared by every button in the app.
    static let press = Animation.spring(response: 0.20, dampingFraction: 0.62)
}

/// A one-pixel separator that reads correctly on the graphite surfaces.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }
}

/// The card every panel group sits in: lifted graphite, soft corner, hairline
/// that brightens when the pointer is over it.
struct CardBackground: View {
    var radius: CGFloat = Theme.Radius.card
    var fill: Color = Theme.panel
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hovering ? Theme.bone.opacity(0.12) : Theme.stroke,
                                  lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: hovering)
    }
}

/// Press feedback for the whole app: the control dips instead of the OS bezel
/// flashing. Applied through `PressableButtonStyle` so every button agrees.
struct PressableButtonStyle: ButtonStyle {
    var dip: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? dip : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Fades and lifts a view in the first time it appears, so switching tools or
/// loading a photo reads as the panel settling rather than as a hard repaint.
struct AppearTransition: ViewModifier {
    @State private var shown = false
    var delay: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear {
                withAnimation(Motion.smooth.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func appearAfter(_ delay: Double = 0) -> some View {
        modifier(AppearTransition(delay: delay))
    }
}
