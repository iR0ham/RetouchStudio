import SwiftUI

struct SidebarControls: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    presetSection
                    faceSection
                    skinSection
                    detailSection
                    reshapeSection
                    colorSection
                    exportSection
                }
                .padding(10)
            }
        }
        .background(.ultraThinMaterial)
        .environment(\.layoutDirection, model.language.layoutDirection)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color.accentColor.opacity(0.95),
                                            Color.accentColor.opacity(0.60)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(model.s.appName)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(model.imageName.isEmpty ? model.s.noImageOpen : model.imageName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Language switch. A segmented control shows both options, which is
            // unambiguous in a way a single toggling glyph is not.
            Picker("", selection: Binding(
                get: { model.language },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.15)) { model.language = newValue }
                    model.refreshDefaultStatus()
                }
            )) {
                Text("EN").tag(AppLanguage.english)
                Text("فا").tag(AppLanguage.persian)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 62)
            .help(model.s.languageHelp)

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(model.s.undoHelp)
            .disabled(!model.canUndo)

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(model.s.redoHelp)
            .disabled(!model.canRedo)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Auto

    /// The two Auto actions are deliberately independent, so each one lives in
    /// the section it actually changes and is labelled with its scope. There is
    /// no combined "Auto" section, because a combined action would apply a
    /// whole-photo color change when the user only wanted to touch the face.
    private var autoRetouchButton: some View {
        ActionButton(title: model.s.autoRetouch,
                     icon: "face.smiling",
                     help: model.s.autoRetouchHelp,
                     enabled: model.hasImage && !model.isBusy) {
            model.autoRetouch()
        }
    }

    private var autoColorLightButton: some View {
        ActionButton(title: model.s.autoColorLight,
                     icon: "wand.and.stars",
                     help: model.s.autoColorLightHelp,
                     enabled: model.hasImage && !model.isBusy) {
            model.autoColorLight()
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        ToolSection(title: model.s.presets, icon: "slider.horizontal.3") {
            VStack(spacing: 6) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7),
                                    GridItem(.flexible(), spacing: 7)], spacing: 7) {
                    ForEach(Preset.all) { preset in
                        PresetChip(title: model.s.presetTitle(preset.id),
                                   isActive: model.isActive(preset)) {
                            model.apply(preset)
                        }
                    }
                }
                .disabled(!model.hasImage)
                .opacity(model.hasImage ? 1 : 0.45)

                Text(model.s.doubleClickHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
    }

    // MARK: - Face

    private var faceSection: some View {
        ToolSection(title: model.s.faceDetection, icon: "face.dashed",
                    onReset: nil, resetHelp: nil) {
            VStack(alignment: .leading, spacing: 7) {
                StatusPill(text: model.faceStatusText,
                           isGood: model.faceStatusIsGood,
                           icon: model.faceStatusIsGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")

                if model.faceCount == 0, model.hasImage {
                    Text(model.s.faceToolsNeedFace)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingToggle(title: model.s.showFaceOverlay, isOn: $model.showFaceOverlay)
                SettingToggle(title: model.s.compareToggle, isOn: $model.compareEnabled)
            }
        }
    }

    // MARK: - Slider groups

    private var skinSection: some View {
        ToolSection(title: model.s.skin, icon: "sparkles",
                    onReset: { model.resetGroup(.skin) },
                    resetHelp: model.s.resetGroupHelp) {
            VStack(spacing: 7) {
                autoRetouchButton
                Text(model.s.autoRetouchScope)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SliderRow(title: model.s.skinSmoothing,
                          value: model.binding(for: \.smooth), range: 0...100,
                          onReset: { model.resetEffect(\.smooth) })
                SliderRow(title: model.s.texturePreserve,
                          value: model.binding(for: \.texturePreserve), range: 0...100,
                          onReset: { model.resetEffect(\.texturePreserve) })
                SliderRow(title: model.s.blemishRemoval,
                          value: model.binding(for: \.blemish), range: 0...100,
                          onReset: { model.resetEffect(\.blemish) })
                SliderRow(title: model.s.wrinkleReduction,
                          value: model.binding(for: \.wrinkle), range: 0...100,
                          onReset: { model.resetEffect(\.wrinkle) })
                SliderRow(title: model.s.skinTone,
                          value: model.binding(for: \.skinToneEvens), range: 0...100,
                          onReset: { model.resetEffect(\.skinToneEvens) })
                SliderRow(title: model.s.darkCircles,
                          value: model.binding(for: \.darkCircles), range: 0...100,
                          onReset: { model.resetEffect(\.darkCircles) })
                SliderRow(title: model.s.skinBrightness,
                          value: model.binding(for: \.skinBrighten),
                          onReset: { model.resetEffect(\.skinBrighten) })
            }
        }
    }

    private var reshapeSection: some View {
        ToolSection(title: model.s.reshape, icon: "arrow.left.and.right.square",
                    onReset: { model.resetGroup(.reshape) },
                    resetHelp: model.s.resetGroupHelp) {
            VStack(spacing: 7) {
                Text(model.s.reshapeScope)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                reshapeSlider(model.s.eyeSize, \.eyeSize)
                reshapeSlider(model.s.noseSize, \.noseSize)
                reshapeSlider(model.s.noseTip, \.noseTip)
                reshapeSlider(model.s.lipSize, \.lipSize)
                reshapeSlider(model.s.cheekSize, \.cheekSize)
                reshapeSlider(model.s.jawWidth, \.jawWidth)
                reshapeSlider(model.s.chinLength, \.chinLength)
                reshapeSlider(model.s.faceWidth, \.faceWidth)
                reshapeSlider(model.s.faceLength, \.faceLength)
            }
        }
    }

    private func reshapeSlider(_ title: String,
                               _ keyPath: WritableKeyPath<Adjustments, Double>) -> some View {
        SliderRow(title: title,
                  value: model.binding(for: keyPath),
                  onReset: { model.resetEffect(keyPath) })
    }

    private var detailSection: some View {
        ToolSection(title: model.s.faceDetail, icon: "eye") {
            VStack(spacing: 7) {
                SliderRow(title: model.s.teethWhitening, value: model.binding(for: \.teethWhiten), range: 0...100,
                          onReset: { model.resetEffect(\.teethWhiten) })
                SliderRow(title: model.s.eyeBrightness, value: model.binding(for: \.eyeBrighten), range: 0...100,
                          onReset: { model.resetEffect(\.eyeBrighten) })
                SliderRow(title: model.s.eyeSharpen, value: model.binding(for: \.eyeSharpen), range: 0...100,
                          onReset: { model.resetEffect(\.eyeSharpen) })
            }
        }
    }

    private var colorSection: some View {
        ToolSection(title: model.s.colorLight, icon: "camera.filters",
                    onReset: { model.resetGroup(.colorLight) },
                    resetHelp: model.s.resetGroupHelp) {
            VStack(spacing: 7) {
                autoColorLightButton
                Text(model.s.autoColorLightScope)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SliderRow(title: model.s.exposure, value: model.binding(for: \.exposure))
                SliderRow(title: model.s.contrast, value: model.binding(for: \.contrast))
                SliderRow(title: model.s.saturation, value: model.binding(for: \.saturation))
                SliderRow(title: model.s.vibrance, value: model.binding(for: \.vibrance))
                SliderRow(title: model.s.warmth, value: model.binding(for: \.warmth))
                SliderRow(title: model.s.clarity, value: model.binding(for: \.clarity))
                SliderRow(title: model.s.vignette, value: model.binding(for: \.vignette), range: 0...100,
                          onReset: { model.resetEffect(\.vignette) })
            }
        }
    }

    private var exportSection: some View {
        ToolSection(title: model.s.exportSection, icon: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 7) {
                if model.hasImage {
                    Text(model.imageInfo)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ActionButton(title: model.s.saveExport,
                             icon: "square.and.arrow.down",
                             help: model.s.exportHelp,
                             enabled: model.hasImage) {
                    model.presentExportSheet()
                }
                Text(model.s.exportFullQuality)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
