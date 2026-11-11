import AppKit
import StudioCore
import SwiftUI

/// The inspector is one card of collapsible rows, the way the reference stacks
/// Layer / Color / Size / Effects. Every adjustment lives in exactly one row, so
/// the panel no longer has to be re-read every time a tool changes — picking a
/// tool simply opens its row and the others stay where the user left them.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    /// Rows the user has open. Seeded with the tool the app starts on.
    @State private var open: Set<Panel> = [.skin]
    /// The name being typed for a saved look.
    @State private var lookName = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Panel.allCases) { panel in
                        PanelRow(panel: panel,
                                 isOpen: open.contains(panel),
                                 model: model,
                                 toggle: { toggle(panel) }) {
                            content(for: panel)
                        }
                        .id(panel)

                        if panel != Panel.allCases.last {
                            Hairline().padding(.leading, 16)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CardBackground(fill: Theme.panel))
            .padding(.vertical, 2)
            .onChange(of: model.toolMode) { _, mode in
                guard let panel = Panel(tool: mode), !open.contains(panel) else { return }
                withAnimation(Motion.smooth) { open = open.union([panel]) }
                proxy.scrollTo(panel, anchor: .top)
            }
        }
        .frame(width: Theme.Metrics.rightPanel)
        .opacity(model.hasImage ? 1 : 0.5)
        .disabled(!model.hasImage)
        .animation(Motion.swell, value: model.hasImage)
    }

    private func toggle(_ panel: Panel) {
        withAnimation(Motion.smooth) {
            if open.contains(panel) {
                open.remove(panel)
            } else {
                open.insert(panel)
                // Opening a row from the list is also how you point the canvas at
                // the tool that owns it, so healing and crop follow.
                if let tool = panel.tool { model.toolMode = tool }
            }
        }
    }

    @ViewBuilder
    private func content(for panel: Panel) -> some View {
        switch panel {
        case .presets: presetsContent
        case .skin: skinContent
        case .shape: shapeContent
        case .eyes: eyesContent
        case .makeup: makeupContent
        case .color: colorContent
        case .looks: looksContent
        case .body: bodyContent
        case .background: backgroundContent
        case .art: artContent
        case .analysis: analysisContent
        }
    }

    // MARK: - Rows

    private var presetColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    }

    private var presetsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                GroupLabel(text: model.s.myLooks)
                HStack(spacing: 6) {
                    TextField(model.s.lookNamePrompt, text: $lookName)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.face(size: 11))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.inset)
                        )
                        .onSubmit(saveLook)
                    Button(action: saveLook) {
                        Text(model.s.saveLook)
                            .font(Theme.Font.face(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.accentSoft)
                            )
                            .foregroundStyle(Theme.accentInk)
                    }
                    .buttonStyle(PressableButtonStyle(dip: 0.95))
                    .disabled(lookName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if model.userPresets.isEmpty {
                    Text(model.s.noLooksYet)
                        .font(Theme.Font.face(size: 10))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: presetColumns, spacing: 6) {
                        ForEach(model.userPresets) { look in
                            PresetTile(title: look.name,
                                       thumb: model.presetThumbs[look.id],
                                       isActive: model.isActive(look),
                                       onDelete: { model.removeUserPreset(look) },
                                       deleteHelp: model.s.deleteLookHelp) {
                                model.apply(look)
                            }
                        }
                    }
                }
            }

            ForEach(PresetGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(text: group.title)
                    LazyVGrid(columns: presetColumns, spacing: 6) {
                        ForEach(Preset.inGroup(group)) { preset in
                            PresetTile(title: preset.title,
                                       thumb: model.presetThumbs[preset.id.rawValue],
                                       isActive: model.isActive(preset)) {
                                model.apply(preset)
                            }
                        }
                    }
                }
            }

            SectionNote(text: model.s.doubleClickHint)
        }
    }

    private func saveLook() {
        model.saveCurrentAsPreset(named: lookName)
        lookName = ""
    }

    private var skinContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterRow(title: model.s.skinSmoothing,
                         hint: model.s.sliderHint(.skinSmoothing),
                         value: model.binding(for: \.smooth),
                         range: 0...100,
                         onReset: { model.resetEffect(\.smooth) })
            ParameterRow(title: model.s.texturePreserve,
                         hint: model.s.sliderHint(.texturePreserve),
                         value: model.binding(for: \.texturePreserve),
                         range: 0...100,
                         onReset: { model.resetEffect(\.texturePreserve) })
            ParameterRow(title: model.s.blemishRemoval,
                         hint: model.s.sliderHint(.blemishRemoval),
                         value: model.binding(for: \.blemish),
                         range: 0...100,
                         onReset: { model.resetEffect(\.blemish) })
            ParameterRow(title: model.s.wrinkleReduction,
                         hint: model.s.sliderHint(.wrinkleReduction),
                         value: model.binding(for: \.wrinkle),
                         range: 0...100,
                         onReset: { model.resetEffect(\.wrinkle) })
            ParameterRow(title: model.s.skinTone,
                         hint: model.s.sliderHint(.skinTone),
                         value: model.binding(for: \.skinToneEvens),
                         range: 0...100,
                         onReset: { model.resetEffect(\.skinToneEvens) })
            ParameterRow(title: model.s.darkCircles,
                         hint: model.s.sliderHint(.darkCircles),
                         value: model.binding(for: \.darkCircles),
                         range: 0...100,
                         onReset: { model.resetEffect(\.darkCircles) })
            ParameterRow(title: model.s.skinBrightness,
                         hint: model.s.sliderHint(.skinBrightness),
                         value: model.binding(for: \.skinBrighten),
                         range: 0...100,
                         onReset: { model.resetEffect(\.skinBrighten) })
            ParameterRow(title: model.s.skinFinish,
                         hint: model.s.sliderHint(.skinFinish),
                         value: model.binding(for: \.skinFinish),
                         onReset: { model.resetEffect(\.skinFinish) })
            ParameterRow(title: model.s.shine,
                         hint: model.s.sliderHint(.shine),
                         value: model.binding(for: \.shine),
                         range: 0...100,
                         onReset: { model.resetEffect(\.shine) })
        }
    }

    private var shapeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterRow(title: model.s.eyeSize,
                         hint: model.s.sliderHint(.eyeSize),
                         value: model.binding(for: \.eyeSize),
                         onReset: { model.resetEffect(\.eyeSize) })
            ParameterRow(title: model.s.noseSize,
                         hint: model.s.sliderHint(.noseSize),
                         value: model.binding(for: \.noseSize),
                         onReset: { model.resetEffect(\.noseSize) })
            ParameterRow(title: model.s.noseTip,
                         hint: model.s.sliderHint(.noseTip),
                         value: model.binding(for: \.noseTip),
                         onReset: { model.resetEffect(\.noseTip) })
            ParameterRow(title: model.s.lipSize,
                         hint: model.s.sliderHint(.lipSize),
                         value: model.binding(for: \.lipSize),
                         onReset: { model.resetEffect(\.lipSize) })
            ParameterRow(title: model.s.cheekSize,
                         hint: model.s.sliderHint(.cheekSize),
                         value: model.binding(for: \.cheekSize),
                         onReset: { model.resetEffect(\.cheekSize) })
            ParameterRow(title: model.s.jawWidth,
                         hint: model.s.sliderHint(.jawWidth),
                         value: model.binding(for: \.jawWidth),
                         onReset: { model.resetEffect(\.jawWidth) })
            ParameterRow(title: model.s.chinLength,
                         hint: model.s.sliderHint(.chinLength),
                         value: model.binding(for: \.chinLength),
                         onReset: { model.resetEffect(\.chinLength) })
            ParameterRow(title: model.s.faceWidth,
                         hint: model.s.sliderHint(.faceWidth),
                         value: model.binding(for: \.faceWidth),
                         onReset: { model.resetEffect(\.faceWidth) })
            ParameterRow(title: model.s.faceLength,
                         hint: model.s.sliderHint(.faceLength),
                         value: model.binding(for: \.faceLength),
                         onReset: { model.resetEffect(\.faceLength) })
            SectionNote(text: model.s.reshapeScope)
        }
    }

    private var eyesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterRow(title: model.s.teethWhitening,
                         hint: model.s.sliderHint(.teethWhitening),
                         value: model.binding(for: \.teethWhiten),
                         range: 0...100,
                         onReset: { model.resetEffect(\.teethWhiten) })
            ParameterRow(title: model.s.eyeBrightness,
                         hint: model.s.sliderHint(.eyeBrightness),
                         value: model.binding(for: \.eyeBrighten),
                         range: 0...100,
                         onReset: { model.resetEffect(\.eyeBrighten) })
            ParameterRow(title: model.s.eyeSharpen,
                         hint: model.s.sliderHint(.eyeSharpen),
                         value: model.binding(for: \.eyeSharpen),
                         range: 0...100,
                         onReset: { model.resetEffect(\.eyeSharpen) })
            ParameterRow(title: model.s.irisEnhance,
                         hint: model.s.sliderHint(.irisEnhance),
                         value: model.binding(for: \.irisEnhance),
                         range: 0...100,
                         onReset: { model.resetEffect(\.irisEnhance) })
            ParameterRow(title: model.s.lashDarken,
                         hint: model.s.sliderHint(.lashDarken),
                         value: model.binding(for: \.lashDarken),
                         range: 0...100,
                         onReset: { model.resetEffect(\.lashDarken) })
            ParameterRow(title: model.s.teethAlign,
                         hint: model.s.sliderHint(.teethAlign),
                         value: model.binding(for: \.teethAlign),
                         range: 0...100,
                         onReset: { model.resetEffect(\.teethAlign) })

            HStack(spacing: 6) {
                GroupLabel(text: model.s.lensColor)
                Spacer(minLength: 6)
                ColorPicker(model.s.lensColor,
                            selection: lensPickerBinding,
                            supportsOpacity: false)
                    .labelsHidden()
                    .help(model.s.pickColorHelp)
            }

            ParameterRow(title: model.s.lensTint,
                         hint: model.s.sliderHint(.lensTint),
                         value: model.binding(for: \.lensTint),
                         range: 0...100,
                         onReset: { model.resetEffect(\.lensTint) })

            if model.hasImage, model.faceCount > 0, !model.hasVisibleTeeth {
                SectionNote(text: model.s.teethNotVisible)
            }
        }
    }

    private var makeupContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) {
                ForEach(MakeupRegion.allCases) { region in
                    PresetChip(title: region.title, isActive: model.makeupRegion == region) {
                        model.makeupRegion = region
                    }
                }
            }

            // Lip and cheek shades are mixed per skin tone. The row opens on the
            // family the photo's own cheek skin measured, and any family can be
            // chosen by hand.
            if model.makeupRegion.hasFamilies {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5),
                          spacing: 4) {
                    ForEach(MakeupFamily.allCases) { family in
                        PresetChip(title: family.title, isActive: model.makeupFamily == family) {
                            model.makeupFamily = family
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                GroupLabel(text: model.s.makeupColor)
                Spacer(minLength: 6)
                ColorPicker(model.s.makeupCustomColor,
                            selection: pickerBinding,
                            supportsOpacity: false)
                    .labelsHidden()
                    .help(model.s.pickColorHelp)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                      spacing: 6) {
                ForEach(swatches) { shade in
                    SwatchChip(color: shade.color,
                               title: shade.title,
                               isActive: model.makeupColor(model.makeupRegion) == shade.color) {
                        model.chooseMakeupShade(shade)
                    }
                }
            }

            ParameterRow(title: model.s.hue,
                         hint: model.s.sliderHint(.makeupHue),
                         value: model.makeupHueBinding(model.makeupRegion),
                         range: 0...360)
            ParameterRow(title: model.s.saturation,
                         hint: model.s.sliderHint(.makeupSaturation),
                         value: model.makeupSaturationBinding(model.makeupRegion),
                         range: 0...100)
            ParameterRow(title: model.s.opacity,
                         hint: model.s.sliderHint(.makeupOpacity),
                         value: model.binding(for: model.makeupRegion.amountPath),
                         range: 0...100,
                         onReset: { model.resetEffect(model.makeupRegion.amountPath) })

            if model.makeupRegion == .lips {
                ParameterRow(title: model.s.lipGloss,
                             hint: model.s.sliderHint(.lipGloss),
                             value: model.binding(for: \.lipGloss),
                             range: 0...100,
                             onReset: { model.resetEffect(\.lipGloss) })
            }
            if model.makeupRegion == .hair {
                ParameterRow(title: model.s.hairShine,
                             hint: model.s.sliderHint(.hairShine),
                             value: model.binding(for: \.hairShine),
                             range: 0...100,
                             onReset: { model.resetEffect(\.hairShine) })
                ParameterRow(title: model.s.hairVolume,
                             hint: model.s.sliderHint(.hairVolume),
                             value: model.binding(for: \.hairVolume),
                             range: 0...100,
                             onReset: { model.resetEffect(\.hairVolume) })
            }

            SectionNote(text: model.faceCount > 0 ? model.s.makeupNote : model.s.makeupNoFace)
        }
    }

    /// The swatches on offer for the region that is open.
    private var swatches: [MakeupShade] {
        let region = model.makeupRegion
        return MakeupShade.shades(region, family: region.hasFamilies ? model.makeupFamily : nil)
    }

    /// What the colour well shows and writes. The picker speaks `Color`; the
    /// model stores the same colour as HSV, because that is what the hue and
    /// saturation sliders edit.
    private var pickerBinding: Binding<Color> {
        Binding(
            get: { model.makeupColor(model.makeupRegion).color },
            set: { newValue in
                guard let ns = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                model.setMakeupColor(model.makeupRegion, MakeupColor(
                    hue: Double(ns.hueComponent) * 360,
                    saturation: Double(ns.saturationComponent),
                    value: Double(ns.brightnessComponent)))
            })
    }

    private var colorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HistogramView(image: model.previewImage,
                          accessibilityLabel: model.s.histogramLabel)
            ParameterRow(title: model.s.exposure,
                         hint: model.s.sliderHint(.exposure),
                         value: model.binding(for: \.exposure),
                         onReset: { model.resetEffect(\.exposure) })
            ParameterRow(title: model.s.contrast,
                         hint: model.s.sliderHint(.contrast),
                         value: model.binding(for: \.contrast),
                         onReset: { model.resetEffect(\.contrast) })
            ParameterRow(title: model.s.blacks,
                         hint: model.s.sliderHint(.blacks),
                         value: model.binding(for: \.blacks),
                         onReset: { model.resetEffect(\.blacks) })
            ParameterRow(title: model.s.whites,
                         hint: model.s.sliderHint(.whites),
                         value: model.binding(for: \.whites),
                         onReset: { model.resetEffect(\.whites) })
            ParameterRow(title: model.s.saturation,
                         hint: model.s.sliderHint(.colorSaturation),
                         value: model.binding(for: \.saturation),
                         onReset: { model.resetEffect(\.saturation) })
            ParameterRow(title: model.s.vibrance,
                         hint: model.s.sliderHint(.vibrance),
                         value: model.binding(for: \.vibrance),
                         onReset: { model.resetEffect(\.vibrance) })
            ParameterRow(title: model.s.warmth,
                         hint: model.s.sliderHint(.warmth),
                         value: model.binding(for: \.warmth),
                         onReset: { model.resetEffect(\.warmth) })
            ParameterRow(title: model.s.clarity,
                         hint: model.s.sliderHint(.clarity),
                         value: model.binding(for: \.clarity),
                         onReset: { model.resetEffect(\.clarity) })
            ParameterRow(title: model.s.splitTone,
                         hint: model.s.sliderHint(.splitTone),
                         value: model.binding(for: \.splitTone),
                         range: 0...100,
                         onReset: { model.resetEffect(\.splitTone) })
            ParameterRow(title: model.s.vignette,
                         hint: model.s.sliderHint(.vignette),
                         value: model.binding(for: \.vignette),
                         range: 0...100,
                         onReset: { model.resetEffect(\.vignette) })

            CurveEditor(model: model)

            GroupLabel(text: model.s.hsl)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                      spacing: 4) {
                ForEach(HSLBand.allCases) { band in
                    PresetChip(title: band.title, isActive: model.hslBand == band) {
                        model.hslBand = band
                    }
                }
            }

            ParameterRow(title: model.s.hue,
                         hint: model.s.sliderHint(.hslHue),
                         value: model.hslBinding(model.hslBand, \.hslHue),
                         onReset: { model.resetHSLBand(model.hslBand) })
            ParameterRow(title: model.s.saturation,
                         hint: model.s.sliderHint(.hslSaturation),
                         value: model.hslBinding(model.hslBand, \.hslSaturation),
                         onReset: { model.resetHSLBand(model.hslBand) })
            ParameterRow(title: model.s.luminance,
                         hint: model.s.sliderHint(.hslLuminance),
                         value: model.hslBinding(model.hslBand, \.hslLuminance),
                         onReset: { model.resetHSLBand(model.hslBand) })

            SectionNote(text: model.s.hslNote)
        }
    }

    private var looksContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) {
                ForEach(FilmLook.allCases) { look in
                    PresetChip(title: look.title,
                               isActive: model.adjustments.look == look) {
                        model.setLook(look)
                    }
                }
            }

            ParameterRow(title: model.s.lookStrength,
                         hint: model.s.sliderHint(.lookStrength),
                         value: model.binding(for: \.lookStrength),
                         range: 0...100,
                         onReset: { model.resetEffect(\.lookStrength) })
            ParameterRow(title: model.s.grain,
                         hint: model.s.sliderHint(.grain),
                         value: model.binding(for: \.grain),
                         range: 0...100,
                         onReset: { model.resetEffect(\.grain) })

            SectionNote(text: model.s.lookNote)
        }
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterRow(title: model.s.bodySmoothing,
                         hint: model.s.sliderHint(.bodySmoothing),
                         value: model.binding(for: \.bodySmooth),
                         range: 0...100,
                         onReset: { model.resetEffect(\.bodySmooth) })
            ParameterRow(title: model.s.bodyBrightness,
                         hint: model.s.sliderHint(.bodyBrightness),
                         value: model.binding(for: \.bodyTone),
                         onReset: { model.resetEffect(\.bodyTone) })
            ParameterRow(title: model.s.bodySlim,
                         hint: model.s.sliderHint(.bodySlim),
                         value: model.binding(for: \.bodySlim),
                         onReset: { model.resetEffect(\.bodySlim) })
            ParameterRow(title: model.s.bodyWaist,
                         hint: model.s.sliderHint(.bodyWaist),
                         value: model.binding(for: \.bodyWaist),
                         onReset: { model.resetEffect(\.bodyWaist) })
            ParameterRow(title: model.s.bodyArms,
                         hint: model.s.sliderHint(.bodyArms),
                         value: model.binding(for: \.bodyArms),
                         onReset: { model.resetEffect(\.bodyArms) })
            ParameterRow(title: model.s.bodyLegs,
                         hint: model.s.sliderHint(.bodyLegs),
                         value: model.binding(for: \.bodyLegs),
                         onReset: { model.resetEffect(\.bodyLegs) })
            subjectNote(scope: model.s.bodyScope)
            poseNote
        }
    }

    /// Waist, arms and legs need joints as well as a silhouette. Say which
    /// group Vision is still missing instead of leaving the sliders looking
    /// broken.
    @ViewBuilder
    private var poseNote: some View {
        switch model.subjectState {
        case .unknown, .detecting:
            SectionNote(text: model.s.poseScope)
        case .unavailable:
            EmptyView()
        case .available:
            if !model.hasBodyPose {
                SectionNote(text: model.s.poseMissing)
            } else if model.bodyPoseGaps.isEmpty {
                SectionNote(text: model.s.poseScope)
            } else {
                ForEach(Array(model.bodyPoseGaps.enumerated()), id: \.offset) { _, gap in
                    SectionNote(text: gap)
                }
            }
        }
    }

    private var backgroundContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Removing the background discards it, so grading it first cannot
            // change what the photo shows. They dim together to say so.
            Group {
                ParameterRow(title: model.s.backgroundBlur,
                             hint: model.s.sliderHint(.backgroundBlur),
                             value: model.binding(for: \.backgroundBlur),
                             range: 0...100,
                             onReset: { model.resetEffect(\.backgroundBlur) })
                ParameterRow(title: model.s.backgroundTone,
                             hint: model.s.sliderHint(.backgroundTone),
                             value: model.binding(for: \.backgroundTone),
                             onReset: { model.resetEffect(\.backgroundTone) })
                ParameterRow(title: model.s.backgroundSaturation,
                             hint: model.s.sliderHint(.backgroundSaturation),
                             value: model.binding(for: \.backgroundSaturation),
                             onReset: { model.resetEffect(\.backgroundSaturation) })

                HStack(spacing: 6) {
                    GroupLabel(text: model.s.backgroundFillColor)
                    Spacer(minLength: 6)
                    ColorPicker(model.s.backgroundFillColor,
                                selection: fillColorBinding,
                                supportsOpacity: false)
                        .labelsHidden()
                        .help(model.s.pickColorHelp)
                }

                ParameterRow(title: model.s.backgroundFill,
                             hint: model.s.sliderHint(.backgroundFill),
                             value: model.binding(for: \.backgroundFill),
                             range: 0...100,
                             onReset: { model.resetEffect(\.backgroundFill) })

                GroupLabel(text: model.s.backdropImageTitle)
                if model.adjustments.backgroundImage.isEmpty {
                    SecondaryButton(title: model.s.chooseBackdrop, icon: "photo") {
                        model.chooseBackdropImage()
                    }
                } else {
                    HStack(spacing: 6) {
                        Icon(name: "photo", size: 12, emphasised: true)
                            .foregroundStyle(Theme.accent)
                        Text(model.adjustments.backgroundImageName.isEmpty
                             ? model.s.backdropImageTitle
                             : model.adjustments.backgroundImageName)
                            .font(Theme.Font.face(size: 11))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Button { model.clearBackdropImage() } label: {
                            Icon(name: "xmark", size: 10.5, emphasised: true)
                                .foregroundStyle(Theme.faint)
                        }
                        .buttonStyle(PressableButtonStyle(dip: 0.9))
                        .help(model.s.backdropClearHelp)
                    }

                    ParameterRow(title: model.s.backdropStrength,
                                 hint: model.s.sliderHint(.backdropStrength),
                                 value: model.binding(for: \.backgroundImageAmount),
                                 range: 0...100,
                                 onReset: { model.adjustments.backgroundImageAmount = 100 })
                    SectionNote(text: model.s.backdropNote)
                }
            }
            .disabled(model.adjustments.backgroundRemove)
            .opacity(model.adjustments.backgroundRemove ? 0.45 : 1)

            Toggle(isOn: removeBackgroundBinding) {
                Text(model.s.backgroundRemove)
                    .font(Theme.Font.face(size: 11))
                    .foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if model.adjustments.backgroundRemove {
                SectionNote(text: model.s.backgroundRemoveNote)
            }

            if model.adjustments.backgroundRemove {
                removalSubjectNote
            } else {
                subjectNote(scope: model.s.backgroundScope)
            }
        }
    }

    /// Removal still needs a subject, but the grading scope sentence would be
    /// describing sliders that are switched off.
    @ViewBuilder
    private var removalSubjectNote: some View {
        switch model.subjectState {
        case .detecting:
            SectionNote(text: model.s.subjectDetecting)
        case .unavailable:
            SectionNote(text: model.s.subjectMissing)
        case .unknown, .available:
            EmptyView()
        }
    }

    private var artContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) {
                ForEach(StickerKind.allCases) { kind in
                    PresetChip(title: kind.title,
                               isActive: model.stickerKindBinding().wrappedValue == kind) {
                        model.stickerKindBinding().wrappedValue = kind
                    }
                }
            }

            HStack(spacing: 6) {
                GroupLabel(text: model.s.makeupColor)
                Spacer(minLength: 6)
                ColorPicker(model.s.makeupCustomColor,
                            selection: artColorBinding,
                            supportsOpacity: false)
                    .labelsHidden()
                    .help(model.s.pickColorHelp)
            }

            ParameterRow(title: model.s.artSize,
                         hint: model.s.sliderHint(.artSize),
                         value: model.stickerSizeBinding(),
                         range: 2...60)
            ParameterRow(title: model.s.artRotation,
                         hint: model.s.sliderHint(.artRotation),
                         value: model.stickerRotationBinding(),
                         range: -180...180)
            ParameterRow(title: model.s.opacity,
                         hint: model.s.sliderHint(.artOpacity),
                         value: model.stickerOpacityBinding(),
                         range: 0...100)

            HStack(spacing: 6) {
                artButton(title: model.s.artDelete, icon: "trash",
                          enabled: model.canDeleteSticker,
                          action: model.deleteSelectedSticker)
                artButton(title: model.s.artDuplicate, icon: "plus.square.on.square",
                          enabled: model.canDeleteSticker,
                          action: model.duplicateSelectedSticker)
                artButton(title: model.s.artClear, icon: "xmark.circle",
                          enabled: model.hasStickers,
                          action: model.clearStickers)
            }

            SectionNote(text: model.s.artNote)
        }
    }

    private func artButton(title: String,
                           icon: String,
                           enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Icon(name: icon, size: 11)
                Text(title)
                    .font(Theme.Font.face(size: 10.5))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.inset)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(dip: 0.94))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(title)
    }

    // MARK: - Face analysis

    private var analysisContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.faces.count > 1 {
                GroupLabel(text: model.s.faceSelectionTitle)
                HStack(spacing: 6) {
                    PresetChip(title: model.s.faceSelectionAuto,
                               isActive: model.selectedFaceIndex == nil) {
                        model.selectFace(nil)
                    }
                    ForEach(Array(model.faces.indices), id: \.self) { index in
                        PresetChip(title: model.s.faceSelectionName(index),
                                   isActive: model.selectedFaceIndex == index) {
                            model.selectFace(index)
                        }
                    }
                }
            }

            Toggle(isOn: model.analysisEnabledBinding) {
                Text(model.s.analysisEnable)
                    .font(Theme.Font.face(size: 11))
                    .foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.analysisReady)

            if !model.analysisReady {
                SectionNote(text: model.s.analysisNoFace)
            } else if model.analysisUsesFaceBoxFallback {
                SectionNote(text: model.s.analysisNoLandmarks)
            }

            Group {
                GroupLabel(text: model.s.analysisStyle)
                HStack(spacing: 6) {
                    PresetChip(title: model.s.analysisStyleOutline,
                               isActive: !model.analysis.showsMesh) {
                        model.analysis.showsMesh = false
                    }
                    PresetChip(title: model.s.analysisStyleMesh,
                               isActive: model.analysis.showsMesh) {
                        model.analysis.showsMesh = true
                    }
                }

                if !model.analysis.showsMesh {
                    Toggle(isOn: model.analysisOutlineBinding) {
                        Text(model.s.analysisFaceOutline)
                            .font(Theme.Font.face(size: 11))
                            .foregroundStyle(Theme.text)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                GroupLabel(text: model.s.analysisInk)
                HStack(spacing: 8) {
                    ForEach(AnalysisTint.allCases) { tint in
                        tintSwatch(tint)
                    }
                    Spacer(minLength: 0)
                }

                ParameterRow(title: model.s.analysisWeight,
                             hint: model.s.sliderHint(.analysisWeight),
                             value: model.analysisWeightBinding,
                             range: 60...240)

                GroupLabel(text: model.s.analysisAreas)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2),
                          spacing: 6) {
                    ForEach(AnalysisRegion.allCases) { region in
                        PresetChip(title: model.s.analysisRegionTitle(region),
                                   isActive: model.analysis.regions.contains(region)) {
                            model.analysisRegionBinding(region).wrappedValue.toggle()
                        }
                    }
                }

                ParameterRow(title: model.s.analysisStrength,
                             hint: model.s.sliderHint(.analysisStrength),
                             value: model.analysisOpacityBinding,
                             range: 5...100)

                Toggle(isOn: model.analysisGlowBinding) {
                    Text(model.s.analysisGlow)
                        .font(Theme.Font.face(size: 11))
                        .foregroundStyle(Theme.text)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                artButton(title: model.s.analysisResetEnds,
                          icon: "arrow.counterclockwise",
                          enabled: model.canResetAnalysisPins,
                          action: model.resetAnalysisPins)

                SectionNote(text: model.analysis.showsMesh
                            ? model.s.analysisMeshNote
                            : model.s.analysisNote)
            }
            .disabled(!model.analysis.isEnabled)
            .opacity(model.analysis.isEnabled ? 1 : 0.45)
        }
    }

    /// A swatch is the colour itself; the selected one carries the accent ring
    /// so the row reads at a glance without labels.
    private func tintSwatch(_ tint: AnalysisTint) -> some View {
        let rgb = tint.rgb
        let active = model.analysis.tint == tint
        return Button {
            model.analysisTintBinding.wrappedValue = tint
        } label: {
            Circle()
                .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                .overlay(Circle().strokeBorder(active ? Theme.accentBright : Color.clear,
                                               lineWidth: 2))
                .frame(width: 22, height: 22)
                .padding(2)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(dip: 0.94))
        .help(model.s.analysisTintTitle(tint))
    }

    private func makeupColor(from color: Color) -> MakeupColor? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return MakeupColor(hue: Double(ns.hueComponent) * 360,
                           saturation: Double(ns.saturationComponent),
                           value: Double(ns.brightnessComponent))
    }

    private var lensPickerBinding: Binding<Color> {
        Binding(get: { model.adjustments.lensColor.color },
                set: { newValue in
                    guard let color = makeupColor(from: newValue) else { return }
                    model.setLensColor(color)
                })
    }

    private var fillColorBinding: Binding<Color> {
        Binding(get: { model.adjustments.backgroundFillColor.color },
                set: { newValue in
                    guard let color = makeupColor(from: newValue) else { return }
                    model.setBackgroundFillColor(color)
                })
    }

    private var removeBackgroundBinding: Binding<Bool> {
        Binding(get: { model.adjustments.backgroundRemove },
                set: { model.adjustments.backgroundRemove = $0 })
    }

    private var artColorBinding: Binding<Color> {
        Binding(get: { model.stickerColorBinding().wrappedValue.color },
                set: { newValue in
                    guard let color = makeupColor(from: newValue) else { return }
                    model.stickerColorBinding().wrappedValue = color
                })
    }

    /// The two scene tools need a subject. Say so instead of leaving the
    /// sliders looking broken while Vision answers, or when it finds nobody.
    @ViewBuilder
    private func subjectNote(scope: String) -> some View {
        switch model.subjectState {
        case .detecting:
            SectionNote(text: model.s.subjectDetecting)
        case .unavailable:
            SectionNote(text: model.s.subjectMissing)
        case .unknown, .available:
            SectionNote(text: scope)
        }
    }
}

