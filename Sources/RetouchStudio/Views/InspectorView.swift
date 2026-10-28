import SwiftUI

/// The inspector is one card of collapsible rows, the way the reference stacks
/// Layer / Color / Size / Effects. Every adjustment lives in exactly one row, so
/// the panel no longer has to be re-read every time a tool changes — picking a
/// tool simply opens its row and the others stay where the user left them.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    /// Rows the user has open. Seeded with the tool the app starts on.
    @State private var open: Set<Panel> = [.skin]

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
        }
    }

    // MARK: - Rows

    private var presetsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2),
                      spacing: 6) {
                ForEach(Preset.all) { preset in
                    PresetChip(title: model.s.presetTitle(preset.id),
                               isActive: model.isActive(preset)) {
                        model.apply(preset)
                    }
                }
            }
            SectionNote(text: model.s.doubleClickHint)
        }
    }

    private var skinContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                         range: 0...100,
                         onReset: { model.resetEffect(\.skinBrighten) })
        }
    }

    private var shapeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            SectionNote(text: model.s.reshapeScope)
        }
    }

    private var eyesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if model.hasImage, model.faceCount > 0, !model.hasVisibleTeeth {
                SectionNote(text: model.s.teethNotVisible)
            }
        }
    }

    private var makeupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            shadeGroup("Lips", model.adjustments.lipShade, model.setLipShade,
                       title: "Color", key: \.lipTint)
            shadeGroup("Cheeks", model.adjustments.blushShade, model.setBlushShade,
                       title: "Flush", key: \.blush)

            VStack(alignment: .leading, spacing: 2) {
                Text("BROWS")
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                    .padding(.top, 2)
                ParameterRow(title: "Define",
                             value: model.binding(for: \.browDefine),
                             range: 0...100,
                             onReset: { model.resetEffect(\.browDefine) })
            }

            SectionNote(text: model.faceCount > 0
                ? "Cosmetics keep the shading underneath them, so lips, cheeks and brows stay three-dimensional."
                : "No face has been detected, so there is nothing for makeup to color.")
        }
    }

    private func shadeGroup(_ heading: String,
                            _ selected: MakeupShade,
                            _ pick: @escaping (MakeupShade) -> Void,
                            title: String,
                            key: WritableKeyPath<Adjustments, Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading.uppercased())
                .font(Theme.Font.section)
                .tracking(0.6)
                .foregroundStyle(Theme.faint)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                      spacing: 6) {
                ForEach(MakeupShade.allCases) { shade in
                    ShadeChip(shade: shade, isActive: selected == shade) {
                        pick(shade)
                    }
                }
            }

            ParameterRow(title: title,
                         value: model.binding(for: key),
                         range: 0...100,
                         onReset: { model.resetEffect(key) })
                .padding(.top, 4)
        }
    }

    private var colorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterRow(title: model.s.exposure,
                         value: model.binding(for: \.exposure),
                         onReset: { model.resetEffect(\.exposure) })
            ParameterRow(title: model.s.contrast,
                         value: model.binding(for: \.contrast),
                         onReset: { model.resetEffect(\.contrast) })
            ParameterRow(title: model.s.blacks,
                         value: model.binding(for: \.blacks),
                         onReset: { model.resetEffect(\.blacks) })
            ParameterRow(title: model.s.whites,
                         value: model.binding(for: \.whites),
                         onReset: { model.resetEffect(\.whites) })
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

            ParameterRow(title: "Strength",
                         value: model.binding(for: \.lookStrength),
                         range: 0...100,
                         onReset: { model.resetEffect(\.lookStrength) })
            ParameterRow(title: "Grain",
                         value: model.binding(for: \.grain),
                         range: 0...100,
                         onReset: { model.resetEffect(\.grain) })

            SectionNote(text: "A grade is applied to the whole photo after Color & Light, so it reshapes the balance you already set.")
        }
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

    private var isModified: Bool { panel.isModified(model.adjustments) }

    private var reset: (() -> Void)? {
        switch panel.resetKind {
        case .nothing: return nil
        case .skin: return { model.resetGroup(.skin) }
        case .shape: return { model.resetGroup(.reshape) }
        case .eyes: return { model.resetEffects([\.teethWhiten, \.eyeBrighten, \.eyeSharpen]) }
        case .makeup: return { model.resetGroup(.makeup) }
        case .color: return { model.resetGroup(.colorLight) }
        case .looks: return { model.resetGroup(.look) }
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
                        .font(.system(size: 13, weight: isOpen ? .semibold : .medium))
                        .foregroundStyle(isOpen || hovering ? Theme.text : Theme.muted)

                    Spacer(minLength: 8)

                    if let reset {
                        Button(action: reset) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle(dip: 0.88))
                        .help(panel.resetHelp ?? model.s.resetGroupHelp)
                        .opacity(isModified ? 1 : 0)
                        .allowsHitTesting(isModified)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isOpen ? Theme.accent : Theme.faint)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .animation(Motion.smooth, value: isOpen)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(dip: 0.99))

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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presets: return "Presets"
        case .skin: return "Skin"
        case .shape: return "Shape"
        case .eyes: return "Eyes & Teeth"
        case .makeup: return "Makeup"
        case .color: return "Color & Light"
        case .looks: return "Looks"
        }
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
        }
    }

    var resetHelp: String? {
        self == .makeup ? L10n.shared.resetMakeupHelp : nil
    }

    func isModified(_ a: Adjustments) -> Bool {
        switch self {
        case .presets: return false
        case .skin:
            return a.smooth != 0 || a.texturePreserve != 0 || a.blemish != 0 || a.wrinkle != 0
                || a.skinToneEvens != 0 || a.darkCircles != 0 || a.skinBrighten != 0
        case .shape: return a.reshapeOnly != .zero
        case .eyes: return a.teethWhiten != 0 || a.eyeBrighten != 0 || a.eyeSharpen != 0
        case .makeup: return a.hasMakeup
        case .color: return a.colorLightOnly != .zero
        case .looks: return a.hasLook || a.grain != 0
        }
    }
}

/// The group a row's reset glyph clears.
enum PanelReset {
    case nothing, skin, shape, eyes, makeup, color, looks
}
