import SwiftUI

/// A titled group of controls, styled as a rounded card.
struct ToolSection<Content: View>: View {
    let title: String
    let icon: String
    let onReset: (() -> Void)?
    let resetHelp: String?
    let content: Content

    init(title: String,
         icon: String,
         onReset: (() -> Void)? = nil,
         resetHelp: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.onReset = onReset
        self.resetHelp = resetHelp
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                // Per-group reset: zeroes only this section's sliders.
                if let onReset {
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help(resetHelp ?? "Reset this section")
                }
            }
            .foregroundStyle(.secondary)

            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

/// A prominent, full-width action button (used for the Auto actions and Export).
struct ActionButton: View {
    let title: String
    let icon: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(enabled ? 1 : 0.35))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// A slider with its label and current value. Double-clicking the label zeroes it.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var onReset: (() -> Void)? = nil

    private var isModified: Bool { abs(value) > 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                Text(String(format: "%.0f", value))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isModified ? Color.accentColor : Color.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.mini)
                .frame(height: 16)
        }
        .contentShape(Rectangle())
        // Double-clicking the row zeroes just this effect.
        .onTapGesture(count: 2) {
            if let onReset { onReset() } else { value = 0 }
        }
    }
}

/// A compact switch row, matching the sidebar's density.
struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
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
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.primary.opacity(0.07))
                )
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isActive ? 0 : 0.07), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

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

struct StatusPill: View {
    let text: String
    let isGood: Bool
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((isGood ? Color.green : Color.orange).opacity(0.15))
        )
        .foregroundStyle(isGood ? Color.green : Color.orange)
    }
}
