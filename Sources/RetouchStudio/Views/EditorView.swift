import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            ToolRail(model: model)
            InspectorView(model: model)
            CompareCanvas(model: model, isDropTarget: $isDropTarget)
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.openImage()
            } label: {
                Label(model.s.open, systemImage: "folder")
            }
            .help(model.s.openHelp)

            Button {
                model.presentExportSheet()
            } label: {
                Label(model.s.export, systemImage: "square.and.arrow.down")
            }
            .disabled(!model.hasImage)
            .help(model.s.exportHelp)

            Button {
                model.resetAll()
            } label: {
                Label(model.s.reset, systemImage: "arrow.counterclockwise")
            }
            .disabled(!model.hasImage || model.adjustments.isIdentity)
            .help(model.s.resetHelp)
        }
    }
}

/// The narrow icon column. Tool selection lives here, and the two canvas
/// overlays sit at the bottom where they are always reachable.
private struct ToolRail: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 4) {
            logo
                .padding(.bottom, 10)

            ForEach(ToolMode.allCases) { mode in
                toolButton(mode)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .frame(width: Theme.Metrics.rail)
        .background(Theme.rail)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 30, height: 30)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.bone.opacity(0.16), lineWidth: 0.5)
                .frame(width: 30, height: 30)
            Image(systemName: "camera.aperture")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accentInk)
        }
    }

    private func toolButton(_ mode: ToolMode) -> some View {
        let active = model.toolMode == mode

        return Button {
            model.toolMode = mode
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(active ? Theme.accentBright : Theme.muted)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Theme.accentSoft : Color.clear)
                )
                .overlay(alignment: .leading) {
                    if active {
                        Capsule()
                            .fill(Theme.accentBright)
                            .frame(width: 2, height: 18)
                            .offset(x: -8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }
}

struct ExportSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.s.exportSection)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.s.format.uppercased())
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                formatPicker
            }

            if model.exportFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.s.quality.uppercased())
                            .font(Theme.Font.section)
                            .tracking(0.6)
                            .foregroundStyle(Theme.faint)
                        Spacer()
                        Text("\(Int((model.exportQuality * 100).rounded()))%")
                            .font(Theme.Font.value)
                            .foregroundStyle(Theme.muted)
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

            HStack(spacing: 8) {
                Spacer()
                Button {
                    model.showExportSheet = false
                } label: {
                    Text(model.s.cancel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(height: 28)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    model.saveExport()
                } label: {
                    Text(model.s.save)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .frame(height: 28)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.accent)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.bone.opacity(0.16), lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
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
                        .foregroundStyle(active ? Theme.accentBright : Theme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? Theme.accentSoft : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
    }
}
