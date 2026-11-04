import AppKit
import SwiftUI

/// Handles the two things SwiftUI's scene cannot: files opened from Finder or
/// the Open With menu, and the quit prompt for unexported adjustments.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    /// Set by the window bridge; reopens the editor scene after SwiftUI tears
    /// the window down while routing an open event.
    var openEditorWindow: (() -> Void)?
    private var pendingURL: URL?
    private var restoringWindow = false

    func attach(model: EditorModel) {
        self.model = model
        // Finder can deliver the open event before the window appears, so an
        // early URL waits here until the model exists.
        if let pendingURL {
            self.pendingURL = nil
            model.requestOpen(url: pendingURL)
            return
        }
        // After the window is on screen, so the alert has something to be modal
        // against. A plain launch is the one place recovery belongs: the owner
        // asked for the last session back, not for a new photo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak model] in
            model?.offerRecoveryIfNeeded()
        }
    }

    /// SwiftUI routes external file events through its own app delegate and
    /// closes the only window on the way. Loading happens here and the window
    /// is put back, so a double-click in Finder keeps the editor on screen.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        if let model {
            model.requestOpen(url: url)
        } else {
            pendingURL = url
        }
        restoringWindow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.restoringWindow else { return }
            self.restoringWindow = false
            if !NSApp.windows.contains(where: { $0.isVisible }) {
                self.openEditorWindow?()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Termination caused by the window teardown above, not by the user.
        if restoringWindow { return .terminateCancel }
        guard let model, model.hasUnsavedChanges else { return .terminateNow }
        guard model.confirmDiscardIfNeeded() else { return .terminateCancel }
        // The owner chose to discard, so the next launch must not offer the
        // recovery copy back.
        model.discardUnsavedChanges()
        return .terminateNow
    }
}

/// SwiftUI keeps its window delegate private, so this proxy intercepts the
/// close before AppKit removes the window. Otherwise the prompt would only show
/// up during the termination that follows, leaving a windowless app when the
/// user cancels.
@MainActor
final class EditorWindowDelegate: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private weak var forwarding: NSWindowDelegate?

    init(model: EditorModel, forwarding: NSWindowDelegate?) {
        self.model = model
        self.forwarding = forwarding
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.confirmDiscardIfNeeded() else { return false }
        // The close was approved, so the later termination must not ask again.
        model.discardUnsavedChanges()
        return true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwarding?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if forwarding?.responds(to: aSelector) == true { return forwarding }
        return super.forwardingTarget(for: aSelector)
    }
}

private struct WindowBridge: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    let appDelegate: AppDelegate

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HookView {
        let openWindow = context.environment.openWindow
        appDelegate.openEditorWindow = { openWindow(id: "editor") }
        let view = HookView()
        view.onWindow = { [weak model] window in
            guard let model else { return }
            let delegate = EditorWindowDelegate(model: model, forwarding: window.delegate)
            context.coordinator.retained = delegate
            window.delegate = delegate
            Self.sync(model, to: window)
        }
        return view
    }

    func updateNSView(_ nsView: HookView, context: Context) {
        guard let window = nsView.window else { return }
        Self.sync(model, to: window)
    }

    /// The window has no title bar of its own: the app draws its own bar in the
    /// content area, so the shell colour, the hidden title and the drag
    /// behaviour all have to be set here. The photo name still goes into
    /// `window.title` — that is what the switcher and Mission Control show.
    private static func sync(_ model: EditorModel, to window: NSWindow) {
        // The keyboard monitor uses this to tell the editor apart from the
        // Settings and About windows, which share the app's event stream.
        window.identifier = NSUserInterfaceItemIdentifier("editor")
        window.title = model.windowTitle
        window.isDocumentEdited = model.hasUnsavedChanges
        window.representedURL = model.imageURL

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.background)
        // Window-background dragging has to stay off: it takes the mouse-down
        // before SwiftUI's canvas gestures see it, so panning and the
        // before/after handle stop responding. The titlebar strip above the
        // toolbar still moves the window.
        window.isMovableByWindowBackground = false
        window.titlebarSeparatorStyle = .none
    }

    final class Coordinator {
        var retained: EditorWindowDelegate?
    }

    final class HookView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