// MARK: - Tone curve

/// A compact three-point curve. The three handles are shadows, mid-tones and
/// highlights; dragging one lifts or lowers that band, and the drawn line is the
/// exact luminance response the kernel applies, so the graph never lies about
/// what the photo will do.
private struct CurveEditor: View {
    @ObservedObject var model: EditorModel

    private let handleXs: [Double] = [0.15, 0.5, 0.85]

    private var values: [Double] {
        [model.adjustments.curveShadows,
         model.adjustments.curveMidtones,
         model.adjustments.curveHighlights]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                GroupLabel(text: model.s.toneCurve)
                Spacer(minLength: 6)
                Button {
                    model.resetEffects([\.curveShadows, \.curveMidtones, \.curveHighlights])
                } label: {
                    Icon(name: "arrow.counterclockwise", size: 11.5, emphasised: true)
                        .foregroundStyle(Theme.faint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(dip: 0.88))
                .disabled(values.allSatisfy { $0 == 0 })
                .opacity(values.allSatisfy { $0 == 0 } ? 0.35 : 1)
                .help(model.s.resetGroupHelp)
            }

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.inset)

                    gridPath(size)
                        .stroke(Theme.faint.opacity(0.14), lineWidth: 0.5)

                    curvePath(size)
                        .stroke(Theme.accent,
                                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                    ForEach(0..<3, id: \.self) { index in
                        handle(index, size: size)
                    }
                }
            }
            .frame(height: 92)
            // A tone curve is a graph: shadows stay on the left in every
            // language, and the handles are positioned in absolute x.
            .environment(\.layoutDirection, .leftToRight)

            SectionNote(text: model.s.curveNote)
        }
    }

    private func handle(_ index: Int, size: CGSize) -> some View {
        let y = 0.5 + values[index] / 100 * 0.35
        return Circle()
            .fill(Theme.accent)
            .overlay(Circle().stroke(Theme.inset, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .position(x: handleXs[index] * size.width,
                      y: (1 - y) * size.height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let unit = 1 - drag.location.y / max(size.height, 1)
                        let raw = (unit - 0.5) / 0.35 * 100
                        setValue(index, min(100, max(-100, raw)))
                    }
            )
    }

    private func setValue(_ index: Int, _ value: Double) {
        switch index {
        case 0: model.adjustments.curveShadows = value
        case 1: model.adjustments.curveMidtones = value
        default: model.adjustments.curveHighlights = value
        }
    }

    /// The same Gaussian-band arithmetic the kernel runs, on display values.
    private func curveValue(_ x: Double) -> Double {
        let s = values[0] / 100
        let m = values[1] / 100
        let h = values[2] / 100
        let wS = exp(-pow((x - 0.14) / 0.18, 2))
        let wM = exp(-pow((x - 0.50) / 0.20, 2))
        let wH = exp(-pow((x - 0.86) / 0.18, 2))
        let delta = 0.26 * s * wS + 0.22 * m * wM + 0.26 * h * wH
        return min(1, max(0, x + delta))
    }

    private func curvePath(_ size: CGSize) -> Path {
        var path = Path()
        let samples = 48
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            let point = CGPoint(x: x * size.width,
                                y: (1 - curveValue(x)) * size.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func gridPath(_ size: CGSize) -> Path {
        var path = Path()
        for i in 1..<4 {
            let fraction = CGFloat(i) / 4
            path.move(to: CGPoint(x: fraction * size.width, y: 0))
            path.addLine(to: CGPoint(x: fraction * size.width, y: size.height))
            path.move(to: CGPoint(x: 0, y: fraction * size.height))
            path.addLine(to: CGPoint(x: size.width, y: fraction * size.height))
        }
        return path
    }
}

// MARK: - Panel rows

/// One accordion row: a title that doubles as the tool name, a dot that says
/// there is work inside, and a chevron that turns as the row opens.
private struct PanelRow<Content: View>: View {
    let panel: Panel
    let isOpen: Bool
    let model: EditorModel
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    private var isModified: Bool {
        switch panel {
        case .art: return model.hasStickers
        case .analysis: return model.analysis != AnalysisSettings()
        default: return panel.isModified(model.adjustments)
        }
    }

    private var reset: (() -> Void)? {
        switch panel.resetKind {
        case .nothing: return nil
        case .skin: return { model.resetGroup(.skin) }
        case .shape: return { model.resetGroup(.reshape) }
        case .eyes:
            return {
                model.resetEffects([\.teethWhiten, \.eyeBrighten, \.eyeSharpen,
                                    \.irisEnhance, \.lashDarken, \.lensTint, \.teethAlign])
            }
        case .makeup: return { model.resetGroup(.makeup) }
        case .color: return { model.resetGroup(.colorLight) }
        case .looks: return { model.resetGroup(.look) }
        case .body: return { model.resetGroup(.body) }
        case .background: return { model.resetGroup(.background) }
        case .art: return { model.clearStickers() }
        case .analysis: return { model.analysis = AnalysisSettings() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .opacity(isModified ? 1 : 0)
                        .animation(Motion.snappy, value: isModified)

                    Text(panel.title)
                        .font(Theme.Font.face(size: 13, weight: isOpen ? .semibold : .medium))
                        .foregroundStyle(isOpen || hovering ? Theme.text : Theme.muted)

                    Spacer(minLength: 8)

                    if let reset {
                        Button(action: reset) {
                            Icon(name: "arrow.counterclockwise", size: 13, emphasised: true)
                                .foregroundStyle(Theme.faint)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle(dip: 0.88))
                        .help(panel.resetHelp ?? model.s.resetGroupHelp)
                        .opacity(isModified ? 1 : 0)
                        .allowsHitTesting(isModified)
                    }

                    Icon(name: "chevron.down", size: 13.5, emphasised: true)
                        .foregroundStyle(isOpen ? Theme.accent : Theme.faint)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .animation(Motion.smooth, value: isOpen)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(dip: 0.99))
            .help("\(panel.title) — \(panel.hint)")

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(AccordionTransition.content)
            }
        }
        .background(hovering ? Theme.bone.opacity(0.022) : Color.clear)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }
}

/// The shared open/close transition: rows grow out of their header rather than
/// pushing the list with a hard cut.
enum AccordionTransition {
    static var content: AnyTransition {
        .modifier(
            active: OpacityOffsetScale(offset: -6, scale: 0.985),
            identity: OpacityOffsetScale(offset: 0, scale: 1)
        )
    }
}

private struct OpacityOffsetScale: ViewModifier {
    var offset: CGFloat
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(offset == 0 ? 1 : 0)
            .offset(y: offset)
            .scaleEffect(scale, anchor: .top)
    }
}

