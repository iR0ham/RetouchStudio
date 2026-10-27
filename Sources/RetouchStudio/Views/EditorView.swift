import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarControls(model: model)
                .frame(width: 320)
            Divider()
            // The canvas always draws left-to-right: its geometry is pixel-based
            // (image position, compare fraction, face boxes). Letting RTL in
            // would mirror the composite while DragGesture coordinates stayed
            // unmirrored, which is what made the compare handle move backwards.
            CompareCanvas(model: model, isDropTarget: $isDropTarget)
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(minWidth: 1020, minHeight: 660)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showExportSheet) {
            ExportSheet(model: model)
        }
        .onChange(of: model.adjustments) { _, _ in
            model.schedulePreview()
        }
        .onAppear { model.refreshDefaultStatus() }
        .onChange(of: model.language) { _, _ in model.refreshDefaultStatus() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
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
                Label(model.s.reset, systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.hasImage || model.adjustments.isIdentity)
            .help(model.s.resetHelp)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.compareEnabled.toggle()
            } label: {
                Label(model.s.compare,
                      systemImage: model.compareEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help(model.s.compareHelp)

            Button {
                model.showFaceOverlay.toggle()
            } label: {
                Label(model.s.faceBox,
                      systemImage: model.showFaceOverlay ? "face.dashed.fill" : "face.dashed")
            }
            .disabled(!model.hasImage)
            .help(model.s.faceBoxHelp)
        }
    }
}

struct ExportSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.s.exportSection)
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(model.s.format)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker(model.s.format, selection: $model.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if model.exportFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.s.quality)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(model.exportQuality * 100))%")
                            .font(.system(size: 11))
                            .monospacedDigit()
                    }
                    Slider(value: $model.exportQuality, in: 0.4...1.0)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.s.originalSize(model.imageInfo))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(model.s.suggestedName(model.suggestedFileName()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button(model.s.cancel) { model.showExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(model.s.save) { model.saveExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .environment(\.layoutDirection, model.language.layoutDirection)
    }
}
