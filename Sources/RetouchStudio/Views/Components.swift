import SwiftUI

/// A rectangle covering only the leading fraction of its width — the before/after
/// split. Always leading-to-trailing in the view's own coordinate space.
struct PartialRect: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let clamped = min(1, max(0, fraction))
        return Path(CGRect(x: rect.minX, y: rect.minY,
                           width: rect.width * CGFloat(clamped), height: rect.height))
    }
}

/// A flat section header. No card, no border: whitespace and type do the work.
struct SectionHeader: View {
    let title: String
    var reset: (() -> Void)? = nil
    var resetHelp: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Theme.Font.section)
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 4)
            if let reset {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(resetHelp ?? "Reset this section")
            }
        }
    }
}

/// A slider whose fill grows from zero instead of from the left edge, so a
/// neutral value looks neutral. Ranges that start at zero fill normally.
struct BipolarSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    /// Smallest change a drag can make. Sliders that show whole numbers use the
    /// default; precision controls such as export quality pass a fraction.
    var step: Double = 1

    @State private var isHovering = false

    private let knob: CGFloat = 11
    private let track: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let usable = max(1, width - knob)
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let knobX = knob / 2 + usable * CGFloat(fraction)
            let zeroX: CGFloat? = (range.lowerBound < 0 && range.upperBound > 0)
                ? knob / 2 + usable * CGFloat((0 - range.lowerBound) / span)
                : nil

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.bone.opacity(0.13))
                    .frame(height: track)

                if let zeroX {
                    Rectangle()
                        .fill(Theme.bone.opacity(0.20))
                        .frame(width: 1, height: 7)
                        .offset(x: zeroX - 0.5)
                }

                Capsule()
                    .fill(Theme.accent.opacity(isHovering ? 1 : 0.9))
                    .frame(width: max(0, zeroX.map { abs(knobX - $0) } ?? knobX), height: track)
                    .offset(x: zeroX.map { min($0, knobX) } ?? 0)

                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(isHovering ? 0.18 : 0.10))
                        .frame(width: 20, height: 20)
                    Circle()
                        .fill(Theme.background)
                        .frame(width: knob, height: knob)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                }
                .frame(width: 20, height: 20)
                .offset(x: knobX - 10)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(1, max(0, (gesture.location.x - knob / 2) / usable))
                        commit(range.lowerBound + Double(fraction) * span, span: span)
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: knob + 3)
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }

    /// Quantizes to the slider's step and pulls values that land near zero onto
    /// zero, so the knob settles exactly on the neutral mark.
    private func commit(_ newValue: Double, span: Double) {
        let spansZero = range.lowerBound <= 0 && range.upperBound > 0
        let snapped: Double
        if spansZero && abs(newValue) <= span * 0.02 {
            snapped = 0
        } else if step > 0 {
            snapped = ((newValue / step).rounded() * step)
        } else {
            snapped = newValue
        }
        if abs(snapped - value) > step / 2 {
            value = snapped
        }
    }
}

/// One slider with its label, live value and a modified marker.
struct ParameterRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var onReset: (() -> Void)? = nil

    @State private var isHovering = false

    private var isModified: Bool { abs(value) > 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 4)
                    .opacity(isModified ? 1 : 0)

                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if isHovering, let onReset {
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain)
                    .help("Reset this slider")
                }

                Text(String(format: "%.0f", value))
                    .font(Theme.Font.value)
                    .foregroundStyle(isModified ? Theme.accentBright : Theme.faint)
                    .frame(minWidth: 26, alignment: .trailing)
            }

            BipolarSlider(value: $value, range: range)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            if let onReset { onReset() } else { value = 0 }
        }
    }
}

/// The one filled, high-emphasis action in the inspector.
struct AccentButton: View {
    let title: String
    let icon: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(Theme.Font.button)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled
                          ? (isHovering ? Theme.accentBright : Theme.accent)
                          : Theme.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.bone.opacity(enabled ? 0.14 : 0), lineWidth: 0.5)
            )
            .foregroundStyle(enabled ? Theme.accentInk : Theme.faint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovering = $0 }
    }
}

/// The quieter action next to an AccentButton: outlined, never filled.
struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(Theme.Font.button)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled && isHovering ? Theme.cardStrong : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.75)
            )
            .foregroundStyle(enabled ? Theme.text : Theme.faint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovering = $0 }
    }
}

struct PresetChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Theme.accentSoft : Theme.bone.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isActive ? Theme.accent.opacity(0.55) : Theme.stroke,
                                      lineWidth: 0.5)
                )
                .foregroundStyle(isActive ? Theme.accentBright : Theme.muted)
        }
        .buttonStyle(.plain)
    }
}

/// A cosmetic shade: the colour itself carries the meaning, so it gets a swatch
/// rather than a word. Same height and corner as PresetChip so the two read as
/// one control family.
struct ShadeChip: View {
    let shade: MakeupShade
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(shade.swatch)
                    .frame(width: 11, height: 11)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.bone.opacity(0.22), lineWidth: 0.5)
                    )
                Text(shade.title)
                    .font(.system(size: 10.5, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Theme.accentSoft : Theme.bone.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isActive ? Theme.accent.opacity(0.55) : Theme.stroke,
                                  lineWidth: 0.5)
            )
            .foregroundStyle(isActive ? Theme.accentBright : Theme.muted)
        }
        .buttonStyle(.plain)
        .help(shade.title)
    }
}

/// Small face-detection readout used in the inspector footer.
struct StatusChip: View {
    let text: String
    let isGood: Bool
    let icon: String
    var neutral: Bool = false

    private var tint: Color {
        if neutral { return Theme.faint }
        return isGood ? Theme.positive : Theme.warning
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(neutral ? Theme.card : tint.opacity(0.14))
        )
        .foregroundStyle(tint)
    }
}

/// A short explanatory line under a control group.
struct SectionNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