/// The rows in the order they appear, each with the tool it belongs to and the
/// way to tell whether it holds any work.
enum Panel: String, CaseIterable, Identifiable {
    case presets
    case skin
    case shape
    case eyes
    case makeup
    case color
    case looks
    case body
    case background
    case art
    case analysis

    var id: String { rawValue }

    var title: String {
        L10n.current.panelTitle(self)
    }

    /// One line for the hover hint. Panels that drive a tool already carry a
    /// subtitle; Presets is the only one that needs its own.
    var hint: String {
        tool?.subtitle ?? L10n.current.presetsHint
    }

    /// The tool whose canvas behaviour this row drives, if any.
    var tool: ToolMode? {
        switch self {
        case .presets: return nil
        case .skin: return .skin
        case .shape: return .reshape
        case .eyes: return .detail
        case .makeup: return .makeup
        case .color: return .color
        case .looks: return .look
        case .body: return .body
        case .background: return .background
        case .art: return .art
        case .analysis: return .analysis
        }
    }

    init?(tool: ToolMode) {
        guard let panel = Panel.allCases.first(where: { $0.tool == tool }) else { return nil }
        self = panel
    }

    /// Which group this row clears. The closure is built by the row itself, so
    /// the enum stays free of main-actor isolation.
    var resetKind: PanelReset {
        switch self {
        case .presets: return .nothing
        case .skin: return .skin
        case .shape: return .shape
        case .eyes: return .eyes
        case .makeup: return .makeup
        case .color: return .color
        case .looks: return .looks
        case .body: return .body
        case .background: return .background
        case .art: return .art
        case .analysis: return .analysis
        }
    }

    var resetHelp: String? {
        self == .makeup ? L10n.current.resetMakeupHelp : nil
    }

    func isModified(_ a: Adjustments) -> Bool {
        switch self {
        case .presets: return false
        case .skin:
            return a.smooth != 0 || a.texturePreserve != 0 || a.blemish != 0 || a.wrinkle != 0
                || a.skinToneEvens != 0 || a.darkCircles != 0 || a.skinBrighten != 0
                || a.skinFinish != 0 || a.shine != 0
        case .shape: return a.reshapeOnly != .zero
        case .eyes:
            return a.teethWhiten != 0 || a.eyeBrighten != 0 || a.eyeSharpen != 0
                || a.irisEnhance != 0 || a.lashDarken != 0
                || a.lensTint != 0 || a.teethAlign != 0
        case .makeup: return a.hasMakeup
        case .color: return a.colorLightOnly != .zero
        case .looks: return a.hasLook || a.grain != 0
        case .body: return a.bodyOnly != .zero
        case .background: return a.backgroundOnly != .zero
        case .art: return false
        case .analysis: return false
        }
    }
}

/// The group a row's reset glyph clears.
enum PanelReset {
    case nothing, skin, shape, eyes, makeup, color, looks, body, background, art, analysis
}
