import SwiftUI

/// Settings sheet for the local models: what is installed, its licence and
/// size, a checksum check, and a download that starts only after the owner sees
/// the exact file list.
struct ModelManagerView: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ModelManager()
    @ObservedObject private var activity = ModelActivity.shared
    @State private var planningID: String?
    @State private var prompt: Prompt?

    private struct PendingDownload: Identifiable {
        let id = UUID()
        let row: AIModelRow
        let plan: AIModelPlan
        let again: Bool
    }

    private enum Prompt: Identifiable {
        case download(PendingDownload)
        case remove(AIModelRow)

        var id: String {
            switch self {
            case .download(let item): return "download-\(item.row.id)"
            case .remove(let row): return "remove-\(row.id)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if manager.loading && manager.rows.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(editor.s.modelsChecking)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 20)
                Spacer(minLength: 0)
            } else if let error = manager.helperError {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(manager.rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if manager.isDownloading { downloadBar }
            if let notice = manager.notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(22)
        .frame(width: 600, height: 600)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, editor.language.layoutDirection)
        .task { await manager.refresh() }
        .alert(item: $prompt) { item in
            switch item {
            case .download(let pending):
                return Alert(
                    title: Text(editor.s.modelsDownloadTitle(pending.row.name)),
                    message: Text(editor.s.modelsDownloadBody(
                        files: pending.plan.files.count,
                        size: sizeText(pending.plan.totalBytes),
                        license: pending.row.license)),
                    primaryButton: .default(Text(editor.s.modelsDownloadAction)) {
                        if pending.again {
                            Task {
                                await manager.remove(pending.row.id)
                                manager.startDownload(pending.plan, name: pending.row.name)
                            }
                        } else {
                            manager.startDownload(pending.plan, name: pending.row.name)
                        }
                    },
                    secondaryButton: .cancel(Text(editor.s.modelsCancel)))
            case .remove(let row):
                return Alert(
                    title: Text(editor.s.modelsRemoveTitle(row.name)),
                    message: Text(editor.s.modelsRemoveBody),
                    primaryButton: .destructive(Text(editor.s.modelsRemoveAction)) {
                        Task {
                            await manager.remove(row.id)
                            manager.notice = editor.s.modelsRemoved(row.name)
                        }
                    },
                    secondaryButton: .cancel(Text(editor.s.modelsCancel)))
            }
        }
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

    private func rowView(_ row: AIModelRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(Theme.Font.face(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    statusChip(row)
                }
                Text("\(editor.s.modelsTaskName(row.task)) · \(row.license) · \(sizeText(row.bytes))")
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                HStack(spacing: 8) {
                    Text(editor.s.modelsUsedFor(actionName(for: row)))
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.muted)
                    if activity.isRunning(row.id) { inUseChip }
                }
                lastUseLine(row)
                if manager.checkingID == row.id {
                    Text(editor.s.modelsChecking)
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.muted)
                } else if let verdict = manager.verdicts[row.id] {
                    switch verdict {
                    case .ok:
                        Text(editor.s.modelsVerified)
                            .font(Theme.Font.face(size: 10.5))
                            .foregroundStyle(Theme.positive)
                    case .failed(let file):
                        Text(editor.s.modelsVerifyFailed(file))
                            .font(Theme.Font.face(size: 10.5))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if manager.checkingID == row.id {
                    ProgressView().controlSize(.small)
                } else {
                    chipButton(editor.s.modelsVerify) {
                        Task { await manager.verify(row.id) }
                    }
                    .disabled(manager.isDownloading)
                }
                if row.installed {
                    chipButton(editor.s.modelsDownloadAgain) {
                        beginDownload(row, again: true)
                    }
                    .disabled(manager.isDownloading || planningID != nil || activity.isRunning(row.id))
                    chipButton(editor.s.modelsRemove) {
                        prompt = .remove(row)
                    }
                    .disabled(manager.isDownloading || activity.isRunning(row.id))
                } else {
                    if planningID == row.id {
                        ProgressView().controlSize(.small)
                    } else {
                        chipButton(editor.s.modelsDownload) {
                            beginDownload(row, again: false)
                        }
                        .disabled(manager.isDownloading || planningID != nil)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.panel)
        )
        .help(row.notes)
    }

    private func statusChip(_ row: AIModelRow) -> some View {
        Text(row.installed ? editor.s.modelsInstalled : editor.s.modelsMissing)
            .font(Theme.Font.face(size: 9.5, weight: .medium))
            .foregroundStyle(row.installed ? Theme.accentInk : Theme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(row.installed ? Theme.accent : Theme.inset)
            )
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
        .background(
            Capsule(style: .continuous)
                .fill(Theme.sky)
        )
    }

    @ViewBuilder
    private func lastUseLine(_ row: AIModelRow) -> some View {
        if row.installed {
            if let date = activity.lastUse(of: row.id) {
                Text(editor.s.modelsLastUsed(ago(date)))
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
            } else {
                Text(editor.s.modelsNeverUsed)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    /// The action that actually loads this model, in the name the editor uses.
    private func actionName(for row: AIModelRow) -> String {
        switch AIModelID(rawValue: row.id) {
        case .flux: return editor.s.aiRemoveObject
        case .migan: return editor.s.aiHealArea
        case .sam: return editor.s.aiMaskSnap
        case .swin: return editor.s.exportUpscale
        case nil: return editor.s.modelsTaskName(row.task)
        }
    }

    private func ago(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return editor.s.modelsJustNow }
        let minutes = seconds / 60
        if minutes < 60 { return editor.s.modelsMinutesAgo(minutes) }
        let hours = minutes / 60
        if hours < 24 { return editor.s.modelsHoursAgo(hours) }
        return editor.s.modelsDaysAgo(hours / 24)
    }

    private var downloadBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(editor.s.modelsDownloading(manager.percent))
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text("\(sizeText(manager.receivedBytes)) / \(sizeText(manager.totalBytes))")
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.muted)
                chipButton(editor.s.modelsCancel) { manager.cancelDownload() }
            }
            if manager.totalBytes > 0 {
                ProgressView(value: Double(manager.percent), total: 100)
                    .tint(Theme.accent)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.inset)
        )
    }

    private func beginDownload(_ row: AIModelRow, again: Bool) {
        planningID = row.id
        Task {
            defer { planningID = nil }
            do {
                let plan = try await manager.plan(for: row.id)
                prompt = .download(PendingDownload(row: row, plan: plan, again: again))
            } catch {
                manager.notice = error.localizedDescription
            }
        }
    }

    private func sizeText(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return editor.s.modelsSizeUnknown }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
