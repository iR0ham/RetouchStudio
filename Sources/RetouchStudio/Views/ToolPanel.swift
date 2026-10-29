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

                smartCard
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

    // MARK: - Smart Analyze

    /// The one generative entry. The two strength dials say how much of the
    /// measurement to apply; Analyze reads the photo and shows what it found
    /// before anything changes. The per-tool Generate buttons this card
    /// replaced applied the same measurements blind.
    private var smartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: model.s.smartAnalyze,
                       subtitle: model.s.smartSubtitle,
                       icon: "sparkles",
                       tint: Theme.sky)

            strengthRow(title: model.s.autoRetouch,
                        value: model.autoRetouchStrength,
                        binding: $model.autoRetouchStrength,
                        tint: Theme.sky,
                        help: model.s.autoRetouchHelp)
            strengthRow(title: model.s.autoColorLight,
                        value: model.autoColorStrength,
                        binding: $model.autoColorStrength,
                        tint: Theme.accent,
                        help: model.s.autoColorLightHelp)

            if let report = model.smartReport {
                HStack(spacing: 6) {
                    Icon(name: "checkmark.circle.fill", size: 12, emphasised: true)
                        .foregroundStyle(Theme.positive)
                    Text(model.s.smartSummary(model.smartFindingCount, report.faces.count))
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.muted)
                }
                .transition(.opacity)
            } else if model.hasImage && model.faceCount == 0 {
                Text(model.s.smartNoFace)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FilledButton(title: model.s.smartAction,
                         icon: "sparkles",
                         tone: .sky,
                         enabled: model.canSmartAnalyze) {
                model.smartAnalyze()
            }
            .help(model.s.smartHelp)

            if model.smartReport != nil {
                SecondaryButton(title: model.s.smartReview,
                                icon: "rectangle.split.2x1") {
                    model.showSmartSheet = true
                }
            }
        }
        .padding(16)
        .background(CardBackground())
        .animation(Motion.smooth, value: model.smartReport != nil)
    }

    private func strengthRow(title: String,
                             value: Double,
                             binding: Binding<Double>,
                             tint: Color,
                             help: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                Text(Digits.percent(Int(value.rounded())))
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: value)
            }
            BipolarSlider(value: binding,
                          range: 0...100,
                          tint: tint)
        }
        .help(help)
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
                .font(Theme.Font.face(size: 10.5))
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
                        .font(Theme.Font.face(size: 11, weight: .medium))
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
                            .font(Theme.Font.face(size: 11, weight: .medium))
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
            CardHeader(title: model.s.healingBrush,
                       subtitle: model.s.healSubtitle,
                       icon: "bandage",
                       tint: Theme.accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(model.s.brushSize)
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 6)
                    Text("\(Digits.num(model.healBrushPixels)) px")
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: model.healBrushPixels)
                }
                BipolarSlider(value: $model.healBrushPercent, range: 0.4...6, step: 0.2)
            }

            HStack {
                Text(model.s.stamps)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Text(Digits.num(model.healSpots.count))
                    .font(Theme.Font.value)
                    .foregroundStyle(model.healSpots.isEmpty ? Theme.faint : Theme.accent)
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: model.healSpots.count)
            }

            SecondaryButton(title: model.s.clearStamps,
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
            CardHeader(title: model.s.cropTool,
                       subtitle: model.s.cropToolSubtitle,
                       icon: "crop",
                       tint: Theme.accent)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.s.cropAspectLabel)
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
                infoRow(model.s.cropSize,
                        "\(Digits.num(Int(model.cropDraftPixelSize.width))) × \(Digits.num(Int(model.cropDraftPixelSize.height))) px")
                infoRow(model.s.workingSize,
                        "\(Digits.num(Int(model.workingPixelSize.width))) × \(Digits.num(Int(model.workingPixelSize.height))) px")
            }

            VStack(spacing: 8) {
                FilledButton(title: model.s.applyCrop,
                             icon: "crop",
                             enabled: model.canApplyCrop) {
                    model.applyCrop()
                }
                SecondaryButton(title: model.s.resetCrop,
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
