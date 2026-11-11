import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        // A drop anywhere on the shell opens the file. The canvas keeps the
        // highlight so the destination still reads as the stage.
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            load(provider)
            return true
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, model.language.layoutDirection)
        .sheet(isPresented: $model.showExportSheet) {
            ExportSheet(model: model)
                .environment(\.layoutDirection, model.language.layoutDirection)
        }
        .sheet(isPresented: $model.showBatchSheet) {
            BatchExportSheet(model: model)
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

    /// Finder hands the file over as URL data, but the provider is allowed to
    /// deliver a URL or a string instead, so all three are accepted. A browser
    /// drag is rejected: it has the URL shape but no file behind it.
    private func load(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let itemURL = item as? URL {
                url = itemURL
            } else if let string = item as? String {
                url = URL(string: string)
            } else {
                url = nil
            }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
            let isProject = url.pathExtension.lowercased() == RetouchProject.fileExtension
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            guard isProject || isImage else { return }
            DispatchQueue.main.async { model.requestOpen(url: url) }
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
                    .help(model.s.formatHelp)
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
                .help("\(model.s.quality) — \(model.s.sliderHint(.exportQuality))")
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
            .help(model.s.exportLongEdgeHelp)

            if model.exportEnlargementRequested, !linesOnly {
                upscaleSection
            }

            if model.analysis.isEnabled {
                analysisSection
            }

            watermarkSection

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

                if model.isExporting {
                    // The render is already running; the only useful action is
                    // to stop it. The job checks cancellation before writing, so
                    // nothing lands on disk.
                    Button {
                        model.cancelExport()
                    } label: {
                        Text(model.s.cancelExport)
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
                } else {
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
        }
        .padding(22)
        .frame(width: 420)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    /// Line-only exports are always PNG, so the format and quality controls
    /// have nothing to say while that mode is chosen. Without a face the export
    /// is a normal photo, so the ordinary format and quality rows stay.
    private var linesOnly: Bool {
        model.analysis.isEnabled && model.analysis.exportMode == .overlayOnly
            && !model.faces.isEmpty
    }

    /// The upscaler only has a job when the chosen edge is above the photo's
    /// own size. When the photo is past its 40 MP ceiling the row stays
    /// visible but off, with the reason in place of the description.
    private var upscaleSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.s.exportUpscale)
                    .font(Theme.Font.face(size: 12.5, weight: .medium))
                    .foregroundStyle(model.exportUpscaleAvailable ? Theme.text : Theme.faint)
                Text(model.exportUpscaleAvailable
                     ? model.s.exportUpscaleDetail + " "
                        + model.s.exportUpscaleEstimate(model.exportUpscaleEstimate)
                     : model.s.exportUpscaleTooLarge)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $model.exportAIUpscale)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .focusable(false)
                .disabled(!model.exportUpscaleAvailable)
                .accessibilityLabel(model.s.exportUpscale)
                .help(model.s.exportUpscaleDetail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.background)
        )
    }

    /// The analysis export choices only appear once the overlay is on, so the
    /// sheet stays as short as it was before the tool existed.
    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.s.analysisExportSection.uppercased())
                .font(Theme.Font.section)
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
                .help(model.s.analysisExportSectionHelp)

            if model.faces.isEmpty {
                Text(model.s.analysisNeedsFace)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            .disabled(model.faces.isEmpty)
            .opacity(model.faces.isEmpty ? 0.5 : 1)

            if model.analysis.exportMode == .poster, !model.faces.isEmpty {
                ParameterRow(title: model.s.analysisMargin,
                             hint: model.s.sliderHint(.analysisMargin),
                             value: model.analysisMarginBinding,
                             range: 4...30)
            }
        }
    }

    /// A signature for saved copies. The editor preview stays clean, so the
    /// note says so and the controls appear only once the switch is on.
    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.s.watermarkSection.uppercased())
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                    .help(model.s.watermarkNote)
                Spacer()
                Toggle("", isOn: $model.watermark.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .focusable(false)
                    .accessibilityLabel(model.s.watermarkSection)
            }

            if model.watermark.enabled {
                TextField(model.s.watermarkTextPlaceholder, text: $model.watermark.text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.face(size: 12))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.background)
                    )

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4),
                                         count: 3),
                          spacing: 4) {
                    ForEach(WatermarkSettings.Position.allCases) { position in
                        PresetChip(title: model.s.watermarkPosition(position),
                                   isActive: model.watermark.position == position) {
                            model.watermark.position = position
                        }
                    }
                }

                ParameterRow(title: model.s.watermarkOpacity,
                             hint: model.s.sliderHint(.watermarkOpacity),
                             value: Binding(get: { model.watermark.opacity },
                                            set: { model.watermark.opacity = $0 }),
                             range: 0.05...1,
                             onReset: { model.watermark.opacity = 0.65 })
                ParameterRow(title: model.s.watermarkSize,
                             hint: model.s.sliderHint(.watermarkSize),
                             value: Binding(get: { model.watermark.sizePercent },
                                            set: { model.watermark.sizePercent = $0 }),
                             range: 1...10,
                             onReset: { model.watermark.sizePercent = 3 })

                Text(model.s.watermarkNote)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(linesOnly ? 0.4 : 1)
        .disabled(linesOnly)
        .animation(Motion.snappy, value: model.watermark.enabled)
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

// MARK: - Batch

struct BatchExportSheet: View {
    @ObservedObject var model: EditorModel

    private var progress: Double {
        model.batchTotal > 0
            ? Double(model.batchCompleted) / Double(model.batchTotal)
            : 0
    }

    /// Which file the batch is on: `batchCompleted` counts finished files.
    private var currentIndex: Int {
        min(model.batchCompleted + 1, model.batchTotal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Icon(name: "photo.on.rectangle.angled", size: 16, emphasised: true)
                    .foregroundStyle(Theme.accent)
                Text(model.s.batchSheetTitle)
                    .font(Theme.Font.face(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(model.s.batchSelected(model.batchTotal))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.faint)
            }

            if model.isBatchRunning || model.batchHasReport {
                progressSection
            } else {
                optionsSection
            }

            Hairline()

            HStack(spacing: 10) {
                if model.isBatchRunning {
                    secondaryButton(model.s.cancel) { model.cancelBatchExport() }
                } else {
                    secondaryButton(model.batchHasReport ? model.s.batchDone : model.s.cancel) {
                        model.dismissBatchSheet()
                    }
                }

                Spacer()

                if !model.isBatchRunning && !model.batchHasReport {
                    primaryButton(model.s.batchStart) { model.startBatchExport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private var optionsSection: some View {
        VStack(spacing: 2) {
            optionRow(model.s.batchIncludeStamps,
                      detail: model.s.batchIncludeStampsDetail,
                      isOn: $model.batchIncludeStamps)
            optionRow(model.s.batchIncludeAnalysis,
                      detail: model.s.batchIncludeAnalysisDetail,
                      isOn: $model.batchIncludeAnalysis)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.background)
        )
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isBatchRunning {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                HStack {
                    Text(model.s.batchProgress(currentIndex, model.batchTotal))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Text(Digits.percent(Int((progress * 100).rounded())))
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: progress)
                }
            } else {
                Text(model.s.statusText(.batchFinished(saved: model.batchSavedCount,
                                                       total: model.batchTotal,
                                                       cropsSkipped: model.batchSkippedCrops)))
                    .font(Theme.Font.face(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func optionRow(_ title: String, detail: String,
                           isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.face(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .focusable(false)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func secondaryButton(_ title: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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
    }

    private func primaryButton(_ title: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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
    }
}
