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
        .sheet(isPresented: $model.showExportSheet) {
            ExportSheet(model: model)
        }
        .onChange(of: model.adjustments) { _, _ in
            model.schedulePreview()
        }
        .onChange(of: model.toolMode) { _, mode in
            if mode == .crop {
                model.beginCrop()
            }
        }
        .onAppear { model.refreshDefaultStatus() }
    }
}

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(model.s.exportSection)
                    .font(.system(size: 15, weight: .semibold))
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

            if model.exportFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.s.quality.uppercased())
                            .font(Theme.Font.section)
                            .tracking(0.6)
                            .foregroundStyle(Theme.faint)
                        Spacer()
                        Text("\(Int((model.exportQuality * 100).rounded()))%")
                            .font(Theme.Font.value)
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                            .animation(Motion.snappy, value: model.exportQuality)
                    }
                    BipolarSlider(value: $model.exportQuality, range: 0.4...1.0, step: 0.01)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.s.originalSize(model.imageInfo))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.muted)
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
                        .font(.system(size: 12.5, weight: .medium))
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

    private var formatPicker: some View {
        HStack(spacing: 2) {
            ForEach(ExportFormat.allCases) { format in
                let active = model.exportFormat == format
                Button {
                    model.exportFormat = format
                } label: {
                    Text(format.title)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
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
