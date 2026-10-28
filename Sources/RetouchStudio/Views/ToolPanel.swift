import SwiftUI

/// The column at the leading edge of the canvas, mirroring the reference's
/// stacked cards: whatever the current tool needs on the canvas first, then the
/// two generative actions, then the state of the document.
struct ToolPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Theme.Metrics.gutter) {
                if model.toolMode == .heal {
                    HealCard(model: model)
                        .transition(.asymmetric(insertion: cardInsertion, removal: .opacity))
                }

                if model.toolMode == .crop {
                    CropCard(model: model)
                        .transition(.asymmetric(insertion: cardInsertion, removal: .opacity))
                }

                autoRetouchCard
                autoColorCard
                statusCard
            }
            .padding(.vertical, 2)
            .animation(Motion.smooth, value: model.toolMode)
        }
        .frame(width: Theme.Metrics.leftPanel)
        .scrollDisabled(!model.hasImage)
        .opacity(model.hasImage ? 1 : 0.5)
        .disabled(!model.hasImage)
        .animation(Motion.swell, value: model.hasImage)
    }

    private var cardInsertion: AnyTransition {
        .opacity.combined(with: .offset(y: -8))
            .combined(with: .scale(scale: 0.97, anchor: .top))
    }

    // MARK: - Auto Retouch

    private var autoRetouchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: model.s.autoRetouch,
                       subtitle: model.s.autoRetouchScope,
                       icon: "wand.and.stars",
                       tint: Theme.sky)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(model.s.autoStrength.uppercased())
                        .font(Theme.Font.section)
                        .tracking(0.6)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 6)
                    Text("\(Int(model.autoRetouchStrength.rounded()))%")
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: model.autoRetouchStrength)
                }

                BipolarSlider(value: $model.autoRetouchStrength,
                              range: 0...100,
                              tint: Theme.sky)
            }

            FilledButton(title: "Generate",
                         icon: "wand.and.stars",
                         tone: .sky,
                         enabled: model.hasImage && !model.isBusy) {
                model.autoRetouch()
            }
            .help(model.s.autoRetouchHelp)
        }
        .padding(16)
        .background(CardBackground())
    }

    // MARK: - Auto Color

    private var autoColorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: model.s.autoColorLight,
                       subtitle: model.s.autoColorLightScope,
                       icon: "camera.filters",
                       tint: Theme.accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(model.s.autoStrength.uppercased())
                        .font(Theme.Font.section)
                        .tracking(0.6)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 6)
                    Text("\(Int(model.autoColorStrength.rounded()))%")
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: model.autoColorStrength)
                }

                BipolarSlider(value: $model.autoColorStrength,
                              range: 0...100,
                              tint: Theme.accent)
            }

            FilledButton(title: "Generate",
                         icon: "camera.filters",
                         enabled: model.hasImage && !model.isBusy) {
                model.autoColorLight()
            }
            .help(model.s.autoColorLightHelp)
        }
        .padding(16)
        .background(CardBackground())
    }

    // MARK: - Status

    /// The chip already says how many faces were found, so the line under it is
    /// for what just happened — and for the canvas hint when nothing did.
    private var detail: String {
        model.status.isEmpty || model.status == model.faceStatusText
            ? model.s.canvasHelp
            : model.status
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                StatusChip(text: model.faceStatusText,
                           isGood: model.faceStatusIsGood,
                           icon: model.faceStatusIsGood
                               ? "checkmark.circle.fill"
                               : (model.hasImage ? "exclamationmark.triangle.fill" : "photo"),
                           neutral: !model.hasImage)
                Spacer(minLength: 0)
            }

            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Motion.smooth, value: detail)

            if !model.imageInfo.isEmpty {
                Text(model.imageInfo)
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.faint)
            }

            Hairline()

            HStack(spacing: 10) {
                Button {
                    model.openImage()
                } label: {
                    Text(model.s.open)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(PressableButtonStyle(dip: 0.94))
                .help(model.s.openHelp)

                Spacer(minLength: 0)

                Button {
                    model.resetAll()
                } label: {
                    HStack(spacing: 4) {
                        Icon(name: "arrow.counterclockwise", size: 11.5, emphasised: true)
                        Text(model.s.reset)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(model.hasImage && !model.adjustments.isIdentity
                                     ? Theme.warning : Theme.faint.opacity(0.7))
                }
                .buttonStyle(PressableButtonStyle(dip: 0.94))
                .disabled(!model.hasImage || model.adjustments.isIdentity)
                .help(model.s.resetHelp)
            }
        }
        .padding(14)
        .background(CardBackground())
    }
}

// MARK: - Healing brush card

/// The reference's brush card: a name, a size, and what the brush has already
/// done to the photo.
private struct HealCard: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Healing Brush",
                       subtitle: model.s.healSubtitle,
                       icon: "bandage",
                       tint: Theme.accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Size")
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 6)
                    Text("\(model.healBrushPixels) px")
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: model.healBrushPixels)
                }
                BipolarSlider(value: $model.healBrushPercent, range: 0.4...6, step: 0.2)
            }

            HStack {
                Text("Stamps")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Text("\(model.healSpots.count)")
                    .font(Theme.Font.value)
                    .foregroundStyle(model.healSpots.isEmpty ? Theme.faint : Theme.accent)
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: model.healSpots.count)
            }

            SecondaryButton(title: "Clear Stamps",
                            icon: "xmark.circle",
                            enabled: model.canClearHealSpots) {
                model.clearHealSpots()
            }
        }
        .padding(16)
        .background(CardBackground())
    }
}

// MARK: - Crop card

private struct CropCard: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Crop",
                       subtitle: "Drag the frame on the photo",
                       icon: "crop",
                       tint: Theme.accent)

            VStack(alignment: .leading, spacing: 8) {
                Text("ASPECT")
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.muted)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                          spacing: 6) {
                    ForEach(CropAspect.allCases) { aspect in
                        PresetChip(title: aspect.title,
                                   isActive: model.cropAspect == aspect) {
                            model.setCropAspect(aspect)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Crop size",
                        "\(Int(model.cropDraftPixelSize.width)) × \(Int(model.cropDraftPixelSize.height)) px")
                infoRow("Working size",
                        "\(Int(model.workingPixelSize.width)) × \(Int(model.workingPixelSize.height)) px")
            }

            VStack(spacing: 8) {
                FilledButton(title: "Apply Crop",
                             icon: "crop",
                             enabled: model.canApplyCrop) {
                    model.applyCrop()
                }
                SecondaryButton(title: "Reset Crop",
                                icon: "arrow.counterclockwise",
                                enabled: model.canResetCrop) {
                    model.resetCrop()
                }
            }
        }
        .padding(16)
        .background(CardBackground())
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.Font.value)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
    }
}
