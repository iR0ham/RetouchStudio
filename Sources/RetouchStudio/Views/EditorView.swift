import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: Theme.Metrics.gutter) {
            TopBar(model: model)

            HStack(spacing: Theme.Metrics.gutter) {
                ToolPanel(model: model)
                CompareCanvas(model: model, isDropTarget: $isDropTarget)
                InspectorView(model: model)
            }
        }
        .padding(.top, Theme.Metrics.topGutter)
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.bottom, Theme.Metrics.gutter)
        .frame(minWidth: 1120, minHeight: 700)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, model.language.layoutDirection)
        .sheet(isPresented: $model.showExportSheet) {
            ExportSheet(model: model)
                .environment(\.layoutDirection, model.language.layoutDirection)
        }
        .sheet(isPresented: $model.showSmartSheet) {
            SmartAnalyzeSheet(model: model)
                .environment(\.layoutDirection, model.language.layoutDirection)
        }
        .onChange(of: model.adjustments) { _, _ in
            model.schedulePreview()
        }
        .onChange(of: model.toolMode) { _, mode in
            if mode == .crop {
                model.beginCrop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.noteActivation()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            model.endPeek()
        }
        .onAppear {
            model.refreshDefaultStatus()
        }
    }
}

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var model: EditorModel

    /// 0 keeps the photo's own size; the rest downscale the longest edge.
    private static let longEdgeChoices: [Int] = [0, 4096, 2048, 1080]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Icon(name: "arrow.down.to.line.compact", size: 16, emphasised: true)
                    .foregroundStyle(Theme.accent)
                Text(model.s.exportSection)
                    .font(Theme.Font.face(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.s.format.uppercased())
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                formatPicker
            }
            .opacity(linesOnly ? 0.4 : 1)
            .disabled(linesOnly)

            if model.exportFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.s.quality.uppercased())
                            .font(Theme.Font.section)
                            .tracking(0.6)
                            .foregroundStyle(Theme.faint)
                        Spacer()
                        Text(Digits.percent(Int((model.exportQuality * 100).rounded())))
                            .font(Theme.Font.value)
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                            .animation(Motion.snappy, value: model.exportQuality)
                    }
                    BipolarSlider(value: $model.exportQuality, range: 0.4...1.0, step: 0.01)
                }
                .opacity(linesOnly ? 0.4 : 1)
                .disabled(linesOnly)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.s.exportLongEdge.uppercased())
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                HStack(spacing: 2) {
                    ForEach(Self.longEdgeChoices, id: \.self) { edge in
                        let active = model.exportLongEdge == edge
                        Button {
                            model.exportLongEdge = edge
                        } label: {
                            Text(edge == 0 ? model.s.exportOriginal : Digits.num(edge))
                                .font(Theme.Font.face(size: 11.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Theme.accentInk : Theme.muted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(active ? Theme.accent : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle(dip: 0.96))
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.background)
                )
            }

            if model.analysis.isEnabled {
                analysisSection
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.s.originalSize(model.imageInfo))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.muted)
                if model.exportLongEdge > 0, model.exportPixelText != model.imageInfo {
                    Text(model.s.exportSize(model.exportPixelText))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.muted)
                }
                Text(model.s.suggestedName(model.suggestedFileName()))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Hairline()

            HStack(spacing: 10) {
                Button {
                    model.showExportSheet = false
                } label: {
                    Text(model.s.cancel)
                        .font(Theme.Font.face(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(height: 36)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.inset)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    model.saveExport()
                } label: {
                    Text(model.s.save)
                        .font(Theme.Font.button)
                        .foregroundStyle(Theme.accentInk)
                        .frame(height: 36)
                        .padding(.horizontal, 22)
                        .background(
                            Capsule(style: .continuous).fill(Theme.accent)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle(dip: 0.96))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    /// Line-only exports are always PNG, so the format and quality controls
    /// have nothing to say while that mode is chosen.
    private var linesOnly: Bool {
        model.analysis.isEnabled && model.analysis.exportMode == .overlayOnly
    }

    /// The analysis export choices only appear once the overlay is on, so the
    /// sheet stays as short as it was before the tool existed.
    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.s.analysisExportSection.uppercased())
                .font(Theme.Font.section)
                .tracking(0.6)
                .foregroundStyle(Theme.faint)

            VStack(spacing: 2) {
                ForEach(AnalysisExportMode.allCases) { mode in
                    let active = model.analysis.exportMode == mode
                    Button {
                        model.analysis.exportMode = mode
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.s.analysisExportTitle(mode))
                                .font(Theme.Font.face(size: 11.5, weight: active ? .semibold : .regular))
                            Spacer(minLength: 6)
                            if active {
                                Icon(name: "checkmark", size: 10, emphasised: true)
                            }
                        }
                        .foregroundStyle(active ? Theme.accentBright : Theme.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? Theme.accentSoft : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle(dip: 0.97))
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.background)
            )

            if model.analysis.exportMode == .poster {
                ParameterRow(title: model.s.analysisMargin,
                             value: model.analysisMarginBinding,
                             range: 4...30)
            }
        }
    }

    private var formatPicker: some View {
        HStack(spacing: 2) {
            ForEach(ExportFormat.allCases) { format in
                let active = model.exportFormat == format
                Button {
                    model.exportFormat = format
                } label: {
                    Text(format.title)
                        .font(Theme.Font.face(size: 11.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.accentInk : Theme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Theme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(dip: 0.96))
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        .animation(Motion.snappy, value: model.exportFormat)
    }
}
