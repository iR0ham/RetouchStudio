import SwiftUI

/// The contextual inspector. Only one tool is visible at a time, so the panel
/// stays short and every control is relevant to what was selected in the rail.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            presetStrip
            Hairline()
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(.horizontal, Theme.Metrics.headerPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                    .opacity(model.hasImage ? 1 : 0.45)
            }
            .disabled(!model.hasImage)
            footer
        }
        .frame(width: Theme.Metrics.panel)
        .background(Theme.panel)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.toolMode.title)
                    .font(Theme.Font.panelTitle)
                    .foregroundStyle(Theme.text)

                Spacer(minLength: 6)

                historyButton("arrow.uturn.backward",
                              help: model.s.undoHelp,
                              enabled: model.canUndo) { model.undo() }
                historyButton("arrow.uturn.forward",
                              help: model.s.redoHelp,
                              enabled: model.canRedo) { model.redo() }
            }

            Text(model.toolMode.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, Theme.Metrics.headerPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func historyButton(_ icon: String,
                               help: String,
                               enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Theme.muted : Theme.faint.opacity(0.6))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Presets

    private var presetStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PRESETS")
                .font(Theme.Font.section)
                .tracking(0.6)
                .foregroundStyle(Theme.faint)

            HStack(spacing: 6) {
                ForEach(Preset.all) { preset in
                    PresetChip(title: model.s.presetTitle(preset.id),
                               isActive: model.isActive(preset)) {
                        model.apply(preset)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.headerPadding)
        .padding(.bottom, 14)
        .opacity(model.hasImage ? 1 : 0.45)
        .disabled(!model.hasImage)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.toolMode {
        case .skin: skinContent
        case .reshape: reshapeContent
        case .detail: detailContent
        case .color: colorContent
        }
    }

    private var skinContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            autoRetouchCard

            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: "Skin",
                              reset: { model.resetGroup(.skin) },
                              resetHelp: model.s.resetGroupHelp)

                ParameterRow(title: model.s.skinSmoothing,
                             value: model.binding(for: \.smooth),
                             range: 0...100,
                             onReset: { model.resetEffect(\.smooth) })
                ParameterRow(title: model.s.texturePreserve,
                             value: model.binding(for: \.texturePreserve),
                             range: 0...100,
                             onReset: { model.resetEffect(\.texturePreserve) })
                ParameterRow(title: model.s.blemishRemoval,
                             value: model.binding(for: \.blemish),
                             range: 0...100,
                             onReset: { model.resetEffect(\.blemish) })
                ParameterRow(title: model.s.wrinkleReduction,
                             value: model.binding(for: \.wrinkle),
                             range: 0...100,
                             onReset: { model.resetEffect(\.wrinkle) })
                ParameterRow(title: model.s.skinTone,
                             value: model.binding(for: \.skinToneEvens),
                             range: 0...100,
                             onReset: { model.resetEffect(\.skinToneEvens) })
                ParameterRow(title: model.s.darkCircles,
                             value: model.binding(for: \.darkCircles),
                             range: 0...100,
                             onReset: { model.resetEffect(\.darkCircles) })
                ParameterRow(title: model.s.skinBrightness,
                             value: model.binding(for: \.skinBrighten),
                             onReset: { model.resetEffect(\.skinBrighten) })
            }

            SectionNote(text: "Double-click a slider to reset it.")
        }
    }

    private var reshapeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionNote(text: model.s.reshapeScope)

            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: "Shape",
                              reset: { model.resetGroup(.reshape) },
                              resetHelp: model.s.resetGroupHelp)

                ParameterRow(title: model.s.eyeSize,
                             value: model.binding(for: \.eyeSize),
                             onReset: { model.resetEffect(\.eyeSize) })
                ParameterRow(title: model.s.noseSize,
                             value: model.binding(for: \.noseSize),
                             onReset: { model.resetEffect(\.noseSize) })
                ParameterRow(title: model.s.noseTip,
                             value: model.binding(for: \.noseTip),
                             onReset: { model.resetEffect(\.noseTip) })
                ParameterRow(title: model.s.lipSize,
                             value: model.binding(for: \.lipSize),
                             onReset: { model.resetEffect(\.lipSize) })
                ParameterRow(title: model.s.cheekSize,
                             value: model.binding(for: \.cheekSize),
                             onReset: { model.resetEffect(\.cheekSize) })
                ParameterRow(title: model.s.jawWidth,
                             value: model.binding(for: \.jawWidth),
                             onReset: { model.resetEffect(\.jawWidth) })
                ParameterRow(title: model.s.chinLength,
                             value: model.binding(for: \.chinLength),
                             onReset: { model.resetEffect(\.chinLength) })
                ParameterRow(title: model.s.faceWidth,
                             value: model.binding(for: \.faceWidth),
                             onReset: { model.resetEffect(\.faceWidth) })
                ParameterRow(title: model.s.faceLength,
                             value: model.binding(for: \.faceLength),
                             onReset: { model.resetEffect(\.faceLength) })
            }
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionNote(text: "These tools use the detected eyes, lips and teeth.")

            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: "Eyes & Teeth")

                ParameterRow(title: model.s.teethWhitening,
                             value: model.binding(for: \.teethWhiten),
                             range: 0...100,
                             onReset: { model.resetEffect(\.teethWhiten) })
                ParameterRow(title: model.s.eyeBrightness,
                             value: model.binding(for: \.eyeBrighten),
                             range: 0...100,
                             onReset: { model.resetEffect(\.eyeBrighten) })
                ParameterRow(title: model.s.eyeSharpen,
                             value: model.binding(for: \.eyeSharpen),
                             range: 0...100,
                             onReset: { model.resetEffect(\.eyeSharpen) })
            }
        }
    }

    private var colorContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            autoColorCard

            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: "Color & Light",
                              reset: { model.resetGroup(.colorLight) },
                              resetHelp: model.s.resetGroupHelp)

                ParameterRow(title: model.s.exposure,
                             value: model.binding(for: \.exposure),
                             onReset: { model.resetEffect(\.exposure) })
                ParameterRow(title: model.s.contrast,
                             value: model.binding(for: \.contrast),
                             onReset: { model.resetEffect(\.contrast) })
                ParameterRow(title: model.s.saturation,
                             value: model.binding(for: \.saturation),
                             onReset: { model.resetEffect(\.saturation) })
                ParameterRow(title: model.s.vibrance,
                             value: model.binding(for: \.vibrance),
                             onReset: { model.resetEffect(\.vibrance) })
                ParameterRow(title: model.s.warmth,
                             value: model.binding(for: \.warmth),
                             onReset: { model.resetEffect(\.warmth) })
                ParameterRow(title: model.s.clarity,
                             value: model.binding(for: \.clarity),
                             onReset: { model.resetEffect(\.clarity) })
                ParameterRow(title: model.s.vignette,
                             value: model.binding(for: \.vignette),
                             range: 0...100,
                             onReset: { model.resetEffect(\.vignette) })
            }
        }
    }

    // MARK: - Auto cards

    private var autoRetouchCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                autoIcon("wand.and.stars")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.s.autoRetouch)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Analyzes the face and only touches skin.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            AccentButton(title: "Apply Auto Retouch",
                         icon: "wand.and.stars",
                         enabled: model.hasImage && !model.isBusy) {
                model.autoRetouch()
            }
            .help(model.s.autoRetouchHelp)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.30), lineWidth: 0.75)
        )
    }

    private var autoColorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                autoIcon("camera.filters")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.s.autoColorLight)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(model.s.autoColorLightScope)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            AccentButton(title: "Apply Auto Color",
                         icon: "camera.filters",
                         enabled: model.hasImage && !model.isBusy) {
                model.autoColorLight()
            }
            .help(model.s.autoColorLightHelp)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.75)
        )
    }

    private func autoIcon(_ name: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 30, height: 30)
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentBright)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 8) {
                StatusChip(text: model.faceStatusText,
                           isGood: model.faceStatusIsGood,
                           icon: model.faceStatusIsGood
                               ? "checkmark.circle.fill"
                               : (model.hasImage ? "exclamationmark.triangle.fill" : "photo"),
                           neutral: !model.hasImage)

                Spacer(minLength: 4)

                Button {
                    model.presentExportSheet()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(model.s.export)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(model.hasImage ? Theme.text : Theme.faint)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.hasImage)
                .help(model.s.exportHelp)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}
