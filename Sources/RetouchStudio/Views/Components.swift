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

/// The title row of a card in the left column.
struct CardHeader: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var tint: Color = Theme.text

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Icon(name: icon, size: 15, emphasised: true)
                        .foregroundStyle(tint)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.face(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .help(subtitle.map { "\(title) — \($0)" } ?? title)
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
                .help(title)
            Spacer(minLength: 4)
            if let reset {
                Button(action: reset) {
                    Icon(name: "arrow.counterclockwise", size: 12, emphasised: true)
                        .foregroundStyle(Theme.faint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(dip: 0.9))
                .help(resetHelp ?? L10n.current.resetGroupHelp)
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
    /// Chartreuse for retouch amounts, sky for the generative controls.
    var tint: Color = Theme.accent
    /// Runs once when the pointer is released. Controls that re-render the
    /// source, such as straighten, commit there instead of on every tick.
    var onEditingEnded: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isDragging = false
    /// Read from the parent before the internal left-to-right override below.
    /// A Persian slider fills and moves from the right, the way the rest of the
    /// mirrored shell reads.
    @Environment(\.layoutDirection) private var direction

    private let knob: CGFloat = 12
    private let track: CGFloat = 4

    private var mirrored: Bool { direction == .rightToLeft }

    private var fill: some ShapeStyle {
        LinearGradient(colors: [tint.opacity(0.72), tint],
                       startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let usable = max(1, width - knob)
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let visual = mirrored ? 1 - fraction : fraction
            let knobX = knob / 2 + usable * CGFloat(visual)
            let zeroX: CGFloat? = (range.lowerBound < 0 && range.upperBound > 0)
                ? knob / 2 + usable * CGFloat(mirrored ? 1 - (0 - range.lowerBound) / span
                                                      : (0 - range.lowerBound) / span)
                : nil
            let grown = isHovering || isDragging

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.bone.opacity(0.14))
                    .frame(height: track)

                if let zeroX {
                    Rectangle()
                        .fill(Theme.bone.opacity(0.22))
                        .frame(width: 1, height: 8)
                        .offset(x: zeroX - 0.5)
                }

                Capsule()
                    .fill(fill)
                    .frame(width: max(0, zeroX.map { abs(knobX - $0) } ?? knobX), height: track)
                    .offset(x: zeroX.map { min($0, knobX) } ?? 0)

                ZStack {
                    Circle()
                        .fill(tint.opacity(grown ? 0.22 : 0))
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(Theme.bone)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(grown ? 0.45 : 0.30), radius: grown ? 4 : 2, y: 1)
                }
                .scaleEffect(grown ? 1.18 : 1)
                .frame(width: 22, height: 22)
                .offset(x: knobX - 10)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let raw = min(1, max(0, (gesture.location.x - knob / 2) / usable))
                        let fraction = mirrored ? 1 - raw : raw
                        commit(range.lowerBound + Double(fraction) * span, span: span)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingEnded?()
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: knob + 10)
        .animation(Motion.snappy, value: isHovering || isDragging)
        .animation(Motion.snappy, value: value)
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
        // The fill and the drag maths are drawn from the left edge. A mirrored
        // slider would invert the handle without inverting the numbers, so the
        // numeric track keeps its own direction in Persian too.
        .environment(\.layoutDirection, .leftToRight)
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
    /// A one-line explanation for the hover tooltip; empty shows just the title.
    var hint: String = ""
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var tint: Color = Theme.accent
    var onReset: (() -> Void)? = nil

    @State private var isHovering = false

    private var isModified: Bool { abs(value) > 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 4, height: 4)
                    .opacity(isModified ? 1 : 0)

                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if isHovering, let onReset {
                    Button(action: onReset) {
                        Icon(name: "arrow.counterclockwise", size: 11.5, emphasised: true)
                            .foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(PressableButtonStyle(dip: 0.9))
                    .help(L10n.current.resetSliderHelp)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                Text(Digits.convert(String(format: "%.0f", value)))
                    .font(Theme.Font.value)
                    .foregroundStyle(isModified ? tint : Theme.faint)
                    .frame(minWidth: 26, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: value)
            }

            BipolarSlider(value: $value, range: range, tint: tint)
        }
        .contentShape(Rectangle())
        .help(hint.isEmpty ? title : "\(title) — \(hint)")
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
        .onTapGesture(count: 2) {
            if let onReset { onReset() } else { value = 0 }
        }
    }
}

/// The filled, high-emphasis action. Chartreuse commits the work; sky generates
/// it, so the two are the same button in two colours rather than two designs.
struct FilledButton: View {
    enum Tone {
        case lime
        case sky

        var fill: Color { self == .lime ? Theme.accent : Theme.sky }
        var bright: Color { self == .lime ? Theme.accentBright : Theme.skyDeep.opacity(0.85) }
        var ink: Color { self == .lime ? Theme.accentInk : Theme.skyInk }
    }

