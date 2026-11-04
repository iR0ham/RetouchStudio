import SwiftUI

/// The horizontal bar that replaced the old icon rail. Tool selection lives in
/// the pill group at the leading edge, the document identity and the two
/// history steps sit in the middle, and the one action that leaves the app is
/// the chartreuse pill at the trailing edge.
struct TopBar: View {
    @ObservedObject var model: EditorModel
    @Namespace private var pill
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        HStack(spacing: 10) {
            toolGroup
                .padding(.leading, 6)

            Spacer(minLength: 16)

            documentLabel

            // In a right-to-left shell the past sits on the right, so the two
            // arrows swap their glyphs instead of being flipped as bitmaps.
            barButton(direction == .rightToLeft ? "arrow.uturn.forward" : "arrow.uturn.backward",
                      help: model.s.undoHelp,
                      enabled: model.canUndo) { model.undo() }
            barButton(direction == .rightToLeft ? "arrow.uturn.backward" : "arrow.uturn.forward",
                      help: model.s.redoHelp,
                      enabled: model.canRedo) { model.redo() }

            exportPill
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Metrics.bar)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.75)
                )
        )
    }

    // MARK: - Tools

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(ToolMode.allCases) { mode in
                toolPill(mode)
            }
        }
    }

    private func toolPill(_ mode: ToolMode) -> some View {
        let active = model.toolMode == mode

        return Button {
            model.toolMode = mode
        } label: {
            ZStack {
                // One background that travels between buttons instead of a
                // highlight fading in place: the eye follows the tool it just
                // picked.
                if active {
                    Capsule(style: .continuous)
                        .fill(Theme.bone)
                        .matchedGeometryEffect(id: "activeTool", in: pill)
                }

                Icon(name: mode.icon, size: 19, emphasised: active)
                    .foregroundStyle(active ? Theme.background : Theme.faint)
                    .scaleEffect(active ? 1.05 : 1)
            }
            .frame(width: 46, height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(dip: 0.93))
        .help(mode.shortcutKey.map { "\(mode.title)  ·  \($0)" } ?? mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.shortcutKey.map { $0 } ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Document

    /// The photo name and the unsaved marker. The window has no title bar of
    /// its own any more, so this is where the document identifies itself.
    private var documentLabel: some View {
        HStack(spacing: 6) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }

            Text(model.hasImage ? model.imageName : model.s.noImageOpen)
                .font(Theme.Font.face(size: 11.5, weight: .medium))
                .foregroundStyle(model.hasImage ? Theme.muted : Theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .trailing)

            Circle()
                .fill(Theme.warning)
                .frame(width: 5, height: 5)
                .opacity(model.hasUnsavedChanges ? 1 : 0)
                .animation(Motion.snappy, value: model.hasUnsavedChanges)
                .help(model.hasUnsavedChanges ? model.s.edited : "")
        }
        .animation(Motion.smooth, value: model.isBusy)
    }

    // MARK: - Actions

    private func barButton(_ icon: String,
                           help: String,
                           enabled: Bool = true,
                           active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: icon, size: 16, emphasised: true)
                .foregroundStyle(!enabled ? Theme.faint.opacity(0.5)
                                   : (active ? Theme.accent : Theme.muted))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Theme.accentSoft : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(dip: 0.9))
        .disabled(!enabled)
        .help(help)
    }

    private var exportPill: some View {
        Button {
            model.presentExportSheet()
        } label: {
            HStack(spacing: 6) {
                Icon(name: "arrow.down.to.line.compact", size: 14, emphasised: true)
                Text(model.s.export)
                    .font(Theme.Font.face(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(model.hasImage ? Theme.accent : Theme.inset)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(dip: 0.95))
        .disabled(!model.hasImage)
        .help(model.s.exportHelp)
        .animation(Motion.snappy, value: model.hasImage)
    }
}