@main
struct RetouchStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    init() {
        // Headless engine check (no UI) for verifying the processing pipeline.
        SelfCheck.runIfRequested()
        // Also behaves like a normal app when launched from a terminal binary.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // A single Window: opening a file from Finder should load it into the
        // editor, not spawn a second window sharing the same model.
        Window(model.s.appName, id: "editor") {
            EditorView(model: model)
                .background(WindowBridge(model: model, appDelegate: appDelegate))
                .onAppear { appDelegate.attach(model: model) }
                // A fallback for SwiftUI versions that route the open event to
                // the scene instead of the app delegate.
                .onOpenURL { url in model.requestOpen(url: url) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.s.aboutTitle) { InfoWindows.shared.showAbout() }
                Divider()
                Menu(model.s.languageMenu) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Button {
                            model.language = language
                            InfoWindows.shared.relocaliseOpenPanels()
                        } label: {
                            if model.language == language {
                                Label(language.title, systemImage: "checkmark")
                            } else {
                                Text(language.title)
                            }
                        }
                    }
                }
            }
            CommandGroup(replacing: .help) {
                // macOS reserves ⌘? for the Help menu's own search field, so
                // this item is reachable from the menu only.
                Button(model.s.helpTitle) { InfoWindows.shared.showHelp() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.s.undoMenu) { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button(model.s.redoMenu) { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button(model.s.openMenu) { model.openImage() }
                    .keyboardShortcut("o")
                Button(model.s.openProjectMenu) { model.openProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu(model.s.openRecentMenu) {
                    if model.recents.entries.isEmpty {
                        Text(model.s.openRecentEmpty)
                    } else {
                        ForEach(model.recents.entries) { entry in
                            Button(entry.name) { model.openRecent(entry) }
                        }
                        Divider()
                        Button(model.s.clearRecentMenu) { model.recents.clear() }
                    }
                }
            }
            CommandGroup(after: .newItem) {
                // A single Window scene does not ship the standard Close item.
                Button(model.s.closeWindow) { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
            CommandGroup(replacing: .saveItem) {
                Button(model.s.saveProjectMenu) { model.saveProject() }
                    .keyboardShortcut("s")
                    .disabled(!model.hasImage)
                Button(model.s.saveProjectAsMenu) { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.hasImage)
                Divider()
                Button(model.s.exportMenu) { model.presentExportSheet() }
                    .keyboardShortcut("e")
                    .disabled(!model.hasImage)
                Button(model.s.batchExportMenu) { model.batchExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.hasImage || model.isBusy)
            }
            CommandMenu(model.s.retouchMenu) {
                Button(model.s.smartAnalyze) { model.smartAnalyze() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!model.canSmartAnalyze)
                Divider()
                Button(model.s.resetMenu) { model.resetAll() }
                    .keyboardShortcut("r")
                    .disabled(!model.hasImage || model.isDocumentPristine)
                Divider()
                Toggle(model.s.showCompareMenu, isOn: $model.compareEnabled)
                Toggle(model.s.showFaceOverlayMenu, isOn: $model.showFaceOverlay)
            }
            CommandGroup(after: .toolbar) {
                Button(model.s.zoomInMenu) { model.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!model.hasImage || model.zoom >= model.effectiveMaxZoom - 0.001)
                Button(model.s.zoomOutMenu) { model.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!model.hasImage || model.zoom <= 1.0001)
                Button(model.s.fitMenu) { model.resetView() }
                    .keyboardShortcut("0")
                    .disabled(!model.hasImage || model.zoom <= 1.0001)
            }
        }

        // ⌘, — the standard preferences window, using the app's own shell.
        Settings {
            SettingsView(model: model)
        }
    }
}