    let title: String
    let icon: String
    var tone: Tone = .lime
    var enabled: Bool = true
    var height: CGFloat = 38
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Icon(name: icon, size: 15, emphasised: true)
                Text(title)
                    .font(Theme.Font.button)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(enabled
                          ? (isHovering ? tone.bright : tone.fill)
                          : Theme.inset)
            )
            .foregroundStyle(enabled ? tone.ink : Theme.faint)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
    }
}

/// The one filled, high-emphasis action in the inspector.
struct AccentButton: View {
    let title: String
    let icon: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        FilledButton(title: title, icon: icon, tone: .lime,
                     enabled: enabled, height: 34, action: action)
    }
}

/// The quieter action next to a filled one: outlined, never solid.
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
                    Icon(name: icon, size: 14, emphasised: true)
                }
                Text(title)
                    .font(Theme.Font.button)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(enabled && isHovering ? Theme.raised : Theme.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.75)
            )
            .foregroundStyle(enabled ? Theme.text : Theme.faint)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
    }
}

struct PresetChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.face(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(isActive ? Theme.accent : Theme.inset)
                )
                .foregroundStyle(isActive ? Theme.accentInk : Theme.muted)
        }
        .buttonStyle(PressableButtonStyle(dip: 0.95))
        .animation(Motion.snappy, value: isActive)
    }
}

/// The small caps heading over a block of related controls, in the same voice
/// as the "STRENGTH" label on the auto cards.
struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.section)
            .tracking(0.6)
            .foregroundStyle(Theme.muted)
            .help(text)
    }
}

/// A preset with its own preview: the photo that is open, rendered through that
/// preset, so the choice is made by looking rather than by reading a word.
/// Without a photo it falls back to a plain tile that still carries the name.
struct PresetTile: View {
    let title: String
    var thumb: NSImage? = nil
    let isActive: Bool
    var onDelete: (() -> Void)? = nil
    var deleteHelp: String = L10n.current.deleteLookHelp
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            thumbnail
                .overlay(
                    LinearGradient(colors: [.clear, Color.black.opacity(0.66)],
                                   startPoint: .center, endPoint: .bottom)
                )
                .overlay(alignment: .bottomLeading) {
                    Text(title)
                        .font(Theme.Font.face(size: 9.5, weight: .semibold))
                        .foregroundStyle(isActive ? Theme.accentBright : Theme.bone)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.bottom, 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isActive ? Theme.accent
                                               : Theme.bone.opacity(hovering ? 0.32 : 0.10),
                                      lineWidth: isActive ? 1.6 : 0.8)
                )
        }
        .buttonStyle(PressableButtonStyle(dip: 0.96))
        .overlay(alignment: .topTrailing) {
            // Outside the label, so the click reaches the delete and not the tile.
            if hovering, let onDelete {
                Button(action: onDelete) {
                    Icon(name: "xmark.circle", size: 12)
                        .foregroundStyle(Theme.bone)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .help(deleteHelp)
                .padding(3)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .animation(Motion.snappy, value: isActive)
        .help(title)
    }

    /// The height is fixed here so the scrim and caption measure the tile: a
    /// `scaledToFill` image reports the photo's own size, which would put the
    /// caption far below the clipped band.
    private var thumbnail: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Theme.inset)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .clipped()
    }
}

/// A cosmetic colour: the colour itself carries the meaning, so it gets a swatch
/// rather than a word. Same height and corner as PresetChip so the two read as
/// one control family.
struct SwatchChip: View {
    let color: MakeupColor
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.color)
                .frame(height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isActive ? Theme.bone : Theme.bone.opacity(0.16),
                                      lineWidth: isActive ? 1.6 : 0.75)
                )
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Icon(name: "checkmark.circle.fill", size: 13.5, emphasised: true)
                            .foregroundStyle(Theme.bone)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                            .padding(3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(isActive ? 1 : 0.94)
        }
        .buttonStyle(PressableButtonStyle(dip: 0.92))
        .frame(height: 30)
        .help(title)
        .animation(Motion.snappy, value: isActive)
    }
}

/// Small face-detection readout used in the status card.
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
        HStack(spacing: 5) {
            Icon(name: icon, size: 12, emphasised: true)
            Text(text)
                .font(Theme.Font.face(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(
            Capsule(style: .continuous)
                .fill(neutral ? Theme.inset : tint.opacity(0.15))
        )
        .foregroundStyle(tint)
        .animation(Motion.smooth, value: text)
    }
}

/// A short explanatory line under a control group.
struct SectionNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.face(size: 10.5))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title and a live number on one line, with the slider underneath — the
/// reference's "Size …… 69 px" row.
struct LabeledSliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var suffix: String = ""
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Text("\(Digits.convert(String(format: "%.0f", value)))\(suffix)")
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: value)
            }
            BipolarSlider(value: $value, range: range, step: step, tint: tint)
        }
    }
}
