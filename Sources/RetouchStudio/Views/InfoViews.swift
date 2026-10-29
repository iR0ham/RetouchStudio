import AppKit
import SwiftUI

/// The small informational panels: About and Help. They are plain AppKit
/// windows hosting SwiftUI content, so they open from the app menu even when
/// the editor window is closed.
@MainActor
final class InfoWindows {

    static let shared = InfoWindows()

    private var windows: [String: NSWindow] = [:]

    func showAbout() {
        let s = L10n.current
        show(id: "about", title: s.aboutTitle, size: NSSize(width: 380, height: 470)) {
            AboutView()
        }
    }

    func showHelp() {
        let s = L10n.current
        show(id: "help", title: s.helpTitle, size: NSSize(width: 560, height: 640)) {
            HelpView()
        }
    }

    private func show<V: View>(id: String,
                               title: String,
                               size: NSSize,
                               @ViewBuilder content: () -> V) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Theme.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows[id] = window
    }
}

// MARK: - About

struct AboutView: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var version: String { info["CFBundleShortVersionString"] as? String ?? "2.1" }
    private var build: String { info["CFBundleVersion"] as? String ?? "1" }
    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)

            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

            Text(L10n.current.appName)
                .font(Theme.Font.face(size: 22, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 16)

            Text(L10n.current.aboutTagline)
                .font(Theme.Font.face(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.top, 3)

            Text("\(L10n.current.aboutVersion) \(version) (\(build))")
                .font(Theme.Font.value)
                .foregroundStyle(Theme.faint)
                .padding(.top, 10)

            Hairline()
                .padding(.horizontal, 34)
                .padding(.vertical, 18)

            VStack(spacing: 8) {
                infoRow(L10n.current.aboutDeveloper, L10n.current.aboutDeveloperName)
                infoRow(L10n.current.aboutCopyright,
                        "\(L10n.current.aboutCopyrightLine) · \(L10n.current.aboutRights)")
            }
            .padding(.horizontal, 34)

            Text(L10n.current.aboutEngine)
                .font(Theme.Font.face(size: 10.5))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 34)
                .padding(.top, 16)

            Spacer(minLength: 18)

            Button {
                NSApp.keyWindow?.performClose(nil)
            } label: {
                Text(L10n.current.closeButton)
                    .font(Theme.Font.button)
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 110, height: 32)
                    .background(Capsule(style: .continuous).fill(Theme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle(dip: 0.96))
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 22)
        }
        .frame(width: 380, height: 470)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.Font.face(size: 11))
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.Font.face(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Help

struct HelpView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                workflow
                shortcuts
            }
            .padding(26)
        }
        .frame(width: 560, height: 640)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.sky.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Icon(name: "sparkles", size: 17, emphasised: true)
                        .foregroundStyle(Theme.sky)
                }
                Text(L10n.current.helpTitle)
                    .font(Theme.Font.face(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(L10n.current.helpIntro)
                .font(Theme.Font.face(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workflow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.current.helpWorkflow)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(L10n.current.helpWorkflowSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(Theme.Font.face(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accentInk)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.accent))
                        Text(step)
                            .font(Theme.Font.face(size: 12))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.panel)
            )
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.current.helpShortcuts)
            VStack(spacing: 0) {
                ForEach(Array(L10n.current.helpShortcutRows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 10) {
                        Text(row.1)
                            .font(Theme.Font.face(size: 12))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 12)
                        Text(row.0)
                            .font(Theme.Font.value)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.inset)
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    if index < L10n.current.helpShortcutRows.count - 1 {
                        Hairline().padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.panel)
            )
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.section)
            .tracking(0.6)
            .foregroundStyle(Theme.faint)
    }
}
