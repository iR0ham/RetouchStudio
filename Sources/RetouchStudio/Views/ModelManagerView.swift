import SwiftUI

/// Settings sheet for the local models: catalog entries, installed versions,
/// the active version, verification, update/rollback, disk use, and a download
/// that starts only after the owner sees the version, size, licences, source
/// and checksum.
struct ModelManagerView: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ModelManager()
    @ObservedObject private var activity = ModelActivity.shared
    @ObservedObject private var runtime = AIRuntimeInstaller.shared
    @State private var prompt: Prompt?

    private enum Prompt: Identifiable {
        case install(ModelCatalogEntry)
        case remove(ModelRecord, String)
        case removeAll(ModelRecord)
        case migrate(ModelRecord)
        case runtime(AIRuntime.Package)

        var id: String {
            switch self {
            case .install(let entry): return "install-\(entry.id)-\(entry.version)"
            case .remove(let record, let version): return "remove-\(record.id)-\(version)"
            case .removeAll(let record): return "remove-all-\(record.id)"
            case .migrate(let record): return "migrate-\(record.id)"
            case .runtime(let package): return "runtime-\(package.version)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if showsRuntimeCard { runtimeCard }
            capabilitySection
            diskLine

            if manager.loading && manager.records.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(editor.s.modelsChecking)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 20)
                Spacer(minLength: 0)
            } else if let error = manager.storeError, !runtimeNeedsSetup {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(manager.records) { record in
                            rowView(record)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if manager.isDownloading { installBar }
            if let notice = manager.notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(22)
        .frame(width: 620, height: 620)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, editor.language.layoutDirection)
        .task {
            await manager.refresh()
        }
        .onChange(of: runtime.phase) { _, phase in
            if phase == .ready {
                Task { await manager.refresh() }
            }
        }
        .alert(item: $prompt) { item in
            switch item {
            case .install(let entry):
                return Alert(
                    title: Text(editor.s.modelsConsentTitle(entry.name, entry.version)),
                    message: Text(editor.s.modelsConsentBody(
                        files: entry.files.count,
                        size: sizeText(entry.sizeBytes),
                        codeLicense: entry.codeLicense,
                        weightsLicense: entry.weightsLicense,
                        host: sourceHost(entry) ?? "—",
                        sha: String((entry.sha256 ?? "").prefix(16)))),
                    primaryButton: .default(Text(editor.s.modelsDownloadAction)) {
                        manager.install(entry)
                    },
                    secondaryButton: .cancel(Text(editor.s.modelsCancel)))
            case .remove(let record, let version):
                return Alert(
                    title: Text(editor.s.modelsRemoveTitle(record.entry.name)),
                    message: Text("\(editor.s.modelsVersionLabel(version))\n" + editor.s.modelsRemoveBody),
                    primaryButton: .destructive(Text(editor.s.modelsRemoveAction)) {
                        Task { await manager.remove(record, version: version) }
                    },
                    secondaryButton: .cancel(Text(editor.s.modelsCancel)))
            case .removeAll(let record):
                return Alert(
                    title: Text(editor.s.modelsRemoveTitle(record.entry.name)),
                    message: Text(editor.s.modelsRemoveBody),
                    primaryButton: .destructive(Text(editor.s.modelsRemoveAction)) {
                        Task { await manager.removeAll(record) }
                    },
                    secondaryButton: .cancel(Text(editor.s.modelsCancel)))
            case .migrate(let record):
                return Alert(
                    title: Text(editor.s.modelsAdoptTitle(record.entry.name)),
                    message: Text(editor.s.modelsAdoptBody(
                        sizeText(manager.legacyBytes[record.id]))),
                    primaryButton: .default(Text(editor.s.modelsAdopt)) {
                        manager.migrateLegacy(record)
                    },
                    secondaryButton: .cancel(Text(editor.s.modelsCancel)))
            case .runtime(let package):
                return Alert(
                    title: Text(editor.s.aiRuntimeDownloadTitle),
                    message: Text(editor.s.aiRuntimeDownloadBody(
                        file: package.fileName,
                        size: sizeText(Int(package.bytes)),
                        hash: package.hashPrefix)),
                    primaryButton: .default(Text(editor.s.modelsDownloadAction)) {
                        runtime.install(package)
                    },
                    secondaryButton: .cancel(Text(editor.s.modelsCancel)) {
                        runtime.declineConsent()
                    })
            }
        }
    }

    private var showsRuntimeCard: Bool {
        AIRuntime.package != nil && AIWorker.bundledRoot == nil
    }

    private var runtimeNeedsSetup: Bool {
        showsRuntimeCard && runtime.phase != .ready
    }

    private var runtimeReady: Bool {
        runtime.phase == .ready
    }

    private var runtimeDownloading: Bool {
        if case .downloading = runtime.phase { return true }
        return false
    }

    private var busy: Bool {
        manager.isDownloading || runtime.isBusy || manager.verifyingKey != nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(editor.s.modelsTitle)
                    .font(Theme.Font.panelTitle)
                    .foregroundStyle(Theme.text)
                Spacer()
                chipButton(editor.s.modelsClose) { dismiss() }
            }
            Text(editor.s.modelsOfflineNote)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diskLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.faint)
            Text(editor.s.modelsDiskUsage(
                used: sizeText(manager.diskUsage),
                free: manager.availableDisk.map { sizeText($0) } ?? editor.s.modelsSizeUnknown))
                .font(Theme.Font.face(size: 10.5))
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
    }

    /// The worker's own answer, not a UI table. Each state carries the reason
    /// the worker recorded: a blocked one prints it under its chip, the others
    /// keep it in the tooltip. Nothing here guesses support.
    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(editor.s.capabilitiesTitle)
                    .font(Theme.Font.section)
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 8)
                if let capabilities = manager.capabilities {
                    Text(editor.s.capabilityProvider(capabilities.platform,
                                                     capabilities.provider))
                        .font(Theme.Font.face(size: 10))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let capabilities = manager.capabilities {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                        GridItem(.flexible(), spacing: 8)],
                              spacing: 4) {
                        ForEach(capabilities.capabilities) { capability in
                            capabilityRow(capability)
                        }
                    }
                }
                .frame(maxHeight: 130)
            } else {
                Text(manager.capabilityNote ?? editor.s.modelsChecking)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func capabilityRow(_ capability: AICapability) -> some View {
        let title: String
        var fill = Theme.inset
        var ink = Theme.muted
        switch capability.state {
        case .supported:
            title = editor.s.capabilityReady
            fill = Theme.accent
            ink = Theme.accentInk
        case .requiresModel:
            title = editor.s.capabilityNeedsModel
            fill = Theme.sky
            ink = Theme.skyInk
        case .blocked:
            title = editor.s.capabilityBlocked
            ink = Theme.warning
        case .unsupported:
            title = editor.s.capabilityUnavailable
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(capabilityTitle(capability))
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(title)
                    .font(Theme.Font.face(size: 9, weight: .medium))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(fill))
            }
            if capability.state == .blocked, let reason = capability.reason {
                Text(editor.s.capabilityWaitingFor(reason))
                    .font(Theme.Font.face(size: 9))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(capability.reason ?? capability.evidence ?? capability.id)
    }

    private func capabilityTitle(_ capability: AICapability) -> String {
        capability.id.split(separator: ".").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " · ")
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(editor.s.aiRuntimeTitle)
                    .font(Theme.Font.face(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(runtimeReady
                     ? editor.s.aiRuntimeInstalledChip
                     : editor.s.aiRuntimeMissingChip)
                    .font(Theme.Font.face(size: 9.5, weight: .medium))
                    .foregroundStyle(runtimeReady ? Theme.accentInk : Theme.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(runtimeReady ? Theme.accent : Theme.inset))
                Spacer(minLength: 8)
                if !runtime.isBusy && !runtimeReady,
                   let package = runtime.package {
                    chipButton(editor.s.aiRuntimeInstall) {
                        if runtime.requestConsent() { prompt = .runtime(package) }
                    }
                    .disabled(busy)
                }
            }
            if runtimeReady {
                Text(editor.s.aiRuntimeInstalledNote)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.positive)
            } else {
                Text(editor.s.aiRuntimeBody)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if runtime.isBusy { runtimeBar }
                if case .failed(let failure) = runtime.phase {
                    Text(failure.message)
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.panel)
        )
    }

    private var runtimeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(runtimeLabel)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if runtimeDownloading {
                    Text("\(sizeText(Int(runtime.received))) / \(sizeText(Int(runtime.total)))")
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.muted)
                    chipButton(editor.s.modelsCancel) { runtime.cancel() }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if runtimeDownloading && runtime.total > 0 {
                ProgressView(value: Double(runtime.percent), total: 100)
                    .tint(Theme.accent)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
    }

    private var runtimeLabel: String {
        switch runtime.phase {
        case .downloading: return editor.s.aiRuntimeDownloading
        case .verifying: return editor.s.aiRuntimeVerifying
        case .installing: return editor.s.aiRuntimeInstalling
        default: return ""
        }
    }

    // MARK: - Rows

    private func rowView(_ record: ModelRecord) -> some View {
        let entry = record.entry
        let runState = ModelRunState.resolve(weightsInstalled: !record.versions.isEmpty,
                                             helperCanRun: AIWorker.isInstalled)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(Theme.Font.face(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                statusChip(record)
                if activity.isRunning(record.id) { inUseChip }
                Spacer(minLength: 8)
                actionButton(record)
            }
            Text("\(capabilityLabel(entry)) · \(editor.s.modelsVersionLabel(entry.version)) · "
                 + "\(sizeText(entry.sizeBytes)) · \(entry.weightsLicense)")
                .font(Theme.Font.face(size: 10.5))
                .foregroundStyle(Theme.faint)
            Text(sourceLine(entry))
                .font(Theme.Font.face(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            // Weights on disk and a helper that can run them are two facts.
            // The row states the second when it is missing instead of letting
            // "Installed" and "Active" imply a runnable model.
            if runState == .installedNotRunnable {
                Text(editor.s.modelsInstalledNoRuntimeNote)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .unverifiable(let reason) = record.availability {
                Text(editor.s.modelsUnverifiable(reason))
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if record.availability == .unsupportedPlatform {
                Text(editor.s.modelsUnavailablePlatform)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.warning)
            }

            ForEach(record.versions) { version in
                versionRow(record, version: version)
            }
            if let legacy = manager.legacyBytes[record.id] {
                HStack(spacing: 8) {
                    Text(editor.s.modelsLegacyFound(sizeText(legacy)))
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    chipButton(editor.s.modelsAdopt) { prompt = .migrate(record) }
                        .disabled(busy || !record.isVerifiable
                                  || !entry.supports(platform: ModelPlatform.current))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.panel)
        )
        .help(entry.notes)
    }

    private func versionRow(_ record: ModelRecord, version: ModelVersionState) -> some View {
        let key = manager.key(record.id, version.version)
        let installed = record.catalogVersionInstalled
        let entry = record.entry
        return HStack(spacing: 8) {
            Text(editor.s.modelsVersionLabel(version.version))
                .font(Theme.Font.face(size: 10.5, weight: .medium))
                .foregroundStyle(version.active ? Theme.text : Theme.muted)
            if version.active {
                Text(editor.s.modelsActiveChip)
                    .font(Theme.Font.face(size: 9, weight: .medium))
                    .foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accent))
                    .help(editor.s.modelsActiveChipHint)
            }
            if !version.manifestOK {
                Text(editor.s.modelsUnverified("manifest"))
                    .font(Theme.Font.face(size: 9.5))
                    .foregroundStyle(Theme.warning)
            }
            if let verdict = manager.verdicts[key] {
                switch verdict {
                case .ok:
                    Text(editor.s.modelsVerified)
                        .font(Theme.Font.face(size: 9.5))
                        .foregroundStyle(Theme.positive)
                case .failed(let detail):
                    Text(detail)
                        .font(Theme.Font.face(size: 9.5))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if manager.verifyingKey == key {
                ProgressView().controlSize(.small)
            } else {
                chipButton(editor.s.modelsVerify) {
                    Task { await manager.verify(record, version: version.version) }
                }
                .disabled(busy || manager.install != nil)
            }
            if !version.active {
                chipButton(editor.s.modelsUseVersion) {
                    Task { await manager.activate(record, version: version.version) }
                }
                .disabled(busy || !record.isVerifiable)
                .help(editor.s.modelsUseVersion)
            }
            chipButton(editor.s.modelsRemove) {
                prompt = record.versions.count > 1
                    ? .remove(record, version.version)
                    : .removeAll(record)
            }
            .disabled(busy || activity.isRunning(record.id))
        }
        .padding(.leading, 2)
    }

    private func actionButton(_ record: ModelRecord) -> some View {
        let entry = record.entry
        return Group {
            switch record.availability {
            case .ready:
                if !record.catalogVersionInstalled {
                    chipButton(record.versions.isEmpty
                               ? editor.s.modelsInstallVersion
                               : editor.s.modelsUpdate) {
                        prompt = .install(entry)
                    }
                    .disabled(busy || activity.isRunning(record.id))
                } else if record.activeVersion == nil {
                    chipButton(editor.s.modelsUseVersion) {
                        Task { await manager.activate(record, version: entry.version) }
                    }
                    .disabled(busy)
                }
            case .unverifiable, .unsupportedPlatform, .notInstalled:
                EmptyView()
            }
        }
    }

    private func statusChip(_ record: ModelRecord) -> some View {
        let text: String
        var fill = Theme.inset
        var ink = Theme.muted
        switch record.availability {
        case .unverifiable:
            text = editor.s.modelsMissing
            fill = Theme.inset
            ink = Theme.warning
        case .unsupportedPlatform:
            text = editor.s.modelsUnavailablePlatform
            ink = Theme.warning
        case .ready, .notInstalled:
            let runState = ModelRunState.resolve(
                weightsInstalled: !record.versions.isEmpty,
                helperCanRun: AIWorker.isInstalled)
            switch runState {
            case .installedNotRunnable:
                text = editor.s.modelsInstalledNoRuntime
                ink = Theme.warning
            case .runnable:
                if record.activeVersion != nil {
                    text = editor.s.modelsInstalled
                    fill = Theme.accent
                    ink = Theme.accentInk
                } else {
                    text = editor.s.modelsInstalled
                }
            case .missing:
                text = editor.s.modelsMissing
            }
        }
        return Text(text)
            .font(Theme.Font.face(size: 9.5, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(fill))
    }

    private var inUseChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.skyInk)
                .frame(width: 5, height: 5)
            Text(editor.s.modelsInUse)
                .font(Theme.Font.face(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.skyInk)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(Theme.sky))
    }

    private var installBar: some View {
        let state = manager.install
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(state.map { "\($0.name) · \(editor.s.modelsVersionLabel($0.version))" }
                     ?? editor.s.modelsDownloadingUnknown)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let state {
                    Text(state.indeterminate
                         ? sizeText(state.receivedBytes)
                         : "\(sizeText(state.receivedBytes)) / \(sizeText(state.totalBytes))")
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.muted)
                }
                chipButton(editor.s.modelsCancel) { manager.cancelInstall() }
            }
            if let state, !state.indeterminate {
                ProgressView(value: Double(state.percent), total: 100)
                    .tint(Theme.accent)
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.inset)
        )
    }

    // MARK: - Labels

    private func capabilityLabel(_ entry: ModelCatalogEntry) -> String {
        editor.s.modelsCapabilityLabel(entry.capabilities)
    }

    private func sourceLine(_ entry: ModelCatalogEntry) -> String {
        let host = sourceHost(entry) ?? "—"
        let sha = String((entry.sha256 ?? "").prefix(16))
        return "\(host) · \(entry.codeLicense) / \(entry.weightsLicense) · SHA-256 \(sha)…"
    }

    private func sourceHost(_ entry: ModelCatalogEntry) -> String? {
        URL(string: entry.sourceUrl)?.host
    }

    private func sizeText(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return editor.s.modelsSizeUnknown }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func sizeText(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return editor.s.modelsSizeUnknown }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.face(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(height: 26)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Theme.inset)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(dip: 0.95))
        .help(title)
    }
}
